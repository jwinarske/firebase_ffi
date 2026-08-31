// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Calls into the built library, which nothing else here does.
//
// The rest of the suite is pure Dart, so it passes even if the code asset is
// named wrong, the library exports nothing, or the platform's export macro is
// inert — the VM resolves an @Native external lazily, at the first call. These
// tests make that call, so a build that produces an unusable library fails here
// rather than in an application.

import 'package:firebase_ffi/database.dart';
import 'package:test/test.dart';

void main() {
  test('the code asset resolves and a native symbol is callable', () {
    // fdb_now_ns is the simplest thing in the ABI: no state, no Firebase.
    final t = nowNs();
    expect(t, greaterThan(0), reason: 'clock came back unset');
  });

  test('the clock advances', () async {
    final a = nowNs();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final b = nowNs();
    expect(b, greaterThan(a));
  });

  test('hasFirebase reports how the library was built', () {
    // Either answer is correct — it says whether the SDK was linked, and both
    // configurations are supported. What matters is that the call works.
    expect(hasFirebase, isA<bool>());
    printOnFailure('hasFirebase = $hasFirebase');
  });
}
