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
# Windows defaults to a short root because MSBuild's FileTracker writes .tlog
# paths that must fit in MAX_PATH (260). Firestore nests four superbuilds deep --
# firestore-build/external/src/grpc-build/third_party/abseil-cpp/... -- and from
# %TEMP% that overshoots by a single character. `core.longpaths` does not help:
# it governs git, not MSBuild.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) _default_src_root="/c/fb" ;;
  *) _default_src_root="${TMPDIR:-/tmp}/firebase-sdk-src" ;;
esac
SRC_ROOT="${2:-$_default_src_root}"
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

# The products a consumer may bind. Everything the SDK offers is not built --
# Analytics, Messaging and the rest have no bindings here -- but Firestore is,
# because a consuming app selects its products at link time and the archives
# have to exist for it to select from. An app that does not bind Firestore does
# not link it: the linker takes only the archive members something references.
#
# This is the expensive one. Firestore drags in gRPC, protobuf and abseil, so it
# dominates both build time and the cached prefix. FIREBASE_SDK_WITH_FIRESTORE=OFF
# builds without it.
#
# Only the products this package binds: App comes along with any of them.
#
# Not merely a build-time saving. Firestore's vendored CMakeLists sets
# cmake_policy(SET CMP0058 OLD), which CMake 4 refuses outright — so on any host
# with a CMake 4 (Homebrew ships one; Ubuntu 24.04 still ships 3.28) the SDK
# cannot configure at all with Firestore included. Excluding what is unused
# removes that, and the Database-on-desktop path pulls LevelDB in on its own.
# A virtualenv the script owns, built from the SDK's own
# external/pip_requirements.txt. The SDK asks for this in as many words --
# find_program(FIREBASE_PYTHON_EXECUTABLE ... "such as one from a venv") -- and
# it beats installing into the host interpreter: no --break-system-packages, no
# guessing which packages a given SDK version wants, and the same behaviour on a
# developer machine as in CI.
VENV="$SRC_ROOT/venv"
if [ ! -x "$VENV/bin/python" ] && [ ! -x "$VENV/Scripts/python.exe" ]; then
  echo "==> creating a build virtualenv"
  "${PYTHON:-python3}" -m venv "$VENV"
fi
if [ -x "$VENV/Scripts/python.exe" ]; then
  VENV_PYTHON="$VENV/Scripts/python.exe"
else
  VENV_PYTHON="$VENV/bin/python"
fi
"$VENV_PYTHON" -m pip install --quiet --upgrade pip
"$VENV_PYTHON" -m pip install --quiet -r "$SRC/external/pip_requirements.txt"
echo "==> python: $("$VENV_PYTHON" --version), $( "$VENV_PYTHON" -m pip freeze | tr '\n' ' ')"

echo "==> configuring"
# CMAKE_POLICY_VERSION_MINIMUM: the SDK's pinned dependencies declare
# cmake_minimum_required below what CMake 4 accepts.
# Windows specifics, taken from the SDK's own desktop.yml / build_desktop.py:
#   * -A names the architecture explicitly, because the Visual Studio
#     generator's default differs between machines.
#   * MSVC_RUNTIME_LIBRARY_STATIC picks /MT over /MD. It is a whole dimension of
#     upstream's build matrix, and mixing it with a consumer built the other way
#     fails at link with symbols that look missing rather than mismatched.
#   * FIREBASE_PYTHON_HOST_EXECUTABLE has to be named on Windows.
# Expanded below as ${WINDOWS_ARGS[@]+...}: macOS ships bash 3.2, where
# expanding an empty array under `set -u` is an error rather than nothing.
# macOS: name the architecture rather than inheriting the host's, the same
# reason -A is named on Windows. The SDK's own build_desktop.py always passes
# it. FIREBASE_SDK_OSX_ARCH overrides, for a build targeting the other arch.
#
# Not set here: CMAKE_OSX_DEPLOYMENT_TARGET. The SDK defaults it to 15.0
# (CMakeLists.txt), so the artifacts require macOS 15 or newer. Lowering it is
# a deliberate choice about what the package supports, not a build detail --
# set FIREBASE_EXTRA_CMAKE_ARGS to make it.
MACOS_ARGS=()
if [ "$PLATFORM" = macos ]; then
  MACOS_ARGS=(-DCMAKE_OSX_ARCHITECTURES="${FIREBASE_SDK_OSX_ARCH:-$(uname -m)}")
fi

# Linux has two incompatible libstdc++ string/list ABIs, and the SDK defaults to
# the legacy one. Everything built on a current distribution uses the newer one,
# so leaving the default in place yields archives whose every std::string-taking
# entry point is mangled differently from the calls we make against it.
#
# The option the SDK documents is FIREBASE_USE_LINUX_CXX11_ABI, but the if()
# that acts on it reads FIREBASE_LINUX_USE_CXX11_ABI -- the declared name and
# the tested name differ, so setting the documented one alone does nothing
# (upstream's own scripts/gha/build_desktop.py sets the tested spelling). Both
# are set here: the tested one is what takes effect today, the declared one is
# what keeps working if upstream reconciles them.
LINUX_ARGS=()
if [ "$PLATFORM" = linux ]; then
  LINUX_ARGS=(
    -DFIREBASE_LINUX_USE_CXX11_ABI=ON
    -DFIREBASE_USE_LINUX_CXX11_ABI=ON
  )
fi

WINDOWS_ARGS=()
if [ "$PLATFORM" = windows ]; then
  WINDOWS_ARGS=(
    -A x64
    -DMSVC_RUNTIME_LIBRARY_STATIC=ON
    "-DFIREBASE_PYTHON_HOST_EXECUTABLE:FILEPATH=$VENV_PYTHON"
  )
fi

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  ${LINUX_ARGS[@]+"${LINUX_ARGS[@]}"} \
  ${MACOS_ARGS[@]+"${MACOS_ARGS[@]}"} \
  ${WINDOWS_ARGS[@]+"${WINDOWS_ARGS[@]}"} \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DFIREBASE_PYTHON_EXECUTABLE="$VENV_PYTHON" \
  -DFIREBASE_CPP_INSTALL=ON \
  -DFIREBASE_USE_BORINGSSL=ON \
  -DFIREBASE_INCLUDE_LIBRARY_DEFAULT=OFF \
  -DFIREBASE_INCLUDE_AUTH=ON \
  -DFIREBASE_INCLUDE_DATABASE=ON \
  -DFIREBASE_INCLUDE_STORAGE=ON \
  -DFIREBASE_INCLUDE_FIRESTORE="${FIREBASE_SDK_WITH_FIRESTORE:-ON}" \
  ${FIREBASE_EXTRA_CMAKE_ARGS:-}

echo "==> building"
# Bounded: the SDK's dependency graph will otherwise start more compilers than
# a runner has memory for and get them OOM-killed.
JOBS="${FIREBASE_BUILD_JOBS:-2}"
# --verbose: compile and link lines in the log. A build this long that fails in
# CI is otherwise a wall of percentages and one error with no command to read.
cmake --build "$SRC/build" --config Release --parallel "$JOBS" \
  ${FIREBASE_BUILD_VERBOSE:+--verbose}

echo "==> installing to $PREFIX"
cmake --install "$SRC/build" --config Release

test -f "$PREFIX/lib/cmake/firebase_cpp_sdk/firebase_cpp_sdk-config.cmake" \
  || { echo "install did not produce the CMake package config"; exit 1; }
echo "==> done"
