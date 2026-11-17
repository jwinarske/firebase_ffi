# firebase_core_ffi

The `firebase_core` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_core` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_core: any
  firebase_core_ffi: ^0.1.0   # registers on Linux
```

## What it covers

App initialization. Everything else registers through it, so an app depends
on this even when it uses only one product.

A named app can be created and deleted, and keeps its own options. No product
is bound to one yet: each `*_ffi` package serves the default app and refuses
an instance on a named app.

## Requirements

`firebase_ffi` needs a prebuilt Firebase C++ SDK — this package does not
download or build one. See its [README](../firebase_ffi/README.md) for how to
point at an install prefix.

Linux only. On any other platform the FlutterFire plugin uses its own
implementation and this package is not registered.

## License

Apache-2.0. See [LICENSE](LICENSE).
