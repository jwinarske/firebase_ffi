// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// App Check, against no backend at all.
//
// A custom provider's token is the App Check token — the desktop SDK returns
// what the provider handed it, with no exchange — so everything about the
// custom path can be checked offline: that the provider is asked, that the
// token Dart supplied comes back, that the cache means it is not asked twice,
// and that a failure to attest is reported rather than parked.
//
// The debug provider is not exercised. It exchanges its token with the App
// Check backend for a real one, which needs a project and a token registered
// in its console. There is no App Check emulator.
//
// Its own directory, and its own `dart test` run, because App Check is
// process-global: once a provider is installed every other product starts
// asking it for tokens through the app's function registry. Sharing a process
// with the emulator suite made these counts include its requests -- which was
// worth seeing, since it is also the proof that the other products really do
// pick the token up.
@TestOn('vm')
library;

import 'dart:async';

import 'package:firebase_ffi/app_check.dart';
import 'package:firebase_ffi/database.dart';
import 'package:test/test.dart';

void main() {
  if (!hasAppCheck) {
    print('App Check not bound in this build — tests skipped');
    return;
  }

  // Far enough ahead that the SDK treats a token as live; the cache compares
  // against wall clock seconds.
  DateTime later() => DateTime.now().add(const Duration(hours: 1));

  setUpAll(() {
    initDatabase(
      appId: '1:1:android:1',
      apiKey: 'app-check-does-not-reach-a-backend-here',
      projectId: 'fdb-app-check',
      // Never reached: nothing in this file talks to a backend.
      databaseUrl: 'http://127.0.0.1:1/?ns=fdb-app-check',
    );
  });

  test('a custom provider supplies the token', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken('token-$asked', later());
    });
    initAppCheck();

    // Forced, because the cache belongs to the AppCheck instance and outlives
    // any one test in this file — an unforced call here would be answered by
    // whatever ran before it.
    final token = await appCheckToken(forceRefresh: true);
    expect(token.token, 'token-1');
    expect(asked, 1);
  });

  test('a live token is served from cache, not from the provider', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken('cached-$asked', later());
    });
    initAppCheck();

    await appCheckToken(forceRefresh: true);
    final before = asked;
    final second = await appCheckToken();

    // The count is the point: the provider was not asked again, which is what
    // stops every request re-attesting.
    expect(asked, before);
    expect(second.token, 'cached-$before');
  });

  test('forceRefresh asks the provider again', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken('fresh-$asked', later());
    });
    initAppCheck();

    await appCheckToken();
    final before = asked;
    final refreshed = await appCheckToken(forceRefresh: true);

    expect(asked, before + 1);
    expect(refreshed.token, 'fresh-$asked');
  });

  test('a provider that cannot attest fails the request', () async {
    useCustomAppCheckProvider(() async {
      throw StateError('no attestation available');
    });
    initAppCheck();

    // Forced, or a token cached by an earlier test would answer it.
    await expectLater(
      appCheckToken(forceRefresh: true),
      throwsA(
        isA<AppCheckException>().having(
          (e) => e.message,
          'message',
          contains('no attestation available'),
        ),
      ),
    );
  });

  test('an expired token is not served from cache', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken(
        'stale-$asked',
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
    });
    initAppCheck();

    await appCheckToken(forceRefresh: true);
    final before = asked;
    await appCheckToken();

    // Not force-refreshed: the SDK asked again because what it held had
    // already expired.
    expect(asked, before + 1);
  });

  test('a limited-use token comes from the same provider', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken('limited-$asked', later());
    });
    initAppCheck();

    final before = asked;
    final token = await limitedUseAppCheckToken();

    // Not served from the cache: a limited-use token is for one use, so the
    // provider is asked even when a live token is already held.
    expect(asked, greaterThan(before));
    expect(token.token, 'limited-$asked');
  });

  test('auto refresh is settable once App Check exists', () {
    useCustomAppCheckProvider(() async => AppCheckToken('x', later()));
    initAppCheck();
    // The SDK has no getter for it, so this asserts what can be asserted: it
    // is accepted rather than refused. Claiming more would be inventing it.
    expect(() => setAppCheckAutoRefresh(true), returnsNormally);
    expect(() => setAppCheckAutoRefresh(false), returnsNormally);
  });

  test('token changes reach a listener', () async {
    var asked = 0;
    useCustomAppCheckProvider(() async {
      asked++;
      return AppCheckToken('watched-$asked', later());
    });
    initAppCheck();

    final seen = <String>[];
    final sub = appCheckTokenChanges().listen((t) => seen.add(t.token));
    addTearDown(sub.cancel);

    await appCheckToken(forceRefresh: true);
    // The listener is called from the SDK thread that completed the token;
    // give the port a turn to deliver it.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(seen, isNotEmpty);
    expect(seen.last, 'watched-$asked');
  });

  group('on a named app', () {
    void makeApp(String name) {
      initNamedApp(
        name: name,
        appId: '1:1:android:2',
        apiKey: 'app-check-does-not-reach-a-backend-here',
        projectId: 'fdb-app-check',
      );
    }

    test('the provider is told which app is asking', () async {
      final askedFor = <String?>[];
      useCustomAppCheckProviderForApps((app) async {
        askedFor.add(app);
        return AppCheckToken('for-${app ?? 'default'}', later());
      });
      makeApp('ac-told');
      addTearDown(() => deleteNamedApp('ac-told'));
      initAppCheck();
      initAppCheck(app: 'ac-told');

      final named = await appCheckToken(forceRefresh: true, app: 'ac-told');
      final main = await appCheckToken(forceRefresh: true);

      expect(named.token, 'for-ac-told');
      expect(main.token, 'for-default');
      expect(askedFor, ['ac-told', null]);
    });

    test('each app keeps its own token', () async {
      var asked = 0;
      useCustomAppCheckProviderForApps((app) async {
        asked++;
        return AppCheckToken('${app ?? 'default'}-$asked', later());
      });
      makeApp('ac-cache');
      addTearDown(() => deleteNamedApp('ac-cache'));
      initAppCheck();
      initAppCheck(app: 'ac-cache');

      final main = await appCheckToken(forceRefresh: true);
      final named = await appCheckToken(forceRefresh: true, app: 'ac-cache');
      final before = asked;

      // Each served from its own app's cache, neither from the other's.
      expect((await appCheckToken()).token, main.token);
      expect((await appCheckToken(app: 'ac-cache')).token, named.token);
      expect(named.token, isNot(main.token));
      expect(asked, before);
    });

    test('each app has its own listener', () async {
      useCustomAppCheckProviderForApps(
        (app) async => AppCheckToken('heard-${app ?? 'default'}', later()),
      );
      makeApp('ac-heard');
      addTearDown(() => deleteNamedApp('ac-heard'));
      initAppCheck();
      initAppCheck(app: 'ac-heard');

      final main = <String>[];
      final named = <String>[];
      final a = appCheckTokenChanges().listen((t) => main.add(t.token));
      addTearDown(a.cancel);
      // A second listener is refused per app, not per process.
      final b = appCheckTokenChanges(
        app: 'ac-heard',
      ).listen((t) => named.add(t.token));
      addTearDown(b.cancel);

      await appCheckToken(forceRefresh: true, app: 'ac-heard');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(named, contains('heard-ac-heard'));
      expect(main, isNot(contains('heard-ac-heard')));
    });

    test('a call on an app App Check was not bound to says so', () {
      makeApp('ac-unbound');
      addTearDown(() => deleteNamedApp('ac-unbound'));
      expect(
        appCheckToken(app: 'ac-unbound'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"ac-unbound"'),
          ),
        ),
      );
      expect(() => initAppCheck(app: 'no-such-app'), throwsStateError);
    });

    test('deleting the app fails a request parked with Dart', () async {
      final asked = Completer<void>();
      final answer = Completer<AppCheckToken>();
      useCustomAppCheckProviderForApps((app) {
        if (app == null) return Future.value(AppCheckToken('main', later()));
        asked.complete();
        return answer.future;
      });
      makeApp('ac-gone');
      initAppCheck(app: 'ac-gone');

      var ended = false;
      appCheckTokenChanges(
        app: 'ac-gone',
      ).listen((_) {}, onDone: () => ended = true);
      final token = appCheckToken(forceRefresh: true, app: 'ac-gone');
      await asked.future;

      deleteNamedApp('ac-gone');
      await expectLater(
        token,
        throwsA(
          isA<AppCheckException>().having(
            (e) => e.message,
            'message',
            contains('deleted'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ended, isTrue);

      // The answer arriving late finds nothing to answer.
      answer.complete(AppCheckToken('too-late', later()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        appCheckToken(app: 'ac-gone'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
