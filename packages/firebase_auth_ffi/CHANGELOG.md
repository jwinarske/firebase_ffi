# Changelog

## Unreleased

### Fixed

- `User` reports what the SDK holds: `email`, `displayName`, `photoURL`,
  `phoneNumber`, `isAnonymous`, `emailVerified`, `metadata` and `providerData`.
  Every user was `isAnonymous: true` with nothing else set, which was wrong for
  a custom token whose uid has an account behind it. Needs the `firebase_ffi`
  release that carries `currentUser()`.

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

- `FirebaseAuthFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_auth` reaches the Firebase C++ SDK unchanged.
