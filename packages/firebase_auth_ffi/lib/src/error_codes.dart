// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The SDK's `firebase::auth::AuthError`, as the codes `firebase_auth` reports.
///
/// The table is the one the FlutterFire Windows plugin uses, which sits on the
/// same C++ SDK, so an app sees the same code here as it does there. Keyed by
/// the enum's value: it is what crosses the FFI boundary, and the SDK does not
/// renumber it -- the values are shared with the Android and iOS SDKs.
library;

import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_ffi/auth.dart' as fdb;

/// What an error the table does not name is reported as.
const unknownErrorCode = 'unknown-error';

const _codes = <int, String>{
  2: 'invalid-custom-token', // kAuthErrorInvalidCustomToken
  3: 'custom-token-mismatch', // kAuthErrorCustomTokenMismatch
  4: 'invalid-credential', // kAuthErrorInvalidCredential
  5: 'user-disabled', // kAuthErrorUserDisabled
  6: 'account-exists-with-different-credentials', // kAuthErrorAccountExistsWithDifferentCredentials
  7: 'operation-not-allowed', // kAuthErrorOperationNotAllowed
  8: 'email-already-in-use', // kAuthErrorEmailAlreadyInUse
  9: 'requires-recent-login', // kAuthErrorRequiresRecentLogin
  10: 'credential-already-in-use', // kAuthErrorCredentialAlreadyInUse
  11: 'invalid-email', // kAuthErrorInvalidEmail
  12: 'wrong-password', // kAuthErrorWrongPassword
  13: 'too-many-requests', // kAuthErrorTooManyRequests
  14: 'user-not-found', // kAuthErrorUserNotFound
  15: 'provider-already-linked', // kAuthErrorProviderAlreadyLinked
  16: 'no-such-provider', // kAuthErrorNoSuchProvider
  17: 'invalid-user-token', // kAuthErrorInvalidUserToken
  18: 'user-token-expired', // kAuthErrorUserTokenExpired
  19: 'network-request-failed', // kAuthErrorNetworkRequestFailed
  20: 'invalid-api-key', // kAuthErrorInvalidApiKey
  21: 'app-not-authorized', // kAuthErrorAppNotAuthorized
  22: 'user-mismatch', // kAuthErrorUserMismatch
  23: 'weak-password', // kAuthErrorWeakPassword
  24: 'no-signed-in-user', // kAuthErrorNoSignedInUser
  26: 'expired-action-code', // kAuthErrorExpiredActionCode
  27: 'invalid-action-code', // kAuthErrorInvalidActionCode
  28: 'invalid-message-payload', // kAuthErrorInvalidMessagePayload
  29: 'invalid-phone-number', // kAuthErrorInvalidPhoneNumber
  30: 'missing-phone-number', // kAuthErrorMissingPhoneNumber
  31: 'invalid-recipient-email', // kAuthErrorInvalidRecipientEmail
  32: 'invalid-sender', // kAuthErrorInvalidSender
  33: 'invalid-verification-code', // kAuthErrorInvalidVerificationCode
  34: 'invalid-verification-id', // kAuthErrorInvalidVerificationId
  35: 'missing-verification-code', // kAuthErrorMissingVerificationCode
  36: 'missing-verification-id', // kAuthErrorMissingVerificationId
  37: 'missing-email', // kAuthErrorMissingEmail
  39: 'quota-exceeded', // kAuthErrorQuotaExceeded
  41: 'session-expired', // kAuthErrorSessionExpired
  45: 'invalid-app-credential', // kAuthErrorInvalidAppCredential
  46: 'missing-app-credential', // kAuthErrorMissingAppCredential
  48: 'invalid-continue-uri', // kAuthErrorInvalidContinueUri
  49: 'missing-continue-uri', // kAuthErrorMissingContinueUri
  54: 'unauthorized-domain', // kAuthErrorUnauthorizedDomain
  58: 'cancelled', // kAuthErrorCancelled
  62: 'tenant-id-mismatch', // kAuthErrorTenantIdMismatch
  63: 'unsupported-tenant-operation', // kAuthErrorUnsupportedTenantOperation
  68: 'missing-client-identifier', // kAuthErrorMissingClientIdentifier
};

/// The plugin's code for an `AuthError` value, or [unknownErrorCode].
String authErrorCode(int sdkCode) => _codes[sdkCode] ?? unknownErrorCode;

/// [e] as the exception `firebase_auth` callers catch.
///
/// The message is the SDK's own. An error the table does not name keeps its
/// number there, since the code no longer says which one it was.
FirebaseAuthException authExceptionOf(fdb.AuthException e) {
  final code = authErrorCode(e.code);
  return FirebaseAuthException(
    code: code,
    message: code == unknownErrorCode
        ? '${e.message} (AuthError ${e.code})'
        : e.message,
  );
}
