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
}
