// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Builds the Firebase C++ SDK this package links against.
//
//   dart run firebase_ffi:build_sdk <install-prefix> [source-dir]
//
// Then name that prefix in the app's pubspec, which is what the build hook
// reads:
//
//   hooks:
//     user_defines:
//       firebase_ffi:
//         products: [auth, database, firestore, storage]
//         firebase_sdk: <install-prefix>
//
// The SDK ships no install rules and does not build unmodified on current
// toolchains, so tool/build_firebase_sdk.sh applies the patch set in patches/.
// Both travel with this package, so a consumer who installed it from pub has
// them; this finds them wherever pub put the package.
//
// The build is CMake and shell either way, so this launches that script rather
// than reimplementing it in Dart — one implementation to keep correct.

import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      arguments.first == '-h' ||
      arguments.first == '--help') {
    stderr.writeln(
      'usage: dart run firebase_ffi:build_sdk <install-prefix> [source-dir]\n'
      '\n'
      '  install-prefix  where the SDK is installed; name it as\n'
      '                  hooks.user_defines.firebase_ffi.firebase_sdk\n'
      '  source-dir      where sources are unpacked and built\n'
      '                  (default: a directory under TMPDIR)\n'
      '\n'
      'FIREBASE_SDK_VERSION selects the release; FIREBASE_SDK_PLATFORM\n'
      'overrides the detected platform. Idempotent: a prefix that already\n'
      'has the SDK is left alone.',
    );
    exit(arguments.isEmpty ? 2 : 0);
  }

  if (Platform.isWindows) {
    // The script is bash and the SDK's own build wants a POSIX shell; Git Bash
    // provides one, and saying so beats a failure inside CMake.
    stderr.writeln('run tool/build_firebase_sdk.sh from Git Bash on Windows');
    exit(2);
  }

  final script = await _scriptPath();
  if (script == null) {
    stderr.writeln('cannot find build_firebase_sdk.sh inside firebase_ffi');
    exit(1);
  }

  final process = await Process.start('bash', [
    script.path,
    ...arguments,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await process.exitCode);
}

/// The script inside this package, wherever pub put it.
///
/// Resolved through the package URI rather than Platform.script: the two are
/// the same for `dart run` from a checkout and differ for a package in the pub
/// cache, which is the case this exists for.
Future<File?> _scriptPath() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:firebase_ffi/firebase_ffi.dart'),
  );
  if (lib == null) return null;
  final root = Directory.fromUri(lib.resolve('../'));
  final script = File.fromUri(root.uri.resolve('tool/build_firebase_sdk.sh'));
  return script.existsSync() ? script : null;
}
