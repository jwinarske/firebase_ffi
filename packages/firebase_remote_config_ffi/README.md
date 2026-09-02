# firebase_remote_config_ffi

The `firebase_remote_config` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_remote_config` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_remote_config: any
  firebase_core_ffi:
    path: ../firebase_core_ffi   # registers on Linux
  firebase_remote_config_ffi:
    path: ../firebase_remote_config_ffi
```

## What it covers

Defaults, fetch and activate, typed reads, settings, and where a value came
from — default or server.

## What it does not

Real-time config updates. The desktop SDK has no config-update listener.

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
