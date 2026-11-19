// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Cloud Storage: objects as bytes, on the default app or a named one.
///
/// Every call takes an `app`: the name `initNamedApp` was given, or nothing
/// for the default app. [initStorage] must have run for that app.
///
/// Downloads arrive as external typed data — the bytes are written once, into
/// the buffer handed to the Dart heap, and never copied. That property is why
/// this module is worth having over a REST call: a Database value is small
/// enough that a copy is free, and an object is not.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:ffi/ffi.dart';

import 'src/ffi/bindings.dart';
import 'src/internal/library_loader.dart';
import 'src/variant_codec.dart';

/// What the backend knows about a stored object. Fields the backend did not
/// set are null rather than empty: "no content type" and "the content type is
/// the empty string" are different answers.
class StorageMetadata {
  const StorageMetadata({
    required this.raw,
    this.bucket,
    this.name,
    this.path,
    this.contentType,
    this.cacheControl,
    this.contentDisposition,
    this.contentEncoding,
    this.contentLanguage,
    this.md5Hash,
    this.sizeBytes = 0,
    this.creationTime,
    this.updatedTime,
    this.generation = 0,
    this.metadataGeneration = 0,
    this.custom = const {},
  });

  factory StorageMetadata.fromMap(Map<String, Object?> m) {
    DateTime? at(String key) {
      final v = m[key];
      // The SDK reports these in milliseconds, and reports 0 for "not set" —
      // which as an epoch would be 1970 rather than absent.
      if (v is! int || v == 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    }

    return StorageMetadata(
      raw: m,
      bucket: m['bucket'] as String?,
      name: m['name'] as String?,
      path: m['path'] as String?,
      contentType: m['contentType'] as String?,
      cacheControl: m['cacheControl'] as String?,
      contentDisposition: m['contentDisposition'] as String?,
      contentEncoding: m['contentEncoding'] as String?,
      contentLanguage: m['contentLanguage'] as String?,
      md5Hash: m['md5Hash'] as String?,
      sizeBytes: (m['sizeBytes'] as int?) ?? 0,
      creationTime: at('creationTime'),
      updatedTime: at('updatedTime'),
      generation: (m['generation'] as int?) ?? 0,
      metadataGeneration: (m['metadataGeneration'] as int?) ?? 0,
      custom: {
        for (final e in ((m['custom'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
    );
  }

  /// Everything the native side sent, including anything this class does not
  /// yet name.
  final Map<String, Object?> raw;

  final String? bucket;
  final String? name;
  final String? path;
  final String? contentType;
  final String? cacheControl;
  final String? contentDisposition;
  final String? contentEncoding;
  final String? contentLanguage;
  final String? md5Hash;
  final int sizeBytes;
  final DateTime? creationTime;
  final DateTime? updatedTime;
  final int generation;
  final int metadataGeneration;
  final Map<String, String> custom;

  @override
  String toString() =>
      'StorageMetadata(${path ?? name}, $sizeBytes bytes'
      '${contentType == null ? '' : ', $contentType'})';
}

/// A Storage operation that failed, carrying the SDK's own code and message.
class StorageException implements Exception {
  const StorageException(this.code, this.message, this.operation);
  final int code;
  final String message;
  final String operation;

  /// True for an upload stopped by [UploadTask.cancel].
  bool get cancelled => code == _cancelled;

  @override
  String toString() => 'StorageException($operation, $code): $message';
}

// kErrorCancelled in the SDK's storage/common.h.
const _cancelled = 11;

/// What a caller may set on an object, on upload or with
/// [updateObjectMetadata]. A field left null is left as it is.
class SettableStorageMetadata {
  const SettableStorageMetadata({
    this.contentType,
    this.cacheControl,
    this.contentDisposition,
    this.contentEncoding,
    this.contentLanguage,
    this.custom,
  });

  final String? contentType;
  final String? cacheControl;
  final String? contentDisposition;
  final String? contentEncoding;
  final String? contentLanguage;

  /// The caller's own keys. These are added to what the object has; a key
  /// that is not named here stays.
  final Map<String, String>? custom;

  Uint8List _encode() {
    final fields = <String, Object?>{
      'contentType': ?contentType,
      'cacheControl': ?cacheControl,
      'contentDisposition': ?contentDisposition,
      'contentEncoding': ?contentEncoding,
      'contentLanguage': ?contentLanguage,
      if (custom != null && custom!.isNotEmpty) 'custom': custom,
    };
    return fields.isEmpty
        ? Uint8List(0)
        : Uint8List.fromList(encodeVariant(fields));
  }
}

/// How far a transfer has got.
class TransferProgress {
  const TransferProgress(
    this.bytesTransferred,
    this.totalBytes, {
    this.paused = false,
  });

  final int bytesTransferred;

  /// The size of the transfer, or -1 before the SDK knows it.
  final int totalBytes;

  /// True for the report a pause produces. A chunk already on its way may
  /// still report after it, with this false.
  final bool paused;

  @override
  String toString() =>
      'TransferProgress($bytesTransferred of $totalBytes'
      '${paused ? ', paused' : ''})';
}

/// A transfer in flight. [T] is what it answers with when it is done.
class TransferTask<T> {
  TransferTask._(this._id, this.done, this._progress);

  final int _id;

  /// The result, or a [StorageException]. A cancelled transfer fails with one
  /// whose [StorageException.cancelled] is true.
  final Future<T> done;

  final StreamController<TransferProgress> _progress;

  /// Progress as the SDK reports it, closed when the transfer ends. A small
  /// one may finish having reported once or not at all.
  Stream<TransferProgress> get progress => _progress.stream;

  /// Stops the transfer where it is. False when there was nothing to pause:
  /// it has not started moving bytes, or has finished.
  bool pause() => fdbStorageTaskControl(_id, 0) == 1;

  /// Continues a paused transfer. False when it was not paused.
  bool resume() => fdbStorageTaskControl(_id, 1) == 1;

  /// Abandons the transfer; [done] then fails. False when it had not started
  /// moving bytes or had already finished.
  bool cancel() => fdbStorageTaskControl(_id, 2) == 1;
}

/// An upload: what [startUpload] and [startFileUpload] answer with. [done] is
/// the stored object's metadata.
typedef UploadTask = TransferTask<StorageMetadata>;

/// A download to a file: what [startFileDownload] answers with. [done] is the
/// number of bytes written.
typedef DownloadTask = TransferTask<int>;

/// One page of a listing. Paths are full paths, usable as they are with every
/// other call here.
class StorageList {
  const StorageList({
    this.prefixes = const [],
    this.items = const [],
    this.nextPageToken,
  });

  /// The "folders" directly under the listed path.
  final List<String> prefixes;

  /// The objects directly under the listed path.
  final List<String> items;

  /// Present when there is another page; pass it to [listObjects].
  final String? nextPageToken;
}

/// True when the library was built with Storage bound.
bool get hasStorage {
  ensureLibraryLoaded();
  try {
    return fdbHaveStorage() != 0;
  } on ArgumentError {
    // The symbol is absent from a build that did not select this product.
    return false;
  }
}

/// Prepares Storage on an app: the default one, or the named one [app].
/// `initDatabase` or `initNamedApp` must have made the app first.
void initStorage({String? app}) {
  ensureLibraryLoaded();
  final rc = _onApp(app, fdbStorageInit);
  if (rc != 0) {
    throw StateError(
      rc != -1
          ? 'Storage instance could not be created ($rc)'
          : app == null || app.isEmpty
          ? 'initStorage before the Firebase app was initialized'
          : 'initStorage on "$app", which is not an app — call initNamedApp '
                'first',
    );
  }
}

// The app a call acts on, as the native side takes it: null for the default
// app, else its name for the length of the call.
T _onApp<T>(String? app, T Function(Pointer<Char> app) call) {
  if (app == null || app.isEmpty) return call(nullptr);
  final native = app.toNativeUtf8();
  try {
    return call(native.cast());
  } finally {
    calloc.free(native);
  }
}

/// Points Storage at a local emulator, after [initStorage] and before the
/// first operation — the SDK freezes the endpoint once a request has gone out.
void useStorageEmulator(String host, int port, {String? app}) {
  final h = host.toNativeUtf8();
  try {
    final rc = _onApp(app, (a) => fdbStorageUseEmulator(a, h.cast(), port));
    if (rc != 0) {
      throw StateError(
        rc == -1
            ? 'useStorageEmulator before initStorage'
            : 'useStorageEmulator($host, $port) was refused ($rc)',
      );
    }
  } finally {
    calloc.free(h);
  }
}

/// Awaits an operation that answers with `[ok, code, message]`.
Future<String> _awaitOutcome(int Function(int port) start, String what) {
  final completer = Completer<String>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete(parts[2]! as String);
    } else {
      completer.completeError(
        StorageException(parts[1]! as int, parts[2]! as String, what),
      );
    }
  };
  final rc = start(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('$what failed to start ($rc)'));
  }
  return completer.future;
}

/// Awaits an operation answering with either a payload buffer or an outcome.
/// A failure arrives as the three-element list, a success as the buffer, so
/// the handler dispatches on the shape rather than needing a second port.
Future<Uint8List> _awaitBuffer(int Function(int port) start, String what) {
  final completer = Completer<Uint8List>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    // Uint8List first, and not `is List<Object?>`: a Uint8List satisfies that
    // too, so testing the outcome shape first sends every successful payload
    // down the error branch to read one of its bytes as a message string.
    if (message is Uint8List) {
      completer.complete(Uint8List.sublistView(message, snapshotHeaderBytes));
      return;
    }
    final parts = message! as List<Object?>;
    completer.completeError(
      StorageException(parts[1]! as int, parts[2]! as String, what),
    );
  };
  final rc = start(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('$what failed to start ($rc)'));
  }
  return completer.future;
}

StorageMetadata _decodeMetadata(Uint8List cbor) {
  final decoded = cborDecode(cbor).toObject();
  if (decoded is! Map) {
    throw StateError('metadata was not a CBOR map');
  }
  return StorageMetadata.fromMap({
    for (final e in decoded.entries) '${e.key}': e.value,
  });
}

/// Uploads [bytes] to [path], answering with the stored object's metadata.
///
/// [contentType] is shorthand for a [metadata] that sets only that.
Future<StorageMetadata> putObject(
  String path,
  Uint8List bytes, {
  String? contentType,
  SettableStorageMetadata? metadata,
  String? app,
}) => startUpload(
  path,
  bytes,
  contentType: contentType,
  metadata: metadata,
  app: app,
).done;

/// Uploads the file at [file] to [path]. The SDK reads it from disk, so it is
/// never held in memory whole.
Future<StorageMetadata> putFile(
  String path,
  String file, {
  String? contentType,
  SettableStorageMetadata? metadata,
  String? app,
}) => startFileUpload(
  path,
  file,
  contentType: contentType,
  metadata: metadata,
  app: app,
).done;

/// Downloads the object at [path] into the file at [file], answering with the
/// number of bytes written. The SDK writes it to disk as it arrives.
Future<int> getFile(String path, String file, {String? app}) =>
    startFileDownload(path, file, app: app).done;

/// Starts uploading [bytes] to [path] and answers with the task, for an upload
/// worth watching or stopping.
UploadTask startUpload(
  String path,
  Uint8List bytes, {
  String? contentType,
  SettableStorageMetadata? metadata,
  String? app,
}) {
  // Copied into native memory for the call. The native side copies again for
  // the duration of the upload, because PutBytes does not take ownership and
  // completes long after this returns.
  final buf = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return _upload(
      path,
      _settable(contentType, metadata),
      'put $path',
      app,
      (a, p, meta, metaLen, port, progress) =>
          fdbStoragePut(a, p, buf, bytes.length, meta, metaLen, port, progress),
    );
  } finally {
    calloc.free(buf);
  }
}

/// Starts uploading the file at [file] to [path] and answers with the task.
UploadTask startFileUpload(
  String path,
  String file, {
  String? contentType,
  SettableStorageMetadata? metadata,
  String? app,
}) {
  final f = file.toNativeUtf8();
  try {
    return _upload(
      path,
      _settable(contentType, metadata),
      'putFile $path',
      app,
      (a, p, meta, metaLen, port, progress) =>
          fdbStoragePutFile(a, p, f.cast(), meta, metaLen, port, progress),
    );
  } finally {
    calloc.free(f);
  }
}

/// Starts downloading the object at [path] into the file at [file] and
/// answers with the task.
DownloadTask startFileDownload(String path, String file, {String? app}) {
  final p = path.toNativeUtf8();
  final f = file.toNativeUtf8();
  try {
    return _task<int>(
      'getFile $path',
      (port, progress) => _onApp(
        app,
        (a) => fdbStorageGetFile(a, p.cast(), f.cast(), port, progress),
      ),
      // An outcome: [ok, bytes written, message].
      (message) => (message! as List<Object?>)[1]! as int,
    );
  } finally {
    calloc
      ..free(p)
      ..free(f);
  }
}

/// Sets what [metadata] names on the object at [path] and answers with its
/// metadata afterwards.
Future<StorageMetadata> updateObjectMetadata(
  String path,
  SettableStorageMetadata metadata, {
  String? app,
}) async {
  final encoded = metadata._encode();
  final p = path.toNativeUtf8();
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  buf.asTypedList(encoded.length).setAll(0, encoded);
  try {
    final payload = await _awaitBuffer(
      (port) => _onApp(
        app,
        (a) => fdbStorageUpdateMetadata(a, p.cast(), buf, encoded.length, port),
      ),
      'updateMetadata $path',
    );
    return _decodeMetadata(payload);
  } finally {
    calloc
      ..free(p)
      ..free(buf);
  }
}

Uint8List _settable(String? contentType, SettableStorageMetadata? metadata) {
  if (metadata == null) {
    return contentType == null
        ? Uint8List(0)
        : SettableStorageMetadata(contentType: contentType)._encode();
  }
  if (contentType != null && metadata.contentType == null) {
    return SettableStorageMetadata(
      contentType: contentType,
      cacheControl: metadata.cacheControl,
      contentDisposition: metadata.contentDisposition,
      contentEncoding: metadata.contentEncoding,
      contentLanguage: metadata.contentLanguage,
      custom: metadata.custom,
    )._encode();
  }
  return metadata._encode();
}

UploadTask _upload(
  String path,
  Uint8List metadata,
  String what,
  String? app,
  int Function(
    Pointer<Char> app,
    Pointer<Char> path,
    Pointer<Uint8> metadata,
    int metadataLen,
    int port,
    int progress,
  )
  start,
) {
  final p = path.toNativeUtf8();
  final meta = calloc<Uint8>(metadata.isEmpty ? 1 : metadata.length);
  meta.asTypedList(metadata.length).setAll(0, metadata);
  try {
    return _task<StorageMetadata>(
      what,
      (port, progress) => _onApp(
        app,
        (a) => start(a, p.cast(), meta, metadata.length, port, progress),
      ),
      (message) => _decodeMetadata(
        Uint8List.sublistView(message! as Uint8List, snapshotHeaderBytes),
      ),
    );
  } finally {
    calloc
      ..free(p)
      ..free(meta);
  }
}

/// Starts a task and wires its two ports. A failure arrives on the result port
/// as `[false, code, message]`; anything else is handed to [decode].
TransferTask<T> _task<T>(
  String what,
  int Function(int port, int progress) start,
  T Function(Object? message) decode,
) {
  final progress = StreamController<TransferProgress>.broadcast();
  final events = RawReceivePort();
  events.handler = (Object? message) {
    final parts = message! as List<Object?>;
    progress.add(
      TransferProgress(
        parts[1]! as int,
        parts[2]! as int,
        paused: parts[0] == 1,
      ),
    );
  };

  final completer = Completer<T>();
  final result = RawReceivePort();
  result.handler = (Object? message) {
    result.close();
    events.close();
    try {
      if (message is! Uint8List &&
          message is List<Object?> &&
          message[0] == false) {
        completer.completeError(
          StorageException(message[1]! as int, message[2]! as String, what),
        );
      } else {
        completer.complete(decode(message));
      }
    } on Object catch (e, st) {
      completer.completeError(e, st);
    }
    progress.close();
  };

  final id = start(result.sendPort.nativePort, events.sendPort.nativePort);
  if (id <= 0) {
    result.close();
    events.close();
    progress.close();
    throw StateError('$what failed to start ($id)');
  }
  return TransferTask<T>._(id, completer.future, progress);
}

/// One page of what is directly under [path]: objects, and the prefixes that
/// stand in for folders. An empty [path] lists the bucket's root.
///
/// [maxResults] is at most 1000. Pass a page's [StorageList.nextPageToken] as
/// [pageToken] for the one after it.
Future<StorageList> listObjects(
  String path, {
  int maxResults = 1000,
  String? pageToken,
  String? app,
}) async {
  RangeError.checkValueInInterval(maxResults, 1, 1000, 'maxResults');
  final p = path.toNativeUtf8();
  final token = (pageToken ?? '').toNativeUtf8();
  try {
    final payload = await _awaitBuffer(
      (port) => _onApp(
        app,
        (a) => fdbStorageList(a, p.cast(), maxResults, token.cast(), port),
      ),
      'list $path',
    );
    final decoded = cborDecode(payload).toObject();
    if (decoded is! Map) throw StateError('the listing was not a CBOR map');
    List<String> paths(String key) => [
      for (final v in (decoded[key] as List?) ?? const []) '$v',
    ];
    return StorageList(
      prefixes: paths('prefixes'),
      items: paths('items'),
      nextPageToken: decoded['nextPageToken'] as String?,
    );
  } finally {
    calloc
      ..free(p)
      ..free(token);
  }
}

/// Downloads the object at [path].
///
/// Two round trips: the download needs a buffer sized before it starts, and
/// only the metadata knows how big the object is. Driving both from here keeps
/// the native side from starting one SDK operation inside another's callback.
Future<Uint8List> getObject(String path, {String? app}) async {
  final meta = await objectMetadata(path, app: app);
  final p = path.toNativeUtf8();
  try {
    return await _awaitBuffer(
      (port) =>
          _onApp(app, (a) => fdbStorageGet(a, p.cast(), meta.sizeBytes, port)),
      'get $path',
    );
  } finally {
    calloc.free(p);
  }
}

/// The metadata of the object at [path], without downloading it.
Future<StorageMetadata> objectMetadata(String path, {String? app}) async {
  final p = path.toNativeUtf8();
  try {
    final payload = await _awaitBuffer(
      (port) => _onApp(app, (a) => fdbStorageMetadata(a, p.cast(), port)),
      'metadata $path',
    );
    return _decodeMetadata(payload);
  } finally {
    calloc.free(p);
  }
}

/// Deletes the object at [path].
Future<void> deleteObject(String path, {String? app}) async {
  final p = path.toNativeUtf8();
  try {
    await _awaitOutcome(
      (port) => _onApp(app, (a) => fdbStorageDelete(a, p.cast(), port)),
      'delete $path',
    );
  } finally {
    calloc.free(p);
  }
}

/// A URL that serves the object at [path], including its access token.
Future<String> downloadUrl(String path, {String? app}) async {
  final p = path.toNativeUtf8();
  try {
    return await _awaitOutcome(
      (port) => _onApp(app, (a) => fdbStorageDownloadUrl(a, p.cast(), port)),
      'downloadUrl $path',
    );
  } finally {
    calloc.free(p);
  }
}
