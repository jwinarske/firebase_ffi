// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Finding the native library when the dynamic loader cannot.
///
/// The bindings are `@Native` externals bound to the code asset
/// `hook/build.dart` emits, so the VM resolves them through its asset table.
/// That table records the bare soname and hands it to `dlopen`, and for a name
/// with no slash glibc searches:
///
///   1. `DT_RPATH` of the calling object and of whatever loaded it — unless
///      that object has `DT_RUNPATH`, which disables RPATH for it entirely.
///   2. `LD_LIBRARY_PATH`.
///   3. `DT_RUNPATH` of the calling object alone. Not inherited.
///   4. `/etc/ld.so.cache`, then the default directories.
///
/// The calling object is the embedder's engine, not the runner. Flutter's GTK
/// engine carries `RUNPATH $ORIGIN` and sits beside the library in the
/// bundle's `lib/`, so step 3 finds it. An embedder whose engine is linked
/// without either tag — ivi-homescreen, desktop-homescreen — falls through to
/// step 4 and fails; the runner's own `$ORIGIN/lib` does not save it, because
/// RUNPATH never applies to a `dlopen` made by a different object.
///
/// [ensureLibraryLoaded] closes that hole by finding the file itself and
/// opening it by absolute path. The soname is registered by that open, so the
/// VM's later bare `dlopen` returns the object already loaded instead of
/// searching again. The bindings are untouched, and the hot path keeps
/// `@Native` rather than `lookupFunction` indirection.
///
/// It deliberately does not go looking in `.dart_tool/hooks_runner/`. Under
/// `dart run` and `dart test` the VM resolves the asset by absolute path
/// already, and opening a sibling build from there would load the library
/// twice — which a transport-only build survives and one with gRPC inside
/// does not.
///
/// It never throws. Every path it knows is a guess about someone else's
/// layout, and the VM may still resolve the asset by a route this does not
/// model — so a failure here is silence, and the VM's own error is what a
/// caller sees.
library;

import 'dart:ffi';
import 'dart:io';

/// The platform's name for the library, as the hook emits it.
String get _libName => switch (true) {
  _ when Platform.isMacOS => 'libfirebase_ffi.dylib',
  _ when Platform.isWindows => 'firebase_ffi.dll',
  _ => 'libfirebase_ffi.so',
};

/// The directory Flutter stages a code asset under, named for the OS.
String _osDirectory() => switch (true) {
  _ when Platform.isMacOS => 'macos',
  _ when Platform.isWindows => 'windows',
  _ => 'linux',
};

bool _done = false;

/// Where the library was found, for diagnostics. Null until something loads.
String? loadedLibraryPath;

/// Loads the native library if the dynamic loader would not find it.
///
/// Called from every entry point that can be the first to touch a native
/// symbol — the `has*` getters and the `init*` functions — so an app never has
/// to know it exists. Idempotent and cheap after the first call.
void ensureLibraryLoaded() {
  if (_done) return;
  _done = true;

  final override = Platform.environment['FIREBASE_FFI_LIB'];
  if (override != null && override.isNotEmpty) {
    if (_tryOpen(override)) return;
  }

  // The loader's own search, which is what the VM is about to do. When this
  // works there is nothing to fix, and nothing below runs.
  try {
    DynamicLibrary.open(_libName);
    loadedLibraryPath = _libName;
    return;
  } on Object {
    // Fall through to the layouts the loader cannot reach.
  }

  for (final path in _candidates()) {
    if (_tryOpen(path)) return;
  }
}

bool _tryOpen(String path) {
  final file = File(path);
  if (!file.existsSync()) return false;
  try {
    DynamicLibrary.open(file.absolute.path);
    loadedLibraryPath = file.absolute.path;
    return true;
  } on Object {
    return false;
  }
}

Iterable<String> _candidates() sync* {
  final name = _libName;

  // Beside a library the embedder has already mapped. Flutter embedders load
  // libapp.so and their engine from the bundle's lib/, which is where the hook
  // stages this one, so this is what fixes an embedder with no RUNPATH.
  final sibling = _siblingOfMappedLibrary(name);
  if (sibling != null) yield sibling;

  // Bundle layouts, relative to the script and to the executable. Flutter
  // stages a code asset under flutter_assets/native_assets/<os>/ as well as
  // in the bundle's lib/, and an embedder may carry either.
  final staged = 'flutter_assets/native_assets/${_osDirectory()}';
  try {
    final scriptDir = File.fromUri(Platform.script).parent.path;
    for (final root in [scriptDir, '$scriptDir/..', '$scriptDir/../..']) {
      yield '$root/lib/$name';
      yield '$root/data/$staged/$name';
      yield '$root/$staged/$name';
    }
  } on Object {
    // Platform.script is not always a file URI; skip it when it is not.
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final root in [exeDir, Directory.current.path]) {
    yield '$root/lib/$name';
    yield '$root/$name';
    yield '$root/data/$staged/$name';
    yield '$root/$staged/$name';
  }

  // Named directories, opened by absolute path: an embedder that ignores
  // LD_LIBRARY_PATH for its own dlopen still tells us where to look.
  for (final dir in (Platform.environment['LD_LIBRARY_PATH'] ?? '').split(
    ':',
  )) {
    if (dir.isNotEmpty) yield '$dir/$name';
  }
}

/// A directory that already has a bundled library mapped into this process.
///
/// Reads `/proc/self/maps`, preferring directories that look like a bundle's
/// `lib/` — the engine and the AOT snapshot live there — over anything else
/// mapped from disk.
String? _siblingOfMappedLibrary(String name) {
  if (!Platform.isLinux) return null;
  try {
    final maps = File('/proc/self/maps');
    if (!maps.existsSync()) return null;

    final seen = <String>{};
    final preferred = <String>[];
    final rest = <String>[];
    for (final line in maps.readAsLinesSync()) {
      final space = line.lastIndexOf(' ');
      if (space < 0) continue;
      final path = line.substring(space + 1);
      if (!path.startsWith('/')) continue;
      final slash = path.lastIndexOf('/');
      if (slash <= 0) continue;
      final dir = path.substring(0, slash);
      if (!seen.add(dir)) continue;
      final base = path.substring(slash + 1);
      if (dir.endsWith('/lib') ||
          base == 'libapp.so' ||
          base.startsWith('libflutter')) {
        preferred.add(dir);
      } else {
        rest.add(dir);
      }
    }
    for (final dir in [...preferred, ...rest]) {
      if (File('$dir/$name').existsSync()) return '$dir/$name';
    }
  } on Object {
    // An unreadable /proc is not worth reporting: this is one guess of several.
  }
  return null;
}
