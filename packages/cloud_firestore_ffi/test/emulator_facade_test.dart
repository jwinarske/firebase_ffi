// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// cloud_firestore, unchanged, against the Firestore emulator. Nothing here
// mentions firebase_ffi.
//
// Skipped without FIREBASE_EMULATOR_HOST.
@TestOn('vm')
library;

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_ffi/cloud_firestore_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — Firestore façade tests skipped');
    return;
  }
  final fsPort =
      int.tryParse(
        Platform.environment['FIREBASE_FIRESTORE_EMULATOR_PORT'] ?? '',
      ) ??
      8080;
  final authPort =
      int.tryParse(Platform.environment['FIREBASE_AUTH_EMULATOR_PORT'] ?? '') ??
      9099;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // See firebase_auth_ffi: a test binding reports Android, and firebase_core
    // rewrites emulator hosts on Android. This is the Linux implementation.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    CloudFirestoreFfi.registerWith();
    FirebaseCoreFfi.registerWith();
    FirebaseAuthFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
      ),
    );
    FirebaseFirestore.instance.useFirestoreEmulator(host, fsPort);

    // The emulator's rules require an authenticated caller, as production's
    // do. Signing in here also exercises the thing that put every product in
    // one native library: Auth and Firestore share a firebase::App, so the
    // credential reaches Firestore without being passed to it.
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
    await FirebaseAuth.instance.signInAnonymously();
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('a document round trips through cloud_firestore', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe/${DateTime.now().microsecondsSinceEpoch}',
    );
    await ref.set({'text': 'hello', 'count': 42, 'flag': true});

    final snap = await ref.get();
    expect(snap.exists, isTrue);
    expect(snap.data()!['text'], 'hello');
    expect(snap.data()!['count'], 42);
    expect(snap.id, ref.id);

    await ref.delete();
    expect((await ref.get()).exists, isFalse);
  });

  test('the tagged types survive as cloud_firestore types', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe/${DateTime.now().microsecondsSinceEpoch}',
    );
    final when = Timestamp.fromDate(DateTime.utc(2026, 8, 31, 9, 30));
    await ref.set({
      'when': when,
      'where': const GeoPoint(51.5074, -0.1278),
      'bytes': Blob(Uint8List.fromList([1, 2, 250])),
      'other': FirebaseFirestore.instance.doc('probe/other'),
    });

    final data = (await ref.get()).data()!;
    expect(data['when'], isA<Timestamp>());
    expect((data['when']! as Timestamp).seconds, when.seconds);
    expect(data['where'], isA<GeoPoint>());
    expect((data['where']! as GeoPoint).latitude, closeTo(51.5074, 1e-9));
    // Blob, not List<int>: the two are indistinguishable once collapsed, which
    // is the bug the codec's tags exist to prevent.
    expect(data['bytes'], isA<Blob>());
    expect((data['bytes']! as Blob).bytes, [1, 2, 250]);
    expect(data['other'], isA<DocumentReference>());
    expect((data['other']! as DocumentReference).path, 'probe/other');

    await ref.delete();
  });

  test('a collection query runs through cloud_firestore', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_q${DateTime.now().microsecondsSinceEpoch}',
    );
    for (var i = 0; i < 4; i++) {
      await coll.doc('doc$i').set({'n': i, 'tag': i < 2 ? 'low' : 'high'});
    }

    final all = await coll.get();
    expect(all.docs, hasLength(4));
    expect(all.docs.first.id, isNotEmpty);

    final low = await coll.where('tag', isEqualTo: 'low').get();
    expect(low.docs.map((d) => d.id).toSet(), {'doc0', 'doc1'});

    final top = await coll.orderBy('n', descending: true).limit(2).get();
    expect(top.docs.map((d) => d.data()['n']).toList(), [3, 2]);

    final combined = await coll
        .where('n', isGreaterThanOrEqualTo: 1)
        .orderBy('n')
        .get();
    expect(combined.docs.map((d) => d.data()['n']).toList(), [1, 2, 3]);

    for (final d in all.docs) {
      await d.reference.delete();
    }
  });

  test('collection().doc() addresses a document under it', () async {
    final ref = FirebaseFirestore.instance.collection('probe').doc('named');
    expect(ref.path, 'probe/named');
    // An id is generated when none is given, as it is on every platform.
    expect(
      FirebaseFirestore.instance.collection('probe').doc().id,
      hasLength(20),
    );
  });

  test('a missing document reports absent rather than empty', () async {
    final snap = await FirebaseFirestore.instance.doc('probe/not-there').get();
    expect(snap.exists, isFalse);
    expect(snap.data(), isNull);
  });
}
