// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Native assets build hook for firebase_ffi.
//
// Drives native/CMakeLists.txt to produce the shared library and declares it
// as a CodeAsset under the id named in bindings.dart's @DefaultAsset. Changing
// the name here without changing that annotation is not a build error; it
// surfaces as a symbol resolution failure at the first call.
//
// Cross builds: emb hands hooks a cross toolchain through FLUTTER_HOOK_CC /
// _AR / _LD (wrapper scripts with the sysroot flags baked in), which the SDK
// turns into input.config.code.cCompiler. Honor it when present, otherwise the
// hook silently builds a host library and the bundle audit rejects it as the
// wrong architecture.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final pkgRoot = input.packageRoot.toFilePath();
    final nativeRoot = '${pkgRoot}native';
    final buildDir = input.outputDirectory.resolve('cmake/').toFilePath();
    await Directory(buildDir).create(recursive: true);

    final compiler = input.config.code.cCompiler;
    var cc = compiler?.compiler.toFilePath();
    final ar = compiler?.archiver.toFilePath();

    // The config only names a C compiler, but this project is mostly C++.
    // Handing CMake the C driver for CXX links without the standard library
    // and shows up as undefined std:: symbols long after the compile passed.
    var cxx = cc == null ? null : _cxxDriverFor(cc);

    // Flutter's Linux desktop build pins clang 18, which cannot parse a
    // libstdc++ newer than itself: GCC 16's <atomic> uses __builtin_popcountg,
    // a clang 19+ builtin, so the failure is a wall of errors inside system
    // headers that names nothing in this project.
    //
    // Probed rather than version-matched, because the pairing that breaks is
    // (this clang, this libstdc++) and neither version alone predicts it.
    // Scoped to clang so a cross toolchain is never second-guessed: the probe
    // compiles for the host, so applying it to a cross compiler would reject a
    // working toolchain over a missing target sysroot.
    if (cxx != null && _isClang(cxx) && !await _canCompileCxx20(cxx)) {
      // Name the replacement explicitly rather than clearing these and
      // letting CMake choose: with no -D flags CMake honors CC/CXX from the
      // environment, which is where the unusable clang came from in the first
      // place, so "unset" would quietly reselect it.
      final fallbackCxx = await _firstOnPath(['g++', 'c++']);
      final fallbackCc = await _firstOnPath(['gcc', 'cc']);
      if (fallbackCxx != null && await _canCompileCxx20(fallbackCxx)) {
        stderr.writeln(
          'firebase_ffi: $cxx cannot compile C++20 against this system\'s '
          'libstdc++ (clang below 19 does not know __builtin_popcountg); '
          'using $fallbackCxx instead. Set hooks.user_defines.firebase_ffi.cxx to override.',
        );
        cxx = fallbackCxx;
        cc = fallbackCc ?? cc;
      } else {
        stderr.writeln(
          'firebase_ffi: $cxx cannot compile C++20 against this system\'s '
          'libstdc++ and no working g++ was found; the build will likely fail. '
          'Set hooks.user_defines.firebase_ffi.cxx to a compiler that can.',
        );
      }
    }

    // Explicit overrides win, including over the fallback above. Same
    // user-defines mechanism as firebase_sdk, for the same reason: an
    // environment variable would never reach this hook.
    cc = _stringDefine(input, 'cc') ?? cc;
    cxx = _stringDefine(input, 'cxx') ?? cxx;

    // On Windows the Visual Studio generator is what makes MSVC usable: it
    // sets up the compiler and the library paths itself. Ninja would need LIB
    // and INCLUDE in the environment, and the hook runner does not forward the
    // ambient environment — an MSVC dev shell in the workflow reaches the step
    // but not this process, which surfaces as
    // "LNK1104: cannot open file 'kernel32.lib'".
    //
    // For the same reason the configured C compiler is ignored there: it
    // resolves to MinGW GCC, which cannot link the MSVC-built SDK.
    final windows = input.config.code.targetOS == OS.windows;
    if (windows && _stringDefine(input, 'cc') == null) {
      cc = null;
      cxx = null;
    }

    final hasNinja = !windows && await _which('ninja');

    // Where find_package(firebase_cpp_sdk) should look on a host build. The
    // cross build gets this from emb's toolchain file, which sets CMAKE_SYSROOT
    // and CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY; a host build has no such file
    // and finds nothing, so the library silently comes out transport-only —
    // 31 KB instead of 14 MB, failing at runtime as "build has no Firebase SDK"
    // rather than at build time.
    //
    // Passed as -D rather than relying on CMake reading CMAKE_PREFIX_PATH from
    // the environment: the hook runner does not forward the ambient environment
    // to build hooks, so the env var alone never arrives.
    // Configured in the consuming package's pubspec.yaml:
    //
    //   hooks:
    //     user_defines:
    //       firebase_ffi:
    //         firebase_sdk: /path/to/prefix   # contains lib/cmake/firebase_cpp_sdk
    //
    // User-defines rather than an environment variable: the hook runner does
    // not forward the ambient environment, so FDB_FIREBASE_SDK or
    // CMAKE_PREFIX_PATH set in a shell never arrives here.
    // Resolved through userDefines.path() so a relative value is interpreted
    // against the pubspec.yaml that declares it, not the process's working
    // directory — which is what makes this usable from a published package.
    final sdkPrefix = input.userDefines.path('firebase_sdk')?.toFilePath();

    // Which Firebase products this app binds. Firestore is off unless asked
    // for: its archives pull in gRPC, protobuf and abseil, and an app that does
    // not reference them should not carry them.
    final products = input.userDefines['products'];
    if (products != null && products is! List) {
      throw const FormatException(
        'hooks.user_defines.firebase_ffi.products must be a list, e.g. '
        '[auth, database, firestore, storage]',
      );
    }
    final selected = (products as List?)?.map((e) => '$e').toSet() ?? const {};
    final wantsFirestore = selected.contains('firestore');
    final wantsStorage = selected.contains('storage');

    // Opting out of Firebase entirely, for the transport benchmark alone.
    final withFirebase = input.userDefines['with_firebase'];
    if (withFirebase != null && withFirebase is! bool) {
      throw const FormatException(
        'hooks.user_defines.firebase_ffi.with_firebase must be a boolean',
      );
    }

    // A cache pinned to a different compiler must be discarded, not reused:
    // CMake refuses to change compilers in place, so without this a corrected
    // selection silently has no effect and the build keeps failing with the
    // old toolchain — which is exactly how the clang fallback above looks like
    // it did nothing.
    final cacheFile = File('${buildDir}CMakeCache.txt');
    if (cacheFile.existsSync() && cxx != null) {
      final cached = RegExp(
        r'^CMAKE_CXX_COMPILER:\w+=(.*)$',
        multiLine: true,
      ).firstMatch(cacheFile.readAsStringSync())?.group(1)?.trim();
      final cachedPrefix = RegExp(
        r'^CMAKE_PREFIX_PATH:\w+=(.*)$',
        multiLine: true,
      ).firstMatch(cacheFile.readAsStringSync())?.group(1)?.trim();
      final prefixChanged =
          sdkPrefix != null &&
          cachedPrefix != null &&
          cachedPrefix != sdkPrefix;
      if ((cached != null && cached != cxx) || prefixChanged) {
        stderr.writeln(
          'firebase_ffi: cached CMake compiler $cached differs from $cxx; '
          'reconfiguring from scratch.',
        );
        await Directory(buildDir).delete(recursive: true);
        await Directory(buildDir).create(recursive: true);
      }
    }

    // A cache alone does not mean the directory is usable: CMake writes
    // CMakeCache.txt early, so a configure that fails afterwards leaves one
    // behind with no generator files. Treating that as "already configured"
    // skips straight to --build and fails as "ninja: build.ninja: No such file
    // or directory", every run from then on, with the real error long gone.
    final configured =
        File('${buildDir}CMakeCache.txt').existsSync() &&
        (File('${buildDir}build.ninja').existsSync() ||
            File('${buildDir}Makefile').existsSync());
    if (!configured) {
      if (Directory(buildDir).existsSync()) {
        await Directory(buildDir).delete(recursive: true);
      }
      await Directory(buildDir).create(recursive: true);
    }

    if (!configured) {
      await _run('cmake', [
        '-S',
        nativeRoot,
        '-B',
        buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        if (cc != null) '-DCMAKE_C_COMPILER=$cc',
        if (cxx != null) '-DCMAKE_CXX_COMPILER=$cxx',
        if (ar != null) '-DCMAKE_AR=$ar',
        if (sdkPrefix != null) '-DCMAKE_PREFIX_PATH=$sdkPrefix',
        if (withFirebase == false) '-DFDB_WITH_FIREBASE=OFF',
        if (wantsFirestore) '-DFDB_WITH_FIRESTORE=ON',
        if (wantsStorage) '-DFDB_WITH_STORAGE=ON',
        if (hasNinja) ...['-G', 'Ninja'],
      ]);
    }

    // --config is required by multi-config generators (the Visual Studio
    // default on Windows), which ignore CMAKE_BUILD_TYPE and would otherwise
    // build Debug while everything here expects Release. Single-config
    // generators accept and ignore it.
    await _run('cmake', [
      '--build',
      buildDir,
      '--config',
      'Release',
      '--parallel',
    ]);

    final libFile = _findBuiltLibrary(buildDir, input.config.code.targetOS);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi/firebase_ffi_asset.dart',
        linkMode: DynamicLoadingBundled(),
        file: libFile.uri,
      ),
    );

    for (final dir in ['src', 'include']) {
      final d = Directory('$nativeRoot/$dir');
      if (!d.existsSync()) continue;
      for (final entity in d.listSync(recursive: true)) {
        if (entity is! File) continue;
        final p = entity.path;
        if (p.endsWith('.cpp') || p.endsWith('.c') || p.endsWith('.h')) {
          output.dependencies.add(entity.uri);
        }
      }
    }
    output.dependencies.add(Uri.file('$nativeRoot/CMakeLists.txt'));

    stderr.writeln('libfirebase_ffi built: ${libFile.path}');
  });
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    stderr.writeln(r.stdout);
    stderr.writeln(r.stderr);
    throw ProcessException(exe, args, 'exited ${r.exitCode}', r.exitCode);
  }
}

Future<bool> _which(String exe) async => await _lookupOnPath(exe) != null;

bool _isClang(String path) =>
    path.split(Platform.pathSeparator).last.toLowerCase().contains('clang');

/// The C++ driver beside a C driver: clang -> clang++, gcc -> g++, keeping any
/// cross prefix and directory. Falls back to the C driver when the name follows
/// no known convention, which is no worse than what CMake would be handed.
String _cxxDriverFor(String cc) {
  final sep = Platform.pathSeparator;
  final i = cc.lastIndexOf(sep);
  final dir = i == -1 ? '' : cc.substring(0, i + 1);
  var name = i == -1 ? cc : cc.substring(i + 1);

  // A Windows driver is `clang.exe`; strip the extension before matching and
  // put it back, or the substitution silently does nothing there.
  var ext = '';
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    ext = name.substring(dot);
    name = name.substring(0, dot);
  }

  for (final pair in const [
    ['clang++', 'clang'],
    ['g++', 'gcc'],
    ['c++', 'cc'],
  ]) {
    if (name.endsWith(pair[1])) {
      return '$dir${name.substring(0, name.length - pair[1].length)}'
          '${pair[0]}$ext';
    }
  }
  return cc;
}

/// Whether [cxx] can compile a C++20 translation unit that pulls in the system
/// headers this project actually uses.
Future<bool> _canCompileCxx20(String cxx) async {
  final dir = await Directory.systemTemp.createTemp('fdb_probe_');
  try {
    final src = File('${dir.path}/probe.cpp')
      ..writeAsStringSync(
        '#include <string>\n#include <atomic>\n'
        '#include <mutex>\nint main() { return 0; }\n',
      );
    final r = await Process.run(cxx, [
      '-std=c++20',
      '-c',
      src.path,
      '-o',
      '${dir.path}/probe.o',
    ]);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The first of [names] that exists on PATH, as an absolute path.
Future<String?> _firstOnPath(List<String> names) async {
  for (final name in names) {
    final found = await _lookupOnPath(name);
    if (found != null) return found;
  }
  return null;
}

/// Resolves [exe] against PATH without shelling out.
///
/// `which` does not exist on Windows and `where` behaves differently, so the
/// lookup is done here: walking PATH is the one form that works everywhere,
/// and it avoids a process per probe.
Future<String?> _lookupOnPath(String exe) async {
  final path = Platform.environment['PATH'];
  if (path == null) return null;
  // PATHEXT is what makes `cmake` resolve to `cmake.exe`; elsewhere the name
  // is used as given.
  final exts = Platform.isWindows
      ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD').split(';')
      : const [''];
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    for (final ext in exts) {
      final candidate = File('$dir${Platform.pathSeparator}$exe$ext');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

/// A user-define that must be a string, or absent.
String? _stringDefine(BuildInput input, String key) {
  final value = input.userDefines[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException(
      'hooks.user_defines.firebase_ffi.$key must be a string',
    );
  }
  return value;
}

/// The shared library CMake produced, named and placed per platform.
///
/// The name differs by OS, and a multi-config generator — the Visual Studio
/// default on Windows — puts output in a per-configuration subdirectory rather
/// than the build root. Both are searched instead of assuming the Linux shape.
File _findBuiltLibrary(String buildDir, OS os) {
  final names = switch (os) {
    OS.windows => const ['firebase_ffi.dll', 'libfirebase_ffi.dll'],
    OS.macOS || OS.iOS => const ['libfirebase_ffi.dylib'],
    _ => const ['libfirebase_ffi.so'],
  };
  final dirs = [buildDir, '${buildDir}Release/', '${buildDir}RelWithDebInfo/'];
  for (final dir in dirs) {
    for (final name in names) {
      final f = File('$dir$name');
      if (f.existsSync()) return f;
    }
  }
  throw StateError(
    'no built library for $os: looked for ${names.join(", ")} in '
    '${dirs.join(", ")}',
  );
}
