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
                                const char* database_url,
                                const char* storage_bucket);

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

/* Point Auth at a local emulator; after fdb_auth_init, before signing in.
 * Returns -1 if Auth is not initialized, -2 for a bad host or port. */
FDB_EXPORT int64_t fdb_auth_use_emulator(const char* host, int64_t port);
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

/* --- Posting results back to Dart --------------------------------------- */

/* Both Firestore and Storage answer a call by posting to a port rather than
 * returning: the SDK completes on its own thread and Dart_PostCObject_DL is
 * safe from any of them. These are the two shapes those answers take, shared
 * so a second module does not grow a second copy of them.
 *
 * Outcome: [ok:bool, code:int, message:string] -- a call that either worked or
 * did not. The strings are copied by Dart_PostCObject_DL, so they may be
 * stack-local here.
 */
FDB_EXPORT void fdb_post_outcome(int64_t port, int ok, int64_t code,
                                 const char* message);

/* Buffer: a snapshot header followed by `len` bytes, handed to Dart as
 * external typed data -- the GC frees it, and nothing here may touch it
 * afterwards. Takes ownership of nothing: it copies `bytes` into a buffer it
 * mallocs, because the SDK's own buffer is not ours to give away.
 */
FDB_EXPORT void fdb_post_buffer(int64_t port, int64_t seq,
                                const uint8_t* bytes, size_t len);

/* Buffer, adopting an already-malloc'd payload rather than copying it. `owned`
 * must come from malloc and is freed by the Dart GC. This is the path a
 * download takes: the bytes are written once, into the buffer that is handed
 * over, with no second copy at any size.
 */
FDB_EXPORT void fdb_post_buffer_owned(int64_t port, int64_t seq,
                                      uint8_t* owned, size_t len);

/* --- Firestore ---------------------------------------------------------- */

/* Firestore values that CBOR has no native type for travel as tagged items.
 * These tag numbers are private to this project: they are not IANA-registered,
 * and nothing outside this ABI should assume them.
 *
 *   40000  timestamp   [seconds:int, nanoseconds:int]
 *   40001  geopoint    [latitude:double, longitude:double]
 *   40002  reference   text, the document path
 *
 * Timestamps are a pair rather than RFC 8949 tag 1, whose payload is a single
 * number: a float64 epoch cannot hold Firestore's nanosecond precision, and
 * silently rounding a timestamp is worse than carrying two integers.
 *
 * Blobs need no tag -- CBOR has a byte string.
 *
 * Sentinels are write-only. Firestore never returns them, so the decoder
 * rejects them rather than inventing a value for something that is an
 * instruction to the server.
 *
 *   40010  delete            null
 *   40011  server timestamp  null
 *   40012  array union       [values...]
 *   40013  array remove      [values...]
 *   40014  increment int     [int]
 *   40015  increment double  [double]
 *
 * The increments carry a one-element array rather than a bare number: Dart's
 * CBOR package drops tags when it normalizes an integer to a small int, so a
 * tagged bare int arrives untagged and reads as an ordinary value.
 */
#define FDB_CBOR_TAG_TIMESTAMP 40000
#define FDB_CBOR_TAG_GEOPOINT 40001
#define FDB_CBOR_TAG_REFERENCE 40002
#define FDB_CBOR_TAG_DELETE 40010
#define FDB_CBOR_TAG_SERVER_TIMESTAMP 40011
#define FDB_CBOR_TAG_ARRAY_UNION 40012
#define FDB_CBOR_TAG_ARRAY_REMOVE 40013
#define FDB_CBOR_TAG_INCREMENT_INT 40014
#define FDB_CBOR_TAG_INCREMENT_DOUBLE 40015

/* Creates the Firestore instance on the shared App. Returns 0, or -1 when
 * fdb_app_init has not run, or -2 if the instance cannot be created. */
FDB_EXPORT int64_t fdb_fs_init(void);

/* Point Firestore at a local emulator; after fdb_fs_init, before the first
 * operation, because settings freeze once the client starts. Returns -1 if
 * Firestore is not initialized, -2 for a bad host or port. */
FDB_EXPORT int64_t fdb_fs_use_emulator(const char* host, int64_t port);

/* Writes `doc_path` from a CBOR-encoded map. `merge` non-zero merges rather
 * than replaces. The outcome is posted to `port` as [ok, code, message]. */
FDB_EXPORT int64_t fdb_fs_set(const char* doc_path, const uint8_t* cbor,
                              size_t len, int32_t merge, int64_t port);

/* Reads `doc_path`. Posts the document as a snapshot buffer on `port`: the
 * usual header, then a CBOR map, or an empty payload when it does not exist. */
FDB_EXPORT int64_t fdb_fs_get(const char* doc_path, int64_t port);

/* Deletes `doc_path`. Outcome posted as for fdb_fs_set. */
/* Runs a query over a collection. `spec` is a CBOR map, or null for a plain
 * read of the collection:
 *
 *   {"where":   [[field, op, value], ...],
 *    "orderBy": [[field, "asc"|"desc"], ...],
 *    "limit": n, "limitToLast": n}
 *
 * Results arrive on `port` as a snapshot buffer whose payload is a CBOR array
 * of {"id", "path", "data"}. Returns -1 if Firestore is not initialized, -2 for
 * a null path, -3 for a spec this ABI cannot apply — which is refused rather
 * than run as a weaker query, since that would return more documents and no
 * error. */
FDB_EXPORT int64_t fdb_fs_query(const char* collection_path,
                               const uint8_t* spec, size_t spec_len,
                               int64_t port);

/* The same query, watched. Returns a listener id for fdb_fs_unlisten, or the
 * same negative codes as fdb_fs_query. Results arrive on `port` with an
 * increasing seq, in the same shape a one-shot query returns. */
FDB_EXPORT int64_t fdb_fs_query_listen(const char* collection_path,
                                      const uint8_t* spec, size_t spec_len,
                                      int64_t port);

/* Transactions.
 *
 * fdb_fs_txn_begin starts one and returns its id. Attempts arrive on `port`
 * with an increasing seq -- the SDK retries, so the handler runs again for
 * each. seq 0 is the terminal event; a negative seq carries the reason.
 *
 * Reads go through fdb_fs_txn_get, which is served by the SDK's own thread:
 * the Transaction belongs to it. Writes are buffered by the caller and applied
 * in one go at fdb_fs_txn_commit, because a write already handed to the SDK
 * could not be taken back if a later line of the handler threw. */
FDB_EXPORT int64_t fdb_fs_txn_begin(int64_t port);
FDB_EXPORT int64_t fdb_fs_txn_get(int64_t txn_id, const char* doc_path,
                                 int64_t port);
FDB_EXPORT int64_t fdb_fs_txn_commit(int64_t txn_id, const uint8_t* writes,
                                    size_t len);
FDB_EXPORT int64_t fdb_fs_txn_abort(int64_t txn_id);

FDB_EXPORT int64_t fdb_fs_delete(const char* doc_path, int64_t port);

/* Watches `doc_path`, posting a snapshot buffer per change. Returns a listener
 * id for fdb_fs_unlisten, or a negative value on failure. */
FDB_EXPORT int64_t fdb_fs_listen(const char* doc_path, int64_t port);

/* Stops a listener started by fdb_fs_listen. */
FDB_EXPORT int64_t fdb_fs_unlisten(int64_t listener_id);

/* Whether this build linked Firestore. */
FDB_EXPORT int32_t fdb_have_firestore(void);

#ifdef __cplusplus
namespace firebase {
class App;
}
// The shared App, for translation units inside this library only.
FDB_EXPORT firebase::App* fdb_current_app(void);
}  // extern "C"
#endif

#endif  // FIREBASE_DB_BRIDGE_H_
