# Changelog

## 0.1.0

First release. Prototype: the API follows the platform interface, but the
binding underneath is young and what it refuses may change.

### Added

- `FirebaseStorageFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_storage` reaches the Firebase C++ SDK unchanged.
