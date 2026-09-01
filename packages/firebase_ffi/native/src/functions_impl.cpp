// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Cloud Functions: one callable, one round trip.
//
// Arguments and results are firebase::Variant, the same type the Realtime
// Database uses, so the CBOR encoder is shared with it. The decoder is new:
// nothing sent a Variant to the SDK before, because the Database binding only
// writes strings.

#include "firebase_bridge.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/functions.h"

namespace {

using ::firebase::Variant;
using ::firebase::functions::Functions;
using ::firebase::functions::HttpsCallableResult;

std::mutex g_mutex;
Functions* g_functions = nullptr;

// The callable reference has to outlive its request, for the same reason a
// StorageReference does: the SDK runs the call on a thread bound to that
// reference's internal, and a temporary destroyed at the end of the statement
// leaves that thread walking freed memory. It crashes inside the SDK's own
// curl transport, which reads as an SDK fault rather than a lifetime one.
//
// Cleaned up on the next call rather than in the completion, because
// destroying the reference inside its own callback frees what the completing
// thread is still unwinding through.
struct InFlightCall {
  std::unique_ptr<firebase::functions::HttpsCallableReference> ref;
  std::shared_ptr<std::atomic<bool>> done;
};
std::vector<InFlightCall> g_calls;

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_functions(void) { return 1; }

FDB_EXPORT int64_t fdb_functions_init(const char* region) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_functions != nullptr) return 0;
  firebase::App* app = fdb_current_app();
  if (app == nullptr) return -1;
  firebase::InitResult result = firebase::kInitResultSuccess;
  g_functions = region == nullptr || *region == '\0'
                    ? Functions::GetInstance(app, &result)
                    : Functions::GetInstance(app, region, &result);
  if (g_functions == nullptr || result != firebase::kInitResultSuccess) {
    g_functions = nullptr;
    return -2;
  }
  return 0;
}

FDB_EXPORT int64_t fdb_functions_use_emulator(const char* origin) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_functions == nullptr) return -1;
  if (origin == nullptr || *origin == '\0') return -2;
  g_functions->UseFunctionsEmulator(origin);
  return 0;
}

FDB_EXPORT int64_t fdb_functions_call(const char* name, const uint8_t* args,
                                     size_t len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_functions == nullptr) return -1;
  if (name == nullptr) return -2;

  Variant data = Variant::Null();
  if (args != nullptr && len != 0) {
    if (!fdb::ParseVariant(args, len, &data)) return -3;
  }

  g_calls.erase(
      std::remove_if(g_calls.begin(), g_calls.end(),
                     [](const InFlightCall& c) { return c.done->load(); }),
      g_calls.end());

  auto done = std::make_shared<std::atomic<bool>>(false);
  auto owned = std::make_unique<firebase::functions::HttpsCallableReference>(
      g_functions->GetHttpsCallable(name));
  auto* ref = owned.get();
  g_calls.push_back(InFlightCall{std::move(owned), done});

  ref->Call(data).OnCompletion(
      [port, done](const firebase::Future<HttpsCallableResult>& f) {
        std::vector<uint8_t> payload;
        if (f.error() != 0) {
          // The reason travels in the payload, as listeners do: a callable
          // usually fails on rules or a thrown error, and the code alone does
          // not say which.
          const std::string text =
              f.error_message() == nullptr ? "" : f.error_message();
          CborEncoder measure;
          cbor_encoder_init(&measure, nullptr, 0, 0);
          cbor_encode_text_string(&measure, text.c_str(), text.size());
          payload.resize(cbor_encoder_get_extra_bytes_needed(&measure));
          CborEncoder enc;
          cbor_encoder_init(&enc, payload.data(), payload.size(), 0);
          cbor_encode_text_string(&enc, text.c_str(), text.size());
          payload.resize(cbor_encoder_get_buffer_size(&enc, payload.data()));
          fdb_post_buffer(port, -1, payload.data(), payload.size());
          done->store(true);
          return;
        }
        if (f.result() != nullptr &&
            !fdb::SerializeVariant(f.result()->data(), payload)) {
          fdb_post_buffer(port, -2, nullptr, 0);
          done->store(true);
          return;
        }
        fdb_post_buffer(port, 1, payload.data(), payload.size());
        done->store(true);
      });
  return 0;
}

}  // extern "C"
