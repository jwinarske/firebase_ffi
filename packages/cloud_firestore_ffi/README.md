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

## What it does not

The document-cursor overloads — `startAfterDocument()` and its siblings — take
a snapshot where the value cursors take the fields it was ordered on. The
values are bound, so paging works.

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
