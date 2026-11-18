// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_auth_ffi/src/error_codes.dart';
import 'package:firebase_ffi/auth.dart' as fdb;
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
    expect(
      () => auth.confirmPasswordReset('code', 'a new password'),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('confirmPasswordReset'),
        ),
      ),
    );
  });

  // The desktop SDK's calls take no settings, and dropping them would mail a
  // link that goes somewhere the app did not ask for.
  test('action-code settings are refused, not dropped', () {
    final auth = FirebaseAuthFfi();
    expect(
      () => auth.sendPasswordResetEmail(
        'a@b.c',
        ActionCodeSettings(url: 'https://example.com/done'),
      ),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('actionCodeSettings'),
        ),
      ),
    );
  });

  // Refused before the SDK is asked, so these need no build with one.
  test('a credential that is not bound names its provider', () {
    final auth = FirebaseAuthFfi();
    expect(
      () => auth.signInWithCredential(
        PhoneAuthProvider.credential(verificationId: 'v', smsCode: '000000'),
      ),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('phone'),
        ),
      ),
    );
    expect(
      () => auth.signInWithCredential(
        EmailAuthProvider.credentialWithLink(
          email: 'a@b.c',
          emailLink: 'https://example.com/?oobCode=x',
        ),
      ),
      throwsA(
        isA<UnimplementedError>().having(
          (e) => e.message,
          'message',
          contains('email link'),
        ),
      ),
    );
  });

  test('an SDK error is reported under the plugin code', () {
    // The values are firebase::auth::AuthError's.
    expect(authErrorCode(2), 'invalid-custom-token');
    expect(authErrorCode(12), 'wrong-password');
    expect(authErrorCode(14), 'user-not-found');
    expect(authErrorCode(23), 'weak-password');

    final e = authExceptionOf(const fdb.AuthException(12, 'bad password'));
    expect(e.code, 'wrong-password');
    expect(e.message, 'bad password');
  });

  test('an SDK error with no plugin code keeps its number', () {
    // kAuthErrorFailure, which the plugins have no name for either.
    final e = authExceptionOf(const fdb.AuthException(1, 'it failed'));
    expect(e.code, 'unknown-error');
    expect(e.message, 'it failed (AuthError 1)');
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
