# Changelog

## 0.1.0

First release. Prototype: the API follows the platform interface, but the
binding underneath is young and what it refuses may change.

### Added

- `FirebaseAppCheckFfi`, registered on Linux through `dartPluginClass`, so an app using
  `firebase_app_check` reaches the Firebase C++ SDK unchanged.
