// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_database` implementation for desktop Linux.
///
/// Values, queries, child events, transactions and `onDisconnect` route to the
/// C++ SDK.
///
/// Two things the desktop SDK cannot do, refused rather than approximated:
///
///  * `startAfter` and `endBefore`. The C++ SDK has `StartAt`, `EndAt` and
///    `EqualTo` and no exclusive form. Treating an exclusive bound as an
///    inclusive one returns one extra child and reports nothing wrong.
///  * Persistence and its cache size. There is no on-disk cache to configure.
///
/// Priorities, `keepSynced` and `purgeOutstandingWrites` are bound.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database_platform_interface/firebase_database_platform_interface.dart';
import 'package:firebase_ffi/database.dart' as fdb;

/// Registered by Flutter on Linux via `dartPluginClass`.
class FirebaseDatabaseFfi extends DatabasePlatform {
  FirebaseDatabaseFfi({FirebaseApp? app, String? databaseURL})
    : super(app: app, databaseURL: databaseURL);

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    DatabasePlatform.instance = FirebaseDatabaseFfi();
  }

  // The binding holds one Database per process, created from the app options
  // and an optional URL, so the URL is remembered rather than re-applied.
  static String? _emulatorUrl;

  @override
  DatabasePlatform delegateFor({FirebaseApp? app, String? databaseURL}) =>
      FirebaseDatabaseFfi(app: app, databaseURL: databaseURL ?? _emulatorUrl);

  @override
  DatabaseReferencePlatform ref([String? path]) =>
      FfiDatabaseReference(this, _segments(path ?? '/'));

  @override
  void useDatabaseEmulator(String host, int port) {
    // firebase_core builds the app before this is called, and the binding
    // takes the database URL when it creates the app. Recorded here so a
    // delegate carries it; initDatabase is what actually applies it.
    _emulatorUrl = 'http://$host:$port';
  }

  @override
  Future<void> goOnline() async => fdb.goOnline();

  @override
  Future<void> goOffline() async => fdb.goOffline();

  @override
  void setPersistenceEnabled(bool enabled) {
    if (!enabled) return;
    // Accepted only when it asks for the behavior that is already the case.
    throw UnimplementedError('the desktop SDK has no on-disk cache to enable');
  }

  @override
  void setPersistenceCacheSizeBytes(int cacheSize) {
    throw UnimplementedError('the desktop SDK has no on-disk cache to size');
  }

  @override
  void setLoggingEnabled(bool enabled) {
    // Advisory, and the SDK's logging is set globally at build time. Accepted
    // silently rather than throwing: an app turning logging on should not
    // fail because of it.
  }

  @override
  Future<void> purgeOutstandingWrites() async => fdb.purgeOutstandingWrites();
}

List<String> _segments(String path) =>
    path.split('/').where((s) => s.isNotEmpty).toList();

String _pathOf(List<String> segments) => '/${segments.join('/')}';

/// A query over a location.
class FfiQuery extends QueryPlatform {
  FfiQuery(DatabasePlatform database, this.segments)
    : super(database: database);

  final List<String> segments;

  // QueryPlatform declares this as a getter that throws; the constructor takes
  // no path to satisfy it with.
  @override
  String get path => segments.join('/');

  String get _path => _pathOf(segments);

  // The platform interface hands modifiers in the order they were chained.
  // The SDK needs the ordering applied before any bound, so the spec is built
  // by kind rather than by arrival: a caller that wrote .startAt().orderByKey()
  // means the same query as .orderByKey().startAt().
  fdb.DbQuery _queryFrom(QueryModifiers modifiers) {
    var q = const fdb.DbQuery();
    final maps = modifiers.toList();

    for (final m in maps.where((m) => m['type'] == 'orderBy')) {
      q = switch (m['name']) {
        'orderByChild' => q.orderByChild(m['path']! as String),
        'orderByKey' => q.orderByKey(),
        'orderByValue' => q.orderByValue(),
        'orderByPriority' => q.orderByPriority(),
        _ => throw UnimplementedError('unknown ordering: ${m['name']}'),
      };
    }

    for (final m in maps.where((m) => m['type'] == 'cursor')) {
      final value = m['value'];
      final key = m['key'] as String?;
      q = switch (m['name']) {
        'startAt' => q.startAt(value, key: key),
        'endAt' => q.endAt(value, key: key),
        'equalTo' => q.equalTo(value, key: key),
        // The SDK has no exclusive bound. Shifting to the inclusive one
        // returns one child too many and says nothing about it.
        'startAfter' || 'endBefore' => throw UnimplementedError(
          '${m['name']} has no equivalent in the desktop SDK, which has only '
          'StartAt, EndAt and EqualTo',
        ),
        _ => throw UnimplementedError('unknown cursor: ${m['name']}'),
      };
    }

    for (final m in maps.where((m) => m['type'] == 'limit')) {
      // 'limit', not 'value': LimitModifier names its field differently from
      // the cursor modifiers, and reading the wrong one gives null.
      final n = m['limit']! as int;
      q = switch (m['name']) {
        'limitToFirst' => q.limitToFirst(n),
        'limitToLast' => q.limitToLast(n),
        _ => throw UnimplementedError('unknown limit: ${m['name']}'),
      };
    }
    return q;
  }

  DatabaseReferencePlatform get _ref =>
      FfiDatabaseReference(database, segments);

  @override
  Future<DataSnapshotPlatform> get(QueryModifiers modifiers) async {
    // Modifiers are not applied: the binding's read is a listener that waits
    // for the value to settle, and a query read would need the same over a
    // filtered listener. Refused rather than silently reading the whole node,
    // which would return more than was asked for.
    if (modifiers.toList().isNotEmpty) {
      throw UnimplementedError(
        'get() with query modifiers is not bound; use onValue() with the same '
        'modifiers, which is filtered by the SDK',
      );
    }
    return FfiDataSnapshot(_ref, await fdb.readValue(_path));
  }

  @override
  Stream<DatabaseEventPlatform> observe(
    QueryModifiers modifiers,
    DatabaseEventType eventType,
  ) {
    final q = _queryFrom(modifiers);
    if (eventType == DatabaseEventType.value) {
      return fdb
          .onQueryValue(_path, q)
          .map(
            (s) => FfiDatabaseEvent(
              type: DatabaseEventType.value,
              snapshot: FfiDataSnapshot(_ref, s.value),
              previousChildKey: null,
            ),
          );
    }

    final wanted = switch (eventType) {
      DatabaseEventType.childAdded => fdb.DbChildEvent.added,
      DatabaseEventType.childChanged => fdb.DbChildEvent.changed,
      DatabaseEventType.childMoved => fdb.DbChildEvent.moved,
      DatabaseEventType.childRemoved => fdb.DbChildEvent.removed,
      DatabaseEventType.value => fdb.DbChildEvent.added,
    };

    // One native listener per stream, filtered here. The SDK delivers all four
    // child kinds on one registration, so asking it for four would open four.
    return fdb
        .onChildEvent(_path, q)
        .where((e) => e.event == wanted)
        .map(
          (e) => FfiDatabaseEvent(
            type: eventType,
            snapshot: FfiDataSnapshot(
              FfiDatabaseReference(database, [...segments, e.key]),
              e.value,
            ),
            previousChildKey: e.previousKey,
          ),
        );
  }

  @override
  Future<void> keepSynced(QueryModifiers modifiers, bool value) async {
    fdb.keepSynced(_path, value, _queryFrom(modifiers));
  }
}

/// A location that can be written as well as read.
class FfiDatabaseReference extends FfiQuery
    implements DatabaseReferencePlatform {
  FfiDatabaseReference(super.database, super.segments);

  @override
  String? get key => segments.isEmpty ? null : segments.last;

  @override
  DatabaseReferencePlatform child(String path) =>
      FfiDatabaseReference(database, [...segments, ..._segments(path)]);

  @override
  DatabaseReferencePlatform? get parent => segments.isEmpty
      ? null
      : FfiDatabaseReference(
          database,
          segments.sublist(0, segments.length - 1),
        );

  @override
  DatabaseReferencePlatform root() => FfiDatabaseReference(database, const []);

  @override
  DatabaseReferencePlatform push() => FfiDatabaseReference(database, [
    ...segments,
    fdb.pushChild(_pathOf(segments)),
  ]);

  @override
  Future<void> set(Object? value) => fdb.setValue(_pathOf(segments), value);

  @override
  Future<void> update(Map<String, Object?> value) =>
      fdb.updateChildren(_pathOf(segments), value);

  @override
  Future<void> remove() => fdb.removeValue(_pathOf(segments));

  @override
  Future<void> setWithPriority(Object? value, Object? priority) =>
      fdb.setValueWithPriority(_pathOf(segments), value, priority);

  @override
  Future<void> setPriority(Object? priority) =>
      fdb.setPriority(_pathOf(segments), priority);

  @override
  OnDisconnectPlatform onDisconnect() =>
      FfiOnDisconnect(this, _pathOf(segments));

  @override
  Future<TransactionResultPlatform> runTransaction(
    TransactionHandler transactionHandler, {
    bool applyLocally = true,
  }) async {
    var aborted = false;
    final committed = await fdb.runDbTransaction(_pathOf(segments), (current) {
      final result = transactionHandler(current);
      if (result.aborted) {
        aborted = true;
        return const fdb.DbTransactionResult.abort();
      }
      return fdb.DbTransactionResult.commit(result.value);
    });
    return FfiTransactionResult(
      committed: !aborted,
      snapshot: FfiDataSnapshot(this, committed),
    );
  }
}

/// A snapshot, holding the decoded value.
class FfiDataSnapshot extends DataSnapshotPlatform {
  FfiDataSnapshot(DatabaseReferencePlatform ref, Object? value)
    : super(ref, {'key': ref.key, 'value': value});
}

/// One event on a stream.
class FfiDatabaseEvent extends DatabaseEventPlatform {
  FfiDatabaseEvent({
    required DatabaseEventType type,
    required DataSnapshotPlatform snapshot,
    required String? previousChildKey,
  }) : _snapshot = snapshot,
       super({
         'eventType': eventTypeToString(type),
         'previousChildKey': previousChildKey,
       });

  final DataSnapshotPlatform _snapshot;

  @override
  DataSnapshotPlatform get snapshot => _snapshot;
}

/// What the server should do if this client goes away.
class FfiOnDisconnect extends OnDisconnectPlatform {
  FfiOnDisconnect(DatabaseReferencePlatform ref, this._path)
    : super(database: ref.database, ref: ref);

  final String _path;

  @override
  Future<void> set(Object? value) => fdb.OnDisconnect(_path).setValue(value);

  @override
  Future<void> update(Map<String, Object?> value) =>
      fdb.OnDisconnect(_path).updateChildren(value);

  @override
  Future<void> remove() => fdb.OnDisconnect(_path).remove();

  @override
  Future<void> cancel() => fdb.OnDisconnect(_path).cancel();

  @override
  Future<void> setWithPriority(Object? value, Object? priority) =>
      fdb.OnDisconnect(_path).setValueWithPriority(value, priority);
}

/// The outcome of a transaction.
class FfiTransactionResult extends TransactionResultPlatform {
  FfiTransactionResult({
    required bool committed,
    required DataSnapshotPlatform snapshot,
  }) : _snapshot = snapshot,
       super(committed);

  final DataSnapshotPlatform _snapshot;

  @override
  DataSnapshotPlatform get snapshot => _snapshot;
}
