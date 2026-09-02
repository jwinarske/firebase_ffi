// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What holds without a Firebase build.

import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:firebase_app_check_platform_interface/firebase_app_check_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registering makes this the platform implementation', () {
    FirebaseAppCheckFfi.registerWith();
    expect(FirebaseAppCheckPlatform.instance, isA<FirebaseAppCheckFfi>());
  });

  test('the platform activate with no provider says so', () {
    // Reached by calling the platform directly. An app cannot get here through
    // firebase_app_check: its activate() defaults providerWindows to
    // const WindowsDebugProvider(), so a provider always arrives.
    expect(
      () => FirebaseAppCheckFfi().activate(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('useCustomProvider'),
            contains('WindowsDebugProvider'),
          ),
        ),
      ),
    );
  });
}
