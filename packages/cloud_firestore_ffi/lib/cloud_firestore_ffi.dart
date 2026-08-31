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

/// cloud_firestore's value types, into the ones the codec carries.
///
/// The two vocabularies describe the same wire types under different names,
/// and the tagged ones are exactly those CBOR has no native representation
/// for -- which is why they have to be translated rather than passed through.
Map<String, Object?> _toFfi(Map<String, dynamic> data) =>
    data.map((k, v) => MapEntry(k, _valueToFfi(v)));

Object? _valueToFfi(Object? v) {
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
