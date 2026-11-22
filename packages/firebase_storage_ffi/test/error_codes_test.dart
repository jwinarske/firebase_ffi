// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_ffi/storage.dart' as fdb;
import 'package:firebase_storage_ffi/src/error_codes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the SDK\'s errors carry the plugin\'s codes', () {
    expect(storageErrorCode(2), 'object-not-found');
    expect(storageErrorCode(6), 'unauthenticated');
    expect(storageErrorCode(7), 'unauthorized');
    expect(storageErrorCode(9), 'invalid-checksum');
    expect(storageErrorCode(11), 'canceled');
  });

  test('one the table does not name is unknown', () {
    expect(storageErrorCode(99), 'unknown');
  });

  test('the SDK\'s message is kept when it gives one', () {
    final e = storageExceptionOf(
      const fdb.StorageException(7, 'denied by rules', 'putData'),
      'putData',
    );
    expect(e.plugin, 'firebase_storage');
    expect(e.code, 'unauthorized');
    expect(e.message, 'putData: denied by rules');
  });

  test('an empty message is the plugin\'s for the code', () {
    final e = storageExceptionOf(
      const fdb.StorageException(7, '', 'putData'),
      'putData',
    );
    expect(
      e.message,
      'putData: User is not authorized to perform the desired action.',
    );
  });

  test('an unnamed error keeps its number', () {
    final e = storageExceptionOf(
      const fdb.StorageException(99, '', 'getData'),
      'getData',
    );
    expect(e.code, 'unknown');
    expect(e.message, 'getData: An unknown error occurred (storage error 99)');
  });
}
