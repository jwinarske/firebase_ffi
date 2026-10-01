# Changelog

## Unreleased

### Added

- `createUserWithEmailAndPassword`, `signInWithCredential` supporting Google, Apple, Facebook, Github, Twitter and generic OAuth providers with the `OAuthCredential` object.

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
