# Changelog

## 0.2.1

### Fixed

- The SDK did not link when built with Clang: Firestore's `AppendBytes` is
  defined in one file and called from another with no explicit
  instantiation, and only GCC happened to emit a copy. Patch 0018
  instantiates it. An SDK built with GCC doesn't need rebuilding.

### Notes

- Building against emb's `flatpak-sdk` provider needs emb 0.8.0 or later.
  The SDK goes into an overlay beside the read-only freedesktop SDK, and
  0.8.0 is the first emb that hands a build hook that overlay.

## 0.2.0

### Breaking

- `keepSynced()` and `onChildEvent()` take their query as `query:`.
- The native ABI: `fdb_auth_*`, the App Check functions and `fdb_rc_*` take
  the app's name first. Only matters to code calling the library directly.
- Builds against Firebase C++ SDK 14.2.0 with this release's patch set. An
  SDK built for 0.1.x has to be rebuilt.

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
  listener gets an error.
- App Check on a named app. `initAppCheck()`, `appCheckToken()`,
  `limitedUseAppCheckToken()`, `setAppCheckAutoRefresh()` and
  `appCheckTokenChanges()` take `app:`. Each app has its own token, cache and
  listener. `useCustomAppCheckProviderForApps()` installs a provider whose
  callback is told which app is asking; `useCustomAppCheckProvider()` answers
  every app alike, as before. Which provider is installed stays process-wide,
  as it is in the SDK. `deleteNamedApp()` ends the app's token stream, and a
  token request still waiting on the callback fails.
- Remote Config on a named app. Every function in `remote_config.dart` takes
  `app:`. Each app has its own defaults, settings and values. The SDK
  persists an app's defaults and fetched values under its name, so an app made
  again under the name finds them. `deleteNamedApp()` waits up to five seconds
  for the app's fetch, and deletes its Remote Config.
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
- On Windows, a `debug_info` build prints why it is aborting, and the stack as
  module+offset, before the process ends. An abort there exits with 0xC0000409
  and nothing else. It takes the C runtime's abort and invalid-parameter hooks,
  which are process-wide under the DLL runtime, so a release build leaves them
  alone.

### Changed

- `keepSynced()` and `onChildEvent()` take their query as `query:`. It was
  an optional positional argument, which cannot sit beside `app:`.
- Native ABI: every `fdb_auth_*` function takes the app's name as its first
  argument, null or empty for the default app. So do `fdb_ac_init`,
  `fdb_ac_get_token`, `fdb_ac_set_auto_refresh`, `fdb_ac_limited_use_token`,
  `fdb_ac_add_listener` and `fdb_ac_remove_listener`, and every `fdb_rc_*`
  function. A custom provider's request carries the asking app's name as its
  payload. The Dart API is unchanged for a caller that passes no `app:`.
- Builds against Firebase C++ SDK 14.2.0, up from 13.12.0.
  `tool/build_firebase_sdk.sh` fetches it. It carries Firestore's removal of
  the compromised eMudhra intermediate certificates from its embedded trust
  store. The Realtime Database connects through libcurl's WebSocket in place
  of uWebSockets and libuv, and every connection checks certificates against
  the system's trust store. Patch 0010 is dropped, 14.1.0 has it. An SDK
  built at 13.x has to be rebuilt.

### Fixed

- `signOut()` could hang for good while Firestore was opening a stream. The
  SDK notifies auth listeners holding a lock that Firestore's token request
  takes in the other order. Patch 0015 drops that lock from the desktop
  `current_user()` once the saved session has loaded. An SDK built without
  the patch set keeps the old behavior.
- A sign-out while Firestore was asking for a token could abort the process
  on an SDK assertion. Patch 0017 answers the request as unauthenticated. An
  SDK built without the patch set keeps the old behavior.
- `deleteNamedApp()` on an app with a Firestore write in flight could
  corrupt the heap: a double free on Linux, 0xC0000409 on Windows. The SDK
  destroyed Firestore's cleanup notifier before the write's callback, which
  had registered with it after cleanup ran. Patch 0016 releases the callbacks
  first. An SDK built without the patch set keeps the old behavior.
- Changing `firebase_sdk`, `products` or `debug_info` in the user-defines
  rebuilt nothing. The hook reused the CMake tree configured for the old ones,
  and kept linking the SDK it found first. It now keeps the arguments of the
  last configure and starts over when they change.
- On a Linux host with abseil and re2 installed, as Fedora has with their
  `-devel` packages, the SDK build linked the host's abseil, and the library
  needed about a hundred of that host's `libabsl_*.so` at runtime. Patch 0014
  builds Firestore's dependencies from their own sources on every host, and
  drops gRPC's libsystemd. Patch 0004 no longer publishes a host abseil: an
  SDK that linked one fails at install.
- A Database that could not connect retried as fast as it could, thousands of
  times a second, for as long as the app ran. A server out of reach did it, and
  so did a session restored from the keyring whose refresh token the server
  refuses, which sent a refresh request on every attempt. Writes waiting on
  the connection still wait, as they do offline. Patch 0013 backs off between
  attempts, from 1s up to 30s. An SDK built without the patch set keeps the
  old behavior.
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
