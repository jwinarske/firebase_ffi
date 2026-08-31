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

  test('the emulator is refused with the reason, not deferred', () {
    // Thrown synchronously, as the platform interface's own unimplemented
    // methods do — so a caller sees it at the call site rather than only on
    // await. Worth asserting the reason too: this is impossible rather than
    // unimplemented, and the difference is what stops someone spending an
    // afternoon looking for the right URL.
    expect(
      () => FirebaseStorageFfi().useStorageEmulator('127.0.0.1', 9199),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('compile-time constants'),
        ),
      ),
    );
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
