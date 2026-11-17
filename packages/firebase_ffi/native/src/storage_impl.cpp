// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// Cloud Storage, on the same firebase::App as Auth, Database and Firestore.
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

#include "firebase_bridge.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/storage.h"
#include "firebase/storage/controller.h"
#include "firebase/storage/list_result.h"
#include "firebase/storage/listener.h"

namespace {

using ::firebase::storage::Controller;
using ::firebase::storage::Listener;
using ::firebase::storage::Metadata;
using ::firebase::storage::Storage;
using ::firebase::storage::StorageListResult;
using ::firebase::storage::StorageReference;

std::mutex g_mutex;
Storage* g_storage = nullptr;

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
std::vector<InFlight> g_inflight;

// Caller holds g_mutex.
StorageReference* Retain(const char* path,
                         std::shared_ptr<std::atomic<bool>>* done_out) {
  g_inflight.erase(
      std::remove_if(g_inflight.begin(), g_inflight.end(),
                     [](const InFlight& f) { return f.done->load(); }),
      g_inflight.end());

  auto done = std::make_shared<std::atomic<bool>>(false);
  auto owned = std::make_unique<StorageReference>(g_storage->GetReference(path));
  StorageReference* raw = owned.get();
  g_inflight.push_back(InFlight{std::move(owned), done});
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
class Task : public Listener {
 public:
  explicit Task(int64_t progress_port) : port_(progress_port) {}

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

  std::unique_ptr<StorageReference> ref;
  // PutBytes does not take ownership and the upload outlives the call.
  std::vector<uint8_t> bytes;
  std::atomic<bool> done{false};

 private:
  void Capture(Controller* controller) {
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

// Tasks by id. A finished one is dropped on the next upload rather than in its
// completion, for the reason InFlight gives: the completing thread is still
// inside the reference the task owns.
std::map<int64_t, std::shared_ptr<Task>> g_tasks;
int64_t g_next_task = 1;

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

FDB_EXPORT int64_t fdb_storage_init(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage != nullptr) return 0;
  firebase::App* app = fdb_current_app();
  if (app == nullptr) return -1;
  firebase::InitResult result = firebase::kInitResultSuccess;
  g_storage = Storage::GetInstance(app, &result);
  if (g_storage == nullptr || result != firebase::kInitResultSuccess) {
    g_storage = nullptr;
    return -2;
  }
  return 0;
}

FDB_EXPORT int64_t fdb_storage_use_emulator(const char* host, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  g_storage->UseEmulator(host, static_cast<int>(port));
  return 0;
}

extern "C++" {
namespace {

// Starts an upload of `bytes` or, when `file` is given, of that file. Returns
// the task id. Caller holds g_mutex.
int64_t StartUpload(const char* path, const uint8_t* bytes, size_t len,
                    const char* file, const char* content_type, int64_t port,
                    int64_t progress_port) {
  for (auto it = g_tasks.begin(); it != g_tasks.end();) {
    it = it->second->done.load() ? g_tasks.erase(it) : std::next(it);
  }

  auto task = std::make_shared<Task>(progress_port);
  task->ref =
      std::make_unique<StorageReference>(g_storage->GetReference(path));
  // Never a null buffer, even for an empty object.
  task->bytes.reserve(1);
  if (file == nullptr && len != 0) task->bytes.assign(bytes, bytes + len);
  const int64_t id = g_next_task++;
  g_tasks[id] = task;

  // The raw pointer, not the shared one: the map keeps the task alive until
  // the next upload after `done`, and a shared_ptr in the callback would be
  // released on the completing thread.
  Task* raw = task.get();
  auto finish = [port, raw](const firebase::Future<Metadata>& f) {
    PostMetadataResult(port, f);
    raw->done.store(true);
  };

  Listener* listener = progress_port == 0 ? nullptr : raw;
  Metadata metadata;
  const bool typed = content_type != nullptr && *content_type != '\0';
  if (typed) metadata.set_content_type(content_type);

  if (file != nullptr) {
    (typed ? raw->ref->PutFile(file, metadata, listener)
           : raw->ref->PutFile(file, listener))
        .OnCompletion(finish);
  } else {
    const void* data = raw->bytes.data();
    (typed ? raw->ref->PutBytes(data, len, metadata, listener)
           : raw->ref->PutBytes(data, len, listener))
        .OnCompletion(finish);
  }
  return id;
}

}  // namespace
}  // extern "C++"

FDB_EXPORT int64_t fdb_storage_put(const char* path, const uint8_t* bytes,
                                   size_t len, const char* content_type,
                                   int64_t port, int64_t progress_port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr || (bytes == nullptr && len != 0)) return -2;
  return StartUpload(path, bytes, len, nullptr, content_type, port,
                     progress_port);
}

FDB_EXPORT int64_t fdb_storage_put_file(const char* path, const char* file,
                                        const char* content_type, int64_t port,
                                        int64_t progress_port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr || file == nullptr || *file == '\0') return -2;
  return StartUpload(path, nullptr, 0, file, content_type, port,
                     progress_port);
}

FDB_EXPORT int64_t fdb_storage_task_control(int64_t task, int32_t action) {
  std::shared_ptr<Controller> controller;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_tasks.find(task);
    if (it == g_tasks.end()) return -1;
    controller = it->second->controller();
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

FDB_EXPORT int64_t fdb_storage_list(const char* path, int64_t max_results,
                                    const char* page_token, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr || max_results < 0 || max_results > 1000) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
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
FDB_EXPORT int64_t fdb_storage_get(const char* path, int64_t capacity,
                                   int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr || capacity < 0) return -2;

  // Allocated with the header in front, so the bytes land where they will be
  // posted from and the download is never copied.
  const size_t total = sizeof(FdbSnapshotHeader) + static_cast<size_t>(capacity);
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) return -3;

  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
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

FDB_EXPORT int64_t fdb_storage_delete(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
  ref->Delete().OnCompletion(
      [port, done](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
        done->store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_metadata(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
  ref->GetMetadata().OnCompletion(
      [port, done](const firebase::Future<Metadata>& f) {
        PostMetadataResult(port, f);
        done->store(true);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_storage_download_url(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr) return -2;
  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
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
