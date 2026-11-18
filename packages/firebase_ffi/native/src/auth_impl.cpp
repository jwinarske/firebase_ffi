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

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <map>
#include <optional>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase_bridge.h"

#include "firebase/app.h"
#include "firebase/auth.h"

namespace {

using ::firebase::auth::Auth;
using ::firebase::auth::AuthResult;
using ::firebase::auth::User;
using ::firebase::auth::UserInfoInterface;
using ::firebase::Variant;

std::mutex g_auth_mutex;
Auth* g_auth = nullptr;

struct CredentialData {
  std::string provider_id;
  std::optional<std::string> email;
  std::optional<std::string> secret;
  std::optional<std::string> id_token;
  std::optional<std::string> access_token;
  std::optional<std::string> raw_nonce;
};

// The SDK answers "not set" with an empty string. Left out of the map so it
// reaches Dart as null, which is what firebase_auth reports for a profile
// field the account does not have.
void PutIfSet(std::map<Variant, Variant>& map, const char* key,
              const std::string& value) {
  if (!value.empty()) map[Variant(key)] = Variant(value);
}

// The fields a User and each entry of its provider data have in common.
void PutProfile(std::map<Variant, Variant>& map,
                const UserInfoInterface& info) {
  map[Variant("uid")] = Variant(info.uid());
  PutIfSet(map, "email", info.email());
  PutIfSet(map, "displayName", info.display_name());
  PutIfSet(map, "photoUrl", info.photo_url());
  PutIfSet(map, "phoneNumber", info.phone_number());
  PutIfSet(map, "providerId", info.provider_id());
}

// A user as CBOR: one encoding for the sign-in answer and for
// fdb_auth_current_user, so the Dart side has one decoder. Keys follow the
// names firebase_auth's platform interface uses.
bool SerializeUser(const User& user, std::vector<uint8_t>& out) {
  std::map<Variant, Variant> map;
  PutProfile(map, user);
  map[Variant("isAnonymous")] = Variant(user.is_anonymous());
  map[Variant("isEmailVerified")] = Variant(user.is_email_verified());

  // Milliseconds since the epoch. Zero is the SDK's "unknown".
  const auto metadata = user.metadata();
  if (metadata.creation_timestamp != 0) {
    map[Variant("creationTimestamp")] =
        Variant(static_cast<int64_t>(metadata.creation_timestamp));
  }
  if (metadata.last_sign_in_timestamp != 0) {
    map[Variant("lastSignInTimestamp")] =
        Variant(static_cast<int64_t>(metadata.last_sign_in_timestamp));
  }

  std::vector<Variant> providers;
  for (const UserInfoInterface& info : user.provider_data()) {
    std::map<Variant, Variant> entry;
    PutProfile(entry, info);
    providers.emplace_back(entry);
  }
  map[Variant("providerData")] = Variant(providers);

  return fdb::SerializeVariant(Variant(map), out);
}

// Posts `{ok, code, message, uid, user}` as a small message, `user` being the
// CBOR from SerializeUser or null. Not external typed data: this is a handful
// of bytes and a copy of it costs less than the finalizer bookkeeping a
// zero-copy post would add — the benchmark showed that crossover sits in the
// kilobytes.
void PostAuthResult(Dart_Port_DL port, bool ok, int code,
                    const std::string& message, const std::string& uid,
                    const std::vector<uint8_t>& user) {
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

  Dart_CObject c_user{};
  if (user.empty()) {
    c_user.type = Dart_CObject_kNull;
  } else {
    c_user.type = Dart_CObject_kTypedData;
    c_user.value.as_typed_data.type = Dart_TypedData_kUint8;
    c_user.value.as_typed_data.length = static_cast<intptr_t>(user.size());
    c_user.value.as_typed_data.values = user.data();
  }

  Dart_CObject* items[5] = {&c_ok, &c_code, &c_msg, &c_uid, &c_user};
  Dart_CObject arr{};
  arr.type = Dart_CObject_kArray;
  arr.value.as_array.length = 5;
  arr.value.as_array.values = items;

  // Dart_PostCObject_DL copies non-external payloads, so the strings and the
  // bytes above may die when this function returns.
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
                   "", {});
    return;
  }
  const AuthResult* result = future.result();
  std::string uid;
  std::vector<uint8_t> user;
  if (result != nullptr && result->user.is_valid()) {
    uid = result->user.uid();
    // A failed encode leaves `user` empty and the uid still answers: the
    // sign-in did happen, and the caller can ask for the user again.
    if (!SerializeUser(result->user, user)) user.clear();
  }
  PostAuthResult(static_cast<Dart_Port_DL>(port), true, 0, "", uid, user);
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

bool ReadCborOptionalString(CborValue* value, std::optional<std::string>* out) {
  if (cbor_value_is_null(value)) {
    *out = std::nullopt;
    return true;
  }

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

  out->emplace(buffer, length);
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
      if (!ReadCborOptionalString(&it, &credential->email)) {
        return false;
      }
    } else if (key == "secret") {
      if (!ReadCborOptionalString(&it, &credential->secret)) {
        return false;
      }
    } else if (key == "idToken") {
      if (!ReadCborOptionalString(&it, &credential->id_token)) {
        return false;
      }
    } else if (key == "accessToken") {
      if (!ReadCborOptionalString(&it, &credential->access_token)) {
        return false;
      }
    } else if (key == "rawNonce") {
      if (!ReadCborOptionalString(&it, &credential->raw_nonce)) {
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

  const char *provider_id = credential.provider_id.c_str();
  const char *email = !credential.email.has_value()
                          ? nullptr
                          : credential.email.value().c_str();
  const char *secret = !credential.secret.has_value()
                           ? nullptr
                           : credential.secret.value().c_str();
  const char *id_token = !credential.id_token.has_value()
                             ? nullptr
                             : credential.id_token.value().c_str();
  const char *access_token = !credential.access_token.has_value()
                                 ? nullptr
                                 : credential.access_token.value().c_str();
  const char *raw_nonce = !credential.raw_nonce.has_value()
                              ? nullptr
                              : credential.raw_nonce.value().c_str();

  if (credential.provider_id ==
      firebase::auth::EmailAuthProvider::kProviderId) {
    if (!email || !secret) {
      return false;
    }

    *out = firebase::auth::EmailAuthProvider::GetCredential(email, secret);
    return true;
  } else if (credential.provider_id ==
             firebase::auth::GoogleAuthProvider::kProviderId) {
    // It accepts idToken or accessToken
    if (!id_token && !access_token)
      return false;
    *out = firebase::auth::GoogleAuthProvider::GetCredential(id_token,
                                                             access_token);
    return true;
  } else if (credential.provider_id ==
             firebase::auth::FacebookAuthProvider::kProviderId) {
    if (!access_token)
      return false;
    *out = firebase::auth::FacebookAuthProvider::GetCredential(access_token);
    return true;
  } else if (credential.provider_id ==
             firebase::auth::GitHubAuthProvider::kProviderId) {
    if (!access_token)
      return false;
    *out = firebase::auth::GitHubAuthProvider::GetCredential(access_token);
    return true;
  } else if (credential.provider_id ==
             firebase::auth::TwitterAuthProvider::kProviderId) {
    if (!access_token && !secret)
      return false;
    *out = firebase::auth::TwitterAuthProvider::GetCredential(access_token,
                                                              secret);
    return true;
  } else { // Generic OAuth
    if (!id_token) {
      return false;
    }

    if (raw_nonce != nullptr) {
      *out = firebase::auth::OAuthProvider::GetCredential(
          provider_id, id_token, raw_nonce, access_token);
    } else {
      // access token cannot be null here
      if (!access_token) {
        return false;
      }
      *out = firebase::auth::OAuthProvider::GetCredential(provider_id, id_token,
                                                          access_token);
    }

    return true;
  }

  return false;
}

// Posts who is signed in to `port`: the CBOR from SerializeUser, or null for
// nobody.
//
// Called by the SDK, on whichever thread caused the change, and sometimes from
// inside a call this file made while holding g_auth_mutex -- adding a listener
// and signing out both notify before they return. So it takes no lock of its
// own and reads the user from the Auth it is handed.
void PostCurrentUser(const std::atomic<int64_t>& slot, Auth* auth) {
  const int64_t port = slot.load();
  if (port == 0 || auth == nullptr) return;

  Dart_CObject message{};
  message.type = Dart_CObject_kNull;
  std::vector<uint8_t> payload;
  const User user = auth->current_user();
  if (user.is_valid()) {
    // Dropped rather than posted as null: null says signed out, and a user
    // that would not encode is still signed in.
    if (!SerializeUser(user, payload)) return;
    message.type = Dart_CObject_kTypedData;
    message.value.as_typed_data.type = Dart_TypedData_kUint8;
    message.value.as_typed_data.length = static_cast<intptr_t>(payload.size());
    message.value.as_typed_data.values = payload.data();
  }
  Dart_PostCObject_DL(static_cast<Dart_Port_DL>(port), &message);
}

// One port per kind of listener. Zero is nobody listening.
std::atomic<int64_t> g_state_port{0};
std::atomic<int64_t> g_token_port{0};

class StateListener : public firebase::auth::AuthStateListener {
 public:
  void OnAuthStateChanged(Auth* auth) override {
    PostCurrentUser(g_state_port, auth);
  }
};

class TokenListener : public firebase::auth::IdTokenListener {
 public:
  void OnIdTokenChanged(Auth* auth) override {
    PostCurrentUser(g_token_port, auth);
  }
};

// Allocated on first use and never freed, like the Auth they attach to. A
// static would be destroyed at exit, and a listener's destructor reaches back
// into every Auth it was added to -- on a thread the SDK may still be using.
StateListener* g_state_listener = nullptr;
TokenListener* g_token_listener = nullptr;

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

// The signed-in uid, or an empty string. Copied into `out`; returns the length
// written, or -1 if the buffer is too small.
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

// The signed-in user, as the CBOR SerializeUser writes. Returns the encoded
// size, and copies it into `out` only when it fits in `cap` -- a caller that
// gets back more than it offered asks again with a buffer that size. 0 is
// nobody signed in, -1 Auth not initialized, -2 a user that would not encode.
FDB_EXPORT int64_t fdb_auth_current_user(uint8_t* out, size_t cap) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) return -1;
  const auto user = g_auth->current_user();
  if (!user.is_valid()) return 0;
  std::vector<uint8_t> payload;
  if (!SerializeUser(user, payload)) return -2;
  if (out != nullptr && payload.size() <= cap) {
    std::memcpy(out, payload.data(), payload.size());
  }
  return static_cast<int64_t>(payload.size());
}

// Reports who is signed in to `port`, now and on every change. `kind` 0 is the
// SDK's auth-state listener: sign-in, sign-out, a different user. `kind` 1 is
// its ID-token listener, which reports those and a refreshed token as well.
// Each message is the CBOR fdb_auth_current_user writes, or null for nobody.
//
// One port per kind; a second call replaces the first. A zero port stops it.
// Returns -1 if Auth is not initialized, -2 for a kind that does not exist.
//
// The listener is removed and added again on every call rather than left in
// place with a new port: the SDK reports the current state when a listener is
// added, which is the first event a new subscriber expects. If the SDK is
// still reading a persisted session it holds that event until it has.
FDB_EXPORT int64_t fdb_auth_listen(int32_t kind, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) return -1;
  if (kind == 0) {
    if (g_state_listener == nullptr) g_state_listener = new StateListener();
    g_auth->RemoveAuthStateListener(g_state_listener);
    g_state_port.store(port);
    if (port != 0) g_auth->AddAuthStateListener(g_state_listener);
    return 0;
  }
  if (kind == 1) {
    if (g_token_listener == nullptr) g_token_listener = new TokenListener();
    g_auth->RemoveIdTokenListener(g_token_listener);
    g_token_port.store(port);
    if (port != 0) g_auth->AddIdTokenListener(g_token_listener);
    return 0;
  }
  return -2;
}

}  // extern "C"
