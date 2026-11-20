// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Remote Config: defaults in, values out.
//
// Values are firebase::Variant, so the CBOR codec is shared with the Realtime
// Database and Functions. Reads are one GetAll rather than a getter per type:
// the SDK's typed getters coerce silently -- GetLong on a string returns 0 --
// and a map keeps whatever type the value actually has.

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/remote_config.h"
#include "firebase_bridge.h"

namespace {

using ::firebase::Variant;
using ::firebase::remote_config::ConfigKeyValueVariant;
using ::firebase::remote_config::RemoteConfig;

std::mutex g_mutex;

// An app's Remote Config. The SDK keeps one per app, and persists each under
// the app's name, so a named app's config is its own on disk as well.
struct ConfigState {
  RemoteConfig* config = nullptr;
  // Set while the app is being deleted. Nothing new starts.
  bool closing = false;
  // Requests whose completion has not answered yet. Shared with the
  // completions, which can outlive the state.
  std::shared_ptr<std::atomic<int>> running =
      std::make_shared<std::atomic<int>>(0);
};

// By app name, "" for the default app.
std::map<std::string, std::unique_ptr<ConfigState>> g_states;

std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

// The Remote Config to act on, or null when the app has none or is being
// deleted. Caller holds g_mutex.
RemoteConfig* ConfigFor(const char* app) {
  const auto it = g_states.find(AppKey(app));
  if (it == g_states.end() || it->second->closing) return nullptr;
  return it->second->config;
}

// Counts a request as running until its completion answers. Caller holds
// g_mutex, and has just had ConfigFor answer for the same app.
std::shared_ptr<std::atomic<int>> Running(const char* app) {
  std::shared_ptr<std::atomic<int>> running =
      g_states.find(AppKey(app))->second->running;
  running->fetch_add(1);
  return running;
}

// A completion that answers a void request on `port`.
std::function<void(const firebase::Future<void>&)> AnswerVoid(
    std::shared_ptr<std::atomic<int>> running, int64_t port) {
  return [running = std::move(running), port](const firebase::Future<void>& f) {
    fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                     f.error_message() == nullptr ? "" : f.error_message());
    running->fetch_sub(1);
  };
}

// A completion that answers an activation on `port`. False means there was
// nothing new to activate, which is not a failure and must not read as one.
std::function<void(const firebase::Future<bool>&)> AnswerActivated(
    std::shared_ptr<std::atomic<int>> running, int64_t port) {
  return [running = std::move(running), port](const firebase::Future<bool>& f) {
    if (f.error() != 0) {
      fdb_post_outcome(port, 0, f.error(),
                       f.error_message() == nullptr ? "" : f.error_message());
    } else {
      fdb_post_outcome(port, 1, f.result() != nullptr && *f.result() ? 1 : 0,
                       "");
    }
    running->fetch_sub(1);
  };
}

// How long deleting an app waits for its running requests. A fetch is the one
// that takes time: the SDK holds the instance for the whole of it, up to the
// fetch timeout, and deleting the instance waits for it to let go.
constexpr auto kReleaseWait = std::chrono::seconds(5);
constexpr auto kReleasePoll = std::chrono::milliseconds(10);

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_remote_config(void) { return 1; }

// Asynchronous because the SDK's getters are only meaningful after
// EnsureInitialized has brought the last activated config into memory.
//
// On an app: the default one for a null or empty name, else the one
// fdb_app_create made. -1 when there is no such app.
FDB_EXPORT int64_t fdb_rc_init(const char* app, int64_t port) {
  // Asked before taking g_mutex: fdb_app_named takes the app registry's lock.
  firebase::App* owner = fdb_app_named(app);
  if (owner == nullptr) return -1;
  std::lock_guard<std::mutex> lock(g_mutex);
  auto found = g_states.find(AppKey(app));
  if (found != g_states.end() && found->second->closing) return -1;
  if (found == g_states.end()) {
    RemoteConfig* config = RemoteConfig::GetInstance(owner);
    if (config == nullptr) return -2;
    auto state = std::make_unique<ConfigState>();
    state->config = config;
    found = g_states.emplace(AppKey(app), std::move(state)).first;
  }
  std::shared_ptr<std::atomic<int>> running = Running(app);
  found->second->config->EnsureInitialized().OnCompletion(
      [running,
       port](const firebase::Future<firebase::remote_config::ConfigInfo>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
        running->fetch_sub(1);
      });
  return 0;
}

// Lets go of a named app's Remote Config, so the app can be deleted. See
// fdb_db_quiesce in firebase_bridge.h for the three steps.
//
// A request cannot be canceled, so it is waited for. A fetch holds the
// instance for as long as it runs, up to the fetch timeout, and one that
// outlasts the wait leaves the app as it was and answers -1.
int64_t fdb_rc_quiesce(const char* app) {
  const std::string key = AppKey(app);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(key);
    if (it == g_states.end()) return 0;
    if (it->second->closing) return -1;
    it->second->closing = true;
  }
  const auto deadline = std::chrono::steady_clock::now() + kReleaseWait;
  for (;;) {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      const auto it = g_states.find(key);
      if (it == g_states.end()) return 0;
      if (it->second->running->load() == 0) return 0;
      if (std::chrono::steady_clock::now() >= deadline) {
        it->second->closing = false;
        return -1;
      }
    }
    std::this_thread::sleep_for(kReleasePoll);
  }
}

void fdb_rc_resume(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_states.find(AppKey(app));
  if (it != g_states.end()) it->second->closing = false;
}

void fdb_rc_release(const char* app) {
  if (app == nullptr || *app == '\0') return;  // the default app stays
  std::unique_ptr<ConfigState> state;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(AppKey(app));
    if (it == g_states.end()) return;
    state = std::move(it->second);
    g_states.erase(it);
  }
  // Outside the lock: deleting waits for the SDK's own threads, which may be
  // finishing a completion. The config on disk stays, under the app's name.
  delete state->config;
}

// Defaults arrive as a CBOR map. They are what a value reads as before any
// fetch has succeeded, which is most of an appliance's life: a device that
// cannot reach the network still has to behave.
FDB_EXPORT int64_t fdb_rc_set_defaults(const char* app, const uint8_t* cbor,
                                       size_t len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;

  std::map<std::string, Variant> parsed;
  if (!fdb::ParseVariantMap(cbor, len, &parsed)) return -3;

  // The SDK holds these pointers for the duration of the call, so the strings
  // have to outlive the vector of structs that points at them.
  std::vector<std::string> keys;
  keys.reserve(parsed.size());
  std::vector<ConfigKeyValueVariant> defaults;
  defaults.reserve(parsed.size());
  for (const auto& kv : parsed) {
    keys.push_back(kv.first);
  }
  size_t i = 0;
  for (const auto& kv : parsed) {
    defaults.push_back(ConfigKeyValueVariant{keys[i].c_str(), kv.second});
    ++i;
  }

  config->SetDefaults(defaults.data(), defaults.size())
      .OnCompletion(AnswerVoid(Running(app), port));
  return 0;
}

// Every key and its current value, as one CBOR map.
FDB_EXPORT int64_t fdb_rc_get_all(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;

  const std::map<std::string, Variant> all = config->GetAll();
  std::vector<uint8_t> payload;
  if (!fdb::SerializeVariantMap(all, payload)) {
    fdb_post_buffer(port, -2, nullptr, 0);
    return 0;
  }
  fdb_post_buffer(port, 1, payload.data(), payload.size());
  return 0;
}

// Fetch and Activate separately, because the platform interface exposes them
// separately and an app that fetches on a schedule and activates at a safe
// moment -- a screen change, an idle period -- cannot express that with only
// the combined call.
FDB_EXPORT int64_t fdb_rc_fetch(const char* app,
                                int64_t cache_expiration_seconds,
                                int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  // A negative value means "the configured interval", which is the no-argument
  // overload; zero is a real value meaning "always fetch" and must not be
  // folded into it.
  firebase::Future<void> f =
      cache_expiration_seconds < 0
          ? config->Fetch()
          : config->Fetch(static_cast<uint64_t>(cache_expiration_seconds));
  f.OnCompletion(AnswerVoid(Running(app), port));
  return 0;
}

FDB_EXPORT int64_t fdb_rc_activate(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  config->Activate().OnCompletion(AnswerActivated(Running(app), port));
  return 0;
}

// Synchronous, because GetInfo is: the SDK answers from memory, and the
// platform interface's lastFetchTime and lastFetchStatus are plain getters
// with nowhere to await.
FDB_EXPORT int64_t fdb_rc_info(const char* app, int64_t* out, size_t cap) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  if (out == nullptr || cap < 4) return -2;
  const firebase::remote_config::ConfigInfo info = config->GetInfo();
  out[0] = static_cast<int64_t>(info.fetch_time);
  out[1] = static_cast<int64_t>(info.last_fetch_status);
  out[2] = static_cast<int64_t>(info.last_fetch_failure_reason);
  out[3] = static_cast<int64_t>(info.throttled_end_time);
  return 4;
}

// Where a key's current value came from. GetAll does not say, and a caller
// that cannot tell a default from a fetched value cannot tell whether a fetch
// has taken effect.
//
// Returned as the SDK's own enum value. Its order is static, remote, default,
// which is not the order the Dart side uses -- that mapping is done by name
// there rather than by index here.
FDB_EXPORT int64_t fdb_rc_value_source(const char* app, const char* key) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  if (key == nullptr || *key == '\0') return -2;
  firebase::remote_config::ValueInfo info{};
  // Any typed getter fills ValueInfo; the value itself is not wanted here, and
  // GetString is the one that cannot fail to represent what is stored.
  (void)config->GetString(key, &info);
  return static_cast<int64_t>(info.source);
}

FDB_EXPORT int64_t fdb_rc_get_settings(const char* app, int64_t* out,
                                       size_t cap) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  if (out == nullptr || cap < 2) return -2;
  const firebase::remote_config::ConfigSettings s = config->GetConfigSettings();
  out[0] = static_cast<int64_t>(s.fetch_timeout_in_milliseconds);
  out[1] = static_cast<int64_t>(s.minimum_fetch_interval_in_milliseconds);
  return 2;
}

FDB_EXPORT int64_t fdb_rc_set_settings(const char* app,
                                       int64_t fetch_timeout_ms,
                                       int64_t minimum_interval_ms,
                                       int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  if (fetch_timeout_ms < 0 || minimum_interval_ms < 0) return -2;
  firebase::remote_config::ConfigSettings settings;
  settings.fetch_timeout_in_milliseconds =
      static_cast<uint64_t>(fetch_timeout_ms);
  settings.minimum_fetch_interval_in_milliseconds =
      static_cast<uint64_t>(minimum_interval_ms);
  config->SetConfigSettings(settings).OnCompletion(
      AnswerVoid(Running(app), port));
  return 0;
}

FDB_EXPORT int64_t fdb_rc_fetch_and_activate(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  RemoteConfig* config = ConfigFor(app);
  if (config == nullptr) return -1;
  config->FetchAndActivate().OnCompletion(AnswerActivated(Running(app), port));
  return 0;
}

}  // extern "C"
