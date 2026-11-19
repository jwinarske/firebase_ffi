// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Cloud Storage, on the default firebase::App or a named one.
//
// Objects are bytes, not documents, so this module is where the external
// typed data path earns what it costs. A download is written once, into the
// buffer that is handed to the Dart GC: no copy at any size. Database values
// travel the same way but are small enough that it never mattered.
//
// Metadata travels as CBOR, encoded with the same grow-and-retry discipline
// the other encoders use -- a measuring pass against a null buffer has to walk
// the whole structure, and stopping at the first CborErrorOutOfMemory sizes the
// buffer from a partial count. That bug shipped once already.

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
#include "firebase/storage.h"
#include "firebase/storage/controller.h"
#include "firebase/storage/list_result.h"
#include "firebase/storage/listener.h"
#include "firebase_bridge.h"

namespace {

using ::firebase::storage::Controller;
using ::firebase::storage::Listener;
using ::firebase::storage::Metadata;
using ::firebase::storage::Storage;
using ::firebase::storage::StorageListResult;
using ::firebase::storage::StorageReference;

std::mutex g_mutex;

// The StorageReference that starts an operation has to outlive it.
//
// The SDK runs the request on a std::thread bound to that reference's
// internal, so a reference destroyed while its request is in flight leaves
// that thread locking a mutex in freed memory:
//
//   pthread_mutex_lock <- firebase::Mutex::Acquire
//                      <- firebase::FutureManager::GetFutureApi
//                      <- StorageReferenceInternal::AsyncSendRequestWithRetry
//
// Intermittently, on an SDK thread with no Dart isolate attached. Holding a
// *copy* in the completion callback does not help: a copy has its own
// internal, and the one that started the work is still destroyed at the end of
// the statement.
//
// So each operation gets a heap-allocated reference that lives until it
// finishes. Cleanup is deferred to the next call rather than done in the
// callback, because destroying the reference inside its own completion would
// free the internal the completing thread is still unwinding through.
struct InFlight {
  std::unique_ptr<StorageReference> ref;
  std::shared_ptr<std::atomic<bool>> done;
};

struct Task;

// One app's Storage and what is running on it. The SDK keeps a Storage per
// app, so the references and tasks that came from one are kept with it: they
// have to be gone before it is.
struct StorageState {
  Storage* storage = nullptr;
  // Set while the app is being deleted. Nothing new starts.
  bool closing = false;
  std::vector<InFlight> inflight;
  // Tasks by id. A finished one is dropped when the next starts rather than in
  // its completion, for the reason InFlight gives: the completing thread is
  // still inside the reference the task owns.
  std::map<int64_t, std::shared_ptr<Task>> tasks;
};

// By app name, "" for the default app.
std::map<std::string, std::unique_ptr<StorageState>> g_states;
// One sequence for every app, so a task id names its task without the app.
int64_t g_next_task = 1;

std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

// The state to start an operation on, or null when the app has no Storage or
// is being deleted. Caller holds g_mutex.
StorageState* StateFor(const char* app) {
  const auto it = g_states.find(AppKey(app));
  if (it == g_states.end() || it->second->closing) return nullptr;
  return it->second.get();
}

// Caller holds g_mutex.
StorageReference* Retain(StorageState* state, const char* path,
                         std::shared_ptr<std::atomic<bool>>* done_out) {
  auto& inflight = state->inflight;
  inflight.erase(
      std::remove_if(inflight.begin(), inflight.end(),
                     [](const InFlight& f) { return f.done->load(); }),
      inflight.end());

  auto done = std::make_shared<std::atomic<bool>>(false);
  auto owned =
      std::make_unique<StorageReference>(state->storage->GetReference(path));
  StorageReference* raw = owned.get();
  inflight.push_back(InFlight{std::move(owned), done});
  *done_out = done;
  return raw;
}

// Progress for one upload, as [state, transferred, total]. State is one of
// FDB_STORAGE_TASK_*.
void PostProgress(int64_t port, int64_t state, int64_t transferred,
                  int64_t total) {
  Dart_CObject c_state{};
  c_state.type = Dart_CObject_kInt64;
  c_state.value.as_int64 = state;
  Dart_CObject c_done{};
  c_done.type = Dart_CObject_kInt64;
  c_done.value.as_int64 = transferred;
  Dart_CObject c_total{};
  c_total.type = Dart_CObject_kInt64;
  c_total.value.as_int64 = total;
  Dart_CObject* items[3] = {&c_state, &c_done, &c_total};
  Dart_CObject arr{};
  arr.type = Dart_CObject_kArray;
  arr.value.as_array.length = 3;
  arr.value.as_array.values = items;
  Dart_PostCObject_DL(port, &arr);
}

// An upload that can be watched and steered.
//
// The SDK offers a Controller two ways and only one is usable here. The
// controller_out argument is assigned on the SDK's worker thread, some time
// after the call returns, by an operator= that deletes and replaces what the
// Controller points at -- so reading it from the thread that wants to pause is
// a race the caller cannot close. The Listener is handed the operation's own
// Controller on every event, on a thread that is allowed to touch it, so the
// copy is taken there.
//
// The copy is replaced on every event rather than kept, because a retried
// upload is a new operation and a Controller for the old one is dead.
//
// The lock here covers the pointer swap and nothing else. The SDK calls the
// listener holding the operation's mutex, and Pause() takes that same mutex
// from the other side, so a lock held across either would deadlock against
// it. OnPaused arrives inside Pause(), on the thread that called it.
class Reporter : public Listener {
 public:
  explicit Reporter(int64_t progress_port) : port_(progress_port) {}

  void OnProgress(Controller* controller) override {
    Capture(controller);
    PostProgress(port_, FDB_STORAGE_TASK_RUNNING,
                 controller->bytes_transferred(),
                 controller->total_byte_count());
  }

  void OnPaused(Controller* controller) override {
    Capture(controller);
    PostProgress(port_, FDB_STORAGE_TASK_PAUSED,
                 controller->bytes_transferred(),
                 controller->total_byte_count());
  }

  std::shared_ptr<Controller> controller() {
    std::lock_guard<std::mutex> lock(swap_);
    return controller_;
  }

  // True once the SDK has attached this to a transfer.
  std::atomic<bool> attached{false};

 private:
  void Capture(Controller* controller) {
    attached.store(true);
    auto fresh = std::make_shared<Controller>(*controller);
    std::shared_ptr<Controller> old;
    {
      std::lock_guard<std::mutex> lock(swap_);
      old = std::move(controller_);
      controller_ = std::move(fresh);
    }
    // `old` is let go here, outside the lock.
  }

  int64_t port_;
  std::mutex swap_;
  std::shared_ptr<Controller> controller_;
};

struct Task {
  explicit Task(int64_t progress_port)
      : reporter(progress_port == 0 ? nullptr : new Reporter(progress_port)) {}

  // The SDK's Listener does not initialize the pointer to its transfer, and
  // its destructor reads it. One that was never attached -- a file that could
  // not be opened never starts a transfer -- holds whatever the allocator left
  // there, and destroying it faulted on Windows. Such a reporter is left
  // allocated: it is small, and that path is a failed upload.
  ~Task() {
    if (reporter != nullptr && reporter->attached.load()) delete reporter;
  }

  Task(const Task&) = delete;
  Task& operator=(const Task&) = delete;

  // Null for an upload nobody watches, which then cannot be steered either.
  Reporter* reporter;
  std::unique_ptr<StorageReference> ref;
  // PutBytes does not take ownership and the upload outlives the call.
  std::vector<uint8_t> bytes;
  // What the caller set, for an upload that carries any.
  Metadata metadata;
  std::atomic<bool> done{false};
};

// Encodes one metadata field only when the SDK actually has it: a null or
// empty string is absence, and writing "" for it would tell the Dart side the
// field was set to an empty value.
bool EncodeTextField(CborEncoder* map, const char* key, const char* value) {
  if (value == nullptr || *value == '\0') return true;
  if (cbor_encode_text_stringz(map, key) != CborNoError) return false;
  return cbor_encode_text_stringz(map, value) == CborNoError;
}

bool EncodeIntField(CborEncoder* map, const char* key, int64_t value) {
  if (cbor_encode_text_stringz(map, key) != CborNoError) return false;
  return cbor_encode_int(map, value) == CborNoError;
}

// One pass over the metadata. Returns false only on a real encoder error;
// CborErrorOutOfMemory is expected while measuring and must not stop the walk,
// or the size this is measuring for comes out short.
bool EncodeMetadata(const Metadata& m, CborEncoder* out) {
  CborEncoder map;
  cbor_encoder_create_map(out, &map, CborIndefiniteLength);

  EncodeTextField(&map, "bucket", m.bucket());
  EncodeTextField(&map, "name", m.name());
  EncodeTextField(&map, "path", m.path());
  EncodeTextField(&map, "contentType", m.content_type());
  EncodeTextField(&map, "cacheControl", m.cache_control());
  EncodeTextField(&map, "contentDisposition", m.content_disposition());
  EncodeTextField(&map, "contentEncoding", m.content_encoding());
  EncodeTextField(&map, "contentLanguage", m.content_language());
  EncodeTextField(&map, "md5Hash", m.md5_hash());
  EncodeIntField(&map, "sizeBytes", m.size_bytes());
  EncodeIntField(&map, "creationTime", m.creation_time());
  EncodeIntField(&map, "updatedTime", m.updated_time());
  EncodeIntField(&map, "generation", m.generation());
  EncodeIntField(&map, "metadataGeneration", m.metadata_generation());

  // Whatever the caller attached on upload, under one key so it cannot collide
  // with a field name this ABI defines.
  const std::map<std::string, std::string>* custom = m.custom_metadata();
  if (custom != nullptr && !custom->empty()) {
    cbor_encode_text_stringz(&map, "custom");
    CborEncoder inner;
    cbor_encoder_create_map(&map, &inner, CborIndefiniteLength);
    for (const auto& kv : *custom) {
      cbor_encode_text_stringz(&inner, kv.first.c_str());
      cbor_encode_text_stringz(&inner, kv.second.c_str());
    }
    cbor_encoder_close_container(&map, &inner);
  }

  cbor_encoder_close_container(out, &map);
  return true;
}

}  // namespace

namespace fdb {

bool SerializeMetadata(const Metadata& m, std::vector<uint8_t>& out) {
  // Grow and retry rather than size against a null buffer in one pass: the
  // encoder reports the shortfall only for the item that overflowed, so a
  // structure with containers needs the walk to continue past the first
  // failure. Doubling from a reasonable start converges in a step or two.
  size_t capacity = 512;
  for (int attempt = 0; attempt < 8; ++attempt) {
    out.assign(capacity, 0);
    CborEncoder enc;
    cbor_encoder_init(&enc, out.data(), out.size(), 0);
    EncodeMetadata(m, &enc);
    const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
    if (extra == 0) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    capacity = (capacity + extra) * 2;
  }
  out.clear();
  return false;
}

}  // namespace fdb

namespace {

// A listing as {prefixes: [path], items: [path], nextPageToken: text}. Paths
// are full paths without the leading slash the SDK puts on them, which is how
// every other call here takes one.
void EncodeList(const StorageListResult& r, CborEncoder* out) {
  CborEncoder map;
  cbor_encoder_create_map(out, &map, CborIndefiniteLength);
  auto paths = [&map](const char* key,
                      const std::vector<StorageReference>& refs) {
    cbor_encode_text_stringz(&map, key);
    CborEncoder arr;
    cbor_encoder_create_array(&map, &arr, CborIndefiniteLength);
    // By value: full_path() is not const.
    for (StorageReference ref : refs) {
      const std::string full = ref.full_path();
      const size_t skip = !full.empty() && full[0] == '/' ? 1 : 0;
      cbor_encode_text_string(&arr, full.c_str() + skip, full.size() - skip);
    }
    cbor_encoder_close_container(&map, &arr);
  };
  paths("prefixes", r.prefixes());
  paths("items", r.items());
  EncodeTextField(&map, "nextPageToken", r.next_page_token().c_str());
  cbor_encoder_close_container(out, &map);
}

// Grow and retry, as SerializeMetadata does and for the same reason.
bool SerializeList(const StorageListResult& r, std::vector<uint8_t>& out) {
  size_t capacity = 1024;
  for (int attempt = 0; attempt < 12; ++attempt) {
    out.assign(capacity, 0);
    CborEncoder enc;
    cbor_encoder_init(&enc, out.data(), out.size(), 0);
    EncodeList(r, &enc);
    const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
    if (extra == 0) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    capacity = (capacity + extra) * 2;
  }
  out.clear();
  return false;
}

// Posts a metadata result, or an outcome when the operation failed. Shared by
// every call that answers with metadata.
void PostMetadataResult(int64_t port, const firebase::Future<Metadata>& f) {
  if (f.error() != 0) {
    fdb_post_outcome(port, 0, f.error(),
                     f.error_message() == nullptr ? "" : f.error_message());
    return;
  }
  std::vector<uint8_t> payload;
  if (f.result() == nullptr || !fdb::SerializeMetadata(*f.result(), payload)) {
    fdb_post_outcome(port, 0, -2, "could not encode metadata");
    return;
  }
  fdb_post_buffer(port, 1, payload.data(), payload.size());
}

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_have_storage(void) { return 1; }

FDB_EXPORT int64_t fdb_storage_init(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const std::string key = AppKey(app);
  const auto it = g_states.find(key);
  // -1 for one that is on its way out too: the app is as good as gone.
  if (it != g_states.end()) return it->second->closing ? -1 : 0;
  firebase::App* owner = fdb_app_named(app);
  if (owner == nullptr) return -1;
  firebase::InitResult result = firebase::kInitResultSuccess;
  Storage* storage = Storage::GetInstance(owner, &result);
  if (storage == nullptr || result != firebase::kInitResultSuccess) return -2;
  auto state = std::make_unique<StorageState>();
  state->storage = storage;
  g_states[key] = std::move(state);
  return 0;
}

FDB_EXPORT int64_t fdb_storage_use_emulator(const char* app, const char* host,
                                            int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  state->storage->UseEmulator(host, static_cast<int>(port));
  return 0;
}

extern "C++" {
namespace {

// How long deleting an app waits for what is running on its Storage, and how
// long after the last of it finished before the Storage is deleted.
constexpr auto kReleaseWait = std::chrono::seconds(5);
constexpr auto kReleasePoll = std::chrono::milliseconds(10);
constexpr auto kReleaseSettle = std::chrono::milliseconds(50);

// Caller holds g_mutex.
bool Idle(const StorageState& state);

// The controllers of the transfers still running that are not in `seen`,
// added to it. Caller holds g_mutex.
std::vector<std::shared_ptr<Controller>> NewControllers(
    const StorageState& state, std::vector<std::shared_ptr<Controller>>* seen);

}  // namespace
}  // extern "C++"

// The SDK runs each request on a detached thread that works through the
// reference that started it, and deleting the Storage frees that reference
// under the thread. So nothing is deleted until everything has finished:
// transfers that can be canceled are, and the rest is waited for. One that
// outlasts the wait leaves the Storage as it was and answers -1. On 0 nothing
// new starts on the app until fdb_storage_release or fdb_storage_resume.
//
// A transfer has no controller until it first reports, and a retried one gets
// another, so they are looked for on every pass of the wait rather than once.
// A request the SDK is retrying sleeps between tries where nothing reaches
// it, for up to its retry window, and this answers -1 for as long.
//
int64_t fdb_storage_quiesce(const char* app) {
  const std::string key = AppKey(app);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(key);
    if (it == g_states.end()) return 0;
    StorageState* state = it->second.get();
    if (state->closing) return -1;
    state->closing = true;
  }

  // Held to the end of the wait, so one that was canceled is not asked again.
  std::vector<std::shared_ptr<Controller>> canceled;
  const auto deadline = std::chrono::steady_clock::now() + kReleaseWait;
  for (;;) {
    std::vector<std::shared_ptr<Controller>> fresh;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      const auto it = g_states.find(key);
      if (it == g_states.end()) return 0;
      if (Idle(*it->second)) break;
      if (std::chrono::steady_clock::now() >= deadline) {
        it->second->closing = false;
        return -1;
      }
      fresh = NewControllers(*it->second, &canceled);
    }
    // Outside the lock, as fdb_storage_task_control does it.
    for (const auto& controller : fresh) controller->Cancel();
    std::this_thread::sleep_for(kReleasePoll);
  }
  return 0;
}

void fdb_storage_resume(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_states.find(AppKey(app));
  if (it != g_states.end()) it->second->closing = false;
}

// `done` is set in the completion, a few frames before the thread is out of
// the reference. The settle covers those frames; it is the same allowance
// Retain makes by leaving a finished reference until the next call.
void fdb_storage_release(const char* app) {
  std::unique_ptr<StorageState> state;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(AppKey(app));
    if (it == g_states.end()) return;
    state = std::move(it->second);
    g_states.erase(it);
  }
  if (!state->inflight.empty() || !state->tasks.empty()) {
    std::this_thread::sleep_for(kReleaseSettle);
  }
  // Listeners and references first: each holds on to the Storage.
  state->tasks.clear();
  state->inflight.clear();
  delete state->storage;
}

extern "C++" {
namespace {

// Reads the settable fields out of a CBOR map into `out`: contentType,
// cacheControl, contentDisposition, contentEncoding, contentLanguage, and
// custom, a map of text to text. A key that is absent is left alone. Returns
// false for bytes that are not such a map; `any` says whether one was set.
bool ApplyMetadata(const uint8_t* cbor, size_t len, Metadata* out, bool* any) {
  *any = false;
  if (cbor == nullptr || len == 0) return true;
  std::map<std::string, firebase::Variant> fields;
  if (!fdb::ParseVariantMap(cbor, len, &fields)) return false;
  auto text = [&fields](const char* key, std::string* value) {
    auto it = fields.find(key);
    if (it == fields.end() || !it->second.is_string()) return false;
    *value = it->second.string_value();
    return true;
  };
  std::string v;
  if (text("contentType", &v)) {
    out->set_content_type(v);
    *any = true;
  }
  if (text("cacheControl", &v)) {
    out->set_cache_control(v);
    *any = true;
  }
  if (text("contentDisposition", &v)) {
    out->set_content_disposition(v);
    *any = true;
  }
  if (text("contentEncoding", &v)) {
    out->set_content_encoding(v);
    *any = true;
  }
  if (text("contentLanguage", &v)) {
    out->set_content_language(v);
    *any = true;
  }
  auto custom = fields.find("custom");
  if (custom != fields.end() && custom->second.is_map()) {
    std::map<std::string, std::string>* target = out->custom_metadata();
    for (const auto& kv : custom->second.map()) {
      if (!kv.first.is_string() || !kv.second.is_string()) return false;
      if (target != nullptr) {
        (*target)[kv.first.string_value()] = kv.second.string_value();
        *any = true;
      }
    }
  }
  return true;
}

bool Idle(const StorageState& state) {
  return std::all_of(state.inflight.begin(), state.inflight.end(),
                     [](const InFlight& f) { return f.done->load(); }) &&
         std::all_of(
             state.tasks.begin(), state.tasks.end(),
             [](const auto& entry) { return entry.second->done.load(); });
}

std::vector<std::shared_ptr<Controller>> NewControllers(
    const StorageState& state, std::vector<std::shared_ptr<Controller>>* seen) {
  std::vector<std::shared_ptr<Controller>> fresh;
  for (const auto& entry : state.tasks) {
    const Task& task = *entry.second;
    if (task.done.load() || task.reporter == nullptr) continue;
    auto controller = task.reporter->controller();
    if (controller == nullptr ||
        std::find(seen->begin(), seen->end(), controller) != seen->end()) {
      continue;
    }
    seen->push_back(controller);
    fresh.push_back(std::move(controller));
  }
  return fresh;
}

// A new task under the next id. Caller holds g_mutex.
Task* NewTask(StorageState* state, const char* path, int64_t progress_port,
              int64_t* id) {
  auto& tasks = state->tasks;
  for (auto it = tasks.begin(); it != tasks.end();) {
    it = it->second->done.load() ? tasks.erase(it) : std::next(it);
  }
  auto task = std::make_shared<Task>(progress_port);
  task->ref =
      std::make_unique<StorageReference>(state->storage->GetReference(path));
  *id = g_next_task++;
  tasks[*id] = task;
  // The raw pointer, not the shared one: the map keeps the task alive until
  // the next one starts after `done`, and a shared_ptr in the completion
  // would be released on the completing thread.
  return task.get();
}

// Starts an upload of `bytes` or, when `file` is given, of that file. Returns
// the task id. Caller holds g_mutex.
int64_t StartUpload(StorageState* state, const char* path, const uint8_t* bytes,
                    size_t len, const char* file, const uint8_t* metadata,
                    size_t metadata_len, int64_t port, int64_t progress_port) {
  Metadata settable;
  bool with_metadata = false;
  if (!ApplyMetadata(metadata, metadata_len, &settable, &with_metadata)) {
    return -3;
  }

  int64_t id = 0;
  Task* raw = NewTask(state, path, progress_port, &id);
  raw->metadata = settable;
  // Never a null buffer, even for an empty object.
  raw->bytes.reserve(1);
  if (file == nullptr && len != 0) raw->bytes.assign(bytes, bytes + len);

  auto finish = [port, raw](const firebase::Future<Metadata>& f) {
    PostMetadataResult(port, f);
    // An upload that succeeded had a transfer, reported or not.
    if (f.error() == 0 && raw->reporter != nullptr) {
      raw->reporter->attached.store(true);
    }
    raw->done.store(true);
  };

  Listener* listener = raw->reporter;
  if (file != nullptr) {
    (with_metadata ? raw->ref->PutFile(file, raw->metadata, listener)
                   : raw->ref->PutFile(file, listener))
        .OnCompletion(finish);
  } else {
    const void* data = raw->bytes.data();
    (with_metadata ? raw->ref->PutBytes(data, len, raw->metadata, listener)
                   : raw->ref->PutBytes(data, len, listener))
        .OnCompletion(finish);
  }
  return id;
}

}  // namespace
}  // extern "C++"

FDB_EXPORT int64_t fdb_storage_put(const char* app, const char* path,
                                   const uint8_t* bytes, size_t len,
                                   const uint8_t* metadata, size_t metadata_len,
                                   int64_t port, int64_t progress_port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr || (bytes == nullptr && len != 0)) return -2;
  return StartUpload(state, path, bytes, len, nullptr, metadata, metadata_len,
                     port, progress_port);
}

FDB_EXPORT int64_t fdb_storage_put_file(const char* app, const char* path,
                                        const char* file,
                                        const uint8_t* metadata,
                                        size_t metadata_len, int64_t port,
                                        int64_t progress_port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr || file == nullptr || *file == '\0') return -2;
  return StartUpload(state, path, nullptr, 0, file, metadata, metadata_len,
                     port, progress_port);
}

// A download to a file, as a task. The result is an outcome whose code is the
// number of bytes written.
FDB_EXPORT int64_t fdb_storage_get_file(const char* app, const char* path,
                                        const char* file, int64_t port,
                                        int64_t progress_port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr || file == nullptr || *file == '\0') return -2;

  int64_t id = 0;
  Task* raw = NewTask(state, path, progress_port, &id);
  raw->ref->GetFile(file, raw->reporter)
      .OnCompletion([port, raw](const firebase::Future<size_t>& f) {
        if (f.error() != 0) {
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
        } else {
          fdb_post_outcome(
              port, 1,
              f.result() == nullptr ? 0 : static_cast<int64_t>(*f.result()),
              "");
          if (raw->reporter != nullptr) raw->reporter->attached.store(true);
        }
        raw->done.store(true);
      });
  return id;
}

// UpdateMetadata keeps a pointer to the Metadata it is given and reads it on
// the SDK's worker thread, so it has to outlive the call the way the
// reference does. A task holds both.
FDB_EXPORT int64_t fdb_storage_update_metadata(const char* app,
                                               const char* path,
                                               const uint8_t* metadata,
                                               size_t metadata_len,
                                               int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr) return -2;
  Metadata settable;
  bool any = false;
  if (!ApplyMetadata(metadata, metadata_len, &settable, &any)) return -3;

  int64_t id = 0;
  Task* raw = NewTask(state, path, 0, &id);
  raw->metadata = settable;
  raw->ref->UpdateMetadata(raw->metadata)
      .OnCompletion([port, raw](const firebase::Future<Metadata>& f) {
        PostMetadataResult(port, f);
        raw->done.store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_task_control(int64_t task, int32_t action) {
  std::shared_ptr<Controller> controller;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const Task* found = nullptr;
    for (const auto& entry : g_states) {
      const auto it = entry.second->tasks.find(task);
      if (it == entry.second->tasks.end()) continue;
      found = it->second.get();
      break;
    }
    if (found == nullptr) return -1;
    if (found->reporter == nullptr) return 0;
    controller = found->reporter->controller();
  }
  // Outside the lock: Pause() calls the listener back before it returns.
  // No controller yet means the transfer has not reported once, and there is
  // nothing to act on.
  if (controller == nullptr) return 0;
  switch (action) {
    case FDB_STORAGE_TASK_PAUSE:
      return controller->Pause() ? 1 : 0;
    case FDB_STORAGE_TASK_RESUME:
      return controller->Resume() ? 1 : 0;
    case FDB_STORAGE_TASK_CANCEL:
      return controller->Cancel() ? 1 : 0;
    default:
      return -2;
  }
}

FDB_EXPORT int64_t fdb_storage_list(const char* app, const char* path,
                                    int64_t max_results, const char* page_token,
                                    int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr || max_results < 0 || max_results > 1000) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(state, path, &done);
  ref->List(static_cast<int>(max_results),
            page_token == nullptr || *page_token == '\0' ? nullptr : page_token)
      .OnCompletion([port, done](const firebase::Future<StorageListResult>& f) {
        if (f.error() != 0) {
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
          done->store(true);
          return;
        }
        std::vector<uint8_t> payload;
        if (f.result() == nullptr || !SerializeList(*f.result(), payload)) {
          fdb_post_outcome(port, 0, -2, "could not encode the listing");
          done->store(true);
          return;
        }
        fdb_post_buffer(port, 1, payload.data(), payload.size());
        done->store(true);
      });
  return 0;
}

// GetBytes needs a buffer sized in advance, and only the metadata knows how
// big the object is. Dart drives those two steps rather than this chaining
// them, because chaining meant starting a second SDK operation from inside the
// first one's completion -- on the SDK's own worker thread -- and that
// segfaulted in the download. Dart is already awaiting each step, so it costs
// nothing to ask for the size first and pass it back in.
FDB_EXPORT int64_t fdb_storage_get(const char* app, const char* path,
                                   int64_t capacity, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr || capacity < 0) return -2;

  // Allocated with the header in front, so the bytes land where they will be
  // posted from and the download is never copied.
  const size_t total = sizeof(FdbSnapshotHeader) + static_cast<size_t>(capacity);
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) return -3;

  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(state, path, &done);
  ref->GetBytes(buf + sizeof(FdbSnapshotHeader), static_cast<size_t>(capacity))
      .OnCompletion([port, buf, capacity,
                     done](const firebase::Future<size_t>& f) {
        if (f.error() != 0) {
          std::free(buf);
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
          done->store(true);
          return;
        }
        // What arrived, not what was asked for: an object rewritten between
        // the size call and this one would otherwise hand Dart the tail of
        // whatever the buffer already held.
        const size_t received = f.result() == nullptr ? 0 : *f.result();
        fdb_post_buffer_owned(
            port, 1, buf,
            received > static_cast<size_t>(capacity)
                ? static_cast<size_t>(capacity)
                : received);
              done->store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_delete(const char* app, const char* path,
                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(state, path, &done);
  ref->Delete().OnCompletion(
      [port, done](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
        done->store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_metadata(const char* app, const char* path,
                                        int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(state, path, &done);
  ref->GetMetadata().OnCompletion(
      [port, done](const firebase::Future<Metadata>& f) {
        PostMetadataResult(port, f);
        done->store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_download_url(const char* app, const char* path,
                                            int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  StorageState* state = StateFor(app);
  if (state == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(state, path, &done);
  ref->GetDownloadUrl().OnCompletion(
      [port, done](const firebase::Future<std::string>& f) {
        if (f.error() != 0) {
          fdb_post_outcome(port, 0, f.error(),
                           f.error_message() == nullptr ? ""
                                                        : f.error_message());
          done->store(true);
          return;
        }
        fdb_post_outcome(port, 1, 0,
                         f.result() == nullptr ? "" : f.result()->c_str());
        done->store(true);
      });
  return 0;
}

}  // extern "C"
