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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:firebase_ffi/functions.dart';
import 'package:firebase_ffi/remote_config.dart';
import 'package:firebase_ffi/storage.dart';
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
  final fnPort =
      int.tryParse(
        Platform.environment['FIREBASE_FUNCTIONS_EMULATOR_PORT'] ?? '',
      ) ??
      5001;
  final fsPort = _port('FIREBASE_FIRESTORE_EMULATOR_PORT', 8080);
  final stPort = _port('FIREBASE_STORAGE_EMULATOR_PORT', 9199);

  setUpAll(() {
    // The database URL is the emulator's, which is all Database needs: the
    // url argument overrides whatever the app options carry.
    initDatabase(
      appId: '1:1:android:1',
      apiKey: 'emulator-does-not-check-this',
      projectId: _projectId,
      databaseUrl: 'http://$_host:$dbPort/?ns=$_projectId',
      // Storage has no url argument to override this with: the bucket comes
      // from the app options, and an empty one builds a URL with no bucket in
      // it, which the emulator answers slowly and unhelpfully rather than
      // rejecting.
      storageBucket: '$_projectId.appspot.com',
    );
    initAuth();
    useAuthEmulator(_host, authPort);
    // Only what this build bound. The suite is run against several product
    // selections, and initializing a product that was not compiled in fails
    // at symbol resolution rather than saying so.
    if (hasFirestore) {
      initFirestore();
      useFirestoreEmulator(_host, fsPort);
    }
    if (hasStorage) {
      initStorage();
      useStorageEmulator(_host, stPort);
    }
  });

  test('auth signs in anonymously against the emulator', () async {
    final who = await signInAnonymously();
    expect(who.uid, isNotEmpty);
    expect(currentUid(), who.uid);
  });

  group('database values', () {
    setUpAll(() async => signInAnonymously());

    String probe() => '/probe/${DateTime.now().microsecondsSinceEpoch}';

    // Reads go through a listener rather than a one-shot get. The desktop
    // SDK's GetValue is a single-shot listener that completes on the first
    // event, and for a path with nothing cached that event is the empty local
    // state -- it answers null for data that is on the server. A listener
    // receives the server's value on its second event, which is what this
    // waits for.
    Future<Object?> readBack(String path) async {
      final completer = Completer<Object?>();
      late StreamSubscription<DbSnapshot> sub;
      sub = onValue(path).listen((s) {
        if (s.value != null && !completer.isCompleted)
          completer.complete(s.value);
      });
      try {
        return await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        await sub.cancel();
      }
    }

    test('a map round trips with its types intact', () async {
      final path = probe();
      await setValue(path, {
        'text': 'hello',
        'n': 42,
        'ratio': 1.5,
        'flag': true,
        'nested': {'deep': 'yes'},
        'list': [1, 2, 3],
      });

      final back = (await readBack(path))! as Map;
      expect(back['text'], 'hello');
      expect(back['n'], 42);
      expect(back['ratio'], closeTo(1.5, 1e-9));
      expect(back['flag'], true);
      expect((back['nested'] as Map)['deep'], 'yes');
      expect(back['list'], [1, 2, 3]);
    });

    test('update writes named children and leaves the rest', () async {
      final path = probe();
      await setValue(path, {'keep': 'me', 'change': 'before'});
      await updateChildren(path, {'change': 'after'});

      final back = (await readBack(path))! as Map;
      // The distinction the call exists for: set with a partial map would have
      // deleted 'keep'.
      expect(back['keep'], 'me');
      expect(back['change'], 'after');
    });

    test('remove deletes what was there', () async {
      final path = probe();
      await setValue(path, 'here');
      expect(await readBack(path), 'here');

      await removeValue(path);
      final seen = <Object?>[];
      final sub = onValue(path).listen((s) => seen.add(s.value));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      expect(seen.last, isNull);
    });

    test('push generates a distinct key without a request', () async {
      final path = probe();
      final a = pushChild(path);
      final b = pushChild(path);
      expect(a, isNotEmpty);
      expect(a, isNot(b));

      await setValue('$path/$a', 'first');
      final back = (await readBack(path))! as Map;
      expect(back[a], 'first');
    });
  });

  group('database reads', () {
    setUpAll(() async => signInAnonymously());

    test('a written value reads back', () async {
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, {'a': 1, 'b': 'two'});

      final back = (await readValue(path))! as Map;
      expect(back['a'], 1);
      expect(back['b'], 'two');
    });

    test('a path that was never written reads as null', () async {
      // The case the SDK's own GetValue gets right by accident and gets wrong
      // for everything else: here it has to be null because it is empty, not
      // because the read gave up.
      expect(await readValue('/probe/never-written-at-all'), isNull);
    });

    test('a second read of a cached path still returns the value', () async {
      // A cached path delivers one event, not two. Counting events would read
      // null here while the value was sitting in front of it.
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'cached');

      expect(await readValue(path), 'cached');
      expect(await readValue(path), 'cached');
    });

    test('a removed value reads as null again', () async {
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'here');
      expect(await readValue(path), 'here');

      await removeValue(path);
      expect(await readValue(path), isNull);
    });
  });

  group('database queries', () {
    setUpAll(() async => signInAnonymously());

    // A node of scores, written once and queried several ways.
    late String root;
    setUpAll(() async {
      root = '/probe/q${DateTime.now().microsecondsSinceEpoch}';
      await setValue(root, {
        'ana': {'score': 30},
        'bo': {'score': 10},
        'cy': {'score': 20},
      });
    });

    Future<Object?> firstValue(Stream<DbSnapshot> s) async {
      final completer = Completer<Object?>();
      late StreamSubscription<DbSnapshot> sub;
      sub = s.listen((e) {
        if (e.value != null && !completer.isCompleted)
          completer.complete(e.value);
      });
      try {
        return await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        await sub.cancel();
      }
    }

    test('a limit returns fewer children than the node holds', () async {
      final v = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToFirst(2),
        ),
      );
      expect((v! as Map).length, 2);
    });

    test('an ordered limit takes from the right end', () async {
      final low = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToFirst(1),
        ),
      );
      final high = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToLast(1),
        ),
      );
      // Ordering by score: bo is 10, ana is 30. If the ordering were dropped
      // the two would come back the same, which is the failure a weaker query
      // produces and does not report.
      expect((low! as Map).keys.single, 'bo');
      expect((high! as Map).keys.single, 'ana');
    });

    test('a bound excludes what falls outside it', () async {
      final v = await firstValue(
        onQueryValue(root, const DbQuery().orderByChild('score').startAt(20)),
      );
      final keys = (v! as Map).keys.toSet();
      expect(keys, containsAll(<String>['cy', 'ana']));
      expect(keys, isNot(contains('bo')));
    });

    test('a spec this ABI cannot apply is refused, not weakened', () async {
      // Both limits at once: the SDK keeps whichever was applied last rather
      // than reporting the conflict, so it is refused here. Running it would
      // return a different set than was asked for and say nothing.
      await expectLater(
        onQueryValue(
          root,
          const DbQuery().orderByKey().limitToFirst(1).limitToLast(1),
        ).first,
        throwsA(isA<ArgumentError>()),
      );
    });

    test('equalTo with a bound is refused', () async {
      await expectLater(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').equalTo(10).startAt(5),
        ).first,
        throwsA(isA<ArgumentError>()),
      );
    });

    test('child events name the child and its neighbour', () async {
      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(
        root,
        const DbQuery().orderByChild('score'),
      ).listen(events.add);
      await _until(
        () => events.length >= 3,
        'the three existing children to arrive',
      );
      await sub.cancel();

      expect(events.every((e) => e.event == DbChildEvent.added), isTrue);
      // In score order: bo 10, cy 20, ana 30. The first has no predecessor,
      // and each later one names the child before it -- which is what lets a
      // caller keep an ordered list without re-reading the node.
      expect(events.map((e) => e.key).toList(), ['bo', 'cy', 'ana']);
      expect(events.first.previousKey, isNull);
      expect(events[1].previousKey, 'bo');
      expect(events[2].previousKey, 'cy');
    });

    test('a removal arrives as its own event', () async {
      final path = '/probe/r${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, {'gone': 'soon'});

      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(path).listen(events.add);
      await _until(() => events.isNotEmpty, 'the child to be seen');

      await removeValue('$path/gone');
      await _until(
        () => events.any((e) => e.event == DbChildEvent.removed),
        'the removal',
      );
      await sub.cancel();

      // A value listener cannot report this: once the node is gone it reports
      // null and says nothing about which child left.
      final removed = events.firstWhere((e) => e.event == DbChildEvent.removed);
      expect(removed.key, 'gone');
    });
  });

  group('database transactions', () {
    setUpAll(() async => signInAnonymously());

    test('a counter increments from its current value', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 7);

      final seen = <Object?>[];
      final committed = await runDbTransaction(path, (current) {
        seen.add(current);
        // The first attempt often sees null: the SDK runs the handler against
        // local state before the server's value arrives, then runs it again.
        final n = (current as int?) ?? 0;
        return DbTransactionResult.commit(n + 1);
      });

      expect(committed, 8);
      // Whatever the attempts saw, the last one had to see the real value or
      // the commit could not be 8.
      expect(seen, isNotEmpty);
    });

    test('a handler may run more than once and must not accumulate', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 1);

      var calls = 0;
      final committed = await runDbTransaction(path, (current) {
        calls++;
        // Derived from `current` alone, never from a running total. A handler
        // that accumulated would give a different answer per retry count.
        return DbTransactionResult.commit(((current as int?) ?? 0) * 10);
      });

      expect(committed, 10);
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('aborting leaves the value alone', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'untouched');

      final result = await runDbTransaction(
        path,
        (_) => const DbTransactionResult.abort(),
      );
      expect(result, isNull);

      final seen = <Object?>[];
      final sub = onValue(path).listen((s) => seen.add(s.value));
      await _until(
        () => seen.any((v) => v == 'untouched'),
        'the untouched value',
      );
      await sub.cancel();
    });

    test('a handler that throws aborts rather than hanging', () async {
      // The SDK's thread is parked until the handler answers, so a throw that
      // did not answer would leave the transaction outstanding forever.
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'safe');

      final result = await runDbTransaction(path, (_) {
        throw StateError('handler blew up');
      }).timeout(const Duration(seconds: 15));
      expect(result, isNull);
    });
  });

  group('database onDisconnect', () {
    setUpAll(() async => signInAnonymously());

    // The value a listener has settled on, rather than a particular event.
    //
    // Counting events does not work here: the desktop SDK sends local state
    // first and the server's answer second, but only when the two differ, so
    // a test that skipped the first and waited for a second timed out on a
    // slower machine and read null for a value that was there. Taking the
    // last value in a window is true whether one event arrives or three.
    Future<Object?> settledValue(
      String path, {
      Duration window = const Duration(seconds: 3),
    }) async {
      Object? last;
      final sub = onValue(path).listen((s) => last = s.value);
      await Future<void>.delayed(window);
      await sub.cancel();
      return last;
    }

    // Waits for the value to become what is expected, so the common case is
    // fast and a slow one still passes.
    Future<Object?> valueBecomes(String path, Object? expected) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Object? seen;
      while (DateTime.now().isBefore(deadline)) {
        seen = await settledValue(
          path,
          window: const Duration(milliseconds: 750),
        );
        if (seen == expected) return seen;
      }
      return seen;
    }

    test('a registration completes', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await expectLater(OnDisconnect(path).setValue('gone'), completes);
      await OnDisconnect(path).cancel();
    });

    test('the server runs it when the connection drops', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'present');
      expect(await valueBecomes(path, 'present'), 'present');

      // The point of the whole feature: this is the cleanup that happens when
      // a device loses power, where nothing on the device gets to run.
      await OnDisconnect(path).remove();
      goOffline();
      goOnline();

      expect(
        await valueBecomes(path, null),
        isNull,
        reason: 'the server never ran the handler',
      );
    });

    test('a cancelled registration does not run', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'stays');
      expect(await valueBecomes(path, 'stays'), 'stays');

      await OnDisconnect(path).remove();
      await OnDisconnect(path).cancel();
      goOffline();
      goOnline();

      // Settled over a window rather than checked immediately: an instant
      // check would pass even if cancel did nothing, because the server would
      // not have run the handler yet.
      expect(
        await settledValue(path, window: const Duration(seconds: 5)),
        'stays',
      );
    });
  });

  group('storage', skip: hasStorage ? null : 'Storage not bound', () {
    // The rules require an authenticated caller, so a binding that loses the
    // credential fails here rather than passing against an open emulator.
    setUpAll(() async => signInAnonymously());

    String probe() => 'probe/${DateTime.now().microsecondsSinceEpoch}';

    test('an object round trips its bytes', () async {
      final path = probe();
      final payload = Uint8List.fromList(List.generate(2048, (i) => i & 0xff));

      final meta = await putObject(
        path,
        payload,
        contentType: 'application/x-test',
      );
      expect(meta.sizeBytes, payload.length);
      expect(meta.contentType, 'application/x-test');

      final back = await getObject(path);
      expect(back, payload);
    });

    test('an empty object is not an error', () async {
      // Zero-length is the case a length-prefixed transport gets wrong, and it
      // is indistinguishable from a failed read unless it is checked.
      final path = probe();
      await putObject(path, Uint8List(0));
      expect(await getObject(path), isEmpty);
    });

    test('metadata comes back for an object that exists', () async {
      final path = probe();
      await putObject(
        path,
        Uint8List.fromList([1, 2, 3]),
        contentType: 'text/plain',
      );

      final meta = await objectMetadata(path);
      expect(meta.sizeBytes, 3);
      expect(meta.contentType, 'text/plain');
      expect(meta.path, contains('probe/'));
    });

    test('a deleted object is gone', () async {
      final path = probe();
      await putObject(path, Uint8List.fromList([7]));
      await deleteObject(path);

      await expectLater(getObject(path), throwsA(isA<StorageException>()));
    });

    test('reading an object that was never written fails', () async {
      await expectLater(
        getObject('probe/never-written'),
        throwsA(isA<StorageException>()),
      );
    });

    test('a large object survives the round trip', () async {
      // Past the point where the transfer is a single buffer, which is where
      // the use-after-free in a completion callback lived.
      final path = probe();
      final payload = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => (i * 31) & 0xff),
      );
      await putObject(path, payload);
      expect(await getObject(path), payload);
    });
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

  test(
    'firestore round trips a document, tags intact',
    skip: hasFirestore ? null : 'Firestore not bound',
    () async {
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
    },
  );

  group('queries', skip: hasFirestore ? null : 'Firestore not bound', () {
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

      // Removed rather than left behind: this collection is shared with the
      // other tests in the group, and a stray document changes what they see.
      // It did — the cursor test counted this one as a fourth row.
      await deleteDocument('$coll/watched1');
    });

    test('cursors page through an ordered result', () async {
      const order = [OrderBy('n')];

      final firstPage = await queryCollection(coll, orderBy: order, limit: 2);
      expect(firstPage.map((d) => d.data['n']).toList(), [0, 1]);

      // startAfter takes the last value of the page before it — which is why
      // the ordering has to be carried along with the cursor.
      final secondPage = await queryCollection(
        coll,
        orderBy: order,
        limit: 2,
        startAfter: [firstPage.last.data['n']],
      );
      expect(secondPage.map((d) => d.data['n']).toList(), [2, 3]);

      // Inclusive and exclusive bounds differ by exactly the boundary row.
      final fromTwo = await queryCollection(coll, orderBy: order, startAt: [2]);
      expect(fromTwo.map((d) => d.data['n']).toList(), [2, 3, 4]);

      final upToTwo = await queryCollection(
        coll,
        orderBy: order,
        endBefore: [2],
      );
      expect(upToTwo.map((d) => d.data['n']).toList(), [0, 1]);
    });

    test('a cursor without an ordering is refused, not ignored', () async {
      // Firestore requires one cursor value per orderBy clause. Without an
      // ordering there is nothing for the value to mean, and running the query
      // anyway would return the whole collection as though the cursor applied.
      await expectLater(
        queryCollection(coll, startAt: [2]),
        throwsA(isA<ArgumentError>()),
      );
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

  group(
    'remote config',
    skip: hasRemoteConfig ? null : 'Remote Config not bound',
    () {
      // Defaults are client-side, so this needs no backend — which is the only
      // reason Remote Config can be tested here at all. The emulator suite has
      // no Remote Config, and a fetch needs a real project.
      setUpAll(() async => initRemoteConfig());

      test('defaults come back with their types intact', () async {
        await setConfigDefaults({
          'greeting': 'hello',
          'retries': 3,
          'ratio': 1.5,
          'enabled': true,
        });

        final values = await configValues();
        expect(values['greeting'], 'hello');
        expect(values['retries'], 3);
        expect(values['ratio'], closeTo(1.5, 1e-9));
        expect(values['enabled'], true);
        // The point of reading a map rather than typed getters: a string does
        // not silently become 0 because something asked for a long.
        expect(values['greeting'], isA<String>());
        expect(values['retries'], isA<int>());
      });

      test('a key with no default is absent, not empty', () async {
        final values = await configValues();
        expect(values.containsKey('never-set'), isFalse);
      });
    },
  );

  group(
    'remote config settings and info',
    skip: hasRemoteConfig ? null : 'Remote Config not bound',
    () {
      setUpAll(() async => initRemoteConfig());

      test('settings round trip', () async {
        await setConfigSettings(
          const RemoteConfigSettings(
            fetchTimeout: Duration(seconds: 17),
            minimumFetchInterval: Duration(minutes: 3),
          ),
        );
        final s = configSettings();
        expect(s.fetchTimeout, const Duration(seconds: 17));
        expect(s.minimumFetchInterval, const Duration(minutes: 3));
      });

      test('nothing fetched yet is not reported as a successful fetch', () {
        // The SDK reports success with a zero fetch time before anything has
        // been fetched. Passing that through as success would tell a caller a
        // fetch worked when none happened.
        final info = configInfo();
        expect(info.lastFetchStatus, RemoteConfigFetchStatus.noFetchYet);
        expect(info.lastFetchTime.millisecondsSinceEpoch, 0);
      });

      test('a default reports itself as a default, not as fetched', () async {
        // The SDK orders ValueSource static, remote, default; the Dart enum
        // orders it static, default, remote. Reading it through the index
        // would report every default as a fetched value -- which is exactly
        // the question this getter exists to answer.
        await setConfigDefaults({'origin_probe': 'local'});
        expect(
          configValueSource('origin_probe'),
          RemoteConfigValueSource.defaultValue,
        );
        expect(
          configValueSource('never_set_anywhere'),
          RemoteConfigValueSource.static,
        );
      });

      test(
        'activating with nothing fetched answers false, not an error',
        () async {
          // There is no Remote Config emulator, so a fetch cannot be exercised
          // here. Activate can: with nothing fetched it must report that there
          // was nothing new rather than fail.
          expect(await activateConfig(), isFalse);
        },
      );
    },
  );

  group('functions', skip: hasFunctions ? null : 'Functions not bound', () {
    setUpAll(() {
      initFunctions();
      // The SDK takes a whole origin here, not a host and port.
      useFunctionsEmulator('http://$_host:$fnPort');
    });

    test('a callable round trips its argument', () async {
      final result = await callFunction('echo', {
        'text': 'hello',
        'n': 42,
        // A double, because the encoder picks the narrowest float that holds
        // the value and the decoder has to read that width back. 1.5 fits in a
        // half, and reading it as a double gave 0.0.
        'ratio': 1.5,
        'nested': {'deep': true},
        'list': [1, 2, 3],
      });
      final received = (result! as Map)['received']! as Map;
      expect(received['text'], 'hello');
      expect(received['n'], 42);
      expect(received['ratio'], closeTo(1.5, 1e-9));
      expect((received['nested']! as Map)['deep'], true);
      expect(received['list'], [1, 2, 3]);
    });

    test('a numeric result comes back as a number', () async {
      expect(await callFunction('add', {'a': 2, 'b': 3}), 5);
    });

    test('a callable that throws carries its reason', () async {
      await expectLater(
        callFunction('boom'),
        throwsA(
          isA<FunctionsException>().having(
            (e) => e.message,
            'message',
            contains('deliberate failure'),
          ),
        ),
      );
    });
  });

  group(
    'firestore float widths',
    skip: hasFirestore ? null : 'Firestore not bound',
    () {
      test('a double survives the round trip whatever its width', () async {
        // The encoder writes the narrowest float that holds a value exactly,
        // so these go out as halves and singles rather than doubles. Reading
        // them back with cbor_value_get_double stored 1.5 as 5.14e-315 --
        // a document that looked written and was not.
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/a';
        await setDocument(path, {
          'half': 1.5,
          'negative': -0.25,
          'single': 0.1,
          'big': 1.7976931348623157e308,
          'whole': 3.0,
        });

        final doc = (await getDocument(path))!;
        expect(doc['half'], closeTo(1.5, 1e-12));
        expect(doc['negative'], closeTo(-0.25, 1e-12));
        expect(doc['single'], closeTo(0.1, 1e-12));
        expect(doc['big'], closeTo(1.7976931348623157e308, 1e295));
        // 3.0 is whole, so the encoder writes it as an integer and Firestore
        // stores an integer. Worth pinning: it is the one case where a double
        // does not come back as one.
        expect((doc['whole']! as num).toDouble(), closeTo(3.0, 1e-12));
      });

      test('a geopoint keeps its coordinates', () async {
        // Latitude and longitude are read through the same call the values
        // above were, and are just as narrow: 51.5 is a half.
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/geo';
        await setDocument(path, {
          'where': const FirestoreGeoPoint(51.5, -0.125),
        });

        final g = (await getDocument(path))!['where']! as FirestoreGeoPoint;
        expect(g.latitude, closeTo(51.5, 1e-12));
        expect(g.longitude, closeTo(-0.125, 1e-12));
      });

      test('a double increment adds what it was given', () async {
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/inc';
        await setDocument(path, {'n': 1.5});
        await setDocument(path, {
          'n': FirestoreSentinel.increment(0.25),
        }, merge: true);

        expect((await getDocument(path))!['n'], closeTo(1.75, 1e-12));
      });
    },
  );
  group('aggregates', skip: hasFirestore ? null : 'Firestore not bound', () {
    late String col;

    setUpAll(() async {
      col = 'agg${DateTime.now().microsecondsSinceEpoch}';
      // Integers, doubles, a document missing the field, and one where it is
      // not a number. The last two are skipped by the server rather than
      // treated as zero, which is what makes the average worth asserting.
      await setDocument('$col/a', {'n': 1, 'd': 1.5});
      await setDocument('$col/b', {'n': 2, 'd': 2.5});
      await setDocument('$col/c', {'n': 3, 'd': 3.5});
      await setDocument('$col/d', {'other': 'no n here'});
      await setDocument('$col/e', {'n': 'not a number'});
    });

    test('a sum of integers comes back whole', () async {
      // Firestore answers an all-integer sum with integer_value. Reading
      // only double_value would give 0 -- the same shape as the half-float
      // bug in the Variant codec, and just as quiet.
      expect(await sumCollection(col, 'n'), closeTo(6.0, 1e-9));
    });

    test('a sum of doubles keeps its fraction', () async {
      expect(await sumCollection(col, 'd'), closeTo(7.5, 1e-9));
    });

    test('an average skips what it cannot add', () async {
      // Five documents, three with a numeric n. 6/3 rather than 6/5, which
      // is what counting the other two as zero would give.
      expect(await averageCollection(col, 'n'), closeTo(2.0, 1e-9));
    });

    test('a filter narrows what is aggregated', () async {
      final sum = await sumCollection(
        col,
        'n',
        where: const [Where.greaterThan('n', 1)],
      );
      expect(sum, closeTo(5.0, 1e-9));
    });

    test('a field nothing has sums to zero', () async {
      expect(await sumCollection(col, 'absent'), 0.0);
    });

    test('an empty collection has no average', () async {
      expect(await averageCollection('agg-empty-$col', 'n'), 0.0);
    });

    test('a field is required', () async {
      await expectLater(sumCollection(col, ''), throwsA(isA<ArgumentError>()));
    });

    test('a field path the SDK rejects is an error, not a crash', () async {
      // The SDK throws on a malformed path, and an exception crossing the C
      // ABI aborts the process rather than reaching here. The query builder
      // already guards its own paths for the same reason.
      await expectLater(
        sumCollection(col, 'a//b'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('count', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('counts without fetching, and respects filters', () async {
      final coll = 'probe_c${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 4; i++) {
        await setDocument('$coll/doc$i', {
          'n': i,
          'tag': i < 2 ? 'low' : 'high',
        });
      }

      expect(await countCollection(coll), 4);
      expect(
        await countCollection(coll, where: const [Where.equalTo('tag', 'low')]),
        2,
      );
      expect(
        await countCollection(
          coll,
          where: const [Where.equalTo('tag', 'nope')],
        ),
        0,
      );

      for (var i = 0; i < 4; i++) {
        await deleteDocument('$coll/doc$i');
      }
    });

    test('an empty collection counts zero rather than failing', () async {
      expect(await countCollection('probe_c_definitely_absent'), 0);
    });
  });

  group(
    'collection groups',
    skip: hasFirestore ? null : 'Firestore not bound',
    () {
      test('finds a collection id at any depth', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final id = 'leaf$stamp';
        await setDocument('probe_cg$stamp/one/$id/x', {'n': 1});
        await setDocument('probe_cg$stamp/two/$id/y', {'n': 2});

        // A path query sees one collection; a group query sees both, which is
        // the whole distinction.
        final onePath = await queryCollection('probe_cg$stamp/one/$id');
        expect(onePath, hasLength(1));

        final group = await queryCollection(id, collectionGroup: true);
        expect(group.map((d) => d.data['n']).toSet(), {1, 2});

        await deleteDocument('probe_cg$stamp/one/$id/x');
        await deleteDocument('probe_cg$stamp/two/$id/y');
      });

      test('filters apply to a group query', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final id = 'leaff$stamp';
        await setDocument('probe_cg$stamp/one/$id/x', {'n': 1});
        await setDocument('probe_cg$stamp/two/$id/y', {'n': 2});

        final filtered = await queryCollection(
          id,
          collectionGroup: true,
          where: const [Where.greaterThan('n', 1)],
        );
        expect(filtered.map((d) => d.data['n']).toList(), [2]);

        await deleteDocument('probe_cg$stamp/one/$id/x');
        await deleteDocument('probe_cg$stamp/two/$id/y');
      });
    },
  );

  group('batches', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('applies every write, or none', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final a = 'probe_b/${stamp}_a';
      final b = 'probe_b/${stamp}_b';

      final batch = FirestoreBatch()
        ..set(a, {'n': 1})
        ..set(b, {'n': 2});
      await batch.commit();

      expect((await getDocument(a))!['n'], 1);
      expect((await getDocument(b))!['n'], 2);

      await (FirestoreBatch()
            ..delete(a)
            ..delete(b))
          .commit();
      expect(await getDocument(a), isNull);
      expect(await getDocument(b), isNull);
    });

    test('an empty batch is a no-op', () async {
      await FirestoreBatch().commit();
    });

    test('a rejected write fails the whole batch', () async {
      final path = 'probe_b/${DateTime.now().microsecondsSinceEpoch}_upd';
      // update on a document that does not exist is refused by Firestore, and
      // the batch it belongs to must not half-apply.
      final other = 'probe_b/${DateTime.now().microsecondsSinceEpoch}_ok';
      await expectLater(
        (FirestoreBatch()
              ..set(other, {'n': 1})
              ..update(path, {'n': 2}))
            .commit(),
        throwsA(isA<FirestoreException>()),
      );
      expect(await getDocument(other), isNull);
    });
  });

  group('transactions', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('reads and writes atomically', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}';
      await setDocument(path, {'n': 1});

      await runTransaction((tx) async {
        final current = await tx.get(path);
        tx.set(path, {'n': (current!['n']! as int) + 1});
      });

      expect((await getDocument(path))!['n'], 2);
      await deleteDocument(path);
    });

    test('a handler that throws leaves the document untouched', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_abort';
      await setDocument(path, {'n': 1});

      await expectLater(
        runTransaction((tx) async {
          tx.set(path, {'n': 99});
          throw StateError('changed my mind');
        }),
        throwsA(isA<StateError>()),
      );

      // The write was buffered, never applied — which is the reason writes are
      // buffered rather than sent as they are recorded.
      expect((await getDocument(path))!['n'], 1);
      await deleteDocument(path);
    });

    test('reading after writing is refused at the call site', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_order';
      await setDocument(path, {'n': 1});

      await expectLater(
        runTransaction((tx) async {
          tx.set(path, {'n': 2});
          // Firestore rejects this at commit; refusing here says which line
          // was wrong instead.
          await tx.get(path);
        }),
        throwsA(isA<StateError>()),
      );
      await deleteDocument(path);
    });

    test(
      'the handler runs again when the document changed underneath',
      () async {
        // The behavior that distinguishes a transaction from a batch, forced
        // deterministically: the first attempt reads, something else writes, and
        // Firestore must notice at commit and run the handler again.
        final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_retry';
        await setDocument(path, {'n': 1});

        var attempts = 0;
        await runTransaction((tx) async {
          attempts++;
          final current = await tx.get(path);
          if (attempts == 1) {
            // Behind the transaction's back, after it has read.
            await setDocument(path, {'n': 100});
          }
          tx.set(path, {'n': (current!['n']! as int) + 1});
        });

        expect(
          attempts,
          greaterThan(1),
          reason: 'the handler should have rerun',
        );
        // 101, not 2: the second attempt read the value the interloper wrote.
        expect((await getDocument(path))!['n'], 101);
        await deleteDocument(path);
      },
    );

    test('a transaction with no writes still completes', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_read';
      await setDocument(path, {'n': 7});
      Map<String, Object?>? seen;
      await runTransaction((tx) async {
        seen = await tx.get(path);
      });
      expect(seen!['n'], 7);
      await deleteDocument(path);
    });
  });

  test(
    'a document that was never written reads as absent, not empty',
    skip: hasFirestore ? null : 'Firestore not bound',
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
