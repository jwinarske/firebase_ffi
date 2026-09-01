// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What holds without a Firebase build. The calling path needs the SDK and is
// covered in emulator_facade_test.dart.

import 'package:cloud_functions_platform_interface/cloud_functions_platform_interface.dart';
import 'package:cloud_functions_ffi/cloud_functions_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registering makes this the platform implementation', () {
    CloudFunctionsFfi.registerWith();
    expect(FirebaseFunctionsPlatform.instance, isA<CloudFunctionsFfi>());
  });

  test('the default region is the one the SDK would pick', () {
    expect(CloudFunctionsFfi().region, 'us-central1');
  });

  test('a delegate keeps the region it was asked for', () {
    final d = CloudFunctionsFfi().delegateFor(region: 'europe-west1');
    expect(d, isA<CloudFunctionsFfi>());
    expect(d.region, 'europe-west1');
  });

  test('a callable carries its name and origin', () {
    final c = CloudFunctionsFfi().httpsCallable(
      'http://127.0.0.1:5001',
      'echo',
      HttpsCallableOptions(),
    );
    expect(c.name, 'echo');
    expect(c.origin, 'http://127.0.0.1:5001');
  });

  test('calling by URI names itself rather than guessing a name', () {
    // The SDK has GetHttpsCallableFromURL and the binding does not expose it.
    // Deriving a name from the URL would call a different function than the
    // one asked for, which is worse than not answering.
    expect(
      () => CloudFunctionsFfi().httpsCallableWithUri(
        null,
        Uri.parse('https://example.com/echo'),
        HttpsCallableOptions(),
      ),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('httpsCallableWithUri'),
        ),
      ),
    );
  });

  test('calling without a Firebase build fails on the missing SDK', () async {
    final c = CloudFunctionsFfi().httpsCallable(
      null,
      'echo',
      HttpsCallableOptions(),
    );
    // Not a FirebaseFunctionsException: nothing reached Functions to fail.
    await expectLater(c.call(), throwsA(isA<StateError>()));
  });
}
