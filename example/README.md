<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Firebase workbench

A Firebase console for desktop and embedded Linux, where the official plugins
have no implementation and the web console is not reachable from the device
you care about.

* **Project** — the options the app connected with, and which products the
  native library was built with.
* **Auth** — sign in anonymously or with a custom token, and see the uid every
  other page is acting as.
* **Realtime Database** — a node, watched live, with set, update, push, remove,
  and the `onDisconnect` registration that makes a device's absence visible.
* **Firestore** — a collection filtered at the server, with a JSON editor for
  the selected document, merge writes and a count.
* **Storage** — objects in and out of the bucket by path, with metadata and a
  download URL. Local paths rather than a file dialog, because boards do not
  have one.
* **Functions** — a callable by name with a JSON argument, and what it answered.
* **Remote Config** — defaults, fetch and activate as separate steps, and where
  each value came from.
* **App Check** — a custom provider standing in for the device's own attestation,
  and the tokens it mints.

Everything the pages do is written against the ordinary plugins —
`firebase_auth`, `cloud_firestore`, `firebase_storage` and the rest. The only
lines that would not appear in the same app on Android are the `registerWith()`
calls at the top of [`lib/main.dart`](lib/main.dart) and the `*_ffi` entries in
[`pubspec.yaml`](pubspec.yaml).

## Running it

```
flutter run -d linux
```

The first screen asks where the project comes from:

* **the emulator suite** — nothing to configure and no credentials. From
  `packages/firebase_ffi`:

  ```
  firebase emulators:start --project fdb-emulator \
    --only auth,database,firestore,storage,functions
  ```

* **a real project** — the path to a `google-services.json` from the Firebase
  console. Read at startup rather than compiled in, so the same build can be
  pointed at staging or at a customer's project by dropping a different file
  beside it.

It needs a build with the Firebase C++ SDK — see [pointing an example at the
SDK](../packages/firebase_ffi/README.md#pointing-an-example-at-the-sdk), with
every product selected. Until then the Project page says the build has no
Firebase, and so does every call.

## On a board

`.emb/` is the emb manifest: the board profiles, and the SDK augment that
cross-builds Firebase into the sysroot. The native library comes from
`firebase_ffi`'s build hook as a code asset rather than from an embedder
plugin, which is what lets this run on an embedder with no plugin support.

```
emb cross ../ivi-homescreen --target rpi5-trixie --build --no-verify \
    --backend drm-kms-egl --app . --mode release \
    --deploy user@raspberrypi.local --deploy-dir firebase-demo
```

## The other examples

* [`packages/firebase_ffi/example`](../packages/firebase_ffi/example) — the
  binding directly, one `dart run` program per product.
* `packages/*_ffi/example/` — `flutter test` walks each plugin's surface,
  including what it does not bind.
