#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# Builds and installs the Firebase C++ SDK that this package links against.
#
# The SDK ships no install rules and does not build unmodified on current
# toolchains, so this applies the patch set under example/.emb/patches — the
# same one the emb augment uses, kept in one place rather than duplicated for
# CI.
#
# Patches are muxed by platform: common/ applies everywhere, then the directory
# for the target platform. Which of the current patches are portable is not yet
# known, so they all sit under linux/ where they are verified, rather than being
# assumed common and failing somewhere else.
#
# Usage: scripts/build_firebase_sdk.sh <install-prefix> [source-cache-dir]
#   FIREBASE_SDK_PLATFORM overrides the detected platform (linux|macos|windows).
#
# Idempotent: if the prefix already contains the CMake package config, it does
# nothing, so a restored cache short-circuits the build.

set -euo pipefail

SDK_VERSION="${FIREBASE_SDK_VERSION:-13.12.0}"
PREFIX="${1:?usage: build_firebase_sdk.sh <install-prefix> [source-dir]}"
SRC_ROOT="${2:-${TMPDIR:-/tmp}/firebase-sdk-src}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_ROOT="$REPO_ROOT/example/.emb/patches/firebase-cpp-sdk"

detect_platform() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
  esac
}
PLATFORM="${FIREBASE_SDK_PLATFORM:-$(detect_platform)}"

if [ -f "$PREFIX/lib/cmake/firebase_cpp_sdk/firebase_cpp_sdk-config.cmake" ]; then
  echo "firebase-cpp-sdk already installed at $PREFIX"
  exit 0
fi

# The SDK generates headers with cmake/version_header.py, which imports absl.
# Checked here because the failure is otherwise a ModuleNotFoundError from a
# Python script invoked inside a CMake custom command, 13% into a 40 minute
# build, naming nothing that suggests a missing pip package.
if ! "${PYTHON:-python3}" -c "import absl" >/dev/null 2>&1; then
  echo "error: the Firebase SDK build needs the Python package absl-py" >&2
  echo "       install it with: ${PYTHON:-python3} -m pip install absl-py" >&2
  exit 1
fi

mkdir -p "$SRC_ROOT"
SRC="$SRC_ROOT/firebase-cpp-sdk-$SDK_VERSION"

if [ ! -d "$SRC" ]; then
  echo "==> fetching firebase-cpp-sdk $SDK_VERSION"
  curl -fsSL \
    "https://github.com/firebase/firebase-cpp-sdk/archive/refs/tags/v$SDK_VERSION.tar.gz" \
    -o "$SRC_ROOT/sdk.tar.gz"
  tar -xzf "$SRC_ROOT/sdk.tar.gz" -C "$SRC_ROOT"
  rm -f "$SRC_ROOT/sdk.tar.gz"

  echo "==> applying patches for $PLATFORM"
  # Ordered by filename across both directories, not directory-by-directory:
  # the numbering is a dependency order, and a later patch's hunks are cut
  # against a tree with the earlier ones already applied. Applying all of
  # common/ before the platform's would reorder them and fail on context.
  #
  # A platform with no patches of its own is not an error here; that shows up
  # later at configure or link, where the missing piece is actually visible.
  patches=$(
    for dir in common "$PLATFORM"; do
      [ -d "$PATCH_ROOT/$dir" ] || continue
      for p in "$PATCH_ROOT/$dir"/*.patch; do
        [ -e "$p" ] && printf '%s\t%s\n' "$(basename "$p")" "$p"
      done
    done | sort -k1,1 | cut -f2
  )
  applied=0
  for p in $patches; do
    echo "    $(basename "$(dirname "$p")")/$(basename "$p")"
    patch -p1 -d "$SRC" -i "$p"
    applied=$((applied + 1))
  done
  echo "==> applied $applied patch(es)"
fi

# Only the products this package binds: App comes along with any of them.
#
# Not merely a build-time saving. Firestore's vendored CMakeLists sets
# cmake_policy(SET CMP0058 OLD), which CMake 4 refuses outright — so on any host
# with a CMake 4 (Homebrew ships one; Ubuntu 24.04 still ships 3.28) the SDK
# cannot configure at all with Firestore included. Excluding what is unused
# removes that, and the Database-on-desktop path pulls LevelDB in on its own.
echo "==> configuring"
# CMAKE_POLICY_VERSION_MINIMUM: the SDK's pinned dependencies declare
# cmake_minimum_required below what CMake 4 accepts.
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DFIREBASE_CPP_INSTALL=ON \
  -DFIREBASE_USE_BORINGSSL=ON \
  -DFIREBASE_INCLUDE_LIBRARY_DEFAULT=OFF \
  -DFIREBASE_INCLUDE_AUTH=ON \
  -DFIREBASE_INCLUDE_DATABASE=ON \
  ${FIREBASE_EXTRA_CMAKE_ARGS:-}

echo "==> building"
# Bounded: the SDK's dependency graph will otherwise start more compilers than
# a runner has memory for and get them OOM-killed.
JOBS="${FIREBASE_BUILD_JOBS:-2}"
cmake --build "$SRC/build" --config Release --parallel "$JOBS"

echo "==> installing to $PREFIX"
cmake --install "$SRC/build" --config Release

test -f "$PREFIX/lib/cmake/firebase_cpp_sdk/firebase_cpp_sdk-config.cmake" \
  || { echo "install did not produce the CMake package config"; exit 1; }
echo "==> done"
