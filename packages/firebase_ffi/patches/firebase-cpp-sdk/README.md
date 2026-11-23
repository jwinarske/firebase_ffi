# firebase-cpp-sdk patches

Muxed by platform. A build applies `common/` first, then the directory for the
platform it targets.

| directory | applies to |
| --- | --- |
| `common/` | every platform |
| `linux/` | desktop Linux (x86-64 and aarch64) |
| `macos/` | macOS |
| `windows/` | Windows |

The install rules (`common/0004`) apply everywhere: they were generalized once
macOS needed them, and now branch internally on the two things that actually
differ — `-Wl,--start-group`, which is GNU ld only, and the platform's secure
store, which is libsecret and libuuid on Linux and the Keychain on macOS. The
result is published through the generated package config as
`firebase_cpp_sdk_SYSTEM_LIBS`, so a consumer links what the SDK needs without
hardcoding it.

The leveldb fix (`common/0002`) was promoted on evidence, not on a guess: macOS
hit the exact failure its own commit message quotes, because the SDK's external
rules share one directory scope and leveldb inherits flatbuffers' patch file.
Its description already said "on any non-MSVC desktop build" — it was never
Linux-specific, the mux just had not been told yet.

`macos/0006` forwards `HOME` into the external-source download. Upstream
forwards it in `build_external_dependencies` but not in
`download_external_sources`, and macOS reaches CocoaPods there, which invokes
brew, which refuses to run without a home directory. Linux never notices, and
`linux/0003` already replaces that whole environment setup, so this stays
macOS-only rather than becoming a common patch that would conflict with it.

`common/0007` deletes the `git gc --aggressive` chained onto boringssl's patch
step. boringssl is fetched shallow into a throwaway build directory, so the
repack has nothing to save, and on a macOS runner it fails outright -- leaving
the stamp unwritten and the tree half-prepared, so what gets reported is a
compile error inside boringssl rather than the repack that caused it. It is
common rather than macos-only because the command has no build purpose on any
platform; the other two were not observed to fail on it.

`common/0009` stops `Repo`'s constructor abandoning setup when it cannot place
a persistence cache. The return is before `server_sync_tree_` is built and
nothing else sets it, so the Database is handed out with a null member and the
first write faults. Windows against the RTDB emulator reaches it: the url is
`http://127.0.0.1:9000/?ns=<project>`, and `AppDataDir` creates each
`/`-separated segment as a directory, so `:` and `?` — reserved in NTFS paths —
fail. The directory is read only under `if (persistence_enabled_)`, which is
off here, so the abandoned setup was over a path nothing used. Common rather
than windows-only: the null member is reachable on any platform through the
same block's other two returns.

`common/0011` makes `~UserSecureManager` wait for the scheduler. Every manager
shares one, and a task keeps a future handle into its manager until the
scheduler destroys the task, after it has run. With a second App's Auth alive
the scheduler outlives the manager being destroyed, so the handle's destructor
raced the manager's and called through a null. Deleting a named app that had
an Auth hit it, on macOS, where the Keychain is slow enough to line the two
up. Reported upstream as firebase/firebase-cpp-sdk#1969.

`common/0012` registers App Check's token functions on every App. The other
products ask for a token through the function registry of their own App, and
the SDK registered the functions on the first App to get an AppCheck only, so
a named app's requests carried no token. Reported upstream as
firebase/firebase-cpp-sdk#1970.

`common/0013` backs off between Database reconnect attempts. The SDK retried
at once, every time, and left a TODO where the backoff goes. A server that
could not be reached was retried thousands of times a second, and so was a
token that could not be fetched: a session restored from the keyring whose
refresh token the server refuses sent about 2,300 refresh requests a second,
and the writes waiting on the connection never failed, so nothing stopped it.
The waits are the Android SDK's: 1s, growing by 1.3 to 30s, jittered, and
back to none once a connection has stayed up 30s. Reported upstream as
firebase/firebase-cpp-sdk#1971.

`common/0014` keeps the host out of Firestore's dependencies. Firestore does
`find_package(re2 QUIET)`, and a distribution's `re2Config.cmake` does
`find_dependency(absl)`, so on a host with re2 and abseil installed gRPC,
protobuf and utf8_range linked that abseil instead of building their own. On
Fedora that was about a hundred `libabsl_*.so` the library needed at runtime,
and a flatpak runtime has none of them (#147). The patch stops the lookup of
re2, which gRPC builds itself either way, disables `find_package(absl)` for the
whole build so anything else that reaches for one fails at configure, and turns
off gRPC's libsystemd, which it links for server socket activation when the
host has it. `common/0004` used to
publish whatever abseil the build found; it now refuses to install one that is
not the build's own. Not upstream.

`common/0015` drops a lock from the desktop `Auth::current_user()`. It added a
listener and waited for it on every call, which takes `listeners_mutex`, to
wait out the load of the saved session. Sign-out notifies listeners holding
that mutex, and Firestore's credentials provider is one, taking its own mutex.
Firestore asks for a token holding its mutex and calls `current_user()`. A
sign-out while a listen was starting deadlocked both. Once the session has
loaded there is nothing to wait for, so the listener is skipped and the flag
that says so is atomic. Reported upstream as firebase/firebase-cpp-sdk#1972.

`common/0016` releases the Firestore core before its cleanup notifier.
`~FirestoreInternal` left both to member destruction, which destroys the
notifier first. Deleting Firestore runs the notifier's `CleanupAll()`, which
resets every Promise registered then and never runs again; the worker queue
goes on until it is disposed, and a pending write's callback moved on it
registers its Promise afresh. When the core went, that Promise unregistered
from the freed notifier: a double free on Linux, 0xC0000409 on Windows, from
deleting an App with a write in flight. Reported upstream as
firebase/firebase-cpp-sdk#1973.

`common/0017` answers a Firestore token request with no user instead of
asserting. `GetToken()` checks for a signed-in user and `RequestToken()`
asserts it again, and a sign-out on another thread can land between the two:
`SignOut()` clears the user without the provider's mutex. The assertion
aborted the process; the request is now answered as unauthenticated, as it is
when nobody was signed in. Reported upstream as
firebase/firebase-cpp-sdk#1974.

`common/0018` makes Firestore link when built with Clang. firebase-ios-sdk's
`ordered_code.h` declares `AppendBytes<INVERT>` and `index_byte_encoder.h`
calls it, but it is defined only in `ordered_code.cc`, with no explicit
instantiation. GCC happens to leave an out-of-line copy there; Clang inlines
every use in that file and emits none, and `libfirestore_core.a` keeps an
undefined reference. The SDK patches Firestore's source with
`cmake/external/firestore.patch.txt`; this adds a second patch file beside it
that instantiates both specializations, and chains it after the first. emb's
`flatpak-sdk` provider builds with Clang. Reported upstream as
firebase/firebase-ios-sdk#17105.

The rest sit in `linux/`.

Patches are applied **sorted by filename across both directories**, not
directory by directory. The numbering is a dependency order — each patch's
hunks are cut against a tree with the earlier ones applied — so applying all of
`common/` before a platform's would reorder them and fail on context.

Windows is supported as of the MSVC branch in `common/0004`: archives are
`*.lib` rather than `*.a`, credentials go through wincred in advapi32, and
MSVC's linker makes repeated passes so the archive cycles need no group
directive — there is no `--start-group` to replace there.

The Windows build follows the SDK's own `desktop.yml`: long-path support
enabled before checkout, the architecture named explicitly because the Visual
Studio generator's default varies by machine, and the MSVC runtime pinned to
static. It is built without vcpkg, like the other two platforms — the SDK
fetches its own dependencies, and `external/vcpkg` is a submodule absent from
the release tarball.
