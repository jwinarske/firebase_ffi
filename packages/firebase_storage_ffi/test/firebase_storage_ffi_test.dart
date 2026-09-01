// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWith installs this as the platform implementation', () {
    FirebaseStorageFfi.registerWith();
    expect(FirebaseStoragePlatform.instance, isA<FirebaseStorageFfi>());
  });

  test('child() joins paths without doubling or dropping separators', () {
    final root = FirebaseStorageFfi().ref('probe');
    expect(root.child('a.bin').fullPath, 'probe/a.bin');
    expect(root.child('/a.bin').fullPath, 'probe/a.bin');
    expect(
      FirebaseStorageFfi().ref('probe/').child('a.bin').fullPath,
      'probe/a.bin',
    );
    expect(FirebaseStorageFfi().ref('').child('a.bin').fullPath, 'a.bin');
  });

  test('the emulator is forwarded, not refused', () async {
    // This used to assert an UnimplementedError saying desktop Storage built
    // its host from compile-time constants. Storage::UseEmulator is stock in
    // 13.12.0 -- that came from reading an older checkout of the SDK than the
    // one this builds.
    //
    // Without a Firebase build there is no library to forward into, so the
    // failure is the missing SDK. What matters is that it is no longer refused
    // as impossible; emulator_facade_test.dart does it against a real one.
    // Whatever comes back, it must not be an UnimplementedError. Asserting a
    // specific failure would only hold in a build without the SDK, and this
    // package's tests run both ways.
    Object? thrown;
    try {
      await FirebaseStorageFfi().useStorageEmulator('127.0.0.1', 9199);
    } on Object catch (e) {
      thrown = e;
    }
    expect(thrown, isNot(isA<UnimplementedError>()));
  });

  test('retry windows are accepted rather than throwing', () {
    final s = FirebaseStorageFfi();
    expect(() => s.setMaxUploadRetryTime(1000), returnsNormally);
    expect(() => s.setMaxDownloadRetryTime(1000), returnsNormally);
    expect(() => s.setMaxOperationRetryTime(1000), returnsNormally);
  });

  test('an unbound method names itself', () {
    // listAll is not bound: the native layer has no listing.
    expect(
      () => FirebaseStorageFfi().ref('probe').listAll(),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
