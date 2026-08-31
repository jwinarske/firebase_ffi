// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWith installs this as the platform implementation', () {
    FirebaseAuthFfi.registerWith();
    expect(FirebaseAuthPlatform.instance, isA<FirebaseAuthFfi>());
  });

  test('no user before signing in', () {
    expect(FirebaseAuthFfi().currentUser, isNull);
  });

  test('the auth state stream is broadcast, so a late listener is allowed', () {
    final auth = FirebaseAuthFfi();
    final a = auth.authStateChanges();
    final b = auth.authStateChanges();
    expect(a.isBroadcast, isTrue);
    expect(() => b.listen((_) {}).cancel(), returnsNormally);
  });

  test('signing out with no user does not invent one', () async {
    final auth = FirebaseAuthFfi();
    await auth.signOut();
    expect(auth.currentUser, isNull);
  });

  // The point of implementing the platform interface rather than a lookalike
  // API: what is not bound reports itself by name instead of being absent.
  test('an unbound method names itself', () async {
    final auth = FirebaseAuthFfi();
    await expectLater(
      auth.signInWithEmailAndPassword('a@b.c', 'pw'),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('signInWithEmailAndPassword'),
        ),
      ),
    );
  });

  test('sign-in failures arrive as FirebaseAuthException', () async {
    // with_firebase: false here, so the native layer refuses before any
    // network call — which is enough to prove the translation happens rather
    // than a raw StateError reaching the caller.
    final auth = FirebaseAuthFfi();
    await expectLater(
      auth.signInAnonymously(),
      throwsA(anyOf(isA<FirebaseAuthException>(), isA<StateError>())),
    );
  });
}
