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

  test('collection() builds a query over that path', () {
    final coll = CloudFirestoreFfi().collection('probe');
    expect(coll.path, 'probe');
    expect(coll.id, 'probe');
    // A root collection has no parent document; a subcollection does.
    expect(coll.parent, isNull);
    expect(
      CloudFirestoreFfi().collection('probe/one/sub').parent?.path,
      'probe/one',
    );
  });

  test('query clauses accumulate without mutating the original', () {
    // Queries are immutable in the plugin, so a query held onto and reused
    // must not acquire filters added to one derived from it.
    final base = CloudFirestoreFfi().collection('probe');
    final filtered = base.where([
      ['n', '==', 1],
    ]);
    expect((filtered.parameters['where'] as List), hasLength(1));
    expect((base.parameters['where'] as List), isEmpty);
  });

  test('cursors accumulate as query parameters', () {
    final q = CloudFirestoreFfi()
        .collection('probe')
        .orderBy([
          ['n', false],
        ])
        .startAt([1])
        .endBefore([9]);
    expect(q.parameters['startAt'], [1]);
    expect(q.parameters['endBefore'], [9]);
  });

  // The honest boundary: what the C ABI does not bind still reports itself by
  // name rather than being absent. Aggregates are the clearest remaining case.
  test('aggregates name themselves as unimplemented', () {
    expect(
      () => CloudFirestoreFfi().collection('probe').count(),
      throwsA(isA<UnimplementedError>()),
    );
  });

  // Batches are still unbound; transactions are not, as of the transaction
  // bindings. This is the third boundary test in a row to need splitting as
  // the thing it asserted was missing got implemented — which is the tests
  // tracking the ABI rather than drifting from it.
  test('batches name themselves as unimplemented', () {
    expect(
      () => CloudFirestoreFfi().batch(),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
