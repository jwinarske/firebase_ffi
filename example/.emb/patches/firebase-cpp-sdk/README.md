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

The rest sit in `linux/`. That is a statement about what has been *verified*,
not about what is inherently Linux-specific: whether each is needed, or even
applies, elsewhere is not yet known. A patch moves up to `common/` when a
platform build proves it belongs there, rather than being assumed portable and
failing in a way that has to be diagnosed through a linker.

Patches are applied **sorted by filename across both directories**, not
directory by directory. The numbering is a dependency order — each patch's
hunks are cut against a tree with the earlier ones applied — so applying all of
`common/` before a platform's would reorder them and fail on context.

Windows is still refused: `FIREBASE_CPP_INSTALL` bails on MSVC, the archive
glob looks for `*.a` rather than `*.lib`, and MSVC needs archives repeated or
combined rather than a link group.
