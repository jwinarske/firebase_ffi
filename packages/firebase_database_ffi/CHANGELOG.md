# Changelog

## Unreleased

### Added

- `FirebaseDatabase.instanceFor(app:)` on a named app. It has its own
  Database, on the app's `databaseURL`, and reads and writes as that app's
  user. Deleting the app fails its open transactions and pending writes and
  sends each listener an error.

### Changed

- The example imports `package:material_ui` in place of
  `package:flutter/material.dart`, which Flutter 3.50 deprecates. It needs
  Flutter 3.47 or later.

### Fixed

- The default app's Database could keep a disk cache, though this package
  says it has none. Whether it did was chance. It never does now.
- `runTransaction()` reported `committed: true` when its handler threw.
  Nothing had been written. It fails with what the handler threw.

## 0.1.1

### Changed

- Requires `firebase_ffi` ^0.1.1. That release stops `google-services.json`
  being rejected when the project has no Realtime Database, and fixes the first
  Database write faulting on Windows.
- The README installs from pub.dev rather than from a path.

## 0.1.0

First release. Prototype: the API follows the platform interface, but the
binding underneath is young and what it refuses may change.

### Added

- `FirebaseDatabaseFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_database` reaches the Firebase C++ SDK unchanged.
