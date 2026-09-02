// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// firebase_database, unchanged, against the Database emulator. Nothing here
// mentions firebase_ffi.
//
// Skipped without FIREBASE_EMULATOR_HOST.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database_ffi/firebase_database_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — Database façade tests skipped');
    return;
  }
  final dbPort =
      int.tryParse(
        Platform.environment['FIREBASE_DATABASE_EMULATOR_PORT'] ?? '',
      ) ??
      9000;
  final authPort =
      int.tryParse(Platform.environment['FIREBASE_AUTH_EMULATOR_PORT'] ?? '') ??
      9099;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    FirebaseAuthFfi.registerWith();
    FirebaseDatabaseFfi.registerWith();

    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
        databaseURL: 'http://$host:$dbPort/?ns=$_projectId',
      ),
    );

    // The rules require an authenticated caller, as production's do. Signing
    // in also exercises what put every product in one native library: Auth
    // and Database share a firebase::App, so the credential reaches Database
    // without being passed to it.
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
    await FirebaseAuth.instance.signInAnonymously();
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  String probe() => 'probe/f${DateTime.now().microsecondsSinceEpoch}';

  test('a value round trips through firebase_database', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({'text': 'hello', 'n': 42, 'ratio': 1.5});

    final snap = await ref.get();
    expect(snap.exists, isTrue);
    final v = snap.value! as Map;
    expect(v['text'], 'hello');
    expect(v['n'], 42);
    expect(v['ratio'], closeTo(1.5, 1e-9));
  });

  test('update leaves the children it does not name', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({'keep': 'me', 'change': 'before'});
    await ref.update({'change': 'after'});

    final v = (await ref.get()).value! as Map;
    expect(v['keep'], 'me');
    expect(v['change'], 'after');
  });

  test('push makes a child with its own key', () async {
    final parent = FirebaseDatabase.instance.ref(probe());
    final child = parent.push();
    expect(child.key, isNotEmpty);

    await child.set('pushed');
    final v = (await parent.get()).value! as Map;
    expect(v[child.key], 'pushed');
  });

  test('remove clears the value', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set('here');
    await ref.remove();
    expect((await ref.get()).exists, isFalse);
  });

  test('an ordered limit takes from the right end', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({
      'ana': {'score': 30},
      'bo': {'score': 10},
      'cy': {'score': 20},
    });

    final low = await ref.orderByChild('score').limitToFirst(1).once();
    final high = await ref.orderByChild('score').limitToLast(1).once();

    // If the ordering were dropped these would be the same node.
    expect((low.snapshot.value! as Map).keys.single, 'bo');
    expect((high.snapshot.value! as Map).keys.single, 'ana');
  });

  test('child events arrive with their neighbour', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({
      'ana': {'score': 30},
      'bo': {'score': 10},
      'cy': {'score': 20},
    });

    final events = <DatabaseEvent>[];
    final sub = ref.orderByChild('score').onChildAdded.listen(events.add);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (events.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await sub.cancel();

    expect(events.map((e) => e.snapshot.key).toList(), ['bo', 'cy', 'ana']);
    expect(events.first.previousChildKey, isNull);
    expect(events[1].previousChildKey, 'bo');
  });

  test('a transaction commits from the current value', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set(7);

    final result = await ref.runTransaction(
      (current) => Transaction.success(((current as int?) ?? 0) + 1),
    );
    expect(result.committed, isTrue);
    expect(result.snapshot.value, 8);
  });

  test('an aborted transaction leaves the value alone', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set('untouched');

    final result = await ref.runTransaction((_) => Transaction.abort());
    expect(result.committed, isFalse);
    expect((await ref.get()).value, 'untouched');
  });

  test('a priority orders siblings through firebase_database', () async {
    final root = FirebaseDatabase.instance.ref(probe());
    await root.child('second').setWithPriority({'x': 1}, 20);
    await root.child('first').setWithPriority({'x': 1}, 10);
    await root.child('third').setWithPriority({'x': 1}, 30);

    final events = <DatabaseEvent>[];
    final sub = root.orderByPriority().onChildAdded.listen(events.add);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (events.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await sub.cancel();

    // Written out of order on purpose: the priority decides, not insertion.
    expect(events.map((e) => e.snapshot.key).toList(), [
      'first',
      'second',
      'third',
    ]);
  });

  test('setPriority reorders without rewriting the value', () async {
    final root = FirebaseDatabase.instance.ref(probe());
    await root.child('a').setWithPriority('value-a', 10);
    await root.child('b').setWithPriority('value-b', 20);
    await root.child('a').setPriority(30);

    final events = <DatabaseEvent>[];
    final sub = root.orderByPriority().onChildAdded.listen(events.add);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (events.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await sub.cancel();

    expect(events.map((e) => e.snapshot.key).toList(), ['b', 'a']);
    expect((await root.child('a').get()).value, 'value-a');
  });

  test('keepSynced and purgeOutstandingWrites are accepted', () async {
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({'a': 1});
    await expectLater(ref.keepSynced(true), completes);
    await expectLater(ref.orderByKey().keepSynced(true), completes);
    await expectLater(ref.keepSynced(false), completes);
    await expectLater(
      FirebaseDatabase.instance.purgeOutstandingWrites(),
      completes,
    );
  });

  test('an exclusive bound is refused rather than widened', () async {
    // startAfter has no equivalent in the desktop SDK. Treating it as startAt
    // would return one child too many and report nothing wrong.
    final ref = FirebaseDatabase.instance.ref(probe());
    await ref.set({'a': 1, 'b': 2});

    await expectLater(
      ref.orderByKey().startAfter('a').once(),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
