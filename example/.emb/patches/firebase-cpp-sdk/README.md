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

The rest sit in `linux/`.

Patches are applied **sorted by filename across both directories**, not
directory by directory. The numbering is a dependency order — each patch's
hunks are cut against a tree with the earlier ones applied — so applying all of
`common/` before a platform's would reorder them and fail on context.

Windows is still refused: `FIREBASE_CPP_INSTALL` bails on MSVC, the archive
glob looks for `*.a` rather than `*.lib`, and MSVC needs archives repeated or
combined rather than a link group.
