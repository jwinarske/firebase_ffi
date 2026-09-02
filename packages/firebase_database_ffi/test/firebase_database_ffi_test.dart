// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What holds without a Firebase build. Anything that reaches the SDK is
// covered in emulator_facade_test.dart.

import 'package:firebase_database_platform_interface/firebase_database_platform_interface.dart';
import 'package:firebase_database_ffi/firebase_database_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registering makes this the platform implementation', () {
    FirebaseDatabaseFfi.registerWith();
    expect(DatabasePlatform.instance, isA<FirebaseDatabaseFfi>());
  });

  test('paths compose without empty segments', () {
    final root = FirebaseDatabaseFfi().ref();
    expect(root.key, isNull);

    final child = root.child('a').child('/b/').child('c');
    expect(child.path, 'a/b/c');
    expect(child.key, 'c');
    expect(child.parent!.path, 'a/b');
    expect(child.root().key, isNull);
  });

  test('an exclusive bound is refused rather than widened', () {
    // startAfter has no equivalent in the desktop SDK, which has StartAt,
    // EndAt and EqualTo. Shifting it to the inclusive bound would return one
    // child too many and report nothing wrong.
    final q = FirebaseDatabaseFfi().ref('probe');
    expect(
      () => q.observe(
        QueryModifiers([StartCursorModifier.startAfter('a', null)]),
        DatabaseEventType.value,
      ),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('startAfter'),
        ),
      ),
    );
  });

  test('persistence names itself rather than pretending', () {
    // There is no on-disk cache on desktop. Accepting the call silently would
    // let an app believe its data survives a restart.
    final db = FirebaseDatabaseFfi();
    expect(() => db.setPersistenceEnabled(true), throwsUnimplementedError);
    expect(
      () => db.setPersistenceCacheSizeBytes(1 << 20),
      throwsUnimplementedError,
    );
    // Asking for what is already true is not an error.
    expect(() => db.setPersistenceEnabled(false), returnsNormally);
  });

  test('logging is accepted rather than throwing', () {
    // Advisory: an app turning logging on should not fail because this build
    // decides it elsewhere.
    expect(
      () => FirebaseDatabaseFfi().setLoggingEnabled(true),
      returnsNormally,
    );
  });
}
