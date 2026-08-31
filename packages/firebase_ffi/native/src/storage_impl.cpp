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
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/storage.h"

namespace {

using ::firebase::storage::Metadata;
using ::firebase::storage::Storage;
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

FDB_EXPORT int64_t fdb_storage_put(const char* path, const uint8_t* bytes,
                                   size_t len, const char* content_type,
                                   int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage == nullptr) return -1;
  if (path == nullptr || (bytes == nullptr && len != 0)) return -2;

  std::shared_ptr<std::atomic<bool>> done;
  StorageReference* ref = Retain(path, &done);
  // PutBytes does not take ownership and the call is asynchronous, so the
  // caller's buffer has to outlive it. Copying is the only safe reading of
  // that contract from here -- the Dart side is free to reuse its list the
  // moment this returns.
  auto* copy = static_cast<uint8_t*>(std::malloc(len == 0 ? 1 : len));
  if (copy == nullptr) return -3;
  if (len != 0) std::memcpy(copy, bytes, len);

  auto finish = [port, copy, done](const firebase::Future<Metadata>& f) {
    std::free(copy);
    PostMetadataResult(port, f);
    done->store(true);
  };

  if (content_type != nullptr && *content_type != '\0') {
    Metadata metadata;
    metadata.set_content_type(content_type);
    ref->PutBytes(copy, len, metadata).OnCompletion(finish);
  } else {
    ref->PutBytes(copy, len).OnCompletion(finish);
  }
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
