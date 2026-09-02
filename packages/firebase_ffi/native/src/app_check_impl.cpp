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

#include "firebase_bridge.h"

#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <utility>

#include "dart_api_dl.h"
#include "firebase/app_check.h"
#include "firebase/app_check/debug_provider.h"

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
AppCheck* g_app_check = nullptr;

// Outstanding GetToken calls the SDK is waiting on, keyed by the id Dart is
// answering. The SDK asks on its own thread and expects the completion later,
// so the request has to outlive the call that made it.
std::map<int64_t, TokenCompletion> g_pending;
int64_t g_next_request = 1;
int64_t g_provider_port = 0;

// A provider whose answer comes from Dart.
//
// GetToken hands back a completion rather than a value, so nothing blocks: the
// request is parked, its id goes to the port, and fdb_ac_supply_token finishes
// it whenever Dart is ready. If Dart never answers, the SDK waits -- the
// request is Dart's to fail, which is what the error arguments are for.
class DartAppCheckProvider : public AppCheckProvider {
 public:
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
      g_pending[id] = std::move(completion);
    }
    // The id travels in the header's seq field with an empty payload; there is
    // nothing else to say, and the framing is the one every other port here
    // already uses.
    fdb_post_buffer(port, id, nullptr, 0);
  }
};

class DartAppCheckProviderFactory : public AppCheckProviderFactory {
 public:
  AppCheckProvider* CreateProvider(firebase::App* app) override {
    (void)app;
    // One provider for the life of the process. The SDK does not tell us when
    // it is done with one, and it holds the pointer, so this is deliberately
    // never freed rather than freed at a moment we would be guessing at.
    static DartAppCheckProvider* provider = new DartAppCheckProvider();
    return provider;
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

PortListener* g_listener = nullptr;

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
FDB_EXPORT int64_t fdb_ac_supply_token(int64_t request_id, const char* token,
                                       int64_t expire_millis,
                                       int64_t error_code,
                                       const char* message) {
  TokenCompletion completion;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_pending.find(request_id);
    if (it == g_pending.end()) return -1;
    completion = std::move(it->second);
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

FDB_EXPORT int64_t fdb_ac_init(void) {
  firebase::App* app = fdb_current_app();
  if (app == nullptr) return -1;
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_app_check == nullptr) {
    g_app_check = AppCheck::GetInstance(app);
    if (g_app_check == nullptr) return -2;
  }
  return 0;
}

namespace {

// The lock covers this file's own state and nothing else. Anything that calls
// into the SDK takes the pointer and lets go first: GetAppCheckToken reaches
// the provider synchronously, on the calling thread, and the provider needs
// the same lock -- holding it across the call deadlocks against ourselves.
AppCheck* Instance() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_app_check;
}

}  // namespace

// The token itself, for a caller that has to attach it to something this
// library does not speak -- a backend of its own, say. Posted as the token
// bytes with the expiry in seq; a negative seq carries the error code and the
// payload is the message.
FDB_EXPORT int64_t fdb_ac_get_token(int32_t force_refresh, int64_t port) {
  AppCheck* app_check = Instance();
  if (app_check == nullptr) return -1;
  app_check->GetAppCheckToken(force_refresh != 0)
      .OnCompletion([port](const firebase::Future<AppCheckToken>& f) {
        if (f.error() != 0 || f.result() == nullptr) {
          const char* msg = f.error_message() == nullptr ? "" : f.error_message();
          fdb_post_buffer(port, f.error() == 0 ? -1 : -f.error(),
                          reinterpret_cast<const uint8_t*>(msg), strlen(msg));
          return;
        }
        const AppCheckToken& token = *f.result();
        fdb_post_buffer(port, token.expire_time_millis,
                        reinterpret_cast<const uint8_t*>(token.token.data()),
                        token.token.size());
      });
  return 0;
}

// Whether the SDK refreshes a token on its own before it expires. Off is the
// right default for a device that attests expensively -- a TPM signature on a
// timer is not free -- so this is a decision the app makes, not one taken for
// it.
FDB_EXPORT int64_t fdb_ac_set_auto_refresh(int32_t enabled) {
  AppCheck* app_check = Instance();
  if (app_check == nullptr) return -1;
  app_check->SetTokenAutoRefreshEnabled(enabled != 0);
  return 0;
}

// A token for a single use, not cached and not shared. The provider's own
// GetLimitedUseToken defaults to GetToken, so a custom provider serves this
// without implementing anything further.
FDB_EXPORT int64_t fdb_ac_limited_use_token(int64_t port) {
  AppCheck* app_check = Instance();
  if (app_check == nullptr) return -1;
  app_check->GetLimitedUseAppCheckToken().OnCompletion(
      [port](const firebase::Future<AppCheckToken>& f) {
        if (f.error() != 0 || f.result() == nullptr) {
          const char* msg =
              f.error_message() == nullptr ? "" : f.error_message();
          fdb_post_buffer(port, f.error() == 0 ? -1 : -f.error(),
                          reinterpret_cast<const uint8_t*>(msg), strlen(msg));
          return;
        }
        const AppCheckToken& token = *f.result();
        fdb_post_buffer(port, token.expire_time_millis,
                        reinterpret_cast<const uint8_t*>(token.token.data()),
                        token.token.size());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_ac_add_listener(int64_t port) {
  AppCheck* app_check = Instance();
  if (app_check == nullptr) return -1;
  PortListener* listener = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_listener != nullptr) return -3;
    g_listener = listener = new PortListener(port);
  }
  app_check->AddAppCheckListener(listener);
  return 0;
}

FDB_EXPORT int64_t fdb_ac_remove_listener(void) {
  AppCheck* app_check = Instance();
  PortListener* listener = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (app_check == nullptr || g_listener == nullptr) return -1;
    listener = g_listener;
    g_listener = nullptr;
  }
  app_check->RemoveAppCheckListener(listener);
  delete listener;
  return 0;
}

}  // extern "C"
