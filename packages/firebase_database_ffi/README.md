# firebase_database_ffi

The `firebase_database` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_database` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_database: any
  firebase_core_ffi:
    path: ../firebase_core_ffi   # registers on Linux
  firebase_database_ffi:
    path: ../firebase_database_ffi
```

## What it covers

Values, queries, child events, transactions, `onDisconnect`, priorities and
`keepSynced`.

## What it does not

`startAfter` and `endBefore` have no exclusive form in the C++ SDK, and
there is no on-disk cache to enable or size.

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
