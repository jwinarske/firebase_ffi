<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# firebase_ffi

Firebase for Dart and Flutter through a single FFI code asset, with no platform
channel and no embedder plugin. Built for embedded Linux, where the official
plugins have no implementation.

| package | |
| --- | --- |
| [`firebase_ffi`](packages/firebase_ffi) | The native library and its own Dart API: Authentication, Realtime Database, Cloud Firestore, Cloud Storage, Cloud Functions, Remote Config and App Check. Pure Dart — no Flutter dependency. |
| [`firebase_core_ffi`](packages/firebase_core_ffi) | `firebase_core` for Linux. Everything else registers through it. |
| [`firebase_auth_ffi`](packages/firebase_auth_ffi) | `firebase_auth` for Linux: anonymous and custom-token sign-in. |
| [`firebase_storage_ffi`](packages/firebase_storage_ffi) | `firebase_storage` for Linux: objects, metadata, download URLs. |
| [`cloud_firestore_ffi`](packages/cloud_firestore_ffi) | `cloud_firestore` for Linux: documents, with the tagged value types. |
| [`cloud_functions_ffi`](packages/cloud_functions_ffi) | `cloud_functions` for Linux: callables by name. |
| [`firebase_remote_config_ffi`](packages/firebase_remote_config_ffi) | `firebase_remote_config` for Linux: defaults, values and their source. |
| [`firebase_app_check_ffi`](packages/firebase_app_check_ffi) | `firebase_app_check` for Linux: the debug provider, or a token the device supplies itself. |
| [`firebase_database_ffi`](packages/firebase_database_ffi) | `firebase_database` for Linux: values, queries, child events, transactions, onDisconnect. |

The eight `*_ffi` packages implement FlutterFire's `*_platform_interface`
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
absent. Firestore's queries, cursors, transactions, batches and `count()` are
all there; what is still unbound is walked through by each package's example
tour — `FieldValue` sentinels and `DocumentReference.update`, `sum` and
`average`, `User.getIdToken`, Storage listing, streaming callables, Remote
Config's update listener, and the Database's exclusive cursors.

The Firebase C++ SDK is linked into one shared library that Dart calls
directly, so every product shares one `firebase::App` and one credential.
Products are opt-in per app: an app that does not name Firestore does not carry
its 23 MB of gRPC, protobuf and abseil.

See [`packages/firebase_ffi/README.md`](packages/firebase_ffi/README.md) for
usage, the API, platform support and how the SDK is built.

## Examples

| | |
| --- | --- |
| [`example/`](example) | One Flutter window over all eight products: sign in, browse and edit both databases, move objects in and out of Storage, call a function, read Remote Config, mint an App Check token. `flutter run -d linux` |
| [`packages/firebase_ffi/example/`](packages/firebase_ffi/example) | The binding directly, one program per product. `dart run example/firestore.dart` |
| `packages/*_ffi/example/` | The smallest app that reaches the SDK, and a tour of what that package binds and what it does not. `flutter run -d linux`, `flutter test` |

All of it runs against the local emulator suite with no project and no
credentials, or against whatever `google-services.json` names.

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

Storage reaches the emulator too, through `useStorageEmulator`: the façade
suite above uploads, downloads, reads metadata and takes a download URL from
it. What the emulator cannot answer for is a real bucket's behaviour — its
tokens, its rules, its quotas — so the live round trip is still there, run by
hand with `FDB_LIVE_STORAGE=1`.

## License

Apache 2.0. See [LICENSE](LICENSE).
