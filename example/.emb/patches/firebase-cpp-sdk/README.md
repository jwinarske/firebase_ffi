# firebase-cpp-sdk patches

Muxed by platform. A build applies `common/` first, then the directory for the
platform it targets.

| directory | applies to |
| --- | --- |
| `common/` | every platform |
| `linux/` | desktop Linux (x86-64 and aarch64) |
| `macos/` | macOS |
| `windows/` | Windows |

Everything currently sits in `linux/`. That is a statement about what has been
*verified*, not about what is inherently Linux-specific: these were written and
tested against desktop Linux, and whether each one is needed — or even applies
— elsewhere is not yet known. A patch moves up to `common/` once a platform
build proves it belongs there, rather than being assumed portable and failing
in a way that has to be diagnosed through a linker.

One is certainly not portable: `0004-Add-install-rules-for-the-desktop-Linux-SDK`
refuses the other platforms outright —

    if(NOT DESKTOP OR MSVC OR APPLE)
      "FIREBASE_CPP_INSTALL is only implemented for desktop Linux builds; "

— and additionally globs `*.a` (Windows uses `.lib`), bakes `-Wl,--start-group`
into the exported target and the pkg-config file, and hardcodes
`-lsecret-1 -luuid -lpthread`. macOS and Windows each need their own install
rules, which is the reason this directory is split by platform rather than
carrying one list.
