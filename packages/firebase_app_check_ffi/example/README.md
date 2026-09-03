<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# firebase_app_check_ffi example

| | |
| --- | --- |
| [`lib/main.dart`](lib/main.dart) | Registers a provider that supplies its own token. `flutter run -d linux` |
| [`test/tour_test.dart`](test/tour_test.dart) | Which provider activate() installs, a custom provider for a device that attests for itself, and cached, forced and limited-use tokens. `flutter test` |

Both are ordinary `firebase_app_check`; the `registerWith()` calls are the only
Linux-specific lines.

Both need a build with the Firebase C++ SDK — see [pointing an example at the
SDK](../../firebase_ffi/README.md#pointing-an-example-at-the-sdk), with
`products: [auth, database, app_check]` here. Without one they say so at the first call.

The tour takes its project from `google-services.json`, or from the emulator
suite. From `packages/firebase_ffi`:

```
export FIREBASE_EMULATOR_HOST=127.0.0.1
firebase emulators:exec --project fdb-emulator --only auth \
  'cd ../firebase_app_check_ffi/example && flutter test'
```

With neither it skips. The app needs your own values in `FirebaseOptions` and
rules that allow an unauthenticated caller; the tour signs in.

All eight products in one window: [`example/`](../../../example).
