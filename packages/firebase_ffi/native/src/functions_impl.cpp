// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Cloud Functions: one callable, one round trip, in any region, on the
// default firebase::App or a named one.
//
// Arguments and results are firebase::Variant, the same type the Realtime
// Database uses, so the CBOR encoder is shared with it. The decoder is new:
// nothing sent a Variant to the SDK before, because the Database binding only
// writes strings.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/functions.h"
#include "firebase_bridge.h"

namespace {

using ::firebase::Variant;
using ::firebase::functions::Functions;
using ::firebase::functions::HttpsCallableResult;

std::mutex g_mutex;

// What the SDK calls the region when none is given.
constexpr const char* kDefaultRegion = "us-central1";

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

// One app's Functions and the calls running on them.
struct FunctionsState {
  // One Functions per region, as the SDK keeps them. The first one created is
  // what an empty region means afterwards, so a caller that only ever names a
  // region at init keeps working.
  std::map<std::string, Functions*> instances;
  Functions* first = nullptr;
  // Set while the app is being deleted. Nothing new starts.
  bool closing = false;
  std::vector<InFlightCall> calls;
};

// By app name, "" for the default app.
std::map<std::string, std::unique_ptr<FunctionsState>> g_states;

std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

// The state to start on, or null when the app has no Functions or is being
// deleted. Caller holds g_mutex.
FunctionsState* StateFor(const char* app) {
  const auto it = g_states.find(AppKey(app));
  if (it == g_states.end() || it->second->closing) return nullptr;
  return it->second.get();
}

// Caller holds g_mutex.
Functions* InstanceFor(const char* app, const char* region) {
  FunctionsState* state = StateFor(app);
  if (state == nullptr) return nullptr;
  if (region == nullptr || *region == '\0') return state->first;
  auto it = state->instances.find(region);
  return it == state->instances.end() ? nullptr : it->second;
}

// How long deleting an app waits for the calls running on its Functions, and
// how long after the last of them finished before the instances are deleted.
constexpr auto kReleaseWait = std::chrono::seconds(5);
constexpr auto kReleasePoll = std::chrono::milliseconds(10);
constexpr auto kReleaseSettle = std::chrono::milliseconds(50);

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_functions(void) { return 1; }

FDB_EXPORT int64_t fdb_functions_init(const char* app, const char* region) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const std::string key =
      region == nullptr || *region == '\0' ? kDefaultRegion : region;
  const std::string app_key = AppKey(app);
  auto found = g_states.find(app_key);
  if (found != g_states.end()) {
    // -1 for one that is on its way out: the app is as good as gone.
    if (found->second->closing) return -1;
    if (found->second->instances.count(key) != 0) return 0;
  }
  firebase::App* owner = fdb_app_named(app);
  if (owner == nullptr) return -1;
  firebase::InitResult result = firebase::kInitResultSuccess;
  Functions* functions = Functions::GetInstance(owner, key.c_str(), &result);
  if (functions == nullptr || result != firebase::kInitResultSuccess) {
    return -2;
  }
  if (found == g_states.end()) {
    found = g_states.emplace(app_key, std::make_unique<FunctionsState>()).first;
  }
  FunctionsState* state = found->second.get();
  state->instances[key] = functions;
  if (state->first == nullptr) state->first = functions;
  return 0;
}

// A call runs on the SDK's transport thread, through the reference that
// started it, and deleting the Functions frees that reference under the
// thread. A call cannot be canceled, so it is waited for. One that outlasts
// the wait leaves everything as it was and answers -1. On 0 nothing new starts
// on the app until fdb_functions_release or fdb_functions_resume.
int64_t fdb_functions_quiesce(const char* app) {
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
      const auto& calls = it->second->calls;
      if (std::all_of(calls.begin(), calls.end(),
                      [](const InFlightCall& c) { return c.done->load(); })) {
        return 0;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        it->second->closing = false;
        return -1;
      }
    }
    std::this_thread::sleep_for(kReleasePoll);
  }
}

void fdb_functions_resume(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_states.find(AppKey(app));
  if (it != g_states.end()) it->second->closing = false;
}

// `done` is set in the completion, a few frames before the thread is out of
// the reference. The settle covers those frames; it is the same allowance the
// calls make by leaving a finished reference until the next one.
void fdb_functions_release(const char* app) {
  std::unique_ptr<FunctionsState> state;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(AppKey(app));
    if (it == g_states.end()) return;
    state = std::move(it->second);
    g_states.erase(it);
  }
  if (!state->calls.empty()) std::this_thread::sleep_for(kReleaseSettle);
  // References first: each holds on to its Functions.
  state->calls.clear();
  for (const auto& entry : state->instances) delete entry.second;
}

FDB_EXPORT int64_t fdb_functions_use_emulator(const char* app,
                                              const char* region,
                                              const char* origin) {
  std::lock_guard<std::mutex> lock(g_mutex);
  Functions* functions = InstanceFor(app, region);
  if (functions == nullptr) return -1;
  if (origin == nullptr || *origin == '\0') return -2;
  functions->UseFunctionsEmulator(origin);
  return 0;
}

FDB_EXPORT int64_t fdb_functions_call(const char* app, const char* region,
                                      const char* target, int32_t flags,
                                      const uint8_t* args, size_t len,
                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  Functions* functions = InstanceFor(app, region);
  if (functions == nullptr) return -1;
  if (target == nullptr || *target == '\0') return -2;
  if ((flags & ~(FDB_FUNCTIONS_CALL_URL | FDB_FUNCTIONS_CALL_LIMITED_USE)) !=
      0) {
    return -4;
  }

  Variant data = Variant::Null();
  if (args != nullptr && len != 0) {
    if (!fdb::ParseVariant(args, len, &data)) return -3;
  }

  // Not null: InstanceFor found an instance on it, under this lock.
  auto& calls = StateFor(app)->calls;
  calls.erase(
      std::remove_if(calls.begin(), calls.end(),
                     [](const InFlightCall& c) { return c.done->load(); }),
      calls.end());

  auto done = std::make_shared<std::atomic<bool>>(false);
  firebase::functions::HttpsCallableOptions options;
  options.limited_use_app_check_token =
      (flags & FDB_FUNCTIONS_CALL_LIMITED_USE) != 0;
  // A URL is used as given: the region and the emulator origin only shape the
  // address the SDK builds from a name.
  auto owned = std::make_unique<firebase::functions::HttpsCallableReference>(
      (flags & FDB_FUNCTIONS_CALL_URL) != 0
          ? functions->GetHttpsCallableFromURL(target, options)
          : functions->GetHttpsCallable(target, options));
  auto* ref = owned.get();
  calls.push_back(InFlightCall{std::move(owned), done});

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
