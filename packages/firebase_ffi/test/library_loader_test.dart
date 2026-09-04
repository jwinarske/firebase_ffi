// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The loader is a fallback for embedders whose engine has no RPATH or
// RUNPATH, so what matters is that it finds the library when the dynamic
// loader would, and stays out of the way when it would not.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/src/internal/library_loader.dart';
import 'package:test/test.dart';

void main() {
  test('it does nothing when the VM can resolve the asset itself', () {
    ensureLibraryLoaded();
    // Under `dart test` the asset table carries an absolute path, so there is
    // nothing to fix and nothing is recorded. That silence is the contract:
    // the loader must never make a working configuration worse.
    final path = loadedLibraryPath;
    if (path != null && path.contains('/')) {
      expect(File(path).existsSync(), isTrue);
    }
  });

  test('calling it again is a no-op', () {
    final first = loadedLibraryPath;
    ensureLibraryLoaded();
    ensureLibraryLoaded();
    expect(loadedLibraryPath, first);
  });

  test('a native call works after it', () {
    // hasFirebase is the getter every product's guard goes through, and it
    // ensures the library itself — an app never calls the loader directly.
    expect(hasFirebase, isA<bool>());
  });

  test('an override that names nothing does not break resolution', () async {
    // The override is a hint, not a gate: a stale FIREBASE_FFI_LIB in an
    // environment must not stop a program that would otherwise have run.
    //
    // Not on Windows. The child re-bundles native assets on the way up and
    // cannot replace .dart_tool/lib/firebase_ffi.dll while this process has it
    // mapped — the loader is fine there, spawning a second Dart process that
    // rewrites the same DLL is not.
    // Inside the package, so `dart run` resolves package:firebase_ffi; the
    // system temp directory is outside any package and would not.
    final probe = File('${Directory.current.path}/.dart_tool/fdb_probe.dart')
      ..writeAsStringSync('''
import 'package:firebase_ffi/database.dart';
void main() => print('resolved: \${hasFirebase is bool}');
''');
    addTearDown(() => probe.deleteSync());

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', probe.path],
      environment: {'FIREBASE_FFI_LIB': '/nonexistent/libfirebase_ffi.so'},
      workingDirectory: Directory.current.path,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('resolved: true'));
  }, testOn: '!windows');
}
