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
/// materialized. Canceling the subscription removes the SDK listener.
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

/// Writes [value] at [path] with [priority], which orders it among its
/// siblings and is what [DbQuery.orderByPriority] reads.
///
/// One operation, not two. Writing the value and then the priority lets a
/// listener see the node in between, still in its old position.
Future<void> setValueWithPriority(
  String path,
  Object? value,
  Object? priority,
) {
  final v = encodeVariant(value);
  final pr = encodeVariant(priority);
  final p = path.toNativeUtf8();
  final vb = calloc<Uint8>(v.isEmpty ? 1 : v.length);
  final pb = calloc<Uint8>(pr.isEmpty ? 1 : pr.length);
  if (v.isNotEmpty) vb.asTypedList(v.length).setAll(0, v);
  if (pr.isNotEmpty) pb.asTypedList(pr.length).setAll(0, pr);
  return _awaitDbOutcome(
    (port) => fdbDbSetWithPriority(p.cast(), vb, v.length, pb, pr.length, port),
    'setValueWithPriority',
  ).whenComplete(() {
    calloc
      ..free(p)
      ..free(vb)
      ..free(pb);
  });
}

/// Sets the priority of an existing node, leaving its value alone.
Future<void> setPriority(String path, Object? priority) {
  final pr = encodeVariant(priority);
  final p = path.toNativeUtf8();
  final pb = calloc<Uint8>(pr.isEmpty ? 1 : pr.length);
  if (pr.isNotEmpty) pb.asTypedList(pr.length).setAll(0, pr);
  return _awaitDbOutcome(
    (port) => fdbDbSetPriority(p.cast(), pb, pr.length, port),
    'setPriority',
  ).whenComplete(() {
    calloc
      ..free(p)
      ..free(pb);
  });
}

/// Keeps [path] in sync with no listener attached, so a later read is served
/// from cache rather than the network.
///
/// Returns as soon as the SDK has taken the instruction; there is nothing to
/// wait for.
void keepSynced(String path, bool keep, [DbQuery? query]) {
  final encoded = (query ?? const DbQuery())._encode();
  final p = path.toNativeUtf8();
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  if (encoded.isNotEmpty) {
    buf.asTypedList(encoded.length).setAll(0, encoded);
  }
  try {
    final rc = fdbDbKeepSynced(p.cast(), buf, encoded.length, keep ? 1 : 0);
    if (rc != 0) throw _refuse(rc, 'keepSynced');
  } finally {
    calloc
      ..free(p)
      ..free(buf);
  }
}

/// Drops writes that have not reached the server.
///
/// Their futures fail rather than hang, which is the point: an app that has
/// given up on a write needs to hear that it will not land.
void purgeOutstandingWrites() {
  if (fdbDbPurgeOutstandingWrites() != 0) {
    throw StateError('purgeOutstandingWrites before the app was initialized');
  }
}

/// Removes whatever is at [path].
Future<void> removeValue(String path) {
  final p = path.toNativeUtf8();
  return _awaitDbOutcome(
    (port) => fdbDbRemove(p.cast(), port),
    'remove',
  ).whenComplete(() => calloc.free(p));
}

/// What the server should do with [path] if this client goes away without
/// saying goodbye.
///
/// Registered with the server now and carried out by it on disconnect, which
/// is the only cleanup that survives a device losing power rather than
/// shutting down — nothing on the device gets to run at that point.
///
/// The future completes when the *registration* lands. Whether the server
/// later carries it out is not something a client can observe.
class OnDisconnect {
  const OnDisconnect(this.path);

  final String path;

  /// Writes [value] on disconnect.
  Future<void> setValue(Object? value) =>
      _withCbor(path, value, fdbDbOnDisconnectSet, 'onDisconnect.set');

  /// Writes the named children on disconnect, leaving the rest.
  Future<void> updateChildren(Map<String, Object?> value) =>
      _withCbor(path, value, fdbDbOnDisconnectUpdate, 'onDisconnect.update');

  /// Writes [value] with [priority] on disconnect, in one operation.
  Future<void> setValueWithPriority(Object? value, Object? priority) {
    final v = encodeVariant(value);
    final pr = encodeVariant(priority);
    final p = path.toNativeUtf8();
    final vb = calloc<Uint8>(v.isEmpty ? 1 : v.length);
    final pb = calloc<Uint8>(pr.isEmpty ? 1 : pr.length);
    if (v.isNotEmpty) vb.asTypedList(v.length).setAll(0, v);
    if (pr.isNotEmpty) pb.asTypedList(pr.length).setAll(0, pr);
    return _awaitDbOutcome(
      (port) => fdbDbOnDisconnectSetWithPriority(
        p.cast(),
        vb,
        v.length,
        pb,
        pr.length,
        port,
      ),
      'onDisconnect.setWithPriority',
    ).whenComplete(() {
      calloc
        ..free(p)
        ..free(vb)
        ..free(pb);
    });
  }

  /// Removes [path] on disconnect. The usual way to clear a presence marker.
  Future<void> remove() {
    final p = path.toNativeUtf8();
    return _awaitDbOutcome(
      (port) => fdbDbOnDisconnectRemove(p.cast(), port),
      'onDisconnect.remove',
    ).whenComplete(() => calloc.free(p));
  }

  /// Drops every registration for [path], not only the last one.
  Future<void> cancel() {
    final p = path.toNativeUtf8();
    return _awaitDbOutcome(
      (port) => fdbDbOnDisconnectCancel(p.cast(), port),
      'onDisconnect.cancel',
    ).whenComplete(() => calloc.free(p));
  }
}

/// What a transaction handler decided.
class DbTransactionResult {
  /// Commit [value].
  const DbTransactionResult.commit(this.value) : abort = false;

  /// Leave the value alone and give up.
  const DbTransactionResult.abort() : value = null, abort = true;

  final Object? value;
  final bool abort;
}

/// Reads [path], lets [handler] decide the next value, and writes it — retrying
/// if it changed underneath.
///
/// [handler] receives the current value and may be called **more than once**:
/// the SDK re-runs it for each attempt, so it must not carry state between
/// calls. Its first call often sees null, because the SDK runs the handler
/// against local state before the server's value has arrived; returning a
/// value computed from that null is correct — the retry will run again with
/// the real one.
///
/// [handler] must be pure: it decides from [current] alone. While it runs, the
/// SDK's database thread is parked waiting for the answer, so a handler that
/// awaited another database call would be waiting on the thread it has
/// stopped. That is why it is synchronous — the type makes the rule rather
/// than a comment asking for it.
///
/// Answers the committed value, or throws [DatabaseException] if the
/// transaction failed. A handler that aborts completes with null.
Future<Object?> runDbTransaction(
  String path,
  DbTransactionResult Function(Object? current) handler,
) {
  final completer = Completer<Object?>();
  final receive = RawReceivePort();
  var txnId = 0;
  var aborted = false;

  receive.handler = (Object? message) {
    final bytes = message! as Uint8List;
    final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);

    if (seq < 0) {
      receive.close();
      if (aborted) {
        // The SDK reports a user abort as a failed future -- with
        // kErrorWriteCanceled, not the kErrorTransactionAbortedByUser the
        // enum suggests. Keyed off what was asked for rather than the code,
        // since either way the transaction did not commit, and an abort the
        // caller requested is not an error.
        completer.complete(null);
        return;
      }
      completer.completeError(
        DatabaseException(
          -seq.toInt(),
          '${decodeSnapshotValue(bytes) ?? "transaction failed"}',
          'runDbTransaction',
        ),
      );
      return;
    }
    if (seq == 0) {
      receive.close();
      completer.complete(decodeSnapshotValue(bytes));
      return;
    }

    // An attempt. The SDK's thread is parked until this answers, so anything
    // that throws here has to still answer, or the transaction never ends.
    DbTransactionResult decision;
    try {
      decision = handler(decodeSnapshotValue(bytes));
    } on Object {
      decision = const DbTransactionResult.abort();
    }
    if (decision.abort) aborted = true;

    final encoded = decision.abort || decision.value == null
        ? Uint8List(0)
        : encodeVariant(decision.value);
    final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
    if (encoded.isNotEmpty) {
      buf.asTypedList(encoded.length).setAll(0, encoded);
    }
    try {
      fdbDbTxnApply(txnId, buf, encoded.length, decision.abort ? 1 : 0);
    } finally {
      calloc.free(buf);
    }
  };

  final p = path.toNativeUtf8();
  txnId = fdbDbTxnRun(p.cast(), receive.sendPort.nativePort);
  calloc.free(p);
  if (txnId <= 0) {
    receive.close();
    return Future.error(switch (txnId) {
      -1 => StateError('runTransaction before the app was initialized'),
      -2 => ArgumentError('a path is required'),
      _ => StateError('runTransaction failed ($txnId)'),
    });
  }
  return completer.future;
}

/// Drops the connection to the backend.
///
/// Registered [OnDisconnect] actions run on the server when this takes effect,
/// which is what makes them observable without pulling the power.
void goOffline() {
  if (fdbDbGoOffline() != 0) {
    throw StateError('goOffline before the Firebase app was initialized');
  }
}

/// Restores the connection dropped by [goOffline].
void goOnline() {
  if (fdbDbGoOnline() != 0) {
    throw StateError('goOnline before the Firebase app was initialized');
  }
}

/// Reads [path] once, through a listener.
///
/// There is no server read on desktop. `DatabaseReference::GetValue` completes
/// on the first event a listener receives, and for a path with nothing cached
/// that event is the empty **local** state — it answers null for data that is
/// on the server. So this attaches a listener and returns the value once it
/// has stopped changing for [settle].
///
/// That is a heuristic, and it is worth being plain about which way it errs.
/// The SDK sends local state first and the server's answer second, but only
/// when the two differ, so counting events cannot work: a cached path sends
/// one event and an uncached path sends two. Waiting for quiet is true in both
/// cases. What it costs is [settle] of latency on every read, and what it
/// risks is returning an intermediate value if a node is being written faster
/// than [settle] — for which a listener, not a read, is the right tool.
///
/// Returns null if nothing arrives within [timeout], which is also what an
/// empty path returns; the two are not distinguishable here, as they are not
/// in the SDK.
Future<Object?> readValue(
  String path, {
  Duration settle = const Duration(milliseconds: 400),
  Duration timeout = const Duration(seconds: 15),
}) async {
  final completer = Completer<Object?>();
  Object? last;
  var seen = false;
  Timer? quiet;

  final sub = onValue(path).listen(
    (s) {
      last = s.value;
      seen = true;
      quiet?.cancel();
      quiet = Timer(settle, () {
        if (!completer.isCompleted) completer.complete(last);
      });
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
  );

  try {
    return await completer.future.timeout(
      timeout,
      // A path that was never written still delivers an event, so a timeout
      // here means nothing arrived at all -- no connection, or a rule that
      // denies the read. Null is what the SDK would say too.
      onTimeout: () => seen ? last : null,
    );
  } finally {
    quiet?.cancel();
    await sub.cancel();
  }
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

/// What a query orders by. A bound (`startAt` and the rest) is meaningless
/// without one, and the SDK requires it to be applied first.
enum DbOrderBy { child, key, value, priority }

/// A query over a node: an ordering, optional bounds, and an optional limit.
///
/// Immutable — each method returns a new query, so a base can be shared.
class DbQuery {
  const DbQuery._(this._spec);

  /// The whole node, unordered.
  const DbQuery() : _spec = const {};

  final Map<String, Object?> _spec;

  DbQuery _with(Map<String, Object?> changes) =>
      DbQuery._({..._spec, ...changes});

  /// Orders by a child field, which every bound is then measured against.
  DbQuery orderByChild(String path) =>
      _with({'orderBy': 'child', 'orderByPath': path});

  DbQuery orderByKey() => _with({'orderBy': 'key'});
  DbQuery orderByValue() => _with({'orderBy': 'value'});
  DbQuery orderByPriority() => _with({'orderBy': 'priority'});

  /// Starts at [value], optionally disambiguated by a child key.
  DbQuery startAt(Object? value, {String? key}) =>
      _with({'startAt': value, if (key != null) 'startAtKey': key});

  DbQuery endAt(Object? value, {String? key}) =>
      _with({'endAt': value, if (key != null) 'endAtKey': key});

  /// Exactly [value]. Cannot be combined with [startAt] or [endAt]: it is both
  /// of them at once, so pairing them is a contradiction rather than a
  /// narrowing, and the native side refuses it.
  DbQuery equalTo(Object? value, {String? key}) =>
      _with({'equalTo': value, if (key != null) 'equalToKey': key});

  /// The first [n] in the ordering. Cannot be combined with [limitToLast].
  DbQuery limitToFirst(int n) => _with({'limitToFirst': n});

  /// The last [n] in the ordering.
  DbQuery limitToLast(int n) => _with({'limitToLast': n});

  Uint8List _encode() => _spec.isEmpty ? Uint8List(0) : encodeVariant(_spec);
}

/// What happened to a child.
enum DbChildEvent { added, changed, moved, removed }

/// One child event, with enough context to keep an ordered list without
/// re-reading the node.
class DbChildSnapshot {
  const DbChildSnapshot({
    required this.event,
    required this.key,
    required this.previousKey,
    required this.value,
  });

  final DbChildEvent event;
  final String key;

  /// The key of the sibling before this one in the query's ordering, or null
  /// when it is first.
  final String? previousKey;

  final Object? value;

  @override
  String toString() => 'DbChildSnapshot(${event.name}, $key)';
}

Object _refuse(int rc, String what) => switch (rc) {
  -1 => StateError('$what before the Firebase app was initialized'),
  -2 => ArgumentError('a path is required'),
  -3 => ArgumentError(
    'this query cannot be applied: an unknown key, equalTo with a bound, or '
    'both limits at once',
  ),
  _ => StateError('$what failed ($rc)'),
};

Stream<T> _listenWith<T>(
  String path,
  DbQuery query,
  String what,
  int Function(Pointer<Char>, Pointer<Uint8>, int, int) start,
  T Function(Uint8List bytes, int seq) decode,
) {
  late RawReceivePort receive;
  late StreamController<T> controller;
  var handle = 0;
  controller = StreamController<T>(
    onListen: () {
      receive = RawReceivePort();
      receive.handler = (Object? message) {
        final bytes = message! as Uint8List;
        final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
        if (seq < 0) {
          controller.addError(
            DatabaseException(
              -seq.toInt(),
              '${decodeSnapshotValue(bytes) ?? "listener canceled"}',
              what,
            ),
          );
          return;
        }
        controller.add(decode(bytes, seq));
      };
      final encoded = query._encode();
      final p = path.toNativeUtf8();
      final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
      if (encoded.isNotEmpty) {
        buf.asTypedList(encoded.length).setAll(0, encoded);
      }
      try {
        handle = start(
          p.cast(),
          buf,
          encoded.length,
          receive.sendPort.nativePort,
        );
      } finally {
        calloc
          ..free(p)
          ..free(buf);
      }
      // A value handle is positive and a child handle is below -1000; the
      // only values in between are the failure codes.
      if (handle > -1000 && handle <= 0) {
        receive.close();
        // Deferred, and the stream closed after it. Adding synchronously here
        // delivers the error before onListen returns -- before the subscriber
        // is attached -- so it surfaces as an unhandled async error instead of
        // reaching the caller that asked for the query.
        final failure = _refuse(handle, what);
        scheduleMicrotask(() {
          controller
            ..addError(failure)
            ..close();
        });
      }
    },
    onCancel: () {
      if (handle > 0 || handle <= -1000) fdbDbUnlisten(handle);
      receive.close();
    },
  );
  return controller.stream;
}

/// Watches a node through a query.
Stream<DbSnapshot> onQueryValue(String path, DbQuery query) => _listenWith(
  path,
  query,
  'onQueryValue',
  fdbDbQueryListen,
  (bytes, seq) => DbSnapshot(
    seq: seq,
    value: decodeSnapshotValue(bytes),
    postedNs: ByteData.sublistView(bytes).getInt64(16, Endian.host),
  ),
);

/// Watches the children of a node, one event per change.
///
/// A value listener reports the whole node on every change, so it cannot say
/// which child moved, and cannot report a removal once the node is gone.
Stream<DbChildSnapshot> onChildEvent(String path, [DbQuery? query]) =>
    _listenWith(
      path,
      query ?? const DbQuery(),
      'onChildEvent',
      fdbDbChildListen,
      (bytes, seq) {
        final m = (decodeSnapshotValue(bytes) as Map?) ?? const {};
        final type = (m['type'] as int?) ?? 0;
        return DbChildSnapshot(
          event: DbChildEvent.values[type.clamp(0, 3)],
          key: '${m['key'] ?? ''}',
          previousKey: m['prev'] == null ? null : '${m['prev']}',
          value: m['value'],
        );
      },
    );

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
