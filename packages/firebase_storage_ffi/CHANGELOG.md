# Changelog

## Unreleased

### Added

- `list` and `listAll`.
- `putFile`.
- `writeToFile`, as a task like an upload.
- `updateMetadata`.
- `putData` and `putFile` pass all of `SettableMetadata`. Only `contentType`
  reached the object.
- Upload tasks report the SDK's progress, and `pause`, `resume` and `cancel`
  act on the transfer. They answered `false` and did nothing. A canceled
  upload fails with code `canceled` and ends in `TaskState.canceled`.
- `FirebaseStorage.instanceFor(app:)` serves a named app, on that app's own
  bucket. Deleting the app cancels its transfers.

### Changed

- `FirebaseException.code` is the code the other `firebase_storage` platforms
  report -- `object-not-found`, `unauthorized`, `unauthenticated` -- in place
  of the SDK's error number as a string. When the SDK gives no message, which
  it often doesn't, the message is the plugin's for that code. The table is
  the FlutterFire Windows plugin's. An error it does not name is `unknown`,
  with the number kept in the message. Code that compared `code` against a
  number has to change.
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

- `FirebaseStorageFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_storage` reaches the Firebase C++ SDK unchanged.
