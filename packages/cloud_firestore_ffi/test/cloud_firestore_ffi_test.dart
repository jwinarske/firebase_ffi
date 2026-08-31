// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:cloud_firestore_ffi/cloud_firestore_ffi.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWith installs this as the platform implementation', () {
    CloudFirestoreFfi.registerWith();
    expect(FirebaseFirestorePlatform.instance, isA<CloudFirestoreFfi>());
  });

  test('doc() builds a reference at the requested path', () {
    expect(CloudFirestoreFfi().doc('probe/one').path, 'probe/one');
  });

  // The honest boundary of this implementation: the C ABI binds documents, so
  // anything query-shaped reports itself by name rather than being absent.
  test('querying names itself as unimplemented', () {
    expect(
      () => CloudFirestoreFfi().collection('probe'),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('transactions and batches name themselves', () {
    final fs = CloudFirestoreFfi();
    expect(() => fs.batch(), throwsA(isA<UnimplementedError>()));
    expect(
      () => fs.runTransaction((_) async {}),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
