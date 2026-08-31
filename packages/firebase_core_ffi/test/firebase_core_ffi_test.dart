// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What can be checked without a backend: registration, the app registry, and
// that the limits are refusals rather than silent surprises. Initializing for
// real needs the native library and a project, which the emulator tests cover.

import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

const _options = FirebaseOptions(
  apiKey: 'k',
  appId: '1:1:android:1',
  messagingSenderId: '1',
  projectId: 'p',
  databaseURL: 'https://p.firebaseio.com',
);

void main() {
  test('registerWith installs this as the platform implementation', () {
    FirebaseCoreFfi.registerWith();
    expect(FirebasePlatform.instance, isA<FirebaseCoreFfi>());
  });

  test(
    'an app that was never initialized is reported missing, not invented',
    () {
      final core = FirebaseCoreFfi();
      expect(() => core.app(), throwsA(isA<FirebaseException>()));
      expect(core.apps, isEmpty);
    },
  );

  test(
    'a named app is refused, because there is one native firebase::App',
    () async {
      final core = FirebaseCoreFfi();
      await expectLater(
        core.initializeApp(name: 'secondary', options: _options),
        throwsA(isA<UnimplementedError>()),
      );
    },
  );

  test('initializeApp reaches the native layer', () async {
    // These tests build firebase_ffi with with_firebase: false, so the native
    // library has no SDK in it and says so. That is the assertion: the call
    // got all the way through to fdb.initDatabase rather than stopping in
    // Dart. A build with the SDK is exercised by the emulator tests.
    final core = FirebaseCoreFfi();
    await expectLater(
      core.initializeApp(options: _options),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no Firebase SDK'),
        ),
      ),
    );
  });
}
