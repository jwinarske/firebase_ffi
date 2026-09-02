# firebase_app_check_ffi

The `firebase_app_check` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_app_check` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_app_check: any
  firebase_core_ffi:
    path: ../firebase_core_ffi   # registers on Linux
  firebase_app_check_ffi:
    path: ../firebase_app_check_ffi
```

## What it covers

The SDK debug provider, or a token your device supplies itself.

## What it does not

App Attest, DeviceCheck and Play Integrity are stubs off iOS and Android,
and none would mean anything on an embedded board.

A method that is not bound throws rather than returning something plausible.
Silence would be worse: an app cannot tell a value it did not get from one that
does not exist.

## Requirements

`firebase_ffi` needs a prebuilt Firebase C++ SDK — this package does not
download or build one. See its [README](../firebase_ffi/README.md) for how to
point at an install prefix.

Linux only. On any other platform the FlutterFire plugin uses its own
implementation and this package is not registered.

## License

Apache-2.0. See [LICENSE](LICENSE).
