// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_storage` implementation for desktop Linux.
///
/// Objects, files, listings, metadata, download URLs and deletion route to the
/// C++ SDK. An upload or a download to a file is a task: it reports the SDK's
/// progress and can be paused, resumed and canceled.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/storage.dart' as fdb;
import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';

// firebase_core_ffi can create a named app, but Storage still runs on the
// default one. An instance that quietly used the default app's project would
// be worse than refusing.
FirebaseApp? _defaultOnly(FirebaseApp? app) {
  if (app != null && app.name != defaultFirebaseAppName) {
    throw UnsupportedError(
      'Storage is not bound to named apps: "${app.name}" was asked for, and '
      'only the default app is served',
    );
  }
  return app;
}

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
      FirebaseStorageFfi(app: _defaultOnly(app), bucket: bucket);

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
    return _FfiTask<fdb.StorageMetadata>(
      this,
      data.length,
      fdb.startUpload(fullPath, data, metadata: _settable(metadata)),
      (m) => m.sizeBytes,
      'putData',
    );
  }

  @override
  TaskPlatform putFile(File file, [SettableMetadata? metadata]) {
    ffiStorage.ensureStorage();
    return _FfiTask<fdb.StorageMetadata>(
      this,
      // Unknown until the SDK has opened the file, which is also where a
      // missing one is reported.
      -1,
      fdb.startFileUpload(fullPath, file.path, metadata: _settable(metadata)),
      (m) => m.sizeBytes,
      'putFile',
    );
  }

  @override
  TaskPlatform writeToFile(File file) {
    ffiStorage.ensureStorage();
    return _FfiTask<int>(
      this,
      // Unknown until the response says how long it is.
      -1,
      fdb.startFileDownload(fullPath, file.path),
      (written) => written,
      'writeToFile',
    );
  }

  @override
  Future<FullMetadata> updateMetadata(SettableMetadata metadata) async {
    ffiStorage.ensureStorage();
    final m = await _translate(
      () => fdb.updateObjectMetadata(fullPath, _settable(metadata)!),
      'updateMetadata',
    );
    return _toFullMetadata(m);
  }

  static fdb.SettableStorageMetadata? _settable(SettableMetadata? m) =>
      m == null
      ? null
      : fdb.SettableStorageMetadata(
          contentType: m.contentType,
          cacheControl: m.cacheControl,
          contentDisposition: m.contentDisposition,
          contentEncoding: m.contentEncoding,
          contentLanguage: m.contentLanguage,
          custom: m.customMetadata,
        );

  @override
  Future<ListResultPlatform> list([ListOptions? options]) async {
    ffiStorage.ensureStorage();
    final page = await _translate(
      () => fdb.listObjects(
        fullPath,
        maxResults: options?.maxResults ?? 1000,
        pageToken: options?.pageToken,
      ),
      'list',
    );
    return _FfiListResult(
      ffiStorage,
      page.nextPageToken,
      page.items,
      page.prefixes,
    );
  }

  @override
  Future<ListResultPlatform> listAll() async {
    ffiStorage.ensureStorage();
    final items = <String>[];
    final prefixes = <String>[];
    String? token;
    do {
      final page = await _translate(
        () => fdb.listObjects(fullPath, pageToken: token),
        'listAll',
      );
      items.addAll(page.items);
      prefixes.addAll(page.prefixes);
      token = page.nextPageToken;
    } while (token != null);
    return _FfiListResult(ffiStorage, null, items, prefixes);
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
      throw _exceptionOf(e, what);
    }
  }

  static FirebaseException _exceptionOf(fdb.StorageException e, String what) =>
      FirebaseException(
        plugin: 'firebase_storage',
        // The plugin's name for the one code an app has to tell apart: a
        // cancel is asked for, not a failure.
        code: e.cancelled ? 'canceled' : '${e.code}',
        message: '$what: ${e.message}',
      );

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

/// One page of a listing, or all of it.
class _FfiListResult extends ListResultPlatform {
  _FfiListResult(
    FirebaseStorageFfi storage,
    String? nextPageToken,
    this._items,
    this._prefixes,
  ) : _storage = storage,
      super(storage, nextPageToken);

  final FirebaseStorageFfi _storage;
  final List<String> _items;
  final List<String> _prefixes;

  @override
  List<ReferencePlatform> get items => [
    for (final path in _items) FfiReference(_storage, path),
  ];

  @override
  List<ReferencePlatform> get prefixes => [
    for (final path in _prefixes) FfiReference(_storage, path),
  ];
}

/// An upload or a download to a file, as a task. [T] is what the transfer
/// answers with, and `sizeOf` reads the byte count out of it.
///
/// Snapshots are the SDK's own progress reports. A small transfer may finish
/// having made none, and then the stream carries only the terminal snapshot.
class _FfiTask<T> extends TaskPlatform {
  _FfiTask(
    this._ref,
    this._total,
    this._upload,
    int Function(T) sizeOf,
    String what,
  ) : _controller = StreamController<TaskSnapshotPlatform>.broadcast() {
    _snapshot = _snap(TaskState.running, 0);
    _upload.progress.listen((p) {
      if (p.totalBytes > 0) _total = p.totalBytes;
      _transferred = p.bytesTransferred;
      if (p.paused) _paused = true;
      // A chunk already on its way reports after the pause did. The task is
      // still paused, so the state is ours to hold rather than the report's.
      _snapshot = _snap(
        _paused ? TaskState.paused : TaskState.running,
        _transferred,
      );
      _controller.add(_snapshot);
    });
    _done = _upload.done.then(
      (result) {
        _total = sizeOf(result);
        _snapshot = _snap(TaskState.success, _total);
        _controller
          ..add(_snapshot)
          ..close();
        return _snapshot;
      },
      onError: (Object e, StackTrace st) {
        final error = e is fdb.StorageException
            ? FfiReference._exceptionOf(e, what)
            : e;
        final canceled = e is fdb.StorageException && e.cancelled;
        _snapshot = _snap(
          canceled ? TaskState.canceled : TaskState.error,
          _transferred,
        );
        _controller
          ..addError(error, st)
          ..close();
        Error.throwWithStackTrace(error, st);
      },
    );
    // The app may watch snapshotEvents and never ask for onComplete. A failed
    // upload must not become an unhandled error because of that.
    _done.ignore();
  }

  final FfiReference _ref;
  final fdb.TransferTask<T> _upload;
  final StreamController<TaskSnapshotPlatform> _controller;
  int _total;
  int _transferred = 0;
  bool _paused = false;
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

  // False is the interface's way of saying the operation did not take effect:
  // the transfer has not started sending, or has already finished.
  @override
  Future<bool> pause() async => _upload.pause();

  @override
  Future<bool> resume() async {
    if (!_upload.resume()) return false;
    _paused = false;
    return true;
  }

  @override
  Future<bool> cancel() async => _upload.cancel();
}

class _FfiTaskSnapshot extends TaskSnapshotPlatform {
  _FfiTaskSnapshot(this._reference, super.state, super.data);

  final FfiReference _reference;

  @override
  ReferencePlatform get ref => _reference;
}
