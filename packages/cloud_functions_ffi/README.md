# cloud_functions_ffi

The `cloud_functions` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `cloud_functions` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  cloud_functions: any
  firebase_core_ffi:
    path: ../firebase_core_ffi   # registers on Linux
  cloud_functions_ffi:
    path: ../cloud_functions_ffi
```

## What it covers

Callables by name. Arguments and results cross as CBOR, so a nested map
arrives as itself rather than as JSON text.

## What it does not

Calling by URI, streaming callables, and a second region in one process.
Each is refused rather than approximated — see the library documentation for
why in each case.

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
