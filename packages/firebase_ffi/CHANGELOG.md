# Changelog

## Unreleased

### Added

- `authStateChanges()` and `idTokenChanges()`, the SDK's auth-state and
  ID-token listeners as streams of `AuthUser?`. The first event is the current
  state, held back until the SDK has finished restoring a persisted session.
  `idTokenChanges()` also reports a refreshed token, and listening to it turns
  the SDK's background refresh on.
- `signInWithCredential()`, sign-in with a provider's credential as the map
  `firebase_auth`'s `AuthCredential.asMap()` makes: password, Google,
  Facebook, GitHub, Twitter, and any other provider id as generic OAuth.
- `createUserWithEmailAndPassword()`.
- Account management on the signed-in user: `reloadUser()`, `updateProfile()`,
  `updatePassword()`, `sendEmailVerification()`, `verifyBeforeUpdateEmail()`,
  `linkWithCredential()`, `unlinkProvider()`,
  `reauthenticateWithCredential()` and `deleteUser()`. And
  `sendPasswordResetEmail()`, which needs nobody signed in.
- `auth.dart` exports `hasFirebase`.
- `initNamedApp()` and `deleteNamedApp()`, a second `firebase::App` by name.
- Auth on a named app. Every function in `auth.dart` takes `app:`, the name
  `initNamedApp()` was given; left out, it is the default app as before. Each
  app has its own user and its own `authStateChanges()` and `idTokenChanges()`.
  `deleteNamedApp()` deletes the app's Auth and ends its streams.
- Storage on a named app. Every function in `storage.dart` takes `app:` the
  same way, and each app has its own Storage on its own bucket.
  `deleteNamedApp()` cancels the app's transfers, waits up to five seconds
  for its other Storage requests, and deletes its Storage. It blocks while it
  waits, and throws `StateError` and leaves the app in place when a request
  outlasts the wait.
- Functions on a named app. `initFunctions()` and `useFunctionsEmulator()`
  take `app:`, and `CallOptions` has an `app`. Each app has its own regions
  and calls as its own user. `deleteNamedApp()` waits up to five seconds for
  the app's calls, as it does for Storage requests, and deletes its Functions.
- Firestore on a named app. Every function in `firestore.dart` takes `app:`,
  and `FirestoreBatch` takes it in its constructor. Each app reads and writes
  as its own user. `deleteNamedApp()` deletes the app's Firestore: its open
  transactions fail, whatever else was pending fails with a
  `FirestoreException`, and each listener gets an error.
- Database on a named app. Every function in `database.dart` takes `app:`,
  and `OnDisconnect` takes it in its constructor. The app needs a
  `databaseUrl`; its Database is created on first use and keeps no disk
  cache. `deleteNamedApp()` deletes the app's Database: its open transactions
  fail, a write still pending fails with a `DatabaseException`, and each
  listener gets an error. Remote Config and App Check still run on the
  default app only.
- `listObjects()`, one page of the objects and prefixes under a path.
- `putFile()`, an upload the SDK reads from disk.
- `startUpload()` and `startFileUpload()`, which answer an `UploadTask`:
  progress as the SDK reports it, and `pause()`, `resume()` and `cancel()`.
- `getFile()` and `startFileDownload()`, a download the SDK writes to disk,
  as a task of the same kind.
- `updateObjectMetadata()`, and `SettableStorageMetadata` as the `metadata`
  argument to the upload calls.
- `callFunctionAtUrl()`, a callable by its URL.
- `CallOptions`, the optional third argument to `callFunction()` and
  `callFunctionAtUrl()`: the region to call through, and a limited-use App
  Check token.
- `initFunctions()` can be called once per region, and
  `useFunctionsEmulator()` takes a `region`. A second region was ignored.
- `currentUser()` and `AuthOutcome.user` return an `AuthUser`: email, display
  name, photo URL, phone number, `isAnonymous`, `isEmailVerified`, creation and
  last sign-in times, and one `AuthUserInfo` per linked provider. A field the
  account does not have is null. Until now a sign-in answered the uid alone.

### Changed

- `keepSynced()` and `onChildEvent()` take their query as `query:`. It was
  an optional positional argument, which cannot sit beside `app:`.
- Native ABI: every `fdb_auth_*` function takes the app's name as its first
  argument, null or empty for the default app. The Dart API is unchanged for a
  caller that passes no `app:`.
- Builds against Firebase C++ SDK 14.2.0, up from 13.12.0.
  `tool/build_firebase_sdk.sh` fetches it. It carries Firestore's removal of
  the compromised eMudhra intermediate certificates from its embedded trust
  store. The Realtime Database connects through libcurl's WebSocket in place
  of uWebSockets and libuv, and every connection checks certificates against
  the system's trust store. Patch 0010 is dropped, 14.1.0 has it. An SDK
  built at 13.x has to be rebuilt.

### Fixed

- Against the Auth emulator, a token refresh and linking a password
  credential went to production and were refused. The SDK's
  `SecureTokenRequest` and `SignUpRequest` set their own hosts over the
  emulator's. SDK 14.1.0 fixed it.
- `runTransaction()` ran a handler that threw up to five times. The abort
  went to the SDK as canceled, which it retries. The handler now runs once.
- A named app's requests carried no App Check token. The SDK registered the
  token functions on the first App only. Patch 0012 registers them on every
  App. An SDK built without the patch set keeps the old behavior.
- Deleting a named app that had an Auth could crash on an SDK thread. The
  SDK destroyed the app's secure-store manager while its scheduler was still
  dropping a task of it. Patch 0011 makes the destructor wait. An SDK built
  without the patch set keeps the old behavior.
- The default app's Database kept a disk cache or not by chance. The SDK
  never initializes its persistence flag, and nothing set it. It is off now,
  as documented. A Database that had been caching to disk no longer does.
- `runDbTransaction()` completed with null when its handler threw, the same
  as a handler that aborted. It fails with what the handler threw. The
  transaction is still aborted.

## 0.1.1

### Fixed

- `GoogleServicesConfig.parse` no longer requires `firebase_url`. The console
  writes that key only once a Realtime Database exists, so a project using Auth
  or Firestore alone could not read its own config. `databaseUrl` is `String?`,
  like the bucket beside it, and `initDatabase` takes it as optional.
- Windows: linking Remote Config failed on two ICU symbols. `app/src/locale.cc`
  includes `<icu.h>` there, and `GetTimezone` is reached only from Remote
  Config, so no earlier Windows build had pulled the object in. `icu` joins the
  system libraries the SDK publishes through its package config.
- Windows: the first Realtime Database write faulted. `Repo`'s constructor
  abandoned setup when it could not create a directory named after the database
  url — against the emulator that name holds `:` and `?`, both reserved in NTFS
  paths — and returned before `server_sync_tree_` was built, leaving a null
  member behind a Database the SDK still handed out. The cache directory is now
  worked out only when persistence is enabled, which is off here.
- An app initialized with no database url is refused by the Database rather
  than accepting writes it can never deliver.

### Added

- `hooks.user_defines.firebase_ffi.debug_info` emits debug info beside the
  optimized build: a PDB under MSVC, `-g` elsewhere. Off by default.
- `platforms:` names linux, macos and windows. pub.dev inferred android and ios
  from the imports; neither can work, and on mobile the official FlutterFire
  plugins are the implementation.

### Notes

- The binding suite runs against the emulator suite on all three desktops now,
  not only Linux. Both Windows bugs above were found that way, within an hour
  of each other.

## 0.1.0

First release. Prototype: the API is small and expected to change.

### Added

- Realtime Database through a single FFI code asset — no platform channel, no
  embedder plugin. `initDatabase`, `setString`, and `onValue` as a
  `Stream<DbSnapshot>`.
- Snapshots delivered with `Dart_PostCObject_DL` as `kExternalTypedData`, so
  the SDK's buffer is read in place. `firebase::Variant` is serialized to a
  tagged flat encoding and decoded in Dart.
- Authentication on the same `firebase::App` as the database: `signInAnonymously`,
  `signInWithCustomToken`, `signOut`, `currentUid`, and `restoredUid` for a
  session restored from the platform secure store. Failures throw
  `AuthException` carrying the SDK's own error code and message.
- `GoogleServicesConfig` — reads the console's `google-services.json`, which is
  what desktop Linux is configured from since it has no config file of its own.
- `tool/mint_custom_token.dart` — signs a Firebase custom token for a device
  uid from a service-account key, using `openssl` so it needs no dependencies.
- Build hook driving CMake, configured through `hooks.user_defines`:
  `firebase_sdk` for the SDK prefix (relative to the declaring `pubspec.yaml`)
  and `with_firebase: false` for a transport-only build.
- Benchmarks for the FFI call and snapshot paths, comparing
  `kExternalTypedData` against a copying post: `bin/bench.dart` and
  `runBenchmarks()`.

### Fixed

- The build hook reconfigures when a previous CMake configure failed partway.
  CMake writes `CMakeCache.txt` before it can fail, and treating that as
  "already configured" made every later run die as
  `ninja: build.ninja: No such file or directory`, long after the real error.

### Changed

- The snapshot wire format is CBOR (RFC 8949) rather than a private tagged
  encoding: TinyCBOR on the native side, the `cbor` package on the Dart side.
  Byte strings now survive as bytes; the previous encoding had no way to
  represent them and wrote null.

- The build hook resolves the built library by target OS (`.so` / `.dylib` /
  `.dll`, including a multi-config generator's `Release/` subdirectory) and
  resolves tools on PATH directly rather than shelling out to `which`, which
  does not exist on Windows.
- Linking the Firebase C++ SDK is implemented per platform — `--start-group`
  for GNU ld's archive cycles on Linux, the frameworks ld64 needs on macOS,
  and the matching MSVC runtime on Windows. A fourth platform is refused at
  configure time with what a port needs, rather than failing inside the
  linker. A transport-only build has no such dependencies.

### Notes

- A missing SDK fails at configure time with instructions, rather than
  producing a library that fails at runtime.
- The build hook derives the C++ driver from the configured C compiler, and
  falls back to `g++` when the toolchain's clang cannot compile C++20 against
  the system libstdc++ — Flutter's Linux desktop build pins clang 18, which
  cannot parse a GCC 16 libstdc++.
- Linux is what runs against a backend: x86-64 in CI against the emulator
  suite, aarch64 (Raspberry Pi 5) by hand against a live project. macOS and
  Windows build and link in CI on every change — Windows requires MSVC, since
  the SDK's archives cannot be linked by MinGW — but nothing exercises them
  against a backend yet.
