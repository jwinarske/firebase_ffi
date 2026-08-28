// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Native assets build hook for firebase_ffi.
//
// Drives native/CMakeLists.txt to produce libfirebase_ffi.so and declares it
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

    final hasNinja = await _which('ninja');

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
      final cached = RegExp(r'^CMAKE_CXX_COMPILER:\w+=(.*)$', multiLine: true)
          .firstMatch(cacheFile.readAsStringSync())
          ?.group(1)
          ?.trim();
      final cachedPrefix =
          RegExp(r'^CMAKE_PREFIX_PATH:\w+=(.*)$', multiLine: true)
              .firstMatch(cacheFile.readAsStringSync())
              ?.group(1)
              ?.trim();
      final prefixChanged =
          sdkPrefix != null && cachedPrefix != null && cachedPrefix != sdkPrefix;
      if ((cached != null && cached != cxx) || prefixChanged) {
        stderr.writeln(
          'firebase_ffi: cached CMake compiler $cached differs from $cxx; '
          'reconfiguring from scratch.',
        );
        await Directory(buildDir).delete(recursive: true);
        await Directory(buildDir).create(recursive: true);
      }
    }

    if (!File('${buildDir}CMakeCache.txt').existsSync()) {
      await _run('cmake', [
        '-S', nativeRoot,
        '-B', buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        if (cc != null) '-DCMAKE_C_COMPILER=$cc',
        if (cxx != null) '-DCMAKE_CXX_COMPILER=$cxx',
        if (ar != null) '-DCMAKE_AR=$ar',
        if (sdkPrefix != null) '-DCMAKE_PREFIX_PATH=$sdkPrefix',
        if (withFirebase == false) '-DFDB_WITH_FIREBASE=OFF',
        if (hasNinja) ...['-G', 'Ninja'],
      ]);
    }

    await _run('cmake', ['--build', buildDir, '--parallel']);

    final libFile = File('${buildDir}libfirebase_ffi.so');
    if (!libFile.existsSync()) {
      throw StateError('libfirebase_ffi.so not found at ${libFile.path}');
    }

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

Future<bool> _which(String exe) async =>
    (await Process.run('which', [exe])).exitCode == 0;

bool _isClang(String path) => path.split(Platform.pathSeparator).last.contains('clang');

/// The C++ driver beside a C driver: clang -> clang++, gcc -> g++, keeping any
/// cross prefix and directory. Falls back to the C driver when the name follows
/// no known convention, which is no worse than what CMake would be handed.
String _cxxDriverFor(String cc) {
  final sep = Platform.pathSeparator;
  final i = cc.lastIndexOf(sep);
  final dir = i == -1 ? '' : cc.substring(0, i + 1);
  final name = i == -1 ? cc : cc.substring(i + 1);
  for (final pair in const [['clang++', 'clang'], ['g++', 'gcc'], ['c++', 'cc']]) {
    if (name.endsWith(pair[1])) {
      return '$dir${name.substring(0, name.length - pair[1].length)}${pair[0]}';
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
      ..writeAsStringSync('#include <string>\n#include <atomic>\n'
          '#include <mutex>\nint main() { return 0; }\n');
    final r = await Process.run(
      cxx,
      ['-std=c++20', '-c', src.path, '-o', '${dir.path}/probe.o'],
    );
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
    final r = await Process.run('which', [name]);
    if (r.exitCode == 0) {
      final path = (r.stdout as String).trim();
      if (path.isNotEmpty) return path;
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
