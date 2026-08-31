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
