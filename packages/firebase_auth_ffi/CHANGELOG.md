# Changelog

## Unreleased

### Added

- Account management on `User`: `reload`, `updateDisplayName`,
  `updatePhotoURL`, `updatePassword`, `sendEmailVerification`,
  `verifyBeforeUpdateEmail`, `linkWithCredential`, `unlink`,
  `reauthenticateWithCredential` and `delete`. And
  `FirebaseAuth.sendPasswordResetEmail`. A call given `ActionCodeSettings`
  throws `UnimplementedError`: the desktop SDK takes none.
- `userChanges` reports the user again after `reload`, a profile update, a
  link or an unlink.
- `createUserWithEmailAndPassword` and `signInWithEmailAndPassword`.
- `signInWithCredential`, for password, Google, Facebook, GitHub and Twitter
  credentials, and any other `OAuthCredential` as generic OAuth: Apple,
  Microsoft, Yahoo. A credential that lacks what its provider needs fails as
  `invalid-credential`. Phone, Game Center, Play Games and email-link
  credentials throw `UnimplementedError`.

### Changed

- An instance for a named app throws `UnsupportedError`. `firebase_core_ffi`
  can create one now, and this package serves only the default app.
- `FirebaseAuthException.code` is the code the other `firebase_auth` platforms
  report -- `invalid-custom-token`, `wrong-password`, `user-disabled` -- in
  place of the SDK's `AuthError` number as a string. The table is the
  FlutterFire Windows plugin's. An error it does not name is `unknown-error`,
  with the number kept in the message. Code that compared `code` against a
  number has to change.

### Fixed

- `authStateChanges`, `idTokenChanges` and `userChanges` are driven by the
  SDK's listeners. They were one stream fed by the sign-in and sign-out calls
  that passed through this package, so a session restored from the secure
  store was never announced and a refreshed token never reported. Each now
  starts with the current state, as on other platforms; before, a listener
  heard nothing until the next sign-in or sign-out. `userChanges` reports what
  `idTokenChanges` does, because no profile update is bound.
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
