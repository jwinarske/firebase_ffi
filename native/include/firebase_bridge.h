// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// C ABI for the firebase_ffi transport prototype.
//
// Two of the native_comms channels, shaped the way a Realtime Database plugin
// would use them:
//
//   Channel A  — Dart calls in directly (fdb_set). A write is a small argument
//                list and a handoff; the FFI call is the whole cost on this
//                side, so it is measured as dispatch, not as round trip.
//
//   Channel B1 — C++ posts a serialized snapshot to a Dart ReceivePort as
//                Dart_CObject_kExternalTypedData. The Dart Uint8List's backing
//                store *is* the malloc'd buffer; nothing is copied after the
//                one serialization, which a DataSnapshot forces anyway because
//                it dies when the listener callback returns.
//
// Deliberately free of any Firebase dependency: this measures the transport,
// and entangling the SDK build would put its link environment in the way of the
// numbers. See README for what wiring the real Database adds.

#ifndef FIREBASE_DB_BRIDGE_H_
#define FIREBASE_DB_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

// The library is built with hidden visibility, so the ABI is opted in
// explicitly. Without this the symbols exist in the object file and are absent
// from the dynamic table, which the VM reports as an unresolved native
// function at the first call rather than as a link error.
#if defined(_WIN32)
#define FDB_EXPORT __declspec(dllexport)
#else
#define FDB_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Hands the VM's dart_api_dl function table to the library. Must be called
// once, before anything that posts to a port; Dart_PostCObject_DL is a null
// pointer until it returns.
FDB_EXPORT int64_t fdb_init_dart_api(void* dart_api_dl_data);

// ── Channel A ───────────────────────────────────────────────────────────────

// A write, shaped like DatabaseReference::SetValue: a path and an encoded
// payload the caller owns for the duration of the call. Returns a request id.
//
// The real implementation would hand `value` to the SDK and complete a Future;
// here it does the argument marshalling and returns, which is the part FFI
// changes. Network time is not this layer's to measure.
FDB_EXPORT int64_t fdb_set(const char* path, const uint8_t* value, size_t len);

// The floor for an FFI call: no work, no allocation. Subtracting this from
// fdb_set isolates argument marshalling from call overhead.
FDB_EXPORT int64_t fdb_noop(void);

// ── Channel B1 ──────────────────────────────────────────────────────────────

// Registers `port` as the sink for snapshots on `path` and returns a listener
// handle. Mirrors Query::AddValueListener, whose callbacks arrive on an SDK
// thread -- which is the point: Dart_PostCObject_DL is safe from any thread,
// so there is no marshal to a platform thread the way a method channel needs.
FDB_EXPORT int64_t fdb_listen(const char* path, int64_t port);

// Stops a listener. Safe to call once per handle.
FDB_EXPORT void fdb_unlisten(int64_t handle);

// Emits one synthetic snapshot of `value_bytes` payload to the listener's port,
// from a worker thread, exactly as a value event would arrive. `seq` is echoed
// in the header so Dart can pair a receipt with its send.
//
// The payload is a tagged tree flattened into one buffer -- the shape a
// Variant has to take to cross as a single external typed data object.
FDB_EXPORT void fdb_emit_snapshot(int64_t handle, int64_t seq, size_t value_bytes);

// Same payload, posted as a plain Dart_CObject_kTypedData instead of
// kExternalTypedData: the VM copies the bytes into a new Dart heap allocation.
// This is the comparison point -- it is what any codec-based channel does at
// minimum, before its own encode and decode.
FDB_EXPORT void fdb_emit_snapshot_copying(int64_t handle, int64_t seq, size_t value_bytes);

// Monotonic nanoseconds from the same clock the library timestamps with, so
// Dart can measure post-to-receive against a single time base.
FDB_EXPORT int64_t fdb_now_ns(void);

// ── v2: the real Database, present only when built with the SDK ─────────────
//
// fdb_have_firebase() reports whether this build linked it, so a caller can
// fall back to the synthetic transport path rather than failing to resolve a
// symbol that is not there.
FDB_EXPORT int64_t fdb_have_firebase(void);

// Creates the App and Database. Returns 0, or negative on failure. Safe to
// call more than once; later calls are no-ops.
FDB_EXPORT int64_t fdb_app_init(const char* app_id, const char* api_key,
                                const char* project_id,
                                const char* database_url);

// DatabaseReference::SetValue with a string payload.
FDB_EXPORT int64_t fdb_db_set_string(const char* path, const char* value);

// Query::AddValueListener. Snapshots arrive on the port in the same framing
// fdb_emit_snapshot uses, with a serialized Variant as the payload.
FDB_EXPORT int64_t fdb_db_listen(const char* path, int64_t port);
FDB_EXPORT void fdb_db_unlisten(int64_t handle);

// ── v2: authentication ──────────────────────────────────────────────────────
//
// Sign-in happens on the same firebase::App the Database uses; the SDK routes
// the credential through it, so an outstanding listener re-authorizes with no
// further call. Both sign-ins are asynchronous and post
// [ok, code, message, uid] to `port` when they complete.
FDB_EXPORT int64_t fdb_auth_init(void);
FDB_EXPORT int64_t fdb_auth_sign_in_anonymously(int64_t port);
FDB_EXPORT int64_t fdb_auth_sign_in_with_custom_token(const char* token,
                                                      int64_t port);
FDB_EXPORT int64_t fdb_auth_sign_out(void);
FDB_EXPORT int64_t fdb_auth_current_uid(char* out, size_t cap);

// Header at the front of every snapshot buffer. Dart reads these fields
// straight out of the typed data; only the value bytes after it are payload.
typedef struct {
  uint32_t magic;    // 0xFDB50000
  uint32_t version;  // 1
  int64_t seq;       // echoes fdb_emit_snapshot's seq
  int64_t posted_ns; // fdb_now_ns() at the moment of posting
  uint32_t value_len;
  uint32_t reserved;
} FdbSnapshotHeader;

#ifdef __cplusplus
namespace firebase {
class App;
}
// The shared App, for translation units inside this library only.
FDB_EXPORT firebase::App* fdb_current_app(void);
}  // extern "C"
#endif

#endif  // FIREBASE_DB_BRIDGE_H_
