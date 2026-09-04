# firebase_ffi

Firebase Realtime Database, Cloud Firestore, Cloud Storage and Authentication
for Dart and Flutter through a single FFI code asset, with no platform channel
and no embedder plugin.

The Firebase C++ SDK is linked into one shared library that Dart calls
directly. The wire format between C++ and Dart is **CBOR** ([RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)),
encoded natively with [TinyCBOR](https://github.com/intel/tinycbor) (MIT,
vendored under `native/third_party/`) and decoded in Dart with the
[`cbor`](https://pub.dev/packages/cbor) package (MIT). A standard format rather
than a private one: a malformed message is rejected by an implementation this
project did not write, instead of being misread by a decoder written to match
one encoder.

Snapshots come back through `Dart_PostCObject_DL` as
`kExternalTypedData`, so the payload the SDK produced is read in place rather
than copied across a channel.

> **Status: prototype.** The API is small and will change. It has been
> exercised on Linux x86-64 and aarch64 (Raspberry Pi 5) against a live
> project; the platform notes below are honest about what has and has not run.

## Why FFI rather than a platform channel

Measured on a Raspberry Pi 5, release AOT, inside a deployed bundle:

| path | p50, across runs |
| --- | --- |
| FFI call, no work (`fdb_noop`) | 56–74 ns |
| 1 KB snapshot, `kExternalTypedData` | 13.4–13.8 µs |
| 1 KB snapshot, copying post | 13.7–14.1 µs |

Zero copy saves **about 2% at 1 KB**, 9% at 16 KB and 40–54% at 256 KB. At the
payload sizes Realtime Database actually carries, zero copy is not the
argument — dispatch cost, posting safely from SDK threads, and not
regenerating a codec are. The `kExternalTypedData` path is used anyway because
it costs nothing extra to keep, but the case for FFI here does not rest on it.

`dart run firebase_ffi:bench` reproduces the table — plain Dart, no Firebase
SDK and no project, so it runs anywhere the library builds. `runBenchmarks()`
is the same thing as a function, for a caller that wants the lines rather than
stdout.

## Requirements

### Upstream status

The Firebase C++ SDK describes its desktop support as follows, in
`release_build_files/readme.md`:

> ## Desktop Workflow Implementations
>
> The Firebase C++ SDK includes desktop workflow support for the following
> subset of Firebase features, enabling their use on Windows, OS X, and Linux:
>
> *   Firebase Authentication
> *   Firebase App Check
> *   Cloud Firestore
> *   Firebase Functions
> *   Firebase Remote Config
> *   Firebase Realtime Database
> *   Firebase Storage
>
> This is a Beta feature, and is intended for workflow use only during the
> development of your app, not for publicly shipping code.

Every product this package binds is on that list. The Beta statement applies
to the desktop workflow itself, upstream, and is quoted here because it is the
ground this package stands on.

App Check is thinner on desktop than the list suggests, and it is better to say
so here than to have it found later: it has one usable provider, the debug one,
plus whatever a custom provider supplies. App Attest, DeviceCheck and Play
Integrity are stubs off iOS and Android.

Every product this package binds can be pointed at an emulator, Storage
included -- `Storage::UseEmulator` is stock in 13.12.0. Only App Check cannot;
there is no App Check emulator, so its custom provider is tested against no
backend at all.


You must supply a built Firebase C++ SDK. This package does not download or
build it — the SDK takes roughly 40 minutes to compile and needs patches on
current toolchains, so vendoring that into a build hook would be hostile.

Point at an install prefix containing `lib/cmake/firebase_cpp_sdk`:

```yaml
# pubspec.yaml of the app that depends on firebase_ffi
hooks:
  user_defines:
    firebase_ffi:
      firebase_sdk: third_party/firebase-cpp-sdk/install   # relative to this file
```

Relative paths resolve against the `pubspec.yaml` that declares them. If the
SDK is not found the build **fails at configure time** with this message
rather than quietly producing a library that fails later at runtime.

To build the transport benchmark alone, without any Firebase:

```yaml
      with_firebase: false
```

The native build also links `libsecret-1` and `uuid` (`libsecret-1-dev` and
`uuid-dev` on Debian), which the SDK requires on Linux.

### Building with emb

[emb](https://github.com/toyota-connected/emb_cli) cross targets supply the SDK
through the toolchain file they inject, so `firebase_sdk` is not needed for a
cross build. The native `local` target does the same as of
[emb_cli#184](https://github.com/toyota-connected/emb_cli/pull/184); on emb
0.3.6 and earlier it does not, so a local build there still needs the
user-define. Plain `flutter build linux` always does.

The example's [`.emb/`](https://github.com/jwinarske/firebase_ffi/tree/main/example/.emb)
carries a manifest with the SDK augment and the patches it needs — linked
rather than referenced by path, because pub excludes dot-directories, so it is
not in the published archive.

### Pointing an example at the SDK

Examples and packages ship `with_firebase: false`, so a clone resolves and
analyzes with nothing installed. Three things have to change together, or the
build silently keeps what it had:

```yaml
hooks:
  user_defines:
    firebase_ffi:
      products: [auth, database, firestore, storage, functions, remote_config, app_check]
      firebase_sdk: /path/to/firebase-cpp-sdk/install
```

```
rm -rf .dart_tool/hooks_runner build   # both, then `pub get`
```

`products` selects what the library binds — Auth and Database always, the rest
opt-in — and a product left out is an undefined symbol at the first call, not a
build error. The caches are keyed without `user_defines`, so a rewritten
pubspec alone changes nothing and the transport-only library is linked again.
CI does exactly this in ci.yml's "Point the facade packages at the SDK".

## Usage

Products are chosen per app, and an app carries only what it names:

```yaml
# pubspec.yaml
hooks:
  user_defines:
    firebase_ffi:
      products: [auth, database, firestore, storage, functions,
                 remote_config, app_check]
```

Measured on one commit, x86_64 Linux: Database and Auth alone are 14.6 MB of
shared library, Firestore adds 23.3 MB of gRPC, protobuf and abseil, and
Storage adds 382 KB. The other three were not measured. CI fails if selecting a
product changes nothing, because that would mean it was never linked.

```dart
import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:firebase_ffi/storage.dart';
import 'package:firebase_ffi/google_services.dart';

// Reads the console's google-services.json. Desktop Linux has no config file
// of its own, so the Android one is what the SDK is configured from.
final cfg = GoogleServicesConfig.load();  // $GOOGLE_SERVICES_JSON, or ./google-services.json

initDatabase(
  appId: cfg.appId,
  apiKey: cfg.apiKey,
  projectId: cfg.projectId,
  databaseUrl: cfg.databaseUrl,
  storageBucket: cfg.storageBucket,  // required before Storage is used
);
initAuth();

// A restored session first: the SDK reads its secure store asynchronously, so
// current_user() is empty for a moment after init. Signing in during that
// window mints a *new* anonymous user and discards the persisted one.
final uid = await restoredUid() ?? (await signInAnonymously()).uid;

final sub = onValue('/some/path').listen((snap) {
  print('${snap.seq}: ${snap.value}');
});
setString('/some/path', 'hello');

// Firestore: values that CBOR has no type for travel as tagged items.
initFirestore();
await setDocument('probe/doc', {
  'text': 'hello',
  'when': FirestoreTimestamp.fromDateTime(DateTime.now().toUtc()),
  'where': const FirestoreGeoPoint(51.5074, -0.1278),
  'stamp': FirestoreSentinel.serverTimestamp,
});
final doc = await getDocument('probe/doc');   // null when absent

// Storage: a download is written once, into the buffer handed to Dart.
initStorage();
await putObject('probe/blob.bin', bytes, contentType: 'application/octet-stream');
final back = await getObject('probe/blob.bin');
```

Authentication shares one `firebase::App` with the database. That is why both
live in a single shared library: two `.so` files each statically linking the
SDK would get one `App` registry apiece, and the credential would never reach
Database.

### API

| | |
| --- | --- |
| `initDatabase(...)`, `initAuth()` | create the shared `App`, then `Auth` |
| `setString(path, value)`, `onValue(path)` | write, and subscribe as a `Stream<DbSnapshot>` |
| `readSnapshot(path, query:)`, `DbSnapshot.order` | a read that keeps the query's child order; the value is a map the SDK sorts by key |
| `signInAnonymously()`, `signInWithCustomToken(token)` | both async; throw `AuthException` carrying the SDK's code and message |
| `restoredUid()`, `currentUid()`, `signOut()` | session restored from the secure store, current uid, sign out |
| `GoogleServicesConfig.load([path])` | parse `google-services.json` |
| `hasFirebase`, `hasFirestore`, `hasStorage` | whether this build bound the product |
| `initFirestore()` | bind Firestore to the shared `App` |
| `setDocument(path, map)`, `getDocument(path)`, `deleteDocument(path)` | write, read (null when absent), delete |
| `onDocument(path)` | subscribe as a `Stream<Map<String, Object?>?>` |
| `FirestoreTimestamp`, `FirestoreGeoPoint`, `FirestoreReference`, `FirestoreSentinel` | the values CBOR has no native type for |
| `initStorage()` | bind Storage; needs `storageBucket` on the app |
| `putObject(path, bytes, contentType:)`, `getObject(path)` | upload, download |
| `objectMetadata(path)`, `downloadUrl(path)`, `deleteObject(path)` | metadata as `StorageMetadata`, a tokenized URL, delete |

Every asynchronous call throws a typed exception carrying the SDK's own code
and message: `AuthException`, `FirestoreException`, `StorageException`.

### Examples

[`example/`](example) has one program per product — Auth, Database, Firestore,
Storage, Functions, Remote Config and App Check — each covering that product's
whole surface rather than one call from it. Plain Dart:

```
dart run example/database.dart
```

They run against the emulator suite with no project and no credentials, or
against whatever `google-services.json` names. See
[`example/README.md`](example/README.md).

For the same products through `firebase_auth`, `cloud_firestore` and the rest,
the repository's [demo app](../../example) is one Flutter window covering all
eight.

### This is not the FlutterFire API

The names and shapes here are this package's own. It is not a drop-in
replacement for `firebase_core`, `cloud_firestore`, `firebase_storage` or
`firebase_auth`: there is no `Firebase.initializeApp`, no
`FirebaseFirestore.instance`, no `DocumentSnapshot`, and no query or
collection API. Porting an app written against those packages means rewriting
its call sites.

## Device identity

For an appliance, prefer a custom token over anonymous auth. An anonymous
identity is defined by a cached blob, so a reflash or a corrupt keyring
destroys it along with its data. `tool/mint_custom_token.dart` signs a token
for a device uid from a service-account key:

```
dart tool/mint_custom_token.dart service-account.json device-001 token.jwt
```

Run it where the key lives — a build host or a provisioning service, never the
device. The device receives only the token: a one-hour credential for exactly
one uid.

### Persisting a session on Linux

The SDK stores credentials through libsecret and has no fallback: on
`__linux__` it is compiled in unconditionally, so a Secret Service provider is
the only supported path. Without one, every launch produces a new anonymous
uid and logs `Secret store failed`.

Headless, that means unlocking a keyring at boot with no one to type a
password:

```ini
# ~/.config/systemd/user/gnome-keyring-headless.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/gnome-keyring-daemon --daemonize --unlock --components=secrets
StandardInput=file:/home/USER/keyring.pass
StandardOutput=null
```

Two things that cost real debugging time: `--unlock` is the verb, not
`--login`, which creates the keyring but leaves the collection locked and
surfaces much later as `Cannot create an item in a locked collection`; and the
password must be fed by systemd rather than through a shell, because unit-file
escaping turns `tr -d \n` into `tr -d n`, silently stripping every *n* from
the password. An empty password does not work at all.

Whatever unlocks the store lives on the device, so this is not stronger than
the device's own security. That is inherent to unattended boot, not a flaw in
this approach — which is another argument for provisioned tokens.

### Finding the library

The bindings are `@Native` externals bound to the code asset the build hook
emits, so the VM resolves them through its asset table, which hands the bare
soname to `dlopen`. For a name with no slash the loader searches `DT_RPATH` of
the calling object and its loaders — unless that object has `DT_RUNPATH`, which
disables RPATH for it — then `LD_LIBRARY_PATH`, then `DT_RUNPATH` of the
calling object alone, then `ld.so.cache` and the default directories.

The calling object is the embedder's engine. Flutter's GTK engine has
`RUNPATH $ORIGIN` and sits beside the library in the bundle's `lib/`, so it
resolves. An engine linked with neither tag — ivi-homescreen,
desktop-homescreen — does not, and the runner's own `$ORIGIN/lib` does not help
it: RUNPATH never applies to a `dlopen` made by a different object.

So before the first native call, this package looks for the library itself and
opens it by absolute path, which registers the soname and makes the VM's later
`dlopen` find it already loaded:

1. `FIREBASE_FFI_LIB`, if set.
2. The dynamic loader's own search — when this works, nothing below runs.
3. Beside a library the embedder already mapped, read from `/proc/self/maps`:
   the engine and `libapp.so` live in the bundle's `lib/`, which is where the
   hook stages this one.
4. Bundle layouts relative to `Platform.script` and the executable — both
   `lib/` and `flutter_assets/native_assets/<os>/`, since Flutter stages a code
   asset in both and an embedder may carry either.
5. Each `LD_LIBRARY_PATH` directory, opened by absolute path — an embedder that
   ignores that variable for its own `dlopen` still tells us where to look.

It does not look under `.dart_tool/hooks_runner/`. `dart run` and `dart test`
resolve the asset by absolute path already, and opening a sibling build from
there loads the library twice — which a transport-only build survives and one
with gRPC inside does not.

Failing all of that it stays silent and lets the VM report, since every path
above is a guess about someone else's layout.

## Platform support

| platform | state |
| --- | --- |
| Linux x86-64 | tested, host and `emb --target local` |
| Linux aarch64 | tested on a Raspberry Pi 5, cross-built with emb |
| macOS 15+ (Apple silicon) | tested in CI: SDK built, linked, 19 symbols exported |
| Windows (x64, MSVC) | tested in CI: SDK built and linked |
| Android, iOS, web | unsupported — use the official FlutterFire plugins |

The Dart side, the C ABI and the build hook are platform-neutral; the hook
resolves the library by platform (`.so` / `.dylib` / `.dll`, including a
multi-config generator's `Release/` subdirectory) and looks tools up on PATH
without shelling out to `which`.

macOS artifacts require **macOS 15 or newer**: the SDK's own CMakeLists defaults
`CMAKE_OSX_DEPLOYMENT_TARGET` to 15.0 when it is not set, and nothing here
overrides it. Pass one through `FIREBASE_EXTRA_CMAKE_ARGS` when building the
SDK if an older minimum is needed.

macOS is done. The SDK's install rules publish what each platform needs as
`firebase_cpp_sdk_SYSTEM_LIBS` — libsecret and libuuid on Linux, the Keychain
through Security, CoreFoundation and Foundation on macOS — so a consumer links
them through `find_package` rather than hardcoding either set. `-Wl,--start-group`
is applied only where the linker is GNU ld; ld64 resolves the archive cycles
unaided.

Windows builds with MSVC. Archives are `*.lib` rather than `*.a`, credentials
go through wincred in advapi32, and MSVC's linker makes repeated passes so the
archive cycles need no group directive. The SDK's config also records which C
runtime its archives were compiled against, because mixing `/MT` and `/MD`
fails at link naming every object file rather than the choice.

A transport-only build (`with_firebase: false`) has none of those dependencies
and is expected to work anywhere.

## License

Apache 2.0. See [LICENSE](LICENSE).
