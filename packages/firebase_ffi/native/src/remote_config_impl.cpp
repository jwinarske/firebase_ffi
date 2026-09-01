// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Remote Config: defaults in, values out.
//
// Values are firebase::Variant, so the CBOR codec is shared with the Realtime
// Database and Functions. Reads are one GetAll rather than a getter per type:
// the SDK's typed getters coerce silently -- GetLong on a string returns 0 --
// and a map keeps whatever type the value actually has.

#include "firebase_bridge.h"

#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/remote_config.h"

namespace {

using ::firebase::Variant;
using ::firebase::remote_config::ConfigKeyValueVariant;
using ::firebase::remote_config::RemoteConfig;

std::mutex g_mutex;
RemoteConfig* g_config = nullptr;

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_remote_config(void) { return 1; }

// Asynchronous because the SDK's getters are only meaningful after
// EnsureInitialized has brought the last activated config into memory.
FDB_EXPORT int64_t fdb_rc_init(int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  firebase::App* app = fdb_current_app();
  if (app == nullptr) return -1;
  if (g_config == nullptr) {
    g_config = RemoteConfig::GetInstance(app);
    if (g_config == nullptr) return -2;
  }
  g_config->EnsureInitialized().OnCompletion(
      [port](const firebase::Future<firebase::remote_config::ConfigInfo>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Defaults arrive as a CBOR map. They are what a value reads as before any
// fetch has succeeded, which is most of an appliance's life: a device that
// cannot reach the network still has to behave.
FDB_EXPORT int64_t fdb_rc_set_defaults(const uint8_t* cbor, size_t len,
                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_config == nullptr) return -1;

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

  g_config->SetDefaults(defaults.data(), defaults.size())
      .OnCompletion([port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Every key and its current value, as one CBOR map.
FDB_EXPORT int64_t fdb_rc_get_all(int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_config == nullptr) return -1;

  const std::map<std::string, Variant> all = g_config->GetAll();
  std::vector<uint8_t> payload;
  if (!fdb::SerializeVariantMap(all, payload)) {
    fdb_post_buffer(port, -2, nullptr, 0);
    return 0;
  }
  fdb_post_buffer(port, 1, payload.data(), payload.size());
  return 0;
}

FDB_EXPORT int64_t fdb_rc_fetch_and_activate(int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_config == nullptr) return -1;
  g_config->FetchAndActivate().OnCompletion(
      [port](const firebase::Future<bool>& f) {
        if (f.error() != 0) {
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
          return;
        }
        // The bool says whether the fetched config was activated -- false
        // means the fetch succeeded and there was nothing new, which is not a
        // failure and must not read as one.
        fdb_post_outcome(port, 1, f.result() != nullptr && *f.result() ? 1 : 0,
                         "");
      });
  return 0;
}

}  // extern "C"
