# firebase_ffi

Firebase Realtime Database and Authentication for Dart and Flutter through a
single FFI code asset, with no platform channel and no embedder plugin.

The Firebase C++ SDK is linked into one shared library that Dart calls
directly. Snapshots come back through `Dart_PostCObject_DL` as
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

`bin/bench.dart` and `runBenchmarks()` reproduce the table.

## Requirements

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

## Usage

```dart
import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/google_services.dart';

// Reads the console's google-services.json. Desktop Linux has no config file
// of its own, so the Android one is what the SDK is configured from.
final cfg = GoogleServicesConfig.load();  // $GOOGLE_SERVICES_JSON, or ./google-services.json

initDatabase(
  appId: cfg.appId,
  apiKey: cfg.apiKey,
  projectId: cfg.projectId,
  databaseUrl: cfg.databaseUrl,
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
| `signInAnonymously()`, `signInWithCustomToken(token)` | both async; throw `AuthException` carrying the SDK's code and message |
| `restoredUid()`, `currentUid()`, `signOut()` | session restored from the secure store, current uid, sign out |
| `GoogleServicesConfig.load([path])` | parse `google-services.json` |
| `hasFirebase` | false in a `with_firebase: false` build |

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

## Platform support

| platform | state |
| --- | --- |
| Linux x86-64 | tested, host and `emb --target local` |
| Linux aarch64 | tested on a Raspberry Pi 5, cross-built with emb |
| Windows, macOS | not tested; the C ABI is portable but the CMake has only been exercised on Linux |
| Android, iOS, web | unsupported — use the official FlutterFire plugins |

## License

Apache 2.0. See [LICENSE](LICENSE).
