// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Cloud Storage: objects as bytes, on the same app as Auth, Database and
/// Firestore.
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

  @override
  String toString() => 'StorageException($operation, $code): $message';
}

/// True when the library was built with Storage bound.
bool get hasStorage {
  try {
    return fdbHaveStorage() != 0;
  } on ArgumentError {
    // The symbol is absent from a build that did not select this product.
    return false;
  }
}

/// Binds Storage to the app already initialized by `initFirebase`.
void initStorage() {
  final rc = fdbStorageInit();
  if (rc != 0) {
    throw StateError(
      rc == -1
          ? 'initStorage before the Firebase app was initialized'
          : 'Storage instance could not be created ($rc)',
    );
  }
}

/// Points Storage at a local emulator, after [initStorage] and before the
/// first operation — the SDK freezes the endpoint once a request has gone out.
void useStorageEmulator(String host, int port) {
  final h = host.toNativeUtf8();
  try {
    final rc = fdbStorageUseEmulator(h.cast(), port);
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
Future<StorageMetadata> putObject(
  String path,
  Uint8List bytes, {
  String? contentType,
}) async {
  final p = path.toNativeUtf8();
  final type = (contentType ?? '').toNativeUtf8();
  // Copied into native memory for the call. The native side copies again for
  // the duration of the upload, because PutBytes does not take ownership and
  // completes long after this returns.
  final buf = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  try {
    final payload = await _awaitBuffer(
      (port) => fdbStoragePut(p.cast(), buf, bytes.length, type.cast(), port),
      'put $path',
    );
    return _decodeMetadata(payload);
  } finally {
    calloc
      ..free(p)
      ..free(type)
      ..free(buf);
  }
}

/// Downloads the object at [path].
///
/// Two round trips: the download needs a buffer sized before it starts, and
/// only the metadata knows how big the object is. Driving both from here keeps
/// the native side from starting one SDK operation inside another's callback.
Future<Uint8List> getObject(String path) async {
  final meta = await objectMetadata(path);
  final p = path.toNativeUtf8();
  try {
    return await _awaitBuffer(
      (port) => fdbStorageGet(p.cast(), meta.sizeBytes, port),
      'get $path',
    );
  } finally {
    calloc.free(p);
  }
}

/// The metadata of the object at [path], without downloading it.
Future<StorageMetadata> objectMetadata(String path) async {
  final p = path.toNativeUtf8();
  try {
    final payload = await _awaitBuffer(
      (port) => fdbStorageMetadata(p.cast(), port),
      'metadata $path',
    );
    return _decodeMetadata(payload);
  } finally {
    calloc.free(p);
  }
}

/// Deletes the object at [path].
Future<void> deleteObject(String path) async {
  final p = path.toNativeUtf8();
  try {
    await _awaitOutcome(
      (port) => fdbStorageDelete(p.cast(), port),
      'delete $path',
    );
  } finally {
    calloc.free(p);
  }
}

/// A URL that serves the object at [path], including its access token.
Future<String> downloadUrl(String path) async {
  final p = path.toNativeUtf8();
  try {
    return await _awaitOutcome(
      (port) => fdbStorageDownloadUrl(p.cast(), port),
      'downloadUrl $path',
    );
  } finally {
    calloc.free(p);
  }
}
