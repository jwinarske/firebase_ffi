// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Channel A + Channel B1, without a Firebase dependency. See the header for
// why the SDK is deliberately not linked here.

#include "firebase_bridge.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include "dart_api_dl.h"

namespace {

std::atomic<int64_t> g_next_handle{1};
std::atomic<int64_t> g_next_request{1};

struct Listener {
  std::string path;
  Dart_Port_DL port;
};

std::mutex g_mutex;
std::map<int64_t, Listener> g_listeners;

int64_t NowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Frees a buffer the Dart GC has finished with. `peer` is the same pointer
// handed to the VM, which is why the buffer must come from malloc and must not
// be touched again once posted.
void SnapshotFinalizer(void* /*isolate_callback_data*/, void* peer) {
  std::free(peer);
}

// Builds one snapshot buffer: a fixed header followed by `value_bytes` of
// payload.
//
// The payload stands in for a Variant tree flattened into a single allocation.
// A real serializer would emit tagged nodes with child offsets so Dart can walk
// it lazily; the cost this measures -- one pass writing value_bytes into a
// fresh allocation -- is the same either way, and it is the copy a DataSnapshot
// forces regardless of transport, since the snapshot dies when the callback
// returns.
uint8_t* BuildSnapshot(int64_t seq, size_t value_bytes, size_t* out_total) {
  const size_t total = sizeof(FdbSnapshotHeader) + value_bytes;
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) {
    *out_total = 0;
    return nullptr;
  }

  FdbSnapshotHeader header{};
  header.magic = 0xFDB50000u;
  header.version = 1u;
  header.seq = seq;
  header.value_len = static_cast<uint32_t>(value_bytes);
  header.posted_ns = NowNs();
  std::memcpy(buf, &header, sizeof(header));

  // A recognizable, non-constant pattern: a memset would let the allocator or
  // the kernel serve pages that never get written, understating the cost.
  uint8_t* payload = buf + sizeof(FdbSnapshotHeader);
  for (size_t i = 0; i < value_bytes; ++i) {
    payload[i] = static_cast<uint8_t>(i * 31u + 7u);
  }

  *out_total = total;
  return buf;
}

bool PortFor(int64_t handle, Dart_Port_DL* out) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_listeners.find(handle);
  if (it == g_listeners.end()) {
    return false;
  }
  *out = it->second.port;
  return true;
}

}  // namespace

extern "C" {

int64_t fdb_init_dart_api(void* dart_api_dl_data) {
  return Dart_InitializeApiDL(dart_api_dl_data);
}

int64_t fdb_noop(void) {
  return 0;
}

int64_t fdb_set(const char* path, const uint8_t* value, size_t len) {
  // What a real write does with its arguments before handing them to the SDK:
  // the path becomes an owned string and the payload is read. Both are what an
  // FFI call replaces a codec encode/decode with.
  const std::string owned_path(path == nullptr ? "" : path);
  volatile uint8_t sink = 0;
  for (size_t i = 0; i < len; ++i) {
    sink = static_cast<uint8_t>(sink ^ value[i]);
  }
  (void)sink;
  (void)owned_path;
  return g_next_request.fetch_add(1, std::memory_order_relaxed);
}

int64_t fdb_listen(const char* path, int64_t port) {
  const int64_t handle = g_next_handle.fetch_add(1, std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(g_mutex);
  g_listeners.emplace(
      handle,
      Listener{path == nullptr ? std::string() : std::string(path),
               static_cast<Dart_Port_DL>(port)});
  return handle;
}

void fdb_unlisten(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_listeners.erase(handle);
}

void fdb_emit_snapshot(int64_t handle, int64_t seq, size_t value_bytes) {
  Dart_Port_DL port = 0;
  if (!PortFor(handle, &port)) {
    return;
  }

  // From a worker thread, as an SDK listener callback would arrive.
  // Dart_PostCObject_DL is safe from any thread; that is the property a method
  // channel does not have, and the reason this needs no marshal.
  std::thread([port, seq, value_bytes] {
    size_t total = 0;
    uint8_t* buf = BuildSnapshot(seq, value_bytes, &total);
    if (buf == nullptr) {
      return;
    }

    Dart_CObject obj{};
    obj.type = Dart_CObject_kExternalTypedData;
    obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
    obj.value.as_external_typed_data.length =
        static_cast<intptr_t>(total);
    obj.value.as_external_typed_data.data = buf;
    obj.value.as_external_typed_data.peer = buf;
    obj.value.as_external_typed_data.callback = SnapshotFinalizer;

    // Ownership passes to the Dart GC here. Nothing may touch buf afterwards.
    Dart_PostCObject_DL(port, &obj);
  }).detach();
}

void fdb_emit_snapshot_copying(int64_t handle, int64_t seq,
                               size_t value_bytes) {
  Dart_Port_DL port = 0;
  if (!PortFor(handle, &port)) {
    return;
  }

  std::thread([port, seq, value_bytes] {
    size_t total = 0;
    uint8_t* buf = BuildSnapshot(seq, value_bytes, &total);
    if (buf == nullptr) {
      return;
    }

    // kTypedData copies into a fresh Dart heap allocation. This is the floor
    // any copying transport pays, before its own encode and decode.
    Dart_CObject obj{};
    obj.type = Dart_CObject_kTypedData;
    obj.value.as_typed_data.type = Dart_TypedData_kUint8;
    obj.value.as_typed_data.length = static_cast<intptr_t>(total);
    obj.value.as_typed_data.values = buf;

    Dart_PostCObject_DL(port, &obj);
    std::free(buf);  // the VM copied; this side still owns it
  }).detach();
}

int64_t fdb_now_ns(void) {
  return NowNs();
}

}  // extern "C"

// Reported rather than inferred from a symbol lookup: a caller that wants the
// transport benchmark on a build without the SDK should not have to catch a
// resolution failure to find that out.
extern "C" FDB_EXPORT int64_t fdb_have_firebase(void) {
#ifdef FDB_HAVE_FIREBASE
  return 1;
#else
  return 0;
#endif
}
