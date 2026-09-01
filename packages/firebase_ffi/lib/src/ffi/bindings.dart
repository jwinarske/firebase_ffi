// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// @Native bindings to the firebase_bridge.h C ABI.
//
// `hook/build.dart` emits libfirebase_ffi.so as a code asset under the id in
// @DefaultAsset below, and the VM resolves these externals against that asset.
// The asset table is the only mechanism the VM consults: a plain
// DynamicLibrary.open never sees it. The id must stay identical to the one the
// hook emits — a mismatch is not a build error, it surfaces as a symbol
// resolution failure at the first call.
@DefaultAsset('package:firebase_ffi/src/ffi/firebase_ffi_asset.dart')
library;

import 'dart:ffi';

/// Header at the front of every snapshot buffer, read in place out of the
/// external typed data rather than decoded.
final class FdbSnapshotHeader extends Struct {
  @Uint32()
  external int magic;
  @Uint32()
  external int version;
  @Int64()
  external int seq;
  @Int64()
  external int postedNs;
  @Uint32()
  external int valueLen;
  @Uint32()
  external int reserved;
}

const fdbSnapshotMagic = 0xFDB50000;

@Native<Int64 Function(Pointer<Void>)>(symbol: 'fdb_init_dart_api')
external int fdbInitDartApi(Pointer<Void> dartApiDlData);

@Native<Int64 Function()>(symbol: 'fdb_noop', isLeaf: true)
external int fdbNoop();

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size)>(
  symbol: 'fdb_set',
  isLeaf: true,
)
external int fdbSet(Pointer<Char> path, Pointer<Uint8> value, int len);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_listen')
external int fdbListen(Pointer<Char> path, int port);

@Native<Void Function(Int64)>(symbol: 'fdb_unlisten')
external void fdbUnlisten(int handle);

@Native<Void Function(Int64, Int64, Size)>(symbol: 'fdb_emit_snapshot')
external void fdbEmitSnapshot(int handle, int seq, int valueBytes);

@Native<Void Function(Int64, Int64, Size)>(symbol: 'fdb_emit_snapshot_copying')
external void fdbEmitSnapshotCopying(int handle, int seq, int valueBytes);

@Native<Int64 Function()>(symbol: 'fdb_now_ns', isLeaf: true)
external int fdbNowNs();

// ── v2: the real Database ───────────────────────────────────────────────────

@Native<Int64 Function()>(symbol: 'fdb_have_firebase', isLeaf: true)
external int fdbHaveFirebase();

@Native<
  Int64 Function(
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
  )
>(symbol: 'fdb_app_init')
external int fdbAppInit(
  Pointer<Char> appId,
  Pointer<Char> apiKey,
  Pointer<Char> projectId,
  Pointer<Char> databaseUrl,
  Pointer<Char> storageBucket,
);

@Native<Int64 Function(Pointer<Char>, Pointer<Char>)>(
  symbol: 'fdb_db_set_string',
)
external int fdbDbSetString(Pointer<Char> path, Pointer<Char> value);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_db_listen')
external int fdbDbListen(Pointer<Char> path, int port);

@Native<Void Function(Int64)>(symbol: 'fdb_db_unlisten')
external void fdbDbUnlisten(int handle);

// ── v2: authentication ──────────────────────────────────────────────────────

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_auth_use_emulator')
external int fdbAuthUseEmulator(Pointer<Char> host, int port);

@Native<Int64 Function()>(symbol: 'fdb_auth_init')
external int fdbAuthInit();

@Native<Int64 Function(Int64)>(symbol: 'fdb_auth_sign_in_anonymously')
external int fdbAuthSignInAnonymously(int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(
  symbol: 'fdb_auth_sign_in_with_custom_token',
)
external int fdbAuthSignInWithCustomToken(Pointer<Char> token, int port);

@Native<Int64 Function()>(symbol: 'fdb_auth_sign_out')
external int fdbAuthSignOut();

@Native<Int64 Function(Pointer<Char>, Size)>(symbol: 'fdb_auth_current_uid')
external int fdbAuthCurrentUid(Pointer<Char> out, int cap);

// --- Firestore ------------------------------------------------------------

@Native<Int32 Function()>(symbol: 'fdb_have_firestore')
external int fdbHaveFirestore();

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_fs_use_emulator')
external int fdbFsUseEmulator(Pointer<Char> host, int port);

@Native<Int64 Function()>(symbol: 'fdb_fs_init')
external int fdbFsInit();

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Int32, Int64)>(
  symbol: 'fdb_fs_set',
)
external int fdbFsSet(
  Pointer<Char> path,
  Pointer<Uint8> cbor,
  int len,
  int merge,
  int port,
);

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Int64)>(
  symbol: 'fdb_fs_query',
)
external int fdbFsQuery(
  Pointer<Char> collectionPath,
  Pointer<Uint8> spec,
  int specLen,
  int port,
);

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Int64)>(
  symbol: 'fdb_fs_query_listen',
)
external int fdbFsQueryListen(
  Pointer<Char> collectionPath,
  Pointer<Uint8> spec,
  int specLen,
  int port,
);

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Int64)>(
  symbol: 'fdb_fs_count',
)
external int fdbFsCount(
  Pointer<Char> collectionPath,
  Pointer<Uint8> spec,
  int specLen,
  int port,
);

@Native<Int64 Function(Pointer<Uint8>, Size, Int64)>(
  symbol: 'fdb_fs_batch_commit',
)
external int fdbFsBatchCommit(Pointer<Uint8> writes, int len, int port);

@Native<Int64 Function(Int64)>(symbol: 'fdb_fs_txn_begin')
external int fdbFsTxnBegin(int port);

@Native<Int64 Function(Int64, Pointer<Char>, Int64)>(symbol: 'fdb_fs_txn_get')
external int fdbFsTxnGet(int txnId, Pointer<Char> docPath, int port);

@Native<Int64 Function(Int64, Pointer<Uint8>, Size)>(
  symbol: 'fdb_fs_txn_commit',
)
external int fdbFsTxnCommit(int txnId, Pointer<Uint8> writes, int len);

@Native<Int64 Function(Int64)>(symbol: 'fdb_fs_txn_abort')
external int fdbFsTxnAbort(int txnId);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_fs_get')
external int fdbFsGet(Pointer<Char> path, int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_fs_delete')
external int fdbFsDelete(Pointer<Char> path, int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_fs_listen')
external int fdbFsListen(Pointer<Char> path, int port);

@Native<Int64 Function(Int64)>(symbol: 'fdb_fs_unlisten')
external int fdbFsUnlisten(int listenerId);

// --- Cloud Storage ---------------------------------------------------------

@Native<Int64 Function()>(symbol: 'fdb_have_storage')
external int fdbHaveStorage();

@Native<Int64 Function()>(symbol: 'fdb_storage_init')
external int fdbStorageInit();

@Native<
  Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Pointer<Char>, Int64)
>(symbol: 'fdb_storage_put')
external int fdbStoragePut(
  Pointer<Char> path,
  Pointer<Uint8> bytes,
  int len,
  Pointer<Char> contentType,
  int port,
);

@Native<Int64 Function(Pointer<Char>, Int64, Int64)>(symbol: 'fdb_storage_get')
external int fdbStorageGet(Pointer<Char> path, int capacity, int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_storage_delete')
external int fdbStorageDelete(Pointer<Char> path, int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(symbol: 'fdb_storage_metadata')
external int fdbStorageMetadata(Pointer<Char> path, int port);

@Native<Int64 Function(Pointer<Char>, Int64)>(
  symbol: 'fdb_storage_download_url',
)
external int fdbStorageDownloadUrl(Pointer<Char> path, int port);

// --- Cloud Functions -------------------------------------------------------

@Native<Int64 Function()>(symbol: 'fdb_have_functions')
external int fdbHaveFunctions();

@Native<Int64 Function(Pointer<Char>)>(symbol: 'fdb_functions_init')
external int fdbFunctionsInit(Pointer<Char> region);

@Native<Int64 Function(Pointer<Char>)>(symbol: 'fdb_functions_use_emulator')
external int fdbFunctionsUseEmulator(Pointer<Char> origin);

@Native<Int64 Function(Pointer<Char>, Pointer<Uint8>, Size, Int64)>(
  symbol: 'fdb_functions_call',
)
external int fdbFunctionsCall(
  Pointer<Char> name,
  Pointer<Uint8> args,
  int len,
  int port,
);
