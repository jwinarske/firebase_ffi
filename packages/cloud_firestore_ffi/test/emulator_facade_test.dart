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

  test('snapshots() reports a change through cloud_firestore', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_s${DateTime.now().microsecondsSinceEpoch}',
    );
    final seen = <QuerySnapshot<Map<String, dynamic>>>[];
    final sub = coll.snapshots().listen(seen.add);
    addTearDown(sub.cancel);

    // The first emission is the current state, which is empty.
    await _until(() => seen.isNotEmpty, 'the initial snapshot');
    expect(seen.first.docs, isEmpty);

    await coll.doc('a').set({'n': 1});
    await _until(
      () => seen.last.docs.length == 1,
      'the written document to arrive',
    );
    expect(seen.last.docs.single.id, 'a');
    expect(seen.last.docs.single.data()['n'], 1);

    await coll.doc('a').delete();
    await _until(() => seen.last.docs.isEmpty, 'the deletion to arrive');
  });

  test('cursors paginate through cloud_firestore', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_p${DateTime.now().microsecondsSinceEpoch}',
    );
    for (var i = 0; i < 5; i++) {
      await coll.doc('doc$i').set({'n': i});
    }

    final first = await coll.orderBy('n').limit(2).get();
    expect(first.docs.map((d) => d.data()['n']).toList(), [0, 1]);

    // The idiom an app actually writes: page forward from the last document
    // of the page before.
    final second = await coll
        .orderBy('n')
        .startAfter([first.docs.last.data()['n']])
        .limit(2)
        .get();
    expect(second.docs.map((d) => d.data()['n']).toList(), [2, 3]);

    final bounded = await coll.orderBy('n').startAt([1]).endBefore([4]).get();
    expect(bounded.docs.map((d) => d.data()['n']).toList(), [1, 2, 3]);

    for (final d in (await coll.get()).docs) {
      await d.reference.delete();
    }
  });

  test('a transaction runs through cloud_firestore', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe_tx/${DateTime.now().microsecondsSinceEpoch}',
    );
    await ref.set({'n': 1});

    final returned = await FirebaseFirestore.instance.runTransaction((
      tx,
    ) async {
      final snap = await tx.get(ref);
      final next = (snap.data()!['n']! as int) + 1;
      tx.set(ref, {'n': next});
      // The handler's return value reaches the caller, which is what
      // runTransaction is for beyond the atomicity.
      return next;
    });

    expect(returned, 2);
    expect((await ref.get()).data()!['n'], 2);
    await ref.delete();
  });

  test('a transaction that throws changes nothing', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe_tx/${DateTime.now().microsecondsSinceEpoch}_abort',
    );
    await ref.set({'n': 1});

    await expectLater(
      FirebaseFirestore.instance.runTransaction((tx) async {
        tx.set(ref, {'n': 99});
        throw StateError('changed my mind');
      }),
      throwsA(isA<StateError>()),
    );

    expect((await ref.get()).data()!['n'], 1);
    await ref.delete();
  });

  test('a batch commits through cloud_firestore', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_wb${DateTime.now().microsecondsSinceEpoch}',
    );
    final batch = FirebaseFirestore.instance.batch()
      ..set(coll.doc('a'), {'n': 1})
      ..set(coll.doc('b'), {'n': 2});
    await batch.commit();

    final docs = (await coll.get()).docs;
    expect(docs.map((d) => d.id).toSet(), {'a', 'b'});

    final cleanup = FirebaseFirestore.instance.batch();
    for (final d in docs) {
      cleanup.delete(d.reference);
    }
    await cleanup.commit();
    expect((await coll.get()).docs, isEmpty);
  });

  test('a collection group query runs through cloud_firestore', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final id = 'leafg$stamp';
    final fs = FirebaseFirestore.instance;
    await fs.doc('probe_cg$stamp/one/$id/x').set({'n': 1});
    await fs.doc('probe_cg$stamp/two/$id/y').set({'n': 2});

    final group = await fs.collectionGroup(id).get();
    expect(group.docs.map((d) => d.data()['n']).toSet(), {1, 2});

    await fs.doc('probe_cg$stamp/one/$id/x').delete();
    await fs.doc('probe_cg$stamp/two/$id/y').delete();
  });

  test('count() runs through cloud_firestore', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_ct${DateTime.now().microsecondsSinceEpoch}',
    );
    for (var i = 0; i < 3; i++) {
      await coll.doc('doc$i').set({'n': i});
    }

    expect((await coll.count().get()).count, 3);
    expect((await coll.where('n', isGreaterThan: 0).count().get()).count, 2);

    for (final d in (await coll.get()).docs) {
      await d.reference.delete();
    }
  });

  test('FieldValue sentinels reach the server', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe_fv/${DateTime.now().microsecondsSinceEpoch}',
    );
    await ref.set({
      'hits': 1,
      'tags': ['a'],
      'stale': 'remove me',
    });

    await ref.set({
      'hits': FieldValue.increment(41),
      'tags': FieldValue.arrayUnion(['b', 'a']),
      'seen': FieldValue.serverTimestamp(),
      'stale': FieldValue.delete(),
    }, SetOptions(merge: true));

    final data = (await ref.get()).data()!;
    // The server did the arithmetic: two clients incrementing at once both
    // land, which a read-modify-write would not.
    expect(data['hits'], 42);
    expect(data['tags'], ['a', 'b']);
    expect(data['seen'], isA<Timestamp>());
    expect(data.containsKey('stale'), isFalse);

    await ref.set({
      'tags': FieldValue.arrayRemove(['a']),
    }, SetOptions(merge: true));
    expect((await ref.get()).data()!['tags'], ['b']);

    await ref.delete();
  });

  test('update writes named fields and refuses a missing document', () async {
    final ref = FirebaseFirestore.instance.doc(
      'probe_up/${DateTime.now().microsecondsSinceEpoch}',
    );
    await ref.set({'keep': 'me', 'change': 'before'});

    await ref.update({'change': 'after'});
    final data = (await ref.get()).data()!;
    expect(data['keep'], 'me');
    expect(data['change'], 'after');

    // What separates update from set(merge: true).
    await expectLater(
      FirebaseFirestore.instance.doc('probe_up/not-there').update({'n': 1}),
      throwsA(isA<FirebaseException>()),
    );

    await ref.delete();
  });

  test('sum and average are computed by the server', () async {
    final coll = FirebaseFirestore.instance.collection(
      'probe_agg${DateTime.now().microsecondsSinceEpoch}',
    );
    for (var i = 1; i <= 4; i++) {
      await coll.doc('d$i').set({'n': i, 'site': i.isEven ? 'a' : 'b'});
    }

    final all = await coll.aggregate(sum('n'), average('n'), count()).get();
    expect(all.count, 4);
    expect(all.getSum('n'), 10);
    expect(all.getAverage('n'), 2.5);

    final filtered = await coll
        .where('site', isEqualTo: 'a')
        .aggregate(sum('n'))
        .get();
    expect(filtered.getSum('n'), 6);

    for (final d in (await coll.get()).docs) {
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

/// Polls until [ready], rather than sleeping a guessed interval.
Future<void> _until(bool Function() ready, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
