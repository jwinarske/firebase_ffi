// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What holds without a Firebase build. Everything that reads a value needs the
// SDK and is covered in emulator_facade_test.dart.

import 'package:firebase_remote_config_ffi/firebase_remote_config_ffi.dart';
import 'package:firebase_remote_config_platform_interface/firebase_remote_config_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registering makes this the platform implementation', () {
    FirebaseRemoteConfigFfi.registerWith();
    expect(
      FirebaseRemoteConfigPlatform.instance,
      isA<FirebaseRemoteConfigFfi>(),
    );
  });

  test('an unread key gives the accessor default rather than throwing', () {
    // No cache has been filled, which is the same shape as a key that was
    // never set: the accessor's own default is the answer.
    final rc = FirebaseRemoteConfigFfi();
    expect(rc.getString('absent'), '');
    expect(rc.getInt('absent'), 0);
    expect(rc.getDouble('absent'), 0.0);
    expect(rc.getBool('absent'), isFalse);
    expect(rc.getValue('absent').source, ValueSource.valueStatic);
  });

  test('real-time updates name themselves as unimplemented', () {
    // Not "not yet": the desktop SDK has no config-update listener to route
    // this to, so it keeps the platform interface's own error.
    expect(
      () => FirebaseRemoteConfigFfi().onConfigUpdated,
      throwsA(isA<UnimplementedError>()),
    );
  });
}
