// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Authentication, sharing the one firebase::App the whole module uses.
//
// The credential is never handed to Database explicitly. The SDK header is
// explicit that "Firebase Realtime Database uses firebase::App to communicate
// with Firebase Authentication", so signing in on the same App is what makes an
// outstanding ValueListener re-authorize and stop returning error 8.
//
// That shared App is also why auth and database have to live in one shared
// library: two .so files each statically linking the SDK would get one App
// registry apiece, and the credential would never reach Database.
//
// Both sign-in calls are asynchronous. Rather than block, they post the outcome
// to a Dart port, so a caller awaits a Future the same way it would for any
// other async native work.

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "firebase_bridge.h"

#include "firebase/app.h"
#include "firebase/auth.h"

namespace {

using ::firebase::auth::Auth;
using ::firebase::auth::AuthResult;

std::mutex g_auth_mutex;
Auth* g_auth = nullptr;

struct CredentialData {
  std::string provider_id;
  std::string email;
  std::string secret;
  std::string id_token;
  std::string access_token;
};

// Posts `{ok, code, message, uid}` as a small message. Not external typed data:
// this is a handful of bytes and a copy of it costs less than the finalizer
// bookkeeping a zero-copy post would add — the benchmark showed that crossover
// sits in the kilobytes.
void PostAuthResult(Dart_Port_DL port, bool ok, int code,
                    const std::string& message, const std::string& uid) {
  Dart_CObject c_ok{};
  c_ok.type = Dart_CObject_kBool;
  c_ok.value.as_bool = ok;

  Dart_CObject c_code{};
  c_code.type = Dart_CObject_kInt64;
  c_code.value.as_int64 = code;

  Dart_CObject c_msg{};
  c_msg.type = Dart_CObject_kString;
  c_msg.value.as_string = const_cast<char*>(message.c_str());

  Dart_CObject c_uid{};
  c_uid.type = Dart_CObject_kString;
  c_uid.value.as_string = const_cast<char*>(uid.c_str());

  Dart_CObject* items[4] = {&c_ok, &c_code, &c_msg, &c_uid};
  Dart_CObject arr{};
  arr.type = Dart_CObject_kArray;
  arr.value.as_array.length = 4;
  arr.value.as_array.values = items;

  // Dart_PostCObject_DL copies non-external payloads, so the strings above may
  // die when this function returns.
  Dart_PostCObject_DL(port, &arr);
}

// Shared completion for both sign-in paths.
void OnSignInComplete(const firebase::Future<AuthResult>& future,
                      void* user_data) {
  const auto port = reinterpret_cast<intptr_t>(user_data);
  if (future.error() != 0) {
    PostAuthResult(static_cast<Dart_Port_DL>(port), false, future.error(),
                   future.error_message() == nullptr ? ""
                                                     : future.error_message(),
                   "");
    return;
  }
  const AuthResult* result = future.result();
  std::string uid;
  if (result != nullptr && result->user.is_valid()) {
    uid = result->user.uid();
  }
  PostAuthResult(static_cast<Dart_Port_DL>(port), true, 0, "", uid);
}

bool ReadCborString(CborValue* value, std::string* out) {
  if (!cbor_value_is_text_string(value)) {
    return false;
  }

  char* buffer = nullptr;
  size_t length = 0;

  const CborError err =
      cbor_value_dup_text_string(value, &buffer, &length, nullptr);

  if (err != CborNoError) {
    return false;
  }

  out->assign(buffer, length);
  free(buffer);

  return true;
}

bool ParseCredentialData(const uint8_t* data,
                                size_t data_len,
                                CredentialData* credential) {
  if (data == nullptr || credential == nullptr) {
    return false;
  }

  CborParser parser;
  CborValue root;

  CborError err =
      cbor_parser_init(data, data_len, 0, &parser, &root);

  if (err != CborNoError || !cbor_value_is_map(&root)) {
    return false;
  }

  CborValue it;

  err = cbor_value_enter_container(&root, &it);
  if (err != CborNoError) {
    return false;
  }

  while (!cbor_value_at_end(&it)) {
    // Key must be a string.
    std::string key;

    if (!ReadCborString(&it, &key)) {
      return false;
    }

    err = cbor_value_advance(&it);
    if (err != CborNoError) {
      return false;
    }

    // Parse value according to the key.
    if (key == "providerId") {
      if (!ReadCborString(&it, &credential->provider_id)) {
        return false;
      }
    } else if (key == "email") {
      if (!ReadCborString(&it, &credential->email)) {
        return false;
      }
    } else if (key == "secret") {
      if (!ReadCborString(&it, &credential->secret)) {
        return false;
      }
    } else if (key == "idToken") {
      if (!ReadCborString(&it, &credential->id_token)) {
        return false;
      }
    } else if (key == "accessToken") {
      if (!ReadCborString(&it, &credential->access_token)) {
        return false;
      }
    } else {
      // Unknown field.
      //
      // We intentionally ignore it, but still advance past its value below.
    }

    err = cbor_value_advance(&it);
    if (err != CborNoError) {
      return false;
    }
  }

  err = cbor_value_leave_container(&root, &it);
  return err == CborNoError;
}

bool BuildCredential(const uint8_t *data, size_t data_len,
                     firebase::auth::Credential *out) {
  if (out == nullptr) {
    return false;
  }

  CredentialData credential;

  if (!ParseCredentialData(data, data_len, &credential)) {
    return false;
  }

  if (credential.provider_id == "password") {
    if (credential.email.empty() || credential.secret.empty()) {
      return false;
    }

    *out = firebase::auth::EmailAuthProvider::GetCredential(
        credential.email.c_str(), credential.secret.c_str());

    return true;
  }

  if (credential.provider_id == "google.com") {
    // It accepts idToken or accessToken
    if (credential.id_token.empty() && credential.access_token.empty()) {
      return false;
    }

    *out = firebase::auth::GoogleAuthProvider::GetCredential(
        credential.id_token.empty() ? nullptr : credential.id_token.c_str(),
        credential.access_token.empty() ? nullptr
                                        : credential.access_token.c_str());

    return true;
  }

  return false;
}

}  // namespace

extern "C" {

// Point Auth at a local emulator. Must be called after fdb_auth_init and
// before signing in: the SDK reconfigures the endpoint, it does not migrate a
// session that already exists.
FDB_EXPORT int64_t fdb_auth_use_emulator(const char* host, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) return -1;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  g_auth->UseEmulator(std::string(host), static_cast<uint32_t>(port));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_init(void) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth != nullptr) {
    return 0;
  }
  firebase::App* app = fdb_current_app();
  if (app == nullptr) {
    return -1;  // fdb_app_init has not run
  }
  firebase::InitResult init_result;
  g_auth = Auth::GetAuth(app, &init_result);
  if (g_auth == nullptr || init_result != firebase::kInitResultSuccess) {
    return -2;
  }
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_in_anonymously(int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }
  g_auth->SignInAnonymously().OnCompletion(
      OnSignInComplete, reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_in_with_custom_token(const char* token,
                                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }
  if (token == nullptr || *token == '\0') {
    return -2;
  }
  g_auth->SignInWithCustomToken(token).OnCompletion(
      OnSignInComplete, reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_in_with_credential(const uint8_t *spec,
                                                    size_t spec_len,
                                                    int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }

  firebase::auth::Credential credential;
  if (!BuildCredential(spec, spec_len, &credential)) {
    return -2;
  }

  g_auth->SignInAndRetrieveDataWithCredential(credential)
      .OnCompletion(OnSignInComplete,
                    reinterpret_cast<void *>(static_cast<intptr_t>(port)));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_out(void) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }
  g_auth->SignOut();
  return 0;
}

FDB_EXPORT int64_t fdb_auth_create_user_with_email_and_password(
    const char *email, const char *password, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }

  if (email == nullptr || *email == '\0') {
    return -2;
  }

  if (password == nullptr || *password == '\0') {
    return -2;
  }

  g_auth->CreateUserWithEmailAndPassword(email, password)
      .OnCompletion(OnSignInComplete,
                    reinterpret_cast<void *>(static_cast<intptr_t>(port)));
  return 0;
}

// The signed-in uid, or an empty string. Copied into `out`; returns the length
// written, or -1 if the buffer is too small.
// The signed-in user's ID token, for talking to a Firebase REST endpoint
// directly. Asynchronous because the SDK refreshes an expired one, which is a
// network call.
//
// GetToken, not GetTokenThreadSafe: the latter is declared only under
// INTERNAL_EXPERIMENTAL and is not in a normal build. g_auth_mutex is held
// across the call for the same reason every other accessor here holds it.
FDB_EXPORT int64_t fdb_auth_id_token(int32_t force_refresh, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) return -1;
  auto user = g_auth->current_user();
  if (!user.is_valid()) return -2;
  user.GetToken(force_refresh != 0)
      .OnCompletion([port](const firebase::Future<std::string>& f) {
        if (f.error() != 0 || f.result() == nullptr) {
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
          return;
        }
        // The token rides in the message field: it is a string, and this is
        // the shape every other auth answer already uses.
        fdb_post_outcome(port, 1, 0, f.result()->c_str());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_auth_current_uid(char* out, size_t cap) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr || out == nullptr) {
    return -1;
  }
  const auto user = g_auth->current_user();
  const std::string uid = user.is_valid() ? user.uid() : std::string();
  if (uid.size() + 1 > cap) {
    return -1;
  }
  std::memcpy(out, uid.c_str(), uid.size() + 1);
  return static_cast<int64_t>(uid.size());
}

}  // extern "C"
