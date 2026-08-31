<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# firebase_ffi

Firebase for Dart and Flutter through a single FFI code asset, with no platform
channel and no embedder plugin. Built for embedded Linux, where the official
plugins have no implementation.

| package | |
| --- | --- |
| [`firebase_ffi`](packages/firebase_ffi) | The native library and its own Dart API: Realtime Database, Cloud Firestore, Cloud Storage and Authentication. Pure Dart — no Flutter dependency. |
| [`firebase_core_ffi`](packages/firebase_core_ffi) | `firebase_core` for Linux. Everything else registers through it. |
| [`firebase_auth_ffi`](packages/firebase_auth_ffi) | `firebase_auth` for Linux: anonymous and custom-token sign-in. |
| [`firebase_storage_ffi`](packages/firebase_storage_ffi) | `firebase_storage` for Linux: objects, metadata, download URLs. |
| [`cloud_firestore_ffi`](packages/cloud_firestore_ffi) | `cloud_firestore` for Linux: documents, with the tagged value types. |

The four `*_ffi` packages implement FlutterFire's `*_platform_interface`
contracts and register themselves on Linux, so an app depends on the ordinary
plugins and its code does not change:

```yaml
dependencies:
  firebase_core: ^4.0.0
  cloud_firestore: ^6.0.0
  firebase_core_ffi:
    path: ../firebase_core_ffi     # registers on Linux
  cloud_firestore_ffi:
    path: ../cloud_firestore_ffi
```

```dart
await Firebase.initializeApp(options: /* … */);
await FirebaseFirestore.instance.doc('probe/one').set({'hello': 'world'});
```

Anything not bound throws the platform interface's own `UnimplementedError`,
naming the method — so what is missing says so rather than being silently
absent. Queries, transactions and batches are the largest such gap today.

The Firebase C++ SDK is linked into one shared library that Dart calls
directly, so every product shares one `firebase::App` and one credential.
Products are opt-in per app: an app that does not name Firestore does not carry
its 23 MB of gRPC, protobuf and abseil.

See [`packages/firebase_ffi/README.md`](packages/firebase_ffi/README.md) for
usage, the API, platform support and how the SDK is built.

## Repository layout

`firebase_ffi` is pure Dart and must stay that way: a command-line consumer
should not inherit Flutter to write a byte to the Realtime Database.
Implementing the platform interfaces requires Flutter, so the implementations
are separate packages rather than libraries inside one. They all share the
single native library, and therefore one `firebase::App` and one credential.

## Testing

CI runs the bindings and the façade against the Firebase emulator suite on
every pull request, which is the only part of this that exercises a real
backend without credentials:

```
scripts/run_emulator_tests.sh          # the bindings
scripts/run_facade_emulator_tests.sh   # firebase_auth and cloud_firestore
```

Storage is the exception. Desktop Storage in the C++ SDK builds every request's
host from compile-time constants, so it cannot be pointed at an emulator at
all; its round trip is a live test against a real bucket, run by hand with
`FDB_LIVE_STORAGE=1`.

## License

Apache 2.0. See [LICENSE](LICENSE).
