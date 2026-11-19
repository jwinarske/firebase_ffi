# cloud_functions_ffi

The `cloud_functions` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `cloud_functions` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  cloud_functions: any
  firebase_core_ffi: ^0.1.0   # registers on Linux
  cloud_functions_ffi: ^0.1.0
```

## What it covers

Callables by name or by URL, in any number of regions, with a limited-use App
Check token when asked for. Arguments and results cross as CBOR, so a nested
map arrives as itself rather than as JSON text.

A named app has its own Functions: `FirebaseFunctions.instanceFor(app: second)`
calls as whoever is signed in on that app. Deleting the app waits up to five
seconds for its calls, blocking while it does. It throws, and leaves the app
in place, if one outlasts the wait.

## What it does not

Streaming callables: the desktop SDK has no streaming call. The `timeout`
option is not applied either, the SDK takes none.

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
