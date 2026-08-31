<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# firebase_ffi

Firebase for Dart and Flutter through a single FFI code asset, with no platform
channel and no embedder plugin. Built for embedded Linux, where the official
plugins have no implementation.

| package | |
| --- | --- |
| [`packages/firebase_ffi`](packages/firebase_ffi) | The native library and its Dart API: Realtime Database, Cloud Firestore, Cloud Storage and Authentication. Pure Dart — no Flutter dependency. |

The Firebase C++ SDK is linked into one shared library that Dart calls
directly, so every product shares one `firebase::App` and one credential.
Products are opt-in per app: an app that does not name Firestore does not carry
its 23 MB of gRPC, protobuf and abseil.

See [`packages/firebase_ffi/README.md`](packages/firebase_ffi/README.md) for
usage, the API, platform support and how the SDK is built.

## Repository layout

Laid out for the FlutterFire-compatible implementation packages to come:
`firebase_core_ffi` and friends implement the `*_platform_interface` contracts
so existing apps can use `cloud_firestore` and `firebase_storage` unchanged.
Those need Flutter; `firebase_ffi` itself must not, so they are separate
packages rather than libraries inside one.

## License

Apache 2.0. See [LICENSE](LICENSE).
