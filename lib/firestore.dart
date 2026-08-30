// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Cloud Firestore, on the same `firebase::App` as [initAuth] and
/// [initDatabase].
///
/// Documents cross as CBOR in both directions. Firestore has value types CBOR
/// has no native form for, so those travel as tagged items — see
/// [FirestoreValue] for the mapping and why the tags are what they are.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:ffi/ffi.dart';

import 'src/ffi/bindings.dart';
import 'src/variant_codec.dart';

/// Tag numbers shared with `native/include/firebase_bridge.h`.
///
/// Private to this project: not IANA-registered, and nothing outside this ABI
/// should assume them.
abstract final class FirestoreTag {
  static const timestamp = 40000;
  static const geoPoint = 40001;
  static const reference = 40002;
  static const delete = 40010;
  static const serverTimestamp = 40011;
  static const arrayUnion = 40012;
  static const arrayRemove = 40013;
  static const incrementInt = 40014;
  static const incrementDouble = 40015;
}

/// A Firestore value with no plain Dart equivalent.
sealed class FirestoreValue {
  const FirestoreValue();
}

/// A point in time, to nanosecond precision.
///
/// Carried as two integers rather than RFC 8949's tag 1, whose payload is a
/// single number: a float64 epoch cannot hold nanoseconds, and rounding a
/// timestamp silently is worse than being explicit.
class FirestoreTimestamp extends FirestoreValue {
  const FirestoreTimestamp(this.seconds, this.nanoseconds);

  factory FirestoreTimestamp.fromDateTime(DateTime t) {
    final us = t.toUtc().microsecondsSinceEpoch;
    return FirestoreTimestamp(us ~/ 1000000, (us % 1000000) * 1000);
  }

  final int seconds;
  final int nanoseconds;

  DateTime toDateTime() => DateTime.fromMicrosecondsSinceEpoch(
    seconds * 1000000 + nanoseconds ~/ 1000,
    isUtc: true,
  );

  @override
  String toString() => 'FirestoreTimestamp(${toDateTime().toIso8601String()})';

  @override
  bool operator ==(Object other) =>
      other is FirestoreTimestamp &&
      other.seconds == seconds &&
      other.nanoseconds == nanoseconds;

  @override
  int get hashCode => Object.hash(seconds, nanoseconds);
}

/// A latitude/longitude pair.
class FirestoreGeoPoint extends FirestoreValue {
  const FirestoreGeoPoint(this.latitude, this.longitude);
  final double latitude;
  final double longitude;

  @override
  String toString() => 'FirestoreGeoPoint($latitude, $longitude)';

  @override
  bool operator ==(Object other) =>
      other is FirestoreGeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);
}

/// A reference to another document, by path.
class FirestoreReference extends FirestoreValue {
  const FirestoreReference(this.path);
  final String path;

  @override
  String toString() => 'FirestoreReference($path)';

  @override
  bool operator ==(Object other) =>
      other is FirestoreReference && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// An instruction to the server rather than a value.
///
/// Firestore never returns these; they only travel on a write. Decoding one
/// would mean the server sent something this mapping does not describe.
class FirestoreSentinel extends FirestoreValue {
  const FirestoreSentinel._(this._tag, [this._payload]);

  /// Removes the field.
  static const delete = FirestoreSentinel._(FirestoreTag.delete);

  /// Sets the field to the server's write time.
  static const serverTimestamp = FirestoreSentinel._(
    FirestoreTag.serverTimestamp,
  );

  /// Adds [values] to an array field, skipping ones already present.
  factory FirestoreSentinel.arrayUnion(List<Object?> values) =>
      FirestoreSentinel._(FirestoreTag.arrayUnion, values);

  /// Removes every instance of [values] from an array field.
  factory FirestoreSentinel.arrayRemove(List<Object?> values) =>
      FirestoreSentinel._(FirestoreTag.arrayRemove, values);

  /// Adds [by] to a numeric field, atomically.
  factory FirestoreSentinel.increment(num by) => FirestoreSentinel._(
    by is int ? FirestoreTag.incrementInt : FirestoreTag.incrementDouble,
    by,
  );

  final int _tag;
  final Object? _payload;
}

// --- CBOR mapping ---------------------------------------------------------

/// Encodes a document body for the native side.
///
/// Plain Dart values map to their CBOR equivalents; [FirestoreValue] instances
/// become tagged items.
CborValue encodeFirestoreValue(Object? v) {
  if (v == null) return const CborNull();
  if (v is bool) return CborBool(v);
  if (v is int) return CborInt(BigInt.from(v));
  if (v is double) return CborFloat(v);
  if (v is String) return CborString(v);
  if (v is Uint8List) return CborBytes(v);
  if (v is FirestoreTimestamp) {
    return CborList([
      CborInt(BigInt.from(v.seconds)),
      CborInt(BigInt.from(v.nanoseconds)),
    ], tags: [FirestoreTag.timestamp]);
  }
  if (v is FirestoreGeoPoint) {
    return CborList([
      CborFloat(v.latitude),
      CborFloat(v.longitude),
    ], tags: [FirestoreTag.geoPoint]);
  }
  if (v is FirestoreReference) {
    return CborString(v.path, tags: [FirestoreTag.reference]);
  }
  if (v is FirestoreSentinel) {
    final payload = v._payload;
    return switch (v._tag) {
      FirestoreTag.arrayUnion || FirestoreTag.arrayRemove => CborList(
        (payload! as List<Object?>).map(encodeFirestoreValue).toList(),
        tags: [v._tag],
      ),
      // A one-element array, not a bare number: the cbor package drops tags
      // when it normalises an integer to a small int, so a tagged bare int
      // arrives untagged and would decode as an ordinary value.
      FirestoreTag.incrementInt => CborList([
        CborInt(BigInt.from(payload! as int)),
      ], tags: [v._tag]),
      FirestoreTag.incrementDouble => CborList([
        CborFloat((payload! as num).toDouble()),
      ], tags: [v._tag]),
      _ => CborNull(tags: [v._tag]),
    };
  }
  if (v is List) return CborList(v.map(encodeFirestoreValue).toList());
  if (v is Map) {
    return CborMap({
      for (final e in v.entries)
        CborString('${e.key}'): encodeFirestoreValue(e.value),
    });
  }
  throw ArgumentError.value(v, 'value', 'no Firestore mapping for this type');
}

/// The inverse: CBOR back to Dart, resolving the tagged types.
///
/// Sentinels are rejected. Firestore does not return them, so one arriving here
/// means the payload does not describe a document.
Object? decodeFirestoreValue(CborValue v) {
  final tag = v.tags.isEmpty ? null : v.tags.first;
  switch (tag) {
    case FirestoreTag.timestamp:
      final a = (v as CborList).toObject()! as List<Object?>;
      return FirestoreTimestamp((a[0]! as num).toInt(), (a[1]! as num).toInt());
    case FirestoreTag.geoPoint:
      final a = (v as CborList).toObject()! as List<Object?>;
      return FirestoreGeoPoint(
        (a[0]! as num).toDouble(),
        (a[1]! as num).toDouble(),
      );
    case FirestoreTag.reference:
      return FirestoreReference((v as CborString).toString());
    case FirestoreTag.delete:
    case FirestoreTag.serverTimestamp:
    case FirestoreTag.arrayUnion:
    case FirestoreTag.arrayRemove:
    case FirestoreTag.incrementInt:
    case FirestoreTag.incrementDouble:
      throw FormatException(
        'sentinel tag $tag in a document: sentinels are write-only, so this '
        'payload is not a document Firestore produced',
      );
  }
  if (v is CborList) return v.map(decodeFirestoreValue).toList();
  if (v is CborMap) {
    return <String, Object?>{
      for (final e in v.entries)
        e.key.toObject().toString(): decodeFirestoreValue(e.value),
    };
  }
  return v.toObject();
}

/// Decodes a document from a snapshot buffer, or null when the payload is
/// empty — which is how a missing document arrives.
Map<String, Object?>? decodeDocument(Uint8List bytes) {
  if (bytes.length < snapshotHeaderBytes) {
    throw const FormatException('snapshot shorter than its header');
  }
  if (bytes.length == snapshotHeaderBytes) return null;
  final decoded = decodeFirestoreValue(
    cborDecode(Uint8List.sublistView(bytes, snapshotHeaderBytes)),
  );
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('document payload is not a map');
  }
  return decoded;
}

// --- API ------------------------------------------------------------------

/// Whether this build binds Firestore.
///
/// False unless the consuming app asked for it:
/// `hooks.user_defines.firebase_ffi.products: [auth, database, firestore]`.
/// Firestore's archives pull in gRPC, protobuf and abseil, so an app that does
/// not reference them does not carry them.
bool get hasFirestore => fdbHaveFirestore() != 0;

/// Creates the Firestore instance on the shared [firebase::App].
///
/// [initDatabase] must have run first — that is what creates the App, and the
/// credential a signed-in user establishes travels with it.
void initFirestore() {
  final rc = fdbFsInit();
  if (rc != 0) {
    throw StateError(
      rc == -1
          ? 'initFirestore before initDatabase: there is no App yet'
          : 'Firestore instance could not be created ($rc)',
    );
  }
}

/// Awaits an operation that posts `[ok, code, message]`.
Future<void> _awaitOutcome(int Function(int port) start, String what) {
  final completer = Completer<void>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete();
    } else {
      completer.completeError(
        FirestoreException(parts[1]! as int, parts[2]! as String, what),
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

/// A Firestore operation that failed, carrying the SDK's own code and message.
class FirestoreException implements Exception {
  const FirestoreException(this.code, this.message, this.operation);
  final int code;
  final String message;
  final String operation;

  @override
  String toString() => 'FirestoreException($operation, $code): $message';
}

/// Writes [data] to [path]. With [merge], fields absent from [data] are left
/// alone rather than removed.
Future<void> setDocument(
  String path,
  Map<String, Object?> data, {
  bool merge = false,
}) {
  final bytes = Uint8List.fromList(cborEncode(encodeFirestoreValue(data)));
  final p = path.toNativeUtf8();
  final buf = malloc<Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  return _awaitOutcome(
    (port) => fdbFsSet(p.cast(), buf.cast(), bytes.length, merge ? 1 : 0, port),
    'set $path',
  ).whenComplete(() {
    // Freed only once the write has been handed to the SDK, which copies it.
    calloc.free(p);
    malloc.free(buf);
  });
}

/// Deletes [path].
Future<void> deleteDocument(String path) {
  final p = path.toNativeUtf8();
  return _awaitOutcome(
    (port) => fdbFsDelete(p.cast(), port),
    'delete $path',
  ).whenComplete(() => calloc.free(p));
}

/// Reads [path], or null when it does not exist.
Future<Map<String, Object?>?> getDocument(String path) {
  final completer = Completer<Map<String, Object?>?>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final bytes = message! as Uint8List;
    final header = ByteData.sublistView(bytes);
    if (header.getInt64(8, Endian.host) < 0) {
      completer.completeError(
        FirestoreException(-1, 'read failed', 'get $path'),
      );
      return;
    }
    completer.complete(decodeDocument(bytes));
  };
  final p = path.toNativeUtf8();
  final rc = fdbFsGet(p.cast(), receive.sendPort.nativePort);
  calloc.free(p);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('get $path failed to start ($rc)'));
  }
  return completer.future;
}

/// Watches [path], emitting the document on every change and null when it does
/// not exist. Cancelling the subscription removes the listener.
Stream<Map<String, Object?>?> onDocument(String path) {
  late StreamController<Map<String, Object?>?> controller;
  late RawReceivePort receive;
  var listenerId = 0;

  void stop() {
    if (listenerId > 0) fdbFsUnlisten(listenerId);
    receive.close();
  }

  controller = StreamController<Map<String, Object?>?>(
    onCancel: stop,
    onListen: () {
      receive = RawReceivePort();
      receive.handler = (Object? message) {
        final bytes = message! as Uint8List;
        final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
        if (seq < 0) {
          // The payload carries the reason rather than just the fact.
          final reason = decodeSnapshotValue(bytes);
          controller.addError(
            StateError('firestore listener cancelled: ${reason ?? "no reason"}'),
          );
          return;
        }
        controller.add(decodeDocument(bytes));
      };
      final p = path.toNativeUtf8();
      listenerId = fdbFsListen(p.cast(), receive.sendPort.nativePort);
      calloc.free(p);
      if (listenerId < 0) {
        controller.addError(StateError('listen $path failed ($listenerId)'));
        stop();
      }
    },
  );
  return controller.stream;
}
