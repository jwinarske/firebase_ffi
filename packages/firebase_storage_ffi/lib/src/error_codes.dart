// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The SDK's `firebase::storage::Error`, as the codes `firebase_storage`
/// reports.
///
/// The table is the FlutterFire Windows plugin's, which sits on the same C++
/// SDK, so an app sees the same code and message here as it does there. Keyed
/// by the enum's value, which is what crosses the FFI boundary.
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/storage.dart' as fdb;

const _codes = <int, (String, String)>{
  1: ('unknown', 'An unknown error occurred'), // kErrorUnknown
  2: (
    'object-not-found',
    'No object exists at the desired reference.',
  ), // kErrorObjectNotFound
  3: (
    'bucket-not-found',
    'No bucket is configured for Firebase Storage.',
  ), // kErrorBucketNotFound
  4: (
    'project-not-found',
    'No project is configured for Firebase Storage.',
  ), // kErrorProjectNotFound
  5: (
    'quota-exceeded',
    'Quota on your Firebase Storage bucket has been exceeded.',
  ), // kErrorQuotaExceeded
  6: (
    'unauthenticated',
    'User is unauthenticated. Authenticate and try again.',
  ), // kErrorUnauthenticated
  7: (
    'unauthorized',
    'User is not authorized to perform the desired action.',
  ), // kErrorUnauthorized
  8: (
    'retry-limit-exceeded',
    'The maximum time limit on an operation (upload, download, delete, etc.) '
        'has been exceeded.',
  ), // kErrorRetryLimitExceeded
  9: (
    'invalid-checksum',
    'File on the client does not match the checksum of the file received by '
        'the server.',
  ), // kErrorNonMatchingChecksum
  10: (
    'download-size-exceeded',
    'Size of the downloaded file exceeds the amount of memory allocated for '
        'the download.',
  ), // kErrorDownloadSizeExceeded
  11: ('canceled', 'User cancelled the operation.'), // kErrorCancelled
};

/// The plugin's code for a `firebase::storage::Error` value. A value the table
/// does not name is `unknown`, as the Windows plugin reports it.
String storageErrorCode(int sdkCode) => _codes[sdkCode]?.$1 ?? 'unknown';

/// [e] as the exception `firebase_storage` callers catch, for the operation
/// [what].
///
/// The message is the SDK's when it gives one; it often gives none, and then
/// it is the plugin's for the code. A value the table does not name keeps its
/// number in the message, since the code no longer says which one it was.
FirebaseException storageExceptionOf(fdb.StorageException e, String what) {
  final known = _codes[e.code];
  final detail = e.message.isNotEmpty
      ? e.message
      : known?.$2 ?? 'An unknown error occurred';
  return FirebaseException(
    plugin: 'firebase_storage',
    code: known?.$1 ?? 'unknown',
    message: known == null
        ? '$what: $detail (storage error ${e.code})'
        : '$what: $detail',
  );
}
