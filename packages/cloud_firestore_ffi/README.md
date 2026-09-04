# cloud_firestore_ffi

The `cloud_firestore` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `cloud_firestore` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  cloud_firestore: any
  firebase_core_ffi:
    path: ../firebase_core_ffi   # registers on Linux
  cloud_firestore_ffi:
    path: ../cloud_firestore_ffi
```

## What it covers

Documents with their tagged value types — timestamps, geopoints, references,
blobs — queries, listeners, transactions, batches, `FieldValue` sentinels,
`update()`, and the `count()`, `sum()` and `average()` aggregates.

`sum()` and `average()` need the SDK patch this repository carries; without it
the C++ SDK offers `Count()` alone.

Cursors of both kinds: the value overloads, and the document ones, which cut a
page at a snapshot. `FieldPath.documentId` works in a `where` too — it is an
enum rather than a `FieldPath`, and reaches the SDK as the protocol's own
`__name__`.

## What it does not

Offline persistence, bundles, named queries and the index manager: the desktop
SDK has no local cache to configure or clear.

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
