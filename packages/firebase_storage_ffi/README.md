# firebase_storage_ffi

The `firebase_storage` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_storage` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_storage: any
  firebase_core_ffi: ^0.1.0   # registers on Linux
  firebase_storage_ffi: ^0.1.0
```

## What it covers

Objects, uploads and downloads of files, listings, reading and updating
metadata, download URLs, deletion, and the emulator. An upload or a download
to a file reports the SDK's progress and can be paused, resumed and canceled.

A named app has its own Storage: `FirebaseStorage.instanceFor(app: second)`
reads and writes that app's bucket, as whoever is signed in on that app.
Deleting the app cancels its transfers and waits a few seconds for its other
requests. It throws, and leaves the app in place, if one outlasts the wait.

## What it does not

`putBlob` is the web's upload and keeps the platform interface's own
`UnimplementedError`. A pause holds the transfer open; a transfer does not
survive a restart. `updateMetadata` sets fields and cannot clear one.

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
