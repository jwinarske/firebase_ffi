// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// cloud_functions, unchanged, against the Functions emulator. Nothing here
// mentions firebase_ffi.
//
// The callables are the ones in packages/firebase_ffi/test/emulator/functions:
// echo returns its argument, add sums two numbers, boom throws.
//
// Skipped without FIREBASE_EMULATOR_HOST.
@TestOn('vm')
library;

import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_functions_ffi/cloud_functions_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — Functions façade tests skipped');
    return;
  }
  final fnPort =
      int.tryParse(
        Platform.environment['FIREBASE_FUNCTIONS_EMULATOR_PORT'] ?? '',
      ) ??
      5001;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // See firebase_auth_ffi: a test binding reports Android, and
    // useFunctionsEmulator rewrites the host to 10.0.2.2 there. This is the
    // Linux implementation.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    CloudFunctionsFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
      ),
    );
    FirebaseFunctions.instance.useFunctionsEmulator(host, fnPort);
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('a callable round trips its argument', () async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('echo')
        .call<Map<String, dynamic>>({
          'text': 'hello',
          'n': 42,
          // A double, which the CBOR encoder writes in the narrowest float
          // that holds it. Reading that width back wrongly gave 0.0 once.
          'ratio': 1.5,
          'nested': {'deep': true},
        });

    final received = result.data['received'] as Map;
    expect(received['text'], 'hello');
    expect(received['n'], 42);
    expect(received['ratio'], closeTo(1.5, 1e-9));
    expect((received['nested'] as Map)['deep'], true);
  });

  test('a numeric result comes back as a number', () async {
    final result = await FirebaseFunctions.instance.httpsCallable('add').call({
      'a': 20,
      'b': 22,
    });
    expect(result.data, 42);
  });

  test(
    'a callable that throws surfaces as a FirebaseFunctionsException',
    () async {
      // The type is what matters: an app catching FirebaseFunctionsException on
      // Android has to catch the same thing here, or the façade is a lookalike.
      await expectLater(
        FirebaseFunctions.instance.httpsCallable('boom').call(),
        throwsA(isA<FirebaseFunctionsException>()),
      );
    },
  );
}
