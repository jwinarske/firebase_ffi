// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// App Check: attesting that a request comes from this app.
//
// The token is not consumed here. Once a provider factory is installed, the
// desktop SDK's Firestore, Database, Storage and Functions each pick the token
// up through the app's function registry and attach it themselves -- which is
// why installing a provider is most of what this file does.
//
// Two providers, because desktop has no third option. The SDK ships App Attest,
// DeviceCheck and Play Integrity as stubs off iOS and Android, and none of them
// would mean anything on an embedded board anyway:
//
//   Debug   -- the SDK's own, exchanging a token registered in the console for
//              a real one. For development.
//   Custom  -- the token comes from Dart. This is the one that matters here: a
//              device that attests by some means of its own (a TPM, a signed
//              provisioning record, a vendor service) has nowhere else to put
//              the result.

#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "dart_api_dl.h"
#include "firebase/app.h"
#include "firebase/app_check.h"
#include "firebase/app_check/debug_provider.h"
#include "firebase_bridge.h"

namespace {

using ::firebase::app_check::AppCheck;
using ::firebase::app_check::AppCheckError;
using ::firebase::app_check::AppCheckListener;
using ::firebase::app_check::AppCheckProvider;
using ::firebase::app_check::AppCheckProviderFactory;
using ::firebase::app_check::AppCheckToken;
using ::firebase::app_check::DebugAppCheckProviderFactory;

using TokenCompletion =
    std::function<void(AppCheckToken, int, const std::string&)>;

std::mutex g_mutex;

// The key an app goes by here: empty for the default app, else the name
// fdb_app_create gave it. The same key the Dart side passes as `app`.
std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

std::string AppKey(const firebase::App* app) {
  const char* name = app->name();
  if (name == nullptr || std::strcmp(name, firebase::kDefaultAppName) == 0) {
    return "";
  }
  return name;
}

class PortListener;

// What fdb_ac_init made for an app.
struct AppCheckState {
  AppCheck* app_check = nullptr;
  PortListener* listener = nullptr;
};

std::map<std::string, AppCheckState> g_app_checks;

// A GetToken the SDK is waiting on, and the app it asked for.
struct PendingRequest {
  std::string app;
  TokenCompletion completion;
};

// Outstanding GetToken calls, keyed by the id Dart is answering. The SDK asks
// on its own thread and expects the completion later, so the request has to
// outlive the call that made it.
std::map<int64_t, PendingRequest> g_pending;
int64_t g_next_request = 1;
int64_t g_provider_port = 0;

// A provider whose answer comes from Dart, one per app.
//
// GetToken hands back a completion rather than a value, so nothing blocks: the
// request is parked, its id and the app go to the port, and
// fdb_ac_supply_token finishes it whenever Dart is ready. If Dart never
// answers, the SDK waits -- the request is Dart's to fail, which is what the
// error arguments are for.
class DartAppCheckProvider : public AppCheckProvider {
 public:
  explicit DartAppCheckProvider(std::string app) : app_(std::move(app)) {}

  // Same path as GetToken. The default would already do this, but it logs a
  // warning on every limited-use request saying the provider did not implement
  // it -- which would appear in the logs of anyone using a custom provider,
  // describing a fallback rather than a problem.
  //
  // Dart is not told which kind was asked for. A limited-use token must not be
  // a cached one, and the callback mints a token per request either way, so
  // there is nothing for it to decide.
  void GetLimitedUseToken(TokenCompletion completion) override {
    GetToken(std::move(completion));
  }

  void GetToken(TokenCompletion completion) override {
    int64_t id;
    int64_t port;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      id = g_next_request++;
      port = g_provider_port;
      if (port == 0) {
        // No port means no one to ask. Fail the request rather than park it
        // forever: a caller waiting on a token it will never get is worse
        // than one told the provider is not wired up.
        completion(AppCheckToken(),
                   firebase::app_check::kAppCheckErrorInvalidConfiguration,
                   "no Dart provider is registered");
        return;
      }
      g_pending[id] = PendingRequest{app_, std::move(completion)};
    }
    // The id travels in the header's seq field and the app's name is the
    // payload, empty for the default app: the framing every other port here
    // already uses.
    fdb_post_buffer(port, id, reinterpret_cast<const uint8_t*>(app_.data()),
                    app_.size());
  }

 private:
  const std::string app_;
};

// Providers by app. The SDK caches the one it is given for as long as the app
// lives and never frees it, so they are held here: the default app's for the
// life of the process, a named app's until fdb_ac_release.
std::map<std::string, std::unique_ptr<DartAppCheckProvider>> g_providers;

class DartAppCheckProviderFactory : public AppCheckProviderFactory {
 public:
  // Called by the SDK the first time an app needs a token, on whichever
  // thread asked. Each app gets its own, so Dart is told which app a request
  // is for.
  AppCheckProvider* CreateProvider(firebase::App* app) override {
    if (app == nullptr) return nullptr;
    const std::string key = AppKey(app);
    std::lock_guard<std::mutex> lock(g_mutex);
    std::unique_ptr<DartAppCheckProvider>& provider = g_providers[key];
    if (provider == nullptr) {
      provider = std::make_unique<DartAppCheckProvider>(key);
    }
    return provider.get();
  }
};

// Forwards token changes to a port as CBOR-free framing: the token bytes are
// the payload, the expiry is the seq.
class PortListener : public AppCheckListener {
 public:
  explicit PortListener(int64_t port) : port_(port) {}

  void OnAppCheckTokenChanged(const AppCheckToken& token) override {
    fdb_post_buffer(port_, token.expire_time_millis,
                    reinterpret_cast<const uint8_t*>(token.token.data()),
                    token.token.size());
  }

 private:
  int64_t port_;
};

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_app_check(void) { return 1; }

// Both installers are callable before fdb_app_init: the factory is a static on
// AppCheck, not a property of an App. That ordering is the point -- a provider
// installed after another product has already made a request has missed it.
FDB_EXPORT int64_t fdb_ac_use_debug_provider(const char* debug_token) {
  DebugAppCheckProviderFactory* factory =
      DebugAppCheckProviderFactory::GetInstance();
  if (factory == nullptr) return -2;
  // An empty token leaves the SDK reading APP_CHECK_DEBUG_TOKEN itself, which
  // is how its own samples are driven.
  if (debug_token != nullptr && debug_token[0] != '\0') {
    factory->SetDebugToken(debug_token);
  }
  AppCheck::SetAppCheckProviderFactory(factory);
  return 0;
}

FDB_EXPORT int64_t fdb_ac_use_custom_provider(int64_t port) {
  if (port == 0) return -2;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_provider_port = port;
  }
  static DartAppCheckProviderFactory* factory =
      new DartAppCheckProviderFactory();
  AppCheck::SetAppCheckProviderFactory(factory);
  return 0;
}

// Answers one parked GetToken. `expire_millis` is absolute, milliseconds since
// epoch, because that is what the SDK caches against -- a duration would have
// to be turned into one here, against a clock Dart cannot see.
//
// -1 for an id that is not parked: already answered, or its app was deleted.
FDB_EXPORT int64_t fdb_ac_supply_token(int64_t request_id, const char* token,
                                       int64_t expire_millis,
                                       int64_t error_code,
                                       const char* message) {
  TokenCompletion completion;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_pending.find(request_id);
    if (it == g_pending.end()) return -1;
    completion = std::move(it->second.completion);
    g_pending.erase(it);
  }
  AppCheckToken result{};
  if (error_code == 0) {
    result.token = token == nullptr ? "" : token;
    result.expire_time_millis = expire_millis;
  }
  // Called outside the lock: the SDK continues its request on this thread, and
  // that work can reach back in here.
  completion(result, static_cast<int>(error_code),
             message == nullptr ? "" : message);
  return 0;
}

// Binds App Check to an app: the default one for a null or empty name, else
// the one fdb_app_create made. -1 when there is no such app.
FDB_EXPORT int64_t fdb_ac_init(const char* app) {
  // Asked before taking g_mutex: fdb_app_named takes the app registry's lock,
  // and nothing here may hold one lock while waiting on the other.
  firebase::App* instance = fdb_app_named(app);
  if (instance == nullptr) return -1;
  std::lock_guard<std::mutex> lock(g_mutex);
  AppCheckState& state = g_app_checks[AppKey(app)];
  if (state.app_check == nullptr) {
    state.app_check = AppCheck::GetInstance(instance);
    if (state.app_check == nullptr) {
      g_app_checks.erase(AppKey(app));
      return -2;
    }
  }
  return 0;
}

// Lets go of a named app's App Check, so the app can be deleted. Called by
// fdb_app_delete after the other products have let go and before the app
// goes, so nothing is left to ask the provider for a token.
//
// A request still parked with Dart is failed here: its completion belongs to
// the app's AppCheck, which goes with the app. Dart's answer to it, when it
// comes, finds nothing to answer and is dropped.
void fdb_ac_release(const char* app) {
  if (app == nullptr || *app == '\0') return;  // the default app stays
  const std::string key = AppKey(app);
  AppCheckState state;
  std::unique_ptr<DartAppCheckProvider> provider;
  std::vector<TokenCompletion> parked;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_app_checks.find(key);
    if (it != g_app_checks.end()) {
      state = it->second;
      g_app_checks.erase(it);
    }
    const auto have = g_providers.find(key);
    if (have != g_providers.end()) {
      provider = std::move(have->second);
      g_providers.erase(have);
    }
    for (auto p = g_pending.begin(); p != g_pending.end();) {
      if (p->second.app == key) {
        parked.push_back(std::move(p->second.completion));
        p = g_pending.erase(p);
      } else {
        ++p;
      }
    }
  }
  // Outside the lock, like every other call into the SDK here.
  for (TokenCompletion& completion : parked) {
    completion(AppCheckToken(), firebase::app_check::kAppCheckErrorUnknown,
               "the app was deleted");
  }
  if (state.app_check != nullptr && state.listener != nullptr) {
    state.app_check->RemoveAppCheckListener(state.listener);
  }
  delete state.listener;
  // The provider is freed while the app's AppCheck still holds the pointer.
  // Nothing asks it again: every product that would has been deleted, and
  // this file no longer knows the app.
}

// extern "C++" around the anonymous namespace: this is inside the extern "C"
// block, where C language linkage suppresses mangling and an anonymous
// namespace alone does not make a name internal. Without it `Instance` is
// exported under that name, which is not one to be exporting.
extern "C++" {
namespace {

// The lock covers this file's own state and nothing else. Anything that calls
// into the SDK takes the pointer and lets go first: GetAppCheckToken reaches
// the provider synchronously, on the calling thread, and the provider needs
// the same lock -- holding it across the call deadlocks against ourselves.
AppCheck* Instance(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_app_checks.find(AppKey(app));
  return it == g_app_checks.end() ? nullptr : it->second.app_check;
}

// Posts a finished token request to `port`: the token bytes with the expiry
// in seq, or a negative seq carrying the error code and the message.
void PostToken(int64_t port, const firebase::Future<AppCheckToken>& f) {
  if (f.error() != 0 || f.result() == nullptr) {
    const char* msg = f.error_message() == nullptr ? "" : f.error_message();
    fdb_post_buffer(port, f.error() == 0 ? -1 : -f.error(),
                    reinterpret_cast<const uint8_t*>(msg), std::strlen(msg));
    return;
  }
  const AppCheckToken& token = *f.result();
  fdb_post_buffer(port, token.expire_time_millis,
                  reinterpret_cast<const uint8_t*>(token.token.data()),
                  token.token.size());
}

}  // namespace
}  // extern "C++"

// The token itself, for a caller that has to attach it to something this
// library does not speak -- a backend of its own, say.
FDB_EXPORT int64_t fdb_ac_get_token(const char* app, int32_t force_refresh,
                                    int64_t port) {
  AppCheck* app_check = Instance(app);
  if (app_check == nullptr) return -1;
  app_check->GetAppCheckToken(force_refresh != 0)
      .OnCompletion([port](const firebase::Future<AppCheckToken>& f) {
        PostToken(port, f);
      });
  return 0;
}

// Whether the SDK refreshes a token on its own before it expires. Off is the
// right default for a device that attests expensively -- a TPM signature on a
// timer is not free -- so this is a decision the app makes, not one taken for
// it.
FDB_EXPORT int64_t fdb_ac_set_auto_refresh(const char* app, int32_t enabled) {
  AppCheck* app_check = Instance(app);
  if (app_check == nullptr) return -1;
  app_check->SetTokenAutoRefreshEnabled(enabled != 0);
  return 0;
}

// A token for a single use, not cached and not shared. The provider's own
// GetLimitedUseToken defaults to GetToken, so a custom provider serves this
// without implementing anything further.
FDB_EXPORT int64_t fdb_ac_limited_use_token(const char* app, int64_t port) {
  AppCheck* app_check = Instance(app);
  if (app_check == nullptr) return -1;
  app_check->GetLimitedUseAppCheckToken().OnCompletion(
      [port](const firebase::Future<AppCheckToken>& f) { PostToken(port, f); });
  return 0;
}

// One listener per app. -3 when the app has one already.
FDB_EXPORT int64_t fdb_ac_add_listener(const char* app, int64_t port) {
  AppCheck* app_check = nullptr;
  PortListener* listener = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_app_checks.find(AppKey(app));
    if (it == g_app_checks.end()) return -1;
    if (it->second.listener != nullptr) return -3;
    app_check = it->second.app_check;
    it->second.listener = listener = new PortListener(port);
  }
  app_check->AddAppCheckListener(listener);
  return 0;
}

FDB_EXPORT int64_t fdb_ac_remove_listener(const char* app) {
  AppCheck* app_check = nullptr;
  PortListener* listener = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_app_checks.find(AppKey(app));
    if (it == g_app_checks.end() || it->second.listener == nullptr) return -1;
    app_check = it->second.app_check;
    listener = it->second.listener;
    it->second.listener = nullptr;
  }
  app_check->RemoveAppCheckListener(listener);
  delete listener;
  return 0;
}

}  // extern "C"
