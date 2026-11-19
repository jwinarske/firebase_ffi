# Changelog

## Unreleased

### Added

- `Firebase.initializeApp(name:)` creates a named app with its own native
  `firebase::App`, and `delete()` on it works. It was refused.
  `firebase_auth_ffi`, `firebase_storage_ffi` and `cloud_functions_ffi` serve
  a named app; the other products do not yet.

### Changed

- The example imports `package:material_ui` in place of
  `package:flutter/material.dart`, which Flutter 3.50 deprecates. It needs
  Flutter 3.47 or later.

## 0.1.1

### Fixed

- A project with no Realtime Database initializes. `databaseURL` reaches the
  binding as null rather than as an empty string, which is what the console
  writes for a project that has none.

### Changed

- Requires `firebase_ffi` ^0.1.1, which carries the config fix above and the
  Windows Database fix.
- The README installs from pub.dev rather than from a path.

## 0.1.0

First release. Prototype: the API follows the platform interface, but the
binding underneath is young and what it refuses may change.

### Added

- `FirebaseCoreFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_core` reaches the Firebase C++ SDK unchanged.
