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

import 'dart:convert';
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

  // The desktop SDK persists its session, so a test that did not sign in
  // would inherit whoever the last one left behind — and a restored user's
  // cached token can be old enough to force a refresh the emulator cannot
  // serve. Starting each test signed out makes the suite order-independent.
  setUp(() => FirebaseAuth.instance.signOut());

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

  test('an anonymous user is reported as one', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();
    final user = cred.user!;
    expect(user.isAnonymous, isTrue);
    expect(user.email, isNull);
    expect(user.providerData, isEmpty);
    expect(user.metadata.creationTime, isNotNull);
    expect(FirebaseAuth.instance.currentUser!.isAnonymous, isTrue);
  });

  test('a user with an account behind it is not anonymous', () async {
    // The emulator is asked for a password account over REST, and a custom
    // token for its uid signs in as it -- the one way to reach a user with a
    // profile through the sign-ins bound here. The emulator accepts an
    // unsigned token, so no service account is involved.
    final email = 'u${DateTime.now().microsecondsSinceEpoch}@example.com';
    final uid = await _createAccount(host, authPort, email, 'Ada Lovelace');

    final cred = await FirebaseAuth.instance.signInWithCustomToken(
      _unsignedToken(uid),
    );
    final user = cred.user!;
    expect(user.uid, uid);
    expect(user.isAnonymous, isFalse);
    expect(user.email, email);
    expect(user.displayName, 'Ada Lovelace');
    expect(user.emailVerified, isFalse);
    expect(user.photoURL, isNull);
    expect(user.providerData.single.providerId, 'password');
    expect(user.providerData.single.email, email);

    final current = FirebaseAuth.instance.currentUser!;
    expect(current.uid, uid);
    expect(current.email, email);
    expect(current.isAnonymous, isFalse);
  });

  test('a fresh sign-in answers an ID token', () async {
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

  test('a refused custom token carries the plugin code', () async {
    await expectLater(
      FirebaseAuth.instance.signInWithCustomToken('not.a.token'),
      throwsA(
        isA<FirebaseAuthException>().having(
          (e) => e.code,
          'code',
          'invalid-custom-token',
        ),
      ),
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

/// Creates a password account in the Auth emulator, returning its uid.
Future<String> _createAccount(
  String host,
  int port,
  String email,
  String name,
) async {
  // The test binding replaces HttpClient with one that answers 400 to
  // everything without sending it. This request has to reach the emulator.
  final overrides = HttpOverrides.current;
  HttpOverrides.global = null;
  final client = HttpClient();
  HttpOverrides.global = overrides;
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://$host:$port/identitytoolkit.googleapis.com/v1/'
        'accounts:signUp?key=any',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'email': email,
        'password': 'not-a-secret',
        'displayName': name,
        'returnSecureToken': true,
      }),
    );
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw StateError(
        'accounts:signUp answered ${response.statusCode}: $body',
      );
    }
    return (jsonDecode(body) as Map<String, Object?>)['localId']! as String;
  } finally {
    client.close();
  }
}

/// A custom token with no signature, which only the emulator accepts.
String _unsignedToken(String uid) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'none', 'typ': 'JWT'})}.${part({'aud': 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit', 'iss': 'firebase-auth-emulator@example.com', 'sub': 'firebase-auth-emulator@example.com', 'iat': now, 'exp': now + 3600, 'uid': uid})}.';
}
