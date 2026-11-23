# Changelog

## 0.2.0

### Breaking

- Needs `firebase_ffi` 0.2.0, which builds against Firebase C++ SDK 14.2.0
  with its patch set. An SDK built for 0.1.x has to be rebuilt.

### Added

- `httpsCallableFromUrl` and `httpsCallableFromUri`.
- More than one region in a process. `FirebaseFunctions.instanceFor(region:)`
  for a second region was refused.
- `HttpsCallableOptions.limitedUseAppCheckToken` is passed to the SDK.
- `FirebaseFunctions.instanceFor(app:)` serves a named app, which calls as its
  own user. Deleting the app waits for its calls.

### Changed

- The example imports `package:material_ui` in place of
  `package:flutter/material.dart`, which Flutter 3.50 deprecates. It needs
  Flutter 3.47 or later.

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

- `CloudFunctionsFfi`, registered on Linux through `dartPluginClass`, so an app using
  `cloud_functions` reaches the Firebase C++ SDK unchanged.
