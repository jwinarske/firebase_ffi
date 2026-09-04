// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The claim this whole layer makes, tested: an app uses firebase_core and
// firebase_auth unchanged, and the calls land on the C++ SDK.
//
// Nothing here mentions firebase_ffi. If these pass, the façade is doing what
// it exists to do; if the API were a lookalike rather than the platform
// interface, this file would not compile.
//
// Skipped without FIREBASE_EMULATOR_HOST, so `flutter test` stays useful.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — façade emulator tests skipped');
    return;
  }
  final authPort =
      int.tryParse(Platform.environment['FIREBASE_AUTH_EMULATOR_PORT'] ?? '') ??
      9099;
  final dbPort =
      int.tryParse(
        Platform.environment['FIREBASE_DATABASE_EMULATOR_PORT'] ?? '',
      ) ??
      9000;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // A test binding reports TargetPlatform.android, and FirebaseAuth's
    // useAuthEmulator rewrites 127.0.0.1 to 10.0.2.2 on Android -- the address
    // an Android emulator uses for its host. Pointed at that, the C++ SDK has
    // nothing to reach and the sign-in hangs until the test times out. This
    // implementation is the Linux one, so the test says so.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // Registration is Flutter's job in a real app; a test binding has no
    // plugin registrant, so it is done by hand here.
    FirebaseCoreFfi.registerWith();
    FirebaseAuthFfi.registerWith();

    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
        databaseURL: 'http://$host:$dbPort/?ns=$_projectId',
      ),
    );
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('Firebase.app() returns the initialized default app', () {
    expect(Firebase.app().name, defaultFirebaseAppName);
    expect(Firebase.app().options.projectId, _projectId);
  });

  test('signInAnonymously through firebase_auth reaches the SDK', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();
    expect(cred.user, isNotNull);
    expect(cred.user!.uid, isNotEmpty);
    expect(FirebaseAuth.instance.currentUser?.uid, cred.user!.uid);
  });

  test('a fresh sign-in answers an ID token', () async {
    // Signed out first: the desktop SDK persists its session and hands back
    // the restored user, whose cached token may be old enough that reading it
    // forces a refresh — which the emulator cannot serve. What this test is
    // about is the token a sign-in just minted.
    await FirebaseAuth.instance.signOut();
    final cred = await FirebaseAuth.instance.signInAnonymously();

    // No refresh happens: the SDK returns the cached token while it has more
    // than five minutes left (GetTokenIfFresh), which it does right after a
    // sign-in. That is why this works against the emulator at all.
    final token = await cred.user!.getIdToken();
    expect(token, isNotNull);
    expect(token!.split('.'), hasLength(3));

    final result = await cred.user!.getIdTokenResult();
    expect(result.token, token);
    expect(result.claims!['user_id'], cred.user!.uid);
    expect(result.signInProvider, 'anonymous');
    expect(result.expirationTime!.isAfter(DateTime.now()), isTrue);
    expect(
      result.issuedAtTime!.isAfter(
        DateTime.now().subtract(const Duration(minutes: 5)),
      ),
      isTrue,
    );
  });

  test('a forced refresh cannot be served by the emulator', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();

    // The refresh goes through SecureTokenRequest, which builds
    // https://securetoken.googleapis.com/v1/token from a compile-time host and
    // overwrites the emulator URL its base class applied. Sign-in honours the
    // emulator; a refresh leaves it and fails on a token the emulator minted.
    //
    // Asserted rather than skipped: it is the boundary of what the emulator
    // can cover here, and if the SDK ever routes this through the emulator
    // the test says so by passing when it should not.
    await expectLater(
      cred.user!.getIdToken(true),
      throwsA(isA<FirebaseAuthException>()),
    );
  });

  test('authStateChanges reports the sign-out', () async {
    final seen = <User?>[];
    final sub = FirebaseAuth.instance.authStateChanges().listen(seen.add);
    addTearDown(sub.cancel);

    await FirebaseAuth.instance.signInAnonymously();
    await FirebaseAuth.instance.signOut();

    // The stream is driven by the calls that pass through, so both events are
    // expected in order.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.length, greaterThanOrEqualTo(2));
    expect(seen.last, isNull);
    expect(FirebaseAuth.instance.currentUser, isNull);
  });
}
