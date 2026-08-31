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
    return CborList(
      [CborInt(BigInt.from(v.seconds)), CborInt(BigInt.from(v.nanoseconds))],
      tags: [FirestoreTag.timestamp],
    );
  }
  if (v is FirestoreGeoPoint) {
    return CborList(
      [CborFloat(v.latitude), CborFloat(v.longitude)],
      tags: [FirestoreTag.geoPoint],
    );
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
      // when it normalizes an integer to a small int, so a tagged bare int
      // arrives untagged and would decode as an ordinary value.
      FirestoreTag.incrementInt => CborList(
        [CborInt(BigInt.from(payload! as int))],
        tags: [v._tag],
      ),
      FirestoreTag.incrementDouble => CborList(
        [CborFloat((payload! as num).toDouble())],
        tags: [v._tag],
      ),
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
  // Before the generic conversion: toObject() renders a byte string as a plain
  // List<int>, which is the one Firestore type that then cannot be told from an
  // array of small integers. Encoding takes a Uint8List, so decoding returns
  // one — the asymmetry was the bug.
  if (v is CborBytes) return Uint8List.fromList(v.bytes);
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
/// Points Firestore at a local emulator. Call after [initFirestore] and before
/// the first operation: Firestore freezes its settings once the client starts,
/// so a later call is refused.
void useFirestoreEmulator(String host, int port) {
  final h = host.toNativeUtf8();
  try {
    final rc = fdbFsUseEmulator(h.cast(), port);
    if (rc != 0) {
      throw StateError('useFirestoreEmulator failed ($rc)');
    }
  } finally {
    calloc.free(h);
  }
}

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
    final seq = header.getInt64(8, Endian.host);
    if (seq < 0) {
      completer.completeError(
        FirestoreException(
          seq.toInt(),
          seq == -2
              ? 'the document exists but could not be encoded'
              : 'read failed',
          'get $path',
        ),
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
            StateError('firestore listener canceled: ${reason ?? "no reason"}'),
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

// --- Queries ---------------------------------------------------------------

/// One document from a query: its body, and where it lives.
///
/// A bare list of bodies would be unusable — nothing inside a document says
/// which document it is.
class QueryDocument {
  const QueryDocument({
    required this.id,
    required this.path,
    required this.data,
  });

  final String id;
  final String path;
  final Map<String, Object?> data;

  @override
  String toString() => 'QueryDocument($path, ${data.length} fields)';
}

/// A filter on a query. The operators are Firestore's own, spelled as the
/// plugin spells them.
class Where {
  const Where(this.field, this.op, this.value);

  const Where.equalTo(String field, Object? value) : this(field, '==', value);
  const Where.notEqualTo(String field, Object? value)
    : this(field, '!=', value);
  const Where.lessThan(String field, Object? value) : this(field, '<', value);
  const Where.lessThanOrEqualTo(String field, Object? value)
    : this(field, '<=', value);
  const Where.greaterThan(String field, Object? value)
    : this(field, '>', value);
  const Where.greaterThanOrEqualTo(String field, Object? value)
    : this(field, '>=', value);
  const Where.arrayContains(String field, Object? value)
    : this(field, 'array-contains', value);
  const Where.arrayContainsAny(String field, List<Object?> values)
    : this(field, 'array-contains-any', values);
  const Where.whereIn(String field, List<Object?> values)
    : this(field, 'in', values);
  const Where.notIn(String field, List<Object?> values)
    : this(field, 'not-in', values);

  final String field;
  final String op;
  final Object? value;
}

/// An ordering clause.
class OrderBy {
  const OrderBy(this.field, {this.descending = false});
  final String field;
  final bool descending;
}

Map<String, Object?> _querySpec({
  required List<Where> where,
  required List<OrderBy> orderBy,
  int? limit,
  int? limitToLast,
  List<Object?>? startAt,
  List<Object?>? startAfter,
  List<Object?>? endAt,
  List<Object?>? endBefore,
}) => <String, Object?>{
  if (where.isNotEmpty)
    'where': [
      for (final w in where) [w.field, w.op, w.value],
    ],
  if (orderBy.isNotEmpty)
    'orderBy': [
      for (final o in orderBy) [o.field, o.descending ? 'desc' : 'asc'],
    ],
  if (limit != null) 'limit': limit,
  if (limitToLast != null) 'limitToLast': limitToLast,
  // One value per orderBy clause. Firestore enforces that correspondence and
  // rejects a mismatch itself, rather than guessing which ordering a value
  // belongs to.
  if (startAt != null) 'startAt': startAt,
  if (startAfter != null) 'startAfter': startAfter,
  if (endAt != null) 'endAt': endAt,
  if (endBefore != null) 'endBefore': endBefore,
};

Uint8List _encodeSpec(Map<String, Object?> spec) => spec.isEmpty
    ? Uint8List(0)
    : Uint8List.fromList(cborEncode(encodeFirestoreValue(spec)));

/// Runs a query over [collectionPath].
///
/// The whole query travels as one CBOR spec rather than as a chain of calls,
/// so the native side holds no per-query state and there is no handle to leak
/// if a caller goes away mid-build.
///
/// A spec the native side cannot apply is refused rather than run without the
/// offending clause: a dropped filter returns more documents and no error,
/// which reads as data.
Future<List<QueryDocument>> queryCollection(
  String collectionPath, {
  List<Where> where = const [],
  List<OrderBy> orderBy = const [],
  int? limit,
  int? limitToLast,
  List<Object?>? startAt,
  List<Object?>? startAfter,
  List<Object?>? endAt,
  List<Object?>? endBefore,
}) {
  final spec = _querySpec(
    where: where,
    orderBy: orderBy,
    limit: limit,
    limitToLast: limitToLast,
    startAt: startAt,
    startAfter: startAfter,
    endAt: endAt,
    endBefore: endBefore,
  );
  final completer = Completer<List<QueryDocument>>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final bytes = message! as Uint8List;
    final header = ByteData.sublistView(bytes);
    final seq = header.getInt64(8, Endian.host);
    if (seq < 0) {
      completer.completeError(
        FirestoreException(
          seq.toInt(),
          seq == -2 ? 'the result could not be encoded' : 'query failed',
          'query $collectionPath',
        ),
      );
      return;
    }
    completer.complete(_decodeQueryResult(bytes));
  };

  final p = collectionPath.toNativeUtf8();
  final encoded = _encodeSpec(spec);
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  if (encoded.isNotEmpty) {
    buf.asTypedList(encoded.length).setAll(0, encoded);
  }
  try {
    final rc = fdbFsQuery(
      p.cast(),
      buf,
      encoded.length,
      receive.sendPort.nativePort,
    );
    if (rc != 0) {
      receive.close();
      return Future.error(switch (rc) {
        -3 => ArgumentError('this query cannot be expressed through the ABI'),
        // The SDK refused something the spec expressed: a field path with a
        // '/' or '[' in it, for instance. Distinct from -3 so a caller can
        // tell "I cannot say that" from "Firestore will not accept it".
        -4 => ArgumentError('Firestore refused this query; see stderr'),
        _ => StateError('query $collectionPath failed to start ($rc)'),
      });
    }
  } finally {
    calloc
      ..free(p)
      ..free(buf);
  }
  return completer.future;
}

List<QueryDocument> _decodeQueryResult(Uint8List bytes) {
  if (bytes.length <= snapshotHeaderBytes) return const [];
  final decoded = cborDecode(Uint8List.sublistView(bytes, snapshotHeaderBytes));
  final list = decodeFirestoreValue(decoded);
  if (list is! List) {
    throw const FormatException('a query result was not a CBOR array');
  }
  return [
    for (final entry in list)
      if (entry is Map)
        QueryDocument(
          id: '${entry['id']}',
          path: '${entry['path']}',
          data: {
            for (final e in ((entry['data'] as Map?) ?? const {}).entries)
              '${e.key}': e.value,
          },
        ),
  ];
}

/// Watches a query, emitting the whole result each time it changes.
///
/// The same spec as [queryCollection], parsed by the same code natively — a
/// second parser would be free to disagree about what a query means.
Stream<List<QueryDocument>> onQuery(
  String collectionPath, {
  List<Where> where = const [],
  List<OrderBy> orderBy = const [],
  int? limit,
  int? limitToLast,
  List<Object?>? startAt,
  List<Object?>? startAfter,
  List<Object?>? endAt,
  List<Object?>? endBefore,
}) {
  final encoded = _encodeSpec(
    _querySpec(
      where: where,
      orderBy: orderBy,
      limit: limit,
      limitToLast: limitToLast,
      startAt: startAt,
      startAfter: startAfter,
      endAt: endAt,
      endBefore: endBefore,
    ),
  );

  late StreamController<List<QueryDocument>> controller;
  late RawReceivePort receive;
  var listenerId = 0;

  void stop() {
    if (listenerId > 0) fdbFsUnlisten(listenerId);
    receive.close();
  }

  controller = StreamController<List<QueryDocument>>(
    onCancel: stop,
    onListen: () {
      receive = RawReceivePort();
      receive.handler = (Object? message) {
        final bytes = message! as Uint8List;
        final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
        if (seq < 0) {
          // The payload carries the reason rather than just the fact: a
          // listener that stops silently is nearly always a rules problem.
          final reason = decodeSnapshotValue(bytes);
          controller.addError(
            StateError(
              'firestore query listener canceled: ${reason ?? "no reason"}',
            ),
          );
          return;
        }
        controller.add(_decodeQueryResult(bytes));
      };

      final p = collectionPath.toNativeUtf8();
      final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
      if (encoded.isNotEmpty) {
        buf.asTypedList(encoded.length).setAll(0, encoded);
      }
      listenerId = fdbFsQueryListen(
        p.cast(),
        buf,
        encoded.length,
        receive.sendPort.nativePort,
      );
      calloc
        ..free(p)
        ..free(buf);
      if (listenerId < 0) {
        controller.addError(
          listenerId == -3 || listenerId == -4
              ? ArgumentError('this query cannot be watched as expressed')
              : StateError('watch $collectionPath failed ($listenerId)'),
        );
        stop();
      }
    },
  );
  return controller.stream;
}

// --- Transactions ----------------------------------------------------------

/// The handle a transaction handler is given.
///
/// Reads go to the backend immediately, through the SDK's transaction so they
/// are part of it. Writes are buffered here and applied together at commit: a
/// write already handed to the SDK could not be taken back if a later line of
/// the handler threw.
class FirestoreTransaction {
  FirestoreTransaction._(this._id);

  final int _id;
  final List<List<Object?>> _writes = [];
  bool _wrote = false;

  /// Reads [path] inside the transaction.
  ///
  /// Firestore requires every read to happen before any write, and rejects a
  /// transaction that does otherwise. Enforced here so the answer is a clear
  /// error at the call site rather than a rejection at commit.
  Future<Map<String, Object?>?> get(String path) {
    if (_wrote) {
      throw StateError(
        'a transaction must do all of its reads before any of its writes; '
        'get("$path") came after a write',
      );
    }
    final completer = Completer<Map<String, Object?>?>();
    final receive = RawReceivePort();
    receive.handler = (Object? message) {
      receive.close();
      final bytes = message! as Uint8List;
      final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
      if (seq < 0) {
        completer.completeError(
          FirestoreException(
            seq.toInt(),
            'read failed',
            'transaction get $path',
          ),
        );
        return;
      }
      completer.complete(decodeDocument(bytes));
    };
    final p = path.toNativeUtf8();
    final rc = fdbFsTxnGet(_id, p.cast(), receive.sendPort.nativePort);
    calloc.free(p);
    if (rc != 0) {
      receive.close();
      return Future.error(StateError('transaction get $path failed ($rc)'));
    }
    return completer.future;
  }

  void set(String path, Map<String, Object?> data, {bool merge = false}) {
    _wrote = true;
    _writes.add([merge ? 'merge' : 'set', path, data]);
  }

  void update(String path, Map<String, Object?> data) {
    _wrote = true;
    _writes.add(['update', path, data]);
  }

  void delete(String path) {
    _wrote = true;
    _writes.add(['delete', path]);
  }

  /// Discards anything buffered, so a retry starts from an empty slate.
  void _reset() {
    _writes.clear();
    _wrote = false;
  }

  Uint8List _encodeWrites() => _writes.isEmpty
      ? Uint8List(0)
      : Uint8List.fromList(cborEncode(encodeFirestoreValue(_writes)));
}

/// Runs [handler] in a transaction, retrying it if Firestore says to.
///
/// The handler may run more than once — that is what a transaction is — so it
/// must not have effects outside the writes it records on the handle.
Future<void> runTransaction(
  Future<void> Function(FirestoreTransaction tx) handler,
) {
  final done = Completer<void>();
  final receive = RawReceivePort();
  late FirestoreTransaction tx;
  var txnId = 0;

  receive.handler = (Object? message) async {
    final bytes = message! as Uint8List;
    final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);

    if (seq < 0) {
      receive.close();
      final reason = decodeSnapshotValue(bytes);
      if (!done.isCompleted) {
        done.completeError(
          FirestoreException(-1, '${reason ?? "failed"}', 'transaction'),
        );
      }
      return;
    }
    if (seq == 0) {
      receive.close();
      if (!done.isCompleted) done.complete();
      return;
    }

    // seq > 0 is an attempt. A retry arrives here again, so the buffer is
    // cleared rather than accumulating what the previous attempt recorded.
    tx._reset();
    try {
      await handler(tx);
    } catch (e) {
      // The handler decided against it. Abort rather than commit a partial
      // set of writes, and let the error surface as the transaction's.
      fdbFsTxnAbort(txnId);
      if (!done.isCompleted) done.completeError(e);
      return;
    }
    final encoded = tx._encodeWrites();
    final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
    if (encoded.isNotEmpty) {
      buf.asTypedList(encoded.length).setAll(0, encoded);
    }
    fdbFsTxnCommit(txnId, buf, encoded.length);
    calloc.free(buf);
  };

  txnId = fdbFsTxnBegin(receive.sendPort.nativePort);
  if (txnId <= 0) {
    receive.close();
    return Future.error(StateError('transaction failed to start ($txnId)'));
  }
  tx = FirestoreTransaction._(txnId);
  return done.future;
}
