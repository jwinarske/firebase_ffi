// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `cloud_firestore` implementation for desktop Linux.
///
/// Documents work: get, set, delete and snapshots, with the value types that
/// need a tag on the wire. Queries do not, and neither do transactions,
/// batches, aggregates or bundles -- the C ABI binds documents only, so those
/// keep the platform interface's own `UnimplementedError`, which names the
/// method rather than failing somewhere further down.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/firestore.dart' as fdb;

/// Registered by Flutter on Linux via `dartPluginClass`.
class CloudFirestoreFfi extends FirebaseFirestorePlatform {
  CloudFirestoreFfi({FirebaseApp? app, String? databaseId})
    : super(appInstance: app, databaseChoice: databaseId);

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseFirestorePlatform.instance = CloudFirestoreFfi();
    // Before an app first touches FieldValue: it captures the factory in a
    // static initializer and never looks again.
    FieldValueFactoryPlatform.instance = FfiFieldValueFactory();
  }

  bool _ready = false;

  /// cloud_firestore has no "initialize" call, so it happens on first use.
  void ensureFirestore() {
    if (_ready) return;
    fdb.initFirestore();
    _ready = true;
  }

  @override
  FirebaseFirestorePlatform delegateFor({
    FirebaseApp? app,
    String? databaseId,
  }) => CloudFirestoreFfi(app: app, databaseId: databaseId);

  @override
  DocumentReferencePlatform doc(String documentPath) =>
      FfiDocumentReference(this, documentPath);

  @override
  CollectionReferencePlatform collection(String collectionPath) =>
      FfiCollectionReference(this, collectionPath);

  @override
  WriteBatchPlatform batch() => FfiWriteBatch(this);

  @override
  QueryPlatform collectionGroup(String collectionPath) =>
      FfiQuery(this, collectionPath, null, isGroup: true);

  @override
  Future<T?> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    ensureFirestore();
    T? result;
    // timeout and maxAttempts are the SDK's own defaults on desktop and are
    // not configurable through the bindings. Accepted rather than refused:
    // an app passing the defaults should not fail because of it.
    await fdb.runTransaction((tx) async {
      // A retry runs this again, so nothing here may depend on the previous
      // attempt -- including `result`, which is overwritten rather than added
      // to.
      result = await transactionHandler(FfiTransaction(this, tx));
    });
    return result;
  }

  Settings _settings = const Settings();

  // cloud_firestore points Firestore at an emulator by writing settings, not
  // by calling useEmulator: FirebaseFirestore.useFirestoreEmulator reads
  // settings, copies it with `host: '<host>:<port>'` and sslEnabled false, and
  // writes it back. So the host override has to be applied from here.
  @override
  Settings get settings => _settings;

  @override
  set settings(Settings settings) {
    _settings = settings;
    final host = settings.host;
    if (host == null) return;
    final i = host.lastIndexOf(':');
    if (i <= 0) {
      throw ArgumentError.value(
        host,
        'settings.host',
        'expected "<host>:<port>"',
      );
    }
    final port = int.tryParse(host.substring(i + 1));
    if (port == null) {
      throw ArgumentError.value(host, 'settings.host', 'port is not a number');
    }
    ensureFirestore();
    fdb.useFirestoreEmulator(host.substring(0, i), port);
  }

  @override
  void useEmulator(String host, int port) {
    ensureFirestore();
    fdb.useFirestoreEmulator(host, port);
  }
}

/// One document.
class FfiDocumentReference extends DocumentReferencePlatform {
  FfiDocumentReference(this.ffiFirestore, String path)
    : super(ffiFirestore, path);

  final CloudFirestoreFfi ffiFirestore;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    ffiFirestore.ensureFirestore();
    await _translate(
      () => fdb.setDocument(path, _toFfi(data), merge: options?.merge ?? false),
      'set',
    );
  }

  @override
  Future<void> update(Map<FieldPath, dynamic> data) async {
    ffiFirestore.ensureFirestore();
    // Keyed by FieldPath, as the batch and the transaction are; the ABI takes
    // the dotted name. The ABI has update only in the batched shape, and one
    // entry is the same write — it fails on a document that is not there,
    // which is what separates it from set(merge: true).
    final batch = fdb.FirestoreBatch()
      ..update(path, {
        for (final e in data.entries)
          e.key.components.join('.'): _valueToFfi(e.value),
      });
    try {
      await batch.commit();
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: 'update: ${e.message}',
      );
    }
  }

  @override
  Future<void> delete() async {
    ffiFirestore.ensureFirestore();
    await _translate(() => fdb.deleteDocument(path), 'delete');
  }

  @override
  Future<DocumentSnapshotPlatform> get([
    GetOptions options = const GetOptions(),
  ]) async {
    ffiFirestore.ensureFirestore();
    final data = await _translate(() => fdb.getDocument(path), 'get');
    return _snapshot(data);
  }

  @override
  Stream<DocumentSnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    required ListenSource listenSource,
  }) {
    ffiFirestore.ensureFirestore();
    return fdb.onDocument(path).map(_snapshot);
  }

  DocumentSnapshotPlatform _snapshot(Map<String, Object?>? data) =>
      DocumentSnapshotPlatform(
        ffiFirestore,
        path,
        data == null ? null : _fromFfi(data),
        // The C++ SDK's desktop listener does not report either flag, and
        // guessing would be worse than reporting the settled case: a caller
        // watching hasPendingWrites to show a pending badge would show it
        // never, rather than at the wrong times.
        InternalSnapshotMetadata(hasPendingWrites: false, isFromCache: false),
      );

  static Future<T> _translate<T>(Future<T> Function() op, String what) async {
    try {
      return await op();
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: '$what: ${e.message}',
      );
    }
  }
}

/// A collection, which is a query over itself.
///
/// Extends the query and only *implements* the collection interface, as the
/// method-channel implementation does. Extending CollectionReferencePlatform
/// instead looks natural and is wrong: its constructor hands QueryPlatform an
/// empty parameter map rather than the seeded defaults, so the plugin's own
/// `where` reads parameters['where'] as null and fails far from the cause.
// ignore: avoid_implementing_value_types
class FfiCollectionReference extends FfiQuery
    implements CollectionReferencePlatform {
  FfiCollectionReference(CloudFirestoreFfi firestore, String path)
    : super(firestore, path, null);

  @override
  String get path => collectionPath;

  @override
  String get id => path.split('/').last;

  @override
  DocumentReferencePlatform? get parent {
    final segments = path.split('/');
    // A root collection has one segment and no parent document; a subcollection
    // is addressed by dropping its own segment.
    if (segments.length < 2) return null;
    return FfiDocumentReference(
      ffiFirestore,
      segments.sublist(0, segments.length - 1).join('/'),
    );
  }

  @override
  DocumentReferencePlatform doc([String? path]) =>
      FfiDocumentReference(ffiFirestore, '${this.path}/${path ?? _autoId()}');

  /// Generated client-side, as every platform does: the id only has to be
  /// unique, not meaningful.
  static String _autoId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return String.fromCharCodes(
      List.generate(20, (_) => chars.codeUnitAt(rand.nextInt(chars.length))),
    );
  }
}

/// A query over one collection.
///
/// Immutable, like the plugin's own: each clause returns a new query rather
/// than mutating this one, so a query held onto and reused does not acquire
/// filters added to a derived query later.
class FfiQuery extends QueryPlatform {
  FfiQuery(
    this.ffiFirestore,
    this.collectionPath,
    Map<String, dynamic>? params, {
    this.isGroup = false,
  }) : super(ffiFirestore, params);

  final CloudFirestoreFfi ffiFirestore;
  final String collectionPath;

  /// Searches every collection with this id, at any depth, rather than one
  /// collection at a path.
  final bool isGroup;

  @override
  bool get isCollectionGroupQuery => isGroup;

  FfiQuery _with(Map<String, dynamic> changes) => FfiQuery(
    ffiFirestore,
    collectionPath,
    {...parameters, ...changes},
    isGroup: isGroup,
  );

  @override
  QueryPlatform where(List<List<dynamic>> conditions) => _with({
    'where': [...((parameters['where'] as List?) ?? const []), ...conditions],
  });

  @override
  QueryPlatform orderBy(Iterable<List<dynamic>> orders) => _with({
    'orderBy': [...((parameters['orderBy'] as List?) ?? const []), ...orders],
  });

  @override
  QueryPlatform startAt(Iterable<dynamic> fields) =>
      _with({'startAt': fields.toList()});

  @override
  QueryPlatform startAfter(Iterable<dynamic> fields) =>
      _with({'startAfter': fields.toList()});

  @override
  QueryPlatform endAt(Iterable<dynamic> fields) =>
      _with({'endAt': fields.toList()});

  @override
  QueryPlatform endBefore(Iterable<dynamic> fields) =>
      _with({'endBefore': fields.toList()});

  @override
  QueryPlatform limit(int limit) => _with({'limit': limit});

  @override
  QueryPlatform limitToLast(int limit) => _with({'limitToLast': limit});

  @override
  Future<QuerySnapshotPlatform> get([
    GetOptions options = const GetOptions(),
  ]) async {
    ffiFirestore.ensureFirestore();

    final List<fdb.QueryDocument> docs;
    try {
      docs = await fdb.queryCollection(
        collectionPath,
        where: whereClauses,
        orderBy: orderClauses,
        limit: parameters['limit'] as int?,
        limitToLast: parameters['limitToLast'] as int?,
        startAt: _cursor('startAt'),
        startAfter: _cursor('startAfter'),
        endAt: _cursor('endAt'),
        endBefore: _cursor('endBefore'),
        collectionGroup: isGroup,
      );
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: 'query: ${e.message}',
      );
    }

    return _toQuerySnapshot(docs);
  }

  /// A cursor's values, translated like any other value: a timestamp or
  /// geopoint page boundary needs the same tagging a stored one does.
  List<Object?>? _cursor(String key) {
    final v = parameters[key];
    if (v is! List || v.isEmpty) return null;
    return [for (final e in v) _valueToFfi(e)];
  }

  List<fdb.Where> get whereClauses => [
    for (final c in ((parameters['where'] as List?) ?? const []))
      if (c is List && c.length == 3)
        fdb.Where(_fieldName(c[0]), _operatorToken(c[1]), _valueToFfi(c[2])),
  ];

  List<fdb.OrderBy> get orderClauses => [
    for (final o in ((parameters['orderBy'] as List?) ?? const []))
      if (o is List && o.length >= 2)
        // [fieldPath, descending] — the plugin's own shape, where element
        // one is the bool it was given.
        fdb.OrderBy(_fieldName(o[0]), descending: o[1] == true),
  ];

  @override
  AggregateQueryPlatform count() =>
      FfiAggregateQuery(this, const [_Aggregate(AggregateType.count)]);

  @override
  AggregateQueryPlatform aggregate(
    AggregateField aggregateField1, [
    AggregateField? aggregateField2,
    AggregateField? aggregateField3,
    AggregateField? aggregateField4,
    AggregateField? aggregateField5,
    AggregateField? aggregateField6,
    AggregateField? aggregateField7,
    AggregateField? aggregateField8,
    AggregateField? aggregateField9,
    AggregateField? aggregateField10,
    AggregateField? aggregateField11,
    AggregateField? aggregateField12,
    AggregateField? aggregateField13,
    AggregateField? aggregateField14,
    AggregateField? aggregateField15,
    AggregateField? aggregateField16,
    AggregateField? aggregateField17,
    AggregateField? aggregateField18,
    AggregateField? aggregateField19,
    AggregateField? aggregateField20,
    AggregateField? aggregateField21,
    AggregateField? aggregateField22,
    AggregateField? aggregateField23,
    AggregateField? aggregateField24,
    AggregateField? aggregateField25,
    AggregateField? aggregateField26,
    AggregateField? aggregateField27,
    AggregateField? aggregateField28,
    AggregateField? aggregateField29,
    AggregateField? aggregateField30,
  ]) {
    // The interface spells this as thirty optional positionals; the server
    // takes them one call each either way.
    final fields = <AggregateField?>[
      aggregateField1,
      aggregateField2,
      aggregateField3,
      aggregateField4,
      aggregateField5,
      aggregateField6,
      aggregateField7,
      aggregateField8,
      aggregateField9,
      aggregateField10,
      aggregateField11,
      aggregateField12,
      aggregateField13,
      aggregateField14,
      aggregateField15,
      aggregateField16,
      aggregateField17,
      aggregateField18,
      aggregateField19,
      aggregateField20,
      aggregateField21,
      aggregateField22,
      aggregateField23,
      aggregateField24,
      aggregateField25,
      aggregateField26,
      aggregateField27,
      aggregateField28,
      aggregateField29,
      aggregateField30,
    ];
    return FfiAggregateQuery(this, [
      for (final field in fields)
        if (field != null) _requestFor(field),
    ]);
  }

  static _Aggregate _requestFor(AggregateField field) => switch (field) {
    (final sum f) => _Aggregate(AggregateType.sum, f.field),
    (final average f) => _Aggregate(AggregateType.average, f.field),
    _ => const _Aggregate(AggregateType.count),
  };

  @override
  Stream<QuerySnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    required ListenSource listenSource,
  }) {
    ffiFirestore.ensureFirestore();
    return fdb
        .onQuery(
          collectionPath,
          where: whereClauses,
          orderBy: orderClauses,
          limit: parameters['limit'] as int?,
          limitToLast: parameters['limitToLast'] as int?,
          startAt: _cursor('startAt'),
          startAfter: _cursor('startAfter'),
          endAt: _cursor('endAt'),
          endBefore: _cursor('endBefore'),
          collectionGroup: isGroup,
        )
        .map(_toQuerySnapshot);
  }

  QuerySnapshotPlatform _toQuerySnapshot(List<fdb.QueryDocument> docs) =>
      QuerySnapshotPlatform(
        [
          for (final d in docs)
            DocumentSnapshotPlatform(
              ffiFirestore,
              d.path,
              _fromFfi(d.data),
              InternalSnapshotMetadata(
                hasPendingWrites: false,
                isFromCache: false,
              ),
            ),
        ],
        // Document changes need the previous result to diff against, which the
        // SDK reports through a listener option this ABI does not bind. An
        // empty list is honest; a fabricated one would drive rebuilds wrongly.
        const [],
        SnapshotMetadataPlatform(false, false),
      );

  /// The plugin converts every field name to a FieldPath before it reaches
  /// here, and a FieldPath's toString() is `FieldPath([tag])` -- which the C++
  /// SDK rejects, from a C++ exception that aborts the process rather than
  /// something Dart can catch. The components joined by dots are what it wants.
  static String _fieldName(Object? field) {
    if (field is FieldPath) return field.components.join('.');
    return '$field';
  }

  /// The plugin spells `orderBy` direction as a bool and `where` operators as
  /// strings; the ABI takes Firestore's own operator spellings.
  static String _operatorToken(Object? op) {
    if (op is String) return op;
    throw UnsupportedError('unsupported query operator: $op');
  }
}

/// The aggregates a query was asked for, computed by the server.
///
/// count, sum and average each return a new query carrying one more request,
/// which is how the plugin builds `coll.aggregate(sum('n'), average('n'))`.
class FfiAggregateQuery extends AggregateQueryPlatform {
  FfiAggregateQuery(this._query, [this._requested = const []]) : super(_query);

  final FfiQuery _query;
  final List<_Aggregate> _requested;

  FfiAggregateQuery _with(_Aggregate extra) =>
      FfiAggregateQuery(_query, [..._requested, extra]);

  @override
  AggregateQueryPlatform count() =>
      _with(const _Aggregate(AggregateType.count));

  @override
  AggregateQueryPlatform sum(String field) =>
      _with(_Aggregate(AggregateType.sum, field));

  @override
  AggregateQueryPlatform average(String field) =>
      _with(_Aggregate(AggregateType.average, field));

  @override
  Future<AggregateQuerySnapshotPlatform> get({
    required AggregateSource source,
  }) async {
    _query.ffiFirestore.ensureFirestore();

    // count() with nothing else asked for is the common case and the one the
    // plugin's own count() takes.
    final wanted = _requested.isEmpty
        ? const [_Aggregate(AggregateType.count)]
        : _requested;

    int? count;
    final sums = <AggregateQueryResponse>[];
    final averages = <AggregateQueryResponse>[];
    try {
      for (final aggregate in wanted) {
        switch (aggregate.type) {
          case AggregateType.count:
            count = await fdb.countCollection(
              _query.collectionPath,
              where: _query.whereClauses,
              orderBy: _query.orderClauses,
              limit: _query.parameters['limit'] as int?,
              limitToLast: _query.parameters['limitToLast'] as int?,
              collectionGroup: _query.isGroup,
            );
          case AggregateType.sum:
            sums.add(
              AggregateQueryResponse(
                type: AggregateType.sum,
                field: aggregate.field,
                value: await fdb.sumCollection(
                  _query.collectionPath,
                  aggregate.field!,
                  where: _query.whereClauses,
                  orderBy: _query.orderClauses,
                  limit: _query.parameters['limit'] as int?,
                  limitToLast: _query.parameters['limitToLast'] as int?,
                  collectionGroup: _query.isGroup,
                ),
              ),
            );
          case AggregateType.average:
            averages.add(
              AggregateQueryResponse(
                type: AggregateType.average,
                field: aggregate.field,
                value: await fdb.averageCollection(
                  _query.collectionPath,
                  aggregate.field!,
                  where: _query.whereClauses,
                  orderBy: _query.orderClauses,
                  limit: _query.parameters['limit'] as int?,
                  limitToLast: _query.parameters['limitToLast'] as int?,
                  collectionGroup: _query.isGroup,
                ),
              ),
            );
        }
      }
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: 'aggregate: ${e.message}',
      );
    }

    return AggregateQuerySnapshotPlatform(
      count: count,
      sum: sums,
      average: averages,
    );
  }
}

/// One requested aggregate. [field] is null only for a count.
class _Aggregate {
  const _Aggregate(this.type, [this.field]);

  final AggregateType type;
  final String? field;
}

/// Builds the sentinels `FieldValue` hands to a write.
///
/// The platform interface's default factory makes objects only its method
/// channel can read. This makes the binding's own, so [_valueToFfi] has
/// nothing to translate — it unwraps and passes them through.
///
/// `FieldValue` captures the factory once, in a static initializer, so this
/// has to be installed by registerWith() before an app first touches it.
class FfiFieldValueFactory extends FieldValueFactoryPlatform {
  @override
  fdb.FirestoreSentinel arrayUnion(List<dynamic> elements) =>
      fdb.FirestoreSentinel.arrayUnion(elements.map(_valueToFfi).toList());

  @override
  fdb.FirestoreSentinel arrayRemove(List<dynamic> elements) =>
      fdb.FirestoreSentinel.arrayRemove(elements.map(_valueToFfi).toList());

  @override
  fdb.FirestoreSentinel delete() => fdb.FirestoreSentinel.delete;

  @override
  fdb.FirestoreSentinel serverTimestamp() =>
      fdb.FirestoreSentinel.serverTimestamp;

  @override
  fdb.FirestoreSentinel increment(num value) =>
      fdb.FirestoreSentinel.increment(value);
}

/// Buffered writes, applied atomically.
class FfiWriteBatch extends WriteBatchPlatform {
  FfiWriteBatch(this._firestore);

  final CloudFirestoreFfi _firestore;
  final fdb.FirestoreBatch _batch = fdb.FirestoreBatch();

  @override
  void set(
    String documentPath,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) {
    _batch.set(documentPath, _toFfi(data), merge: options?.merge ?? false);
  }

  @override
  void update(String documentPath, Map<FieldPath, dynamic> data) {
    // Keyed by FieldPath here, as in a transaction's update.
    _batch.update(documentPath, {
      for (final e in data.entries)
        e.key.components.join('.'): _valueToFfi(e.value),
    });
  }

  @override
  void delete(String documentPath) => _batch.delete(documentPath);

  @override
  Future<void> commit() async {
    _firestore.ensureFirestore();
    try {
      await _batch.commit();
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: 'batch commit: ${e.message}',
      );
    }
  }
}

/// A transaction handle.
///
/// Reads reach the backend through the SDK's transaction; writes are recorded
/// and applied together when the handler returns.
class FfiTransaction extends TransactionPlatform {
  FfiTransaction(this._firestore, this._tx);

  final CloudFirestoreFfi _firestore;
  final fdb.FirestoreTransaction _tx;

  @override
  Future<DocumentSnapshotPlatform> get(String documentPath) async {
    final Map<String, Object?>? data;
    try {
      data = await _tx.get(documentPath);
    } on fdb.FirestoreException catch (e) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: '${e.code}',
        message: 'transaction get: ${e.message}',
      );
    }
    return DocumentSnapshotPlatform(
      _firestore,
      documentPath,
      data == null ? null : _fromFfi(data),
      InternalSnapshotMetadata(hasPendingWrites: false, isFromCache: false),
    );
  }

  @override
  TransactionPlatform set(
    String documentPath,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) {
    _tx.set(documentPath, _toFfi(data), merge: options?.merge ?? false);
    return this;
  }

  @override
  TransactionPlatform update(
    String documentPath,
    Map<FieldPath, dynamic> data,
  ) {
    // The plugin keys updates by FieldPath; the ABI takes the dotted name, as
    // it does for query fields.
    _tx.update(documentPath, {
      for (final e in data.entries)
        e.key.components.join('.'): _valueToFfi(e.value),
    });
    return this;
  }

  @override
  TransactionPlatform delete(String documentPath) {
    _tx.delete(documentPath);
    return this;
  }
}

/// cloud_firestore's value types, into the ones the codec carries.
///
/// The two vocabularies describe the same wire types under different names,
/// and the tagged ones are exactly those CBOR has no native representation
/// for -- which is why they have to be translated rather than passed through.
Map<String, Object?> _toFfi(Map<String, dynamic> data) =>
    data.map((k, v) => MapEntry(k, _valueToFfi(v)));

Object? _valueToFfi(Object? v) {
  // FieldValue.increment and the rest. The delegate is already the binding's
  // sentinel, because FfiFieldValueFactory built it.
  if (v is FieldValuePlatform) {
    return FieldValuePlatform.getDelegate(v);
  }
  if (v is Timestamp) {
    return fdb.FirestoreTimestamp(v.seconds, v.nanoseconds);
  }
  if (v is GeoPoint) {
    return fdb.FirestoreGeoPoint(v.latitude, v.longitude);
  }
  if (v is DocumentReferencePlatform) {
    return fdb.FirestoreReference(v.path);
  }
  if (v is Blob) return Uint8List.fromList(v.bytes);
  if (v is List) return v.map(_valueToFfi).toList();
  if (v is Map) {
    return v.map((k, e) => MapEntry('$k', _valueToFfi(e)));
  }
  return v;
}

Map<String, dynamic> _fromFfi(Map<String, Object?> data) =>
    data.map((k, v) => MapEntry(k, _valueFromFfi(v)));

Object? _valueFromFfi(Object? v) {
  if (v is fdb.FirestoreTimestamp) {
    return Timestamp(v.seconds, v.nanoseconds);
  }
  if (v is fdb.FirestoreGeoPoint) {
    return GeoPoint(v.latitude, v.longitude);
  }
  if (v is fdb.FirestoreReference) {
    return FirebaseFirestorePlatform.instance.doc(v.path);
  }
  // Before the List check: a Uint8List is a List<int>, and Firestore's own
  // type for bytes is Blob. Getting this order wrong turns every blob into a
  // list of small integers -- the same collapse the codec tags exist to stop.
  if (v is Uint8List) return Blob(v);
  if (v is List) return v.map(_valueFromFfi).toList();
  if (v is Map) {
    return v.map((k, e) => MapEntry('$k', _valueFromFfi(e)));
  }
  return v;
}
