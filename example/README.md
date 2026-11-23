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
  download URL. A local path, because boards have no file dialog; where the
  desktop has one, Open and Save as fill it in.
* **Functions** — a callable by name with a JSON argument, and what it answered.
* **Remote Config** — defaults, fetch and activate as separate steps, and where
  each value came from.
* **App Check** — a custom provider standing in for the device's own attestation,
  and the tokens it mints.

Everything the pages do is written against the ordinary plugins —
`firebase_auth`, `cloud_firestore`, `firebase_storage` and the rest. The only
lines that would not appear in the same app on Android are the `registerWith()`
calls at the top of [`lib/main.dart`](lib/main.dart), the `*_ffi` entries in
[`pubspec.yaml`](pubspec.yaml), and the desktop file dialog for
`google-services.json` in [`lib/src/config_file.dart`](lib/src/config_file.dart).

## Running it

This repository builds with [emb](https://github.com/toyota-connected/emb_cli),
and `.emb/` here is the manifest for this app. From this directory:

```
# once: build the Firebase C++ SDK augment into the workspace overlay
emb cross . --target local --prepare -D FIREBASE_WITH_FIRESTORE=ON -w <workspace>

# build the embedder, assemble the bundle, and run it
emb cross ../../ivi-homescreen --target local --build --backend wayland-egl \
    --app . --mode debug --run -w <workspace>
```

`--prepare` takes this manifest, because all it needs is the `cross:` block and
its augments; `--build` takes the embedder's source, and `--app .` is what
points it back here. Pass `-w`, or emb takes the current directory as its
workspace and leaves a `.config/` of SDK sources inside the repository.

On emb 0.3.6 and earlier the local target does not inject the overlay through
its toolchain file, so `firebase_sdk` in `pubspec.yaml` still has to name it —
see [pointing an example at the
SDK](../packages/firebase_ffi/README.md#pointing-an-example-at-the-sdk). emb
stages the code asset into the bundle's `lib/` beside the engine and into
`flutter_assets/native_assets/linux/`, and neither the runner nor the engine
carries an RPATH, so the library is found by the search in
`firebase_ffi/lib/src/internal/library_loader.dart`.

Plain Flutter is the fallback when there is no emb workspace:

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

  The Database rules there want a caller who is signed in, under `demo/`:
  sign in on the Auth page first.

* **a real project** — the path to a `google-services.json` from the Firebase
  console. Read at startup rather than compiled in, so the same build can be
  pointed at staging or at a customer's project by dropping a different file
  beside it. Left blank, it is `$GOOGLE_SERVICES_JSON`, then
  `google-services.json` in the working directory, then in
  `$XDG_CONFIG_HOME` (`~/.config`). On a desktop with xdg-desktop-portal,
  **Browse** opens the desktop's file dialog.

Either way it needs a build with the Firebase C++ SDK, with every product
selected. Until then the Project page says the build has no Firebase, and so
does every call.

## On a board

`.emb/` is the emb manifest: the board profiles, and the SDK augment that
cross-builds Firebase into the sysroot, from the patch set in
`packages/firebase_ffi/patches/`. The native library comes from
`firebase_ffi`'s build hook as a code asset rather than from an embedder
plugin, which is what lets this run on an embedder with no plugin support.

Take `with_firebase: false` out of `pubspec.yaml` first, or the board gets the
transport-only library and every page says the build has no Firebase. The
cross toolchain finds the SDK in the sysroot, so `firebase_sdk` isn't needed.

```
emb cross ../../ivi-homescreen --target rpi5-trixie --build --no-verify \
    --backend drm-kms-egl -D FIREBASE_WITH_FIRESTORE=ON --app . \
    --mode release --deploy user@raspberrypi.local --deploy-dir firebase-demo
```

A board has a path field and no file dialog. Put `google-services.json` in
`~/.config/` on the board and the connect screen finds it.

The Auth session is kept by the SDK through libsecret, which needs a Secret
Service with an unlocked collection. A headless board usually has neither:
gnome-keyring may start on demand, but nothing unlocks its login keyring, so
the save fails with `Cannot create an item in a locked collection` in the log
and the user signs in again on every start. Unlocking the keyring at login
with `pam_gnome_keyring` fixes it; so does a login keyring with no password,
which leaves the session's refresh token unencrypted on disk.

## As a flatpak

`package.flatpak` in `.emb/base.emb.yaml` is the app's flatpak: its id, the
freedesktop runtime it runs on, and the sandbox. With the overlay built as
above:

```
emb cross ../../ivi-homescreen --target local --backend wayland-egl \
    --app . --build --flatpak -D FIREBASE_WITH_FIRESTORE=ON -w <workspace>
```

emb compiles with the host's toolchain and copies the result into the
flatpak, so the host has to be older than the runtime. A host newer than the
runtime builds a bundle that does not start: `version 'GLIBC_2.43' not found`
from a Fedora 44 build on 25.08. CI builds it on ubuntu-24.04 and keeps the
bundle as an artifact of the emb workflow. Building against the runtime's own
SDK instead is
[emb_cli#335](https://github.com/toyota-connected/emb_cli/issues/335).

The sandbox has the network, a display and the GPU, and nothing else:

* No filesystem. A path like `~/google-services.json` is not there inside the
  sandbox. **Browse** goes through the FileChooser portal, which gives the
  app the one file picked and nothing else. Or copy it to
  `~/.var/app/io.github.jwinarske.FirebaseFfiDemo/config/`, the sandbox's
  `$XDG_CONFIG_HOME`, where it is found without asking. The Storage page
  works the same way: Open for a file to upload, Save as for where a
  download goes. A typed path outside the app's directory is refused for a
  download: the sandbox would accept the write into its own copy of that
  directory and drop it when the app quits.
* No `org.freedesktop.secrets`. The Auth session is kept by libsecret in a
  file of the app's own under `~/.var/app/<id>/data/keyrings/`, encrypted with
  a key from the Secret portal. Another flatpak cannot read it, and this one
  cannot read the user's keyring.

The emulator suite on the host is reachable as `127.0.0.1`, since the sandbox
shares the host's network.

## The other examples

* [`packages/firebase_ffi/example`](../packages/firebase_ffi/example) — the
  binding directly, one `dart run` program per product.
* `packages/*_ffi/example/` — `flutter test` walks each plugin's surface,
  including what it does not bind.
