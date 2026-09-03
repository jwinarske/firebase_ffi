<!-- SPDX-FileCopyrightText: 2026 Joel Winarske -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# firebase_ffi examples

Plain Dart programs, one per product, each covering that product's whole
surface rather than one call from it. [`setup.dart`](setup.dart) is the
bootstrap they share: it builds the app, signs in, and initializes what the
program asked for.

| | |
| --- | --- |
| [`auth.dart`](auth.dart) | anonymous and custom-token sign-in, the ID token, session restore, a rejected credential, sign-out |
| [`database.dart`](database.dart) | writes, listeners, child events, queries, transactions, priorities, `onDisconnect`, offline writes |
| [`firestore.dart`](firestore.dart) | documents, the tagged value types, server sentinels, queries and cursors, listeners, transactions, batches, aggregates, collection groups |
| [`storage.dart`](storage.dart) | upload, download, metadata, download URLs, deletion — with the bytes checked |
| [`functions.dart`](functions.dart) | callables, what arguments and results may be, failures, regions |
| [`remote_config.dart`](remote_config.dart) | defaults, settings, fetch and activate, where a value came from |
| [`app_check.dart`](app_check.dart) | a custom provider for a fleet, and the debug provider for development |

They need a build with the Firebase C++ SDK — see [pointing an example at the
SDK](../README.md#pointing-an-example-at-the-sdk). Without one each says so and
stops.

Against the emulator suite, which needs no project and no credentials, from
`packages/firebase_ffi`:

```
firebase emulators:exec --project fdb-emulator \
  --only auth,database,firestore,storage,functions \
  'FIREBASE_EMULATOR_HOST=127.0.0.1 dart run example/database.dart'
```

The config and the callables are in `test/emulator/`. Remote Config and App
Check have no emulator; those two say what they skip.

Against a real project, put `google-services.json` in the working directory or
point `GOOGLE_SERVICES_JSON` at one, and `dart run example/firestore.dart`.
Each program writes under one throwaway path and deletes it on the way out.

The same products through `firebase_auth`, `cloud_firestore` and the rest: the
[demo app](../../../example), and `flutter test` in each façade package's
`example/`.
