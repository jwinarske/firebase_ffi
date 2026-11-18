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
#include <mutex>
#include <optional>
#include <string>
#include <utility>
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

// Refuses a string with a NUL in it. The SDK takes these as C strings, so one
// would be cut there, and a password that is cut is a different password.
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

  const bool whole = memchr(buffer, '\0', length) == nullptr;
  if (whole) out->assign(buffer, length);
  free(buffer);

  return whole;
}

bool ReadCborOptionalString(CborValue* value, std::optional<std::string>* out) {
  if (cbor_value_is_null(value)) {
    *out = std::nullopt;
    return true;
  }

  std::string text;
  if (!ReadCborString(value, &text)) {
    return false;
  }
  *out = std::move(text);
  return true;
}

bool ParseCredentialData(const uint8_t* data, size_t data_len,
                         CredentialData* credential) {
  if (data == nullptr || credential == nullptr) {
    return false;
  }

  CborParser parser;
  CborValue root;

  CborError err = cbor_parser_init(data, data_len, 0, &parser, &root);

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

// Null when a field is absent or was sent as null. firebase_auth's asMap()
// sends every field it knows, so most of them arrive as null.
const char* OrNull(const std::optional<std::string>& value) {
  return value.has_value() ? value->c_str() : nullptr;
}

// Builds the SDK credential a parsed map describes. Returns null on success,
// or what the provider needed and did not get.
//
// Every check here is one the SDK makes with FIREBASE_ASSERT in the matching
// GetCredential, so a credential that fails one must not reach it.
const char* BuildCredential(const CredentialData& data,
                            firebase::auth::Credential* out) {
  const char* provider_id = data.provider_id.c_str();
  const char* email = OrNull(data.email);
  const char* secret = OrNull(data.secret);
  const char* id_token = OrNull(data.id_token);
  const char* access_token = OrNull(data.access_token);
  const char* raw_nonce = OrNull(data.raw_nonce);

  if (data.provider_id == firebase::auth::EmailAuthProvider::kProviderId) {
    if (!email || !secret) return "an email and a password are required";
    *out = firebase::auth::EmailAuthProvider::GetCredential(email, secret);
  } else if (data.provider_id ==
             firebase::auth::GoogleAuthProvider::kProviderId) {
    if (!id_token && !access_token) {
      return "an ID token or an access token is required";
    }
    *out = firebase::auth::GoogleAuthProvider::GetCredential(id_token,
                                                             access_token);
  } else if (data.provider_id ==
             firebase::auth::FacebookAuthProvider::kProviderId) {
    if (!access_token) return "an access token is required";
    *out = firebase::auth::FacebookAuthProvider::GetCredential(access_token);
  } else if (data.provider_id ==
             firebase::auth::GitHubAuthProvider::kProviderId) {
    if (!access_token) return "an access token is required";
    *out = firebase::auth::GitHubAuthProvider::GetCredential(access_token);
  } else if (data.provider_id ==
             firebase::auth::TwitterAuthProvider::kProviderId) {
    if (!access_token || !secret) {
      return "an access token and a secret are required";
    }
    *out = firebase::auth::TwitterAuthProvider::GetCredential(access_token,
                                                              secret);
  } else {
    // Any other provider id is a generic OAuth one, which is how Apple
    // arrives.
    if (!id_token) return "an ID token is required";
    if (raw_nonce != nullptr) {
      *out = firebase::auth::OAuthProvider::GetCredential(
          provider_id, id_token, raw_nonce, access_token);
    } else {
      if (!access_token) {
        return "an access token or a raw nonce is required with the ID token";
      }
      *out = firebase::auth::OAuthProvider::GetCredential(provider_id, id_token,
                                                          access_token);
    }
  }
  return nullptr;
}

void* PortData(int64_t port) {
  return reinterpret_cast<void*>(static_cast<intptr_t>(port));
}

// Completion for a call that answers nothing: [ok, code, message].
void OnDone(const firebase::Future<void>& future, void* user_data) {
  const auto port = static_cast<int64_t>(reinterpret_cast<intptr_t>(user_data));
  fdb_post_outcome(
      port, future.error() == 0 ? 1 : 0, future.error(),
      future.error_message() == nullptr ? "" : future.error_message());
}

const char kNoUser[] = "no user is signed in";

// The SDK hands back an invalid future when the user went away between the
// check and the call. No completion ever runs on one, so it is answered here
// rather than left for the caller to wait on.
void Answer(const firebase::Future<void>& future, int64_t port) {
  if (future.status() == firebase::kFutureStatusInvalid) {
    fdb_post_outcome(port, 0, firebase::auth::kAuthErrorNoSignedInUser,
                     kNoUser);
    return;
  }
  future.OnCompletion(OnDone, PortData(port));
}

void Answer(const firebase::Future<AuthResult>& future, int64_t port) {
  if (future.status() == firebase::kFutureStatusInvalid) {
    PostAuthResult(static_cast<Dart_Port_DL>(port), false,
                   firebase::auth::kAuthErrorNoSignedInUser, kNoUser, "", {});
    return;
  }
  future.OnCompletion(OnSignInComplete, PortData(port));
}

// The credential a CBOR map describes. 0 with `out` set, -2 for bytes that
// are not such a map, and 1 when the map lacks what its provider needs --
// which has been answered on `port` as kAuthErrorInvalidCredential, the way
// the SDK would refuse it, so a caller hears that in one place.
int CredentialFrom(const uint8_t* spec, size_t spec_len, int64_t port,
                   firebase::auth::Credential* out) {
  CredentialData data;
  if (!ParseCredentialData(spec, spec_len, &data) || data.provider_id.empty()) {
    return -2;
  }
  if (const char* missing = BuildCredential(data, out)) {
    PostAuthResult(static_cast<Dart_Port_DL>(port), false,
                   firebase::auth::kAuthErrorInvalidCredential,
                   data.provider_id + ": " + missing, "", {});
    return 1;
  }
  return 0;
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

// What one app's Auth needs: the instance, and a port per kind of listener.
// Zero is nobody listening.
struct AuthState;

class StateListener : public firebase::auth::AuthStateListener {
 public:
  explicit StateListener(const AuthState* state) : state_(state) {}
  void OnAuthStateChanged(Auth* auth) override;

 private:
  const AuthState* state_;
};

class TokenListener : public firebase::auth::IdTokenListener {
 public:
  explicit TokenListener(const AuthState* state) : state_(state) {}
  void OnIdTokenChanged(Auth* auth) override;

 private:
  const AuthState* state_;
};

struct AuthState {
  Auth* auth = nullptr;
  std::atomic<int64_t> state_port{0};
  std::atomic<int64_t> token_port{0};
  // Allocated on first use. Freed with the state, when a named app is
  // deleted; the default app's are never freed, like its Auth. A static would
  // be destroyed at exit, and a listener's destructor reaches back into every
  // Auth it was added to -- on a thread the SDK may still be using.
  StateListener* state_listener = nullptr;
  TokenListener* token_listener = nullptr;
};

void StateListener::OnAuthStateChanged(Auth* auth) {
  PostCurrentUser(state_->state_port, auth);
}

void TokenListener::OnIdTokenChanged(Auth* auth) {
  PostCurrentUser(state_->token_port, auth);
}

// One per app that fdb_auth_init has run for, by app name. The default app is
// the empty name. Guarded by g_auth_mutex.
std::map<std::string, AuthState*> g_auths;

// Null and empty both name the default app.
std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

// Caller holds g_auth_mutex. Null until fdb_auth_init has run for the app.
AuthState* StateFor(const char* app) {
  const auto it = g_auths.find(AppKey(app));
  return it == g_auths.end() ? nullptr : it->second;
}

Auth* AuthFor(const char* app) {
  AuthState* state = StateFor(app);
  return state == nullptr ? nullptr : state->auth;
}

}  // namespace

extern "C" {

// Point Auth at a local emulator. Must be called after fdb_auth_init and
// before signing in: the SDK reconfigures the endpoint, it does not migrate a
// session that already exists.
FDB_EXPORT int64_t fdb_auth_use_emulator(const char* app, const char* host,
                                         int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  auth->UseEmulator(std::string(host), static_cast<uint32_t>(port));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_init(const char* app) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (StateFor(app) != nullptr) {
    return 0;
  }
  firebase::App* instance = fdb_app_named(app);
  if (instance == nullptr) {
    return -1;  // no such app: fdb_app_init or fdb_app_create has not run
  }
  firebase::InitResult init_result;
  Auth* auth = Auth::GetAuth(instance, &init_result);
  if (auth == nullptr || init_result != firebase::kInitResultSuccess) {
    return -2;
  }
  auto* state = new AuthState();
  state->auth = auth;
  g_auths[AppKey(app)] = state;
  return 0;
}

// Lets go of a named app's Auth, so the app can be deleted. Called by
// fdb_app_delete, before the app goes. Nothing to do for an app Auth was
// never initialized on.
//
// A call still waiting on the SDK is not answered: deleting the Auth drops
// its futures. An app is deleted when it is finished with, not mid sign-in.
void fdb_auth_release(const char* app) {
  if (app == nullptr || *app == '\0') return;  // the default app stays
  AuthState* state = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_auth_mutex);
    const auto it = g_auths.find(app);
    if (it == g_auths.end()) return;
    state = it->second;
    g_auths.erase(it);
    // Ports first: removing a listener does not stop one already running.
    state->state_port.store(0);
    state->token_port.store(0);
    if (state->state_listener != nullptr) {
      state->auth->RemoveAuthStateListener(state->state_listener);
    }
    if (state->token_listener != nullptr) {
      state->auth->RemoveIdTokenListener(state->token_listener);
    }
  }
  // Outside the lock: the Auth's destructor waits for its own work, and a
  // completion running on that thread may be waiting for the lock.
  delete state->auth;
  delete state->state_listener;
  delete state->token_listener;
  delete state;
}

FDB_EXPORT int64_t fdb_auth_sign_in_anonymously(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) {
    return -1;
  }
  auth->SignInAnonymously().OnCompletion(
      OnSignInComplete, reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_in_with_custom_token(const char* app,
                                                      const char* token,
                                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) {
    return -1;
  }
  if (token == nullptr || *token == '\0') {
    return -2;
  }
  auth->SignInWithCustomToken(token).OnCompletion(
      OnSignInComplete, reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

// `spec` is a CBOR map: providerId, and whichever of email, secret, idToken,
// accessToken and rawNonce the provider takes. Other keys are skipped.
//
// A map the provider cannot be built from is answered on `port` as
// kAuthErrorInvalidCredential. -2 is kept for a `spec` that is not such a
// map at all.
FDB_EXPORT int64_t fdb_auth_sign_in_with_credential(const char* app,
                                                    const uint8_t* spec,
                                                    size_t spec_len,
                                                    int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) {
    return -1;
  }

  firebase::auth::Credential credential;
  const int built = CredentialFrom(spec, spec_len, port, &credential);
  if (built != 0) {
    return built < 0 ? built : 0;
  }

  auth->SignInAndRetrieveDataWithCredential(credential)
      .OnCompletion(OnSignInComplete,
                    reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

FDB_EXPORT int64_t fdb_auth_sign_out(const char* app) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) {
    return -1;
  }
  auth->SignOut();
  return 0;
}

// An empty email or password goes to the SDK, which answers on `port` with
// the code for it. -2 is only for a null pointer.
FDB_EXPORT int64_t fdb_auth_create_user_with_email_and_password(
    const char* app, const char* email, const char* password, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) {
    return -1;
  }
  if (email == nullptr || password == nullptr) {
    return -2;
  }
  auth->CreateUserWithEmailAndPassword(email, password)
      .OnCompletion(OnSignInComplete,
                    reinterpret_cast<void*>(static_cast<intptr_t>(port)));
  return 0;
}

// The signed-in user's ID token, for talking to a Firebase REST endpoint
// directly. Asynchronous because the SDK refreshes an expired one, which is a
// network call.
//
// GetToken, not GetTokenThreadSafe: the latter is declared only under
// INTERNAL_EXPERIMENTAL and is not in a normal build. g_auth_mutex is held
// across the call for the same reason every other accessor here holds it.
FDB_EXPORT int64_t fdb_auth_id_token(const char* app, int32_t force_refresh,
                                     int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  auto user = auth->current_user();
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
FDB_EXPORT int64_t fdb_auth_current_uid(const char* app, char* out,
                                        size_t cap) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr || out == nullptr) {
    return -1;
  }
  const auto user = auth->current_user();
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
FDB_EXPORT int64_t fdb_auth_current_user(const char* app, uint8_t* out,
                                         size_t cap) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  const auto user = auth->current_user();
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
// One port per kind and app; a second call replaces the first. A zero port
// stops it. Returns -1 if Auth is not initialized on the app, -2 for a kind
// that does not exist.
//
// The listener is removed and added again on every call rather than left in
// place with a new port: the SDK reports the current state when a listener is
// added, which is the first event a new subscriber expects. If the SDK is
// still reading a persisted session it holds that event until it has.
FDB_EXPORT int64_t fdb_auth_listen(const char* app, int32_t kind,
                                   int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  AuthState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (kind == 0) {
    if (state->state_listener == nullptr) {
      state->state_listener = new StateListener(state);
    }
    state->auth->RemoveAuthStateListener(state->state_listener);
    state->state_port.store(port);
    if (port != 0) state->auth->AddAuthStateListener(state->state_listener);
    return 0;
  }
  if (kind == 1) {
    if (state->token_listener == nullptr) {
      state->token_listener = new TokenListener(state);
    }
    state->auth->RemoveIdTokenListener(state->token_listener);
    state->token_port.store(port);
    if (port != 0) state->auth->AddIdTokenListener(state->token_listener);
    return 0;
  }
  return -2;
}

// ── Account management ──────────────────────────────────────────────────────
//
// Each of these answers on `port`. With nobody signed in that answer is
// kAuthErrorNoSignedInUser, not a return code: a caller holding a user from
// before a sign-out finds out the same way it finds out anything else.
// Returns -1 if Auth is not initialized and -2 for a null argument.

FDB_EXPORT int64_t fdb_auth_send_password_reset_email(const char* app,
                                                      const char* email,
                                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  if (email == nullptr) return -2;
  Answer(auth->SendPasswordResetEmail(email), port);
  return 0;
}

// The SDK merges what the server holds into its copy of the user. It notifies
// no listener for that, so the caller reads the user again afterwards.
FDB_EXPORT int64_t fdb_auth_user_reload(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  Answer(auth->current_user().Reload(), port);
  return 0;
}

// Deletes the account and signs out.
FDB_EXPORT int64_t fdb_auth_user_delete(const char* app, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  Answer(auth->current_user().Delete(), port);
  return 0;
}

FDB_EXPORT int64_t fdb_auth_user_send_email_verification(const char* app,
                                                         int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  Answer(auth->current_user().SendEmailVerification(), port);
  return 0;
}

// Mails a link to `email`. The account's address changes when it is followed.
FDB_EXPORT int64_t fdb_auth_user_verify_before_update_email(const char* app,
                                                            const char* email,
                                                            int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  if (email == nullptr) return -2;
  Answer(auth->current_user().SendEmailVerificationBeforeUpdatingEmail(email),
         port);
  return 0;
}

FDB_EXPORT int64_t fdb_auth_user_update_password(const char* app,
                                                 const char* password,
                                                 int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  if (password == nullptr) return -2;
  Answer(auth->current_user().UpdatePassword(password), port);
  return 0;
}

// A null field is left as it is, and an empty one is removed from the
// account: that is how the SDK reads its UserProfile.
FDB_EXPORT int64_t fdb_auth_user_update_profile(const char* app,
                                                const char* display_name,
                                                const char* photo_url,
                                                int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  User::UserProfile profile;
  profile.display_name = display_name;
  profile.photo_url = photo_url;
  Answer(auth->current_user().UpdateUserProfile(profile), port);
  return 0;
}

// The three below answer as a sign-in does: [ok, code, message, uid, user].
// `spec` is the map fdb_auth_sign_in_with_credential takes.

FDB_EXPORT int64_t fdb_auth_user_link_with_credential(const char* app,
                                                      const uint8_t* spec,
                                                      size_t spec_len,
                                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  firebase::auth::Credential credential;
  const int built = CredentialFrom(spec, spec_len, port, &credential);
  if (built != 0) return built < 0 ? built : 0;
  Answer(auth->current_user().LinkWithCredential(credential), port);
  return 0;
}

FDB_EXPORT int64_t fdb_auth_user_reauthenticate(const char* app,
                                                const uint8_t* spec,
                                                size_t spec_len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  firebase::auth::Credential credential;
  const int built = CredentialFrom(spec, spec_len, port, &credential);
  if (built != 0) return built < 0 ? built : 0;
  Answer(auth->current_user().ReauthenticateAndRetrieveData(credential), port);
  return 0;
}

FDB_EXPORT int64_t fdb_auth_user_unlink(const char* app,
                                        const char* provider_id, int64_t port) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  Auth* const auth = AuthFor(app);
  if (auth == nullptr) return -1;
  if (provider_id == nullptr) return -2;
  Answer(auth->current_user().Unlink(provider_id), port);
  return 0;
}

}  // extern "C"
