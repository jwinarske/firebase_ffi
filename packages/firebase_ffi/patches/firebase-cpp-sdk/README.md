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
