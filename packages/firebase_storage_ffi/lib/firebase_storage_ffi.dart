// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_storage` implementation for desktop Linux.
///
/// Objects, metadata, download URLs and deletion route to the C++ SDK.
/// Listing, file uploads and resumable control keep the platform interface's
/// own `UnimplementedError`, which names the method that is missing.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/storage.dart' as fdb;
import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';

/// Registered by Flutter on Linux via `dartPluginClass`.
class FirebaseStorageFfi extends FirebaseStoragePlatform {
  FirebaseStorageFfi({FirebaseApp? app, String? bucket})
    : super(appInstance: app, bucket: bucket ?? '');

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseStoragePlatform.instance = FirebaseStorageFfi();
  }

  bool _ready = false;

  /// firebase_storage has no "initialize" call, so it happens on first use.
  void ensureStorage() {
    if (_ready) return;
    fdb.initStorage();
    _ready = true;
  }

  @override
  FirebaseStoragePlatform delegateFor({FirebaseApp? app, String? bucket}) =>
      FirebaseStorageFfi(app: app, bucket: bucket);

  @override
  ReferencePlatform ref(String path) => FfiReference(this, path);

  @override
  Future<void> useStorageEmulator(String host, int port) async {
    // The SDK asks for this before any other call on the instance, so the
    // instance is created here rather than left to first use.
    ensureStorage();
    fdb.useStorageEmulator(host, port);
  }

  // Retry windows are the SDK's own on desktop and are not configurable
  // through the bindings. Accepted silently rather than throwing: they are
  // advisory, and an app setting one should not fail because of it.
  @override
  void setMaxOperationRetryTime(int time) {}

  @override
  void setMaxUploadRetryTime(int time) {}

  @override
  void setMaxDownloadRetryTime(int time) {}
}

/// A reference to one object.
class FfiReference extends ReferencePlatform {
  FfiReference(this.ffiStorage, String path) : super(ffiStorage, path);

  final FirebaseStorageFfi ffiStorage;

  @override
  ReferencePlatform child(String path) =>
      FfiReference(ffiStorage, _join(fullPath, path));

  @override
  Future<void> delete() async {
    ffiStorage.ensureStorage();
    await _translate(() => fdb.deleteObject(fullPath), 'delete');
  }

  @override
  Future<String> getDownloadURL() async {
    ffiStorage.ensureStorage();
    return _translate(() => fdb.downloadUrl(fullPath), 'getDownloadURL');
  }

  @override
  Future<FullMetadata> getMetadata() async {
    ffiStorage.ensureStorage();
    final m = await _translate(
      () => fdb.objectMetadata(fullPath),
      'getMetadata',
    );
    return _toFullMetadata(m);
  }

  @override
  Future<Uint8List?> getData([int maxSize = 10485760]) async {
    ffiStorage.ensureStorage();
    final bytes = await _translate(() => fdb.getObject(fullPath), 'getData');
    // The interface's contract: past the cap, answer null rather than hand
    // back a truncated object that looks complete.
    if (bytes.length > maxSize) return null;
    return bytes;
  }

  @override
  TaskPlatform putData(Uint8List data, [SettableMetadata? metadata]) {
    ffiStorage.ensureStorage();
    return _FfiTask(
      this,
      data.length,
      _translate(
        () => fdb.putObject(fullPath, data, contentType: metadata?.contentType),
        'putData',
      ),
    );
  }

  static String _join(String base, String child) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final c = child.startsWith('/') ? child.substring(1) : child;
    return b.isEmpty ? c : '$b/$c';
  }

  /// Carries the SDK's own code and message into the exception callers expect,
  /// rather than remapping to a guess at the nearest plugin code.
  static Future<T> _translate<T>(Future<T> Function() op, String what) async {
    try {
      return await op();
    } on fdb.StorageException catch (e) {
      throw FirebaseException(
        plugin: 'firebase_storage',
        code: '${e.code}',
        message: '$what: ${e.message}',
      );
    }
  }

  FullMetadata _toFullMetadata(fdb.StorageMetadata m) => FullMetadata({
    'bucket': m.bucket,
    'fullPath': m.path,
    'name': m.name,
    'size': m.sizeBytes,
    'contentType': m.contentType,
    'cacheControl': m.cacheControl,
    'contentDisposition': m.contentDisposition,
    'contentEncoding': m.contentEncoding,
    'contentLanguage': m.contentLanguage,
    'md5Hash': m.md5Hash,
    'generation': '${m.generation}',
    'metageneration': '${m.metadataGeneration}',
    'creationTimeMillis': m.creationTime?.millisecondsSinceEpoch,
    'updatedTimeMillis': m.updatedTime?.millisecondsSinceEpoch,
    'timeCreated': m.creationTime,
    'updated': m.updatedTime,
    'customMetadata': m.custom.isEmpty ? null : m.custom,
  });
}

/// An upload, as a task.
///
/// The C++ SDK reports progress through a Listener that is not bound, so this
/// emits one running snapshot and then the terminal one. Saying it transferred
/// everything before it has would be worse than reporting nothing: a progress
/// bar driven by that would be wrong rather than absent.
class _FfiTask extends TaskPlatform {
  _FfiTask(this._ref, this._total, Future<fdb.StorageMetadata> upload)
    : _controller = StreamController<TaskSnapshotPlatform>.broadcast() {
    _snapshot = _snap(TaskState.running, 0);
    _done = upload
        .then((m) {
          _snapshot = _snap(TaskState.success, m.sizeBytes);
          _controller
            ..add(_snapshot)
            ..close();
          return _snapshot;
        })
        .catchError((Object e, StackTrace st) {
          _snapshot = _snap(TaskState.error, 0);
          _controller
            ..addError(e, st)
            ..close();
          throw e;
        });
  }

  final FfiReference _ref;
  final int _total;
  final StreamController<TaskSnapshotPlatform> _controller;
  late TaskSnapshotPlatform _snapshot;
  late final Future<TaskSnapshotPlatform> _done;

  TaskSnapshotPlatform _snap(TaskState state, int transferred) =>
      _FfiTaskSnapshot(_ref, state, {
        'bytesTransferred': transferred,
        'totalBytes': _total,
      });

  @override
  Stream<TaskSnapshotPlatform> get snapshotEvents => _controller.stream;

  @override
  TaskSnapshotPlatform get snapshot => _snapshot;

  @override
  Future<TaskSnapshotPlatform> get onComplete => _done;

  // PutBytes has no Controller bound, so an upload cannot be paused, resumed
  // or canceled. Reporting false is the interface's way of saying the
  // operation did not take effect.
  @override
  Future<bool> pause() async => false;

  @override
  Future<bool> resume() async => false;

  @override
  Future<bool> cancel() async => false;
}

class _FfiTaskSnapshot extends TaskSnapshotPlatform {
  _FfiTaskSnapshot(this._reference, super.state, super.data);

  final FfiReference _reference;

  @override
  ReferencePlatform get ref => _reference;
}
