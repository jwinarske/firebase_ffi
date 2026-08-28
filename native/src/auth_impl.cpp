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

#include "dart_api_dl.h"
#include "firebase_bridge.h"

#include "firebase/app.h"
#include "firebase/auth.h"

namespace {

using ::firebase::auth::Auth;
using ::firebase::auth::AuthResult;

std::mutex g_auth_mutex;
Auth* g_auth = nullptr;

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

}  // namespace

extern "C" {

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

FDB_EXPORT int64_t fdb_auth_sign_out(void) {
  std::lock_guard<std::mutex> lock(g_auth_mutex);
  if (g_auth == nullptr) {
    return -1;
  }
  g_auth->SignOut();
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

}  // extern "C"
