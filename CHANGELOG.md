# Changelog

## 0.1.0

First release. Prototype: the API is small and expected to change.

### Added

- Realtime Database through a single FFI code asset — no platform channel, no
  embedder plugin. `initDatabase`, `setString`, and `onValue` as a
  `Stream<DbSnapshot>`.
- Snapshots delivered with `Dart_PostCObject_DL` as `kExternalTypedData`, so
  the SDK's buffer is read in place. `firebase::Variant` is serialized to a
  tagged flat encoding and decoded in Dart.
- Authentication on the same `firebase::App` as the database: `signInAnonymously`,
  `signInWithCustomToken`, `signOut`, `currentUid`, and `restoredUid` for a
  session restored from the platform secure store. Failures throw
  `AuthException` carrying the SDK's own error code and message.
- `GoogleServicesConfig` — reads the console's `google-services.json`, which is
  what desktop Linux is configured from since it has no config file of its own.
- `tool/mint_custom_token.dart` — signs a Firebase custom token for a device
  uid from a service-account key, using `openssl` so it needs no dependencies.
- Build hook driving CMake, configured through `hooks.user_defines`:
  `firebase_sdk` for the SDK prefix (relative to the declaring `pubspec.yaml`)
  and `with_firebase: false` for a transport-only build.
- Benchmarks for the FFI call and snapshot paths, comparing
  `kExternalTypedData` against a copying post: `bin/bench.dart` and
  `runBenchmarks()`.

### Fixed

- The build hook reconfigures when a previous CMake configure failed partway.
  CMake writes `CMakeCache.txt` before it can fail, and treating that as
  "already configured" made every later run die as
  `ninja: build.ninja: No such file or directory`, long after the real error.

### Notes

- A missing SDK fails at configure time with instructions, rather than
  producing a library that fails at runtime.
- The build hook derives the C++ driver from the configured C compiler, and
  falls back to `g++` when the toolchain's clang cannot compile C++20 against
  the system libstdc++ — Flutter's Linux desktop build pins clang 18, which
  cannot parse a GCC 16 libstdc++.
- Tested on Linux x86-64 and aarch64 (Raspberry Pi 5) against a live project.
  Windows and macOS are untested.
