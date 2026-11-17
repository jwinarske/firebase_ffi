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

  test('a callable by URI carries the URI and no name', () {
    final uri = Uri.parse('https://example.com/echo');
    final c = CloudFunctionsFfi().httpsCallableWithUri(
      null,
      uri,
      HttpsCallableOptions(),
    );
    expect(c.uri, uri);
    expect(c.name, isNull);
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
