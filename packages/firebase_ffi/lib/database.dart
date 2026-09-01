// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The v2 slice: `ref().set()` and `onValue` against the real Firebase
/// Realtime Database, over FFI, with no platform channel anywhere.
///
/// This is not a `FirebaseDatabasePlatform` implementation yet — it is the two
/// operations the transport prototype set out to prove, wired to the SDK. What
/// it establishes is that the whole path works end to end: the build hook links
/// the SDK, the C ABI reaches it, listener callbacks post from SDK worker
/// threads, and a Variant crosses as one external typed data buffer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/ffi/bindings.dart';
import 'src/variant_codec.dart';

/// Whether this build linked the Firebase C++ SDK. False for the standalone
/// transport benchmark, which builds without it.
bool get hasFirebase => fdbHaveFirebase() != 0;

/// The clock the native side stamps snapshots with. Exposed so a caller can
/// measure delivery latency against a single time base rather than guessing at
/// the offset between two.
int nowNs() => fdbNowNs();

/// One snapshot, decoded.
class DbSnapshot {
  DbSnapshot({required this.seq, required this.value, required this.postedNs});

  /// Monotonically increasing per listener. Negative means the stream was
  /// canceled and [value] is null.
  final int seq;
  final Object? value;

  /// When the native side posted it, on the same clock [fdbNowNs] reads — so a
  /// caller can measure delivery latency without a second time base.
  final int postedNs;

  bool get isCanceled => seq < 0;
}

/// Creates the App and Database. Idempotent.
///
/// Throws [StateError] rather than returning a code: a failure here is a
/// configuration problem the caller cannot proceed past.
void initDatabase({
  required String appId,
  required String apiKey,
  required String projectId,
  required String databaseUrl,
  String? storageBucket,
}) {
  if (!hasFirebase) {
    throw StateError(
      'this build has no Firebase SDK — configure with FDB_WITH_FIREBASE=ON '
      'and an SDK on CMAKE_PREFIX_PATH (or an emb augment)',
    );
  }
  final rc = fdbInitDartApi(NativeApi.initializeApiDLData);
  if (rc != 0) {
    throw StateError('Dart_InitializeApiDL failed: $rc');
  }

  final a = appId.toNativeUtf8();
  final k = apiKey.toNativeUtf8();
  final p = projectId.toNativeUtf8();
  final u = databaseUrl.toNativeUtf8();
  // Set on the app or not at all: Storage takes its bucket from the app's
  // options, and an app created without one fails the first operation with an
  // unknown error rather than refusing to initialize.
  final b = (storageBucket ?? '').toNativeUtf8();
  try {
    final result = fdbAppInit(a.cast(), k.cast(), p.cast(), u.cast(), b.cast());
    if (result != 0) {
      throw StateError('firebase App/Database init failed: $result');
    }
  } finally {
    for (final ptr in [a, k, p, u, b]) {
      calloc.free(ptr);
    }
  }
}

/// `ref(path).set(value)` for a string value.
///
/// Returns once the write has been handed to the SDK. It does not wait for the
/// server: completing a Dart Future from the SDK's Future is the next piece of
/// the ABI, and is deliberately not faked here.
void setString(String path, String value) {
  final p = path.toNativeUtf8();
  final v = value.toNativeUtf8();
  try {
    final rc = fdbDbSetString(p.cast(), v.cast());
    if (rc != 0) {
      throw StateError('set failed: $rc');
    }
  } finally {
    calloc.free(p);
    calloc.free(v);
  }
}

/// `ref(path).onValue`.
///
/// Each snapshot arrives as one external typed data buffer whose backing store
/// is the C allocation; the header is read in place and only the Variant is
/// materialized. Cancelling the subscription removes the SDK listener.
/// A Realtime Database operation that failed.
class DatabaseException implements Exception {
  const DatabaseException(this.code, this.message, this.operation);
  final int code;
  final String message;
  final String operation;

  @override
  String toString() => 'DatabaseException($operation, $code): $message';
}

Future<void> _awaitDbOutcome(int Function(int port) start, String what) {
  final completer = Completer<void>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete();
    } else {
      completer.completeError(
        DatabaseException(parts[1]! as int, parts[2]! as String, what),
      );
    }
  };
  final rc = start(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(switch (rc) {
      -1 => StateError('$what before the Firebase app was initialized'),
      -2 => ArgumentError('a path is required'),
      -3 => ArgumentError('this value cannot be encoded'),
      -4 => ArgumentError('update takes a map of children'),
      _ => StateError('$what failed to start ($rc)'),
    });
  }
  return completer.future;
}

Future<void> _withCbor(
  String path,
  Object? value,
  int Function(Pointer<Char>, Pointer<Uint8>, int, int) call,
  String what,
) {
  final encoded = encodeVariant(value);
  final p = path.toNativeUtf8();
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  buf.asTypedList(encoded.length).setAll(0, encoded);
  return _awaitDbOutcome(
    (port) => call(p.cast(), buf, encoded.length, port),
    what,
  ).whenComplete(() {
    calloc
      ..free(p)
      ..free(buf);
  });
}

/// Writes [value] at [path], replacing whatever was there.
Future<void> setValue(String path, Object? value) =>
    _withCbor(path, value, fdbDbSet, 'set');

/// Writes the named children of [value] and leaves the rest alone.
///
/// Not [setValue] with a partial map, which would delete everything the map
/// does not mention.
Future<void> updateChildren(String path, Map<String, Object?> value) =>
    _withCbor(path, value, fdbDbUpdate, 'update');

/// Removes whatever is at [path].
Future<void> removeValue(String path) {
  final p = path.toNativeUtf8();
  return _awaitDbOutcome(
    (port) => fdbDbRemove(p.cast(), port),
    'remove',
  ).whenComplete(() => calloc.free(p));
}

/// A new child key under [path], generated locally.
///
/// No request is made: the key is derived from the clock and a random seed, so
/// it can be written to immediately with [setValue].
String pushChild(String path) {
  const cap = 64;
  final p = path.toNativeUtf8();
  final out = calloc<Uint8>(cap);
  try {
    final rc = fdbDbPush(p.cast(), out.cast(), cap);
    if (rc < 0) {
      throw switch (rc) {
        -1 => StateError('pushChild before the Firebase app was initialized'),
        -2 => ArgumentError('a path is required'),
        _ => StateError('pushChild failed ($rc)'),
      };
    }
    return utf8.decode(out.asTypedList(rc));
  } finally {
    calloc
      ..free(p)
      ..free(out);
  }
}

Stream<DbSnapshot> onValue(String path) {
  final port = ReceivePort();
  final p = path.toNativeUtf8();
  late final int handle;
  late final StreamController<DbSnapshot> controller;

  void stop() {
    fdbDbUnlisten(handle);
    port.close();
    calloc.free(p);
  }

  controller = StreamController<DbSnapshot>(onCancel: stop);

  handle = fdbDbListen(p.cast(), port.sendPort.nativePort);
  if (handle < 0) {
    calloc.free(p);
    port.close();
    return Stream<DbSnapshot>.error(
      StateError('listen failed: database not initialized'),
    );
  }

  port.listen((message) {
    final bytes = message as Uint8List;
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.host) != fdbSnapshotMagic) {
      controller.addError(const FormatException('bad snapshot magic'));
      return;
    }
    // Offsets into FdbSnapshotHeader: magic 0, version 4, seq 8, posted_ns 16.
    final seq = view.getInt64(8, Endian.host);
    final postedNs = view.getInt64(16, Endian.host);
    if (seq < 0) {
      // The payload carries the SDK's error code and message.
      final reason = decodeSnapshotValue(bytes);
      controller.addError(
        StateError('database listener canceled: ${reason ?? "no reason"}'),
      );
      return;
    }
    controller.add(
      DbSnapshot(
        seq: seq,
        value: decodeSnapshotValue(bytes),
        postedNs: postedNs,
      ),
    );
  });

  return controller.stream;
}
