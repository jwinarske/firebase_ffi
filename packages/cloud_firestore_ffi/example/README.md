<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# cloud_firestore_ffi example

| | |
| --- | --- |
| [`lib/main.dart`](lib/main.dart) | Writes a document and reads it back. `flutter run -d linux` |
| [`test/tour_test.dart`](test/tour_test.dart) | Documents, the tagged value types, queries and cursors, collection groups, live snapshots, transactions, batches, count(), and what is not bound. `flutter test` |

Both are ordinary `cloud_firestore`; the `registerWith()` calls are the only
Linux-specific lines.

Both need a build with the Firebase C++ SDK — see [pointing an example at the
SDK](../../firebase_ffi/README.md#pointing-an-example-at-the-sdk), with
`products: [auth, database, firestore]` here. Without one they say so at the first call.

The tour takes its project from `google-services.json`, or from the emulator
suite. From `packages/firebase_ffi`:

```
export FIREBASE_EMULATOR_HOST=127.0.0.1
firebase emulators:exec --project fdb-emulator --only auth,firestore \
  'cd ../cloud_firestore_ffi/example && flutter test'
```

With neither it skips. The app needs your own values in `FirebaseOptions` and
rules that allow an unauthenticated caller; the tour signs in.

All eight products in one window: [`example/`](../../../example).
