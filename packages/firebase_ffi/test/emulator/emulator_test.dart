// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Exercises the bindings against the Firebase emulator suite.
//
// Everything else in CI builds and links; nothing calls the SDK. That gap is
// not theoretical: Storage crashed on two runs in three from a use-after-free
// in a completion callback, and no amount of building would have found it —
// only calling it does.
//
// Run by scripts/run_emulator_tests.sh, which starts the emulators. Skipped
// when FIREBASE_EMULATOR_HOST is unset, so `dart test` stays useful without
// them.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:test/test.dart';

const _projectId = 'fdb-emulator';

String get _host => Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
int _port(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

void main() {
  if (_host.isEmpty) {
    // Not a failure: the suite is meaningless without a backend, and saying so
    // is better than a green run that tested nothing.
    print('FIREBASE_EMULATOR_HOST unset — emulator tests skipped');
    return;
  }

  final dbPort = _port('FIREBASE_DATABASE_EMULATOR_PORT', 9000);
  final authPort = _port('FIREBASE_AUTH_EMULATOR_PORT', 9099);
  final fsPort = _port('FIREBASE_FIRESTORE_EMULATOR_PORT', 8080);

  setUpAll(() {
    // The database URL is the emulator's, which is all Database needs: the
    // url argument overrides whatever the app options carry.
    initDatabase(
      appId: '1:1:android:1',
      apiKey: 'emulator-does-not-check-this',
      projectId: _projectId,
      databaseUrl: 'http://$_host:$dbPort/?ns=$_projectId',
    );
    initAuth();
    useAuthEmulator(_host, authPort);
    initFirestore();
    useFirestoreEmulator(_host, fsPort);
  });

  test('auth signs in anonymously against the emulator', () async {
    final who = await signInAnonymously();
    expect(who.uid, isNotEmpty);
    expect(currentUid(), who.uid);
  });

  test('database round trips a value', () async {
    final path = '/probe/${DateTime.now().microsecondsSinceEpoch}';
    final seen = <String>[];
    final sub = onValue(path).listen((s) {
      if (s.value != null) seen.add('${s.value}');
    });
    addTearDown(sub.cancel);

    setString(path, 'hello');
    await _until(() => seen.contains('hello'), 'the written value to arrive');
  });

  test('firestore round trips a document, tags intact', () async {
    final path = 'probe/${DateTime.now().microsecondsSinceEpoch}';
    final when = FirestoreTimestamp.fromDateTime(
      DateTime.utc(
        2026,
        8,
        30,
        12,
        0,
        0,
        0,
      ).add(const Duration(microseconds: 1)),
    );
    await setDocument(path, {
      'text': 'hello',
      'count': 42,
      'bytes': Uint8List.fromList([1, 2, 250]),
      'when': when,
      'where': const FirestoreGeoPoint(51.5074, -0.1278),
      'nested': {'deep': true},
    });

    final back = await getDocument(path);
    expect(back, isNotNull);
    expect(back!['text'], 'hello');
    expect(back['count'], 42);
    expect(back['bytes'], isA<Uint8List>());
    expect((back['bytes']! as Uint8List).toList(), [1, 2, 250]);
    expect(back['where'], isA<FirestoreGeoPoint>());
    expect((back['nested']! as Map)['deep'], true);

    // The tag that cannot survive a float64 epoch, which is why timestamps do
    // not travel as RFC 8949 tag 1.
    final t = back['when']! as FirestoreTimestamp;
    expect(t.nanoseconds, when.nanoseconds);

    await deleteDocument(path);
    expect(await getDocument(path), isNull);
  });

  group('queries', () {
    // One collection per run: the emulator keeps state for the process, and a
    // filter matching leftovers from an earlier run would pass for the wrong
    // reason.
    final coll = 'probe_q_${DateTime.now().microsecondsSinceEpoch}';

    setUpAll(() async {
      for (var i = 0; i < 5; i++) {
        await setDocument('$coll/doc$i', {
          'n': i,
          'even': i.isEven,
          'tag': i < 3 ? 'low' : 'high',
        });
      }
    });

    test('reads a whole collection', () async {
      final docs = await queryCollection(coll);
      expect(docs, hasLength(5));
      expect(docs.map((d) => d.id).toSet(), {
        'doc0',
        'doc1',
        'doc2',
        'doc3',
        'doc4',
      });
      // The id and path are why documents come back rather than bodies:
      // without them a result cannot be addressed again.
      expect(docs.first.path, startsWith('$coll/'));
    });

    test('filters with where', () async {
      final low = await queryCollection(
        coll,
        where: const [Where.equalTo('tag', 'low')],
      );
      expect(low.map((d) => d.id).toSet(), {'doc0', 'doc1', 'doc2'});

      final big = await queryCollection(
        coll,
        where: const [Where.greaterThanOrEqualTo('n', 3)],
      );
      expect(big.map((d) => d.id).toSet(), {'doc3', 'doc4'});
    });

    test('orders and limits', () async {
      final desc = await queryCollection(
        coll,
        orderBy: const [OrderBy('n', descending: true)],
        limit: 2,
      );
      expect(desc.map((d) => d.data['n']).toList(), [4, 3]);
    });

    test('combines a filter with an ordering', () async {
      final evens = await queryCollection(
        coll,
        where: const [Where.equalTo('even', true)],
        orderBy: const [OrderBy('n')],
      );
      expect(evens.map((d) => d.data['n']).toList(), [0, 2, 4]);
    });

    test('a query matching nothing is empty, not an error', () async {
      final none = await queryCollection(
        coll,
        where: const [Where.equalTo('tag', 'nonexistent')],
      );
      expect(none, isEmpty);
    });

    test('a field path the SDK rejects does not abort the process', () async {
      // The SDK validates field paths and throws std::invalid_argument. That
      // exception crossing the ABI would kill the process rather than reach
      // Dart, so it is caught and returned as an error code -- and the proof
      // is that the test after this one still runs.
      await expectLater(
        queryCollection(coll, where: const [Where.equalTo('bad/path', 1)]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the isolate survived the rejected field path', () async {
      final docs = await queryCollection(coll);
      expect(docs, hasLength(5));
    });

    test('a watched query reports a document that starts matching', () async {
      final seen = <List<QueryDocument>>[];
      final sub = onQuery(
        coll,
        where: const [Where.equalTo('tag', 'watched')],
      ).listen(seen.add);
      addTearDown(sub.cancel);

      // The first emission is the current state: nothing matches yet.
      await _until(() => seen.isNotEmpty, 'the initial result');
      expect(seen.first, isEmpty);

      await setDocument('$coll/watched1', {'n': 99, 'tag': 'watched'});
      await _until(
        () => seen.any((r) => r.length == 1),
        'the new document to arrive',
      );
      expect(seen.last.single.id, 'watched1');

      // And stops matching when it no longer does.
      await setDocument('$coll/watched1', {'n': 99, 'tag': 'other'});
      await _until(() => seen.last.isEmpty, 'the document to leave the result');
    });

    test('an operator the ABI does not know is refused', () async {
      // Refused rather than dropped: a filter silently ignored would return
      // every document and look like data.
      await expectLater(
        queryCollection(coll, where: const [Where('n', 'approximately', 3)]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test(
    'a document that was never written reads as absent, not empty',
    () async {
      expect(await getDocument('probe/definitely-not-there'), isNull);
    },
  );
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
