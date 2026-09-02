#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# Assert that this project's translation units export only the fdb_ C ABI.
#
# Every impl file sits inside one extern "C" block, where C language linkage
# suppresses mangling -- so a helper in an anonymous namespace is still
# exported under its plain name. firebase_impl.cpp and firestore_impl.cpp both
# defined g_next_txn, and the link failed with "multiple definition".
#
# The obvious check -- look for a name defined twice -- does not work, and it
# is worth saying why: it only finds the collision in a build that compiles
# both files, which is exactly the build that already fails at link time. A
# product selection without Firestore compiles neither pair and reports
# nothing. So this checks the property that holds regardless of which products
# are selected: nothing but the ABI leaves these objects.
#
# The fix for a finding is extern "C++" { namespace { ... } } around the
# helper.
#
#   check_exported_symbols.sh <cmake-build-dir>
set -euo pipefail

builddir="${1:?usage: check_exported_symbols.sh <cmake-build-dir>}"

# This project's objects only: the vendored C in the same library -- TinyCBOR,
# zlib, dart_api_dl -- exports plenty of names on purpose, and they are not
# ours to police.
objs=$(find "$builddir" -path "*firebase_ffi.dir/src/*.o" 2>/dev/null | sort)
if [ -z "$objs" ]; then
  echo "::error::no firebase_ffi objects under $builddir"
  exit 1
fi

status=0
for o in $objs; do
  leaked=$(nm -g --defined-only "$o" 2>/dev/null \
    | awk '{print $3}' \
    | grep -vE '^fdb_' \
    | grep -vE '^_' \
    | grep -vE '^DW\.' \
    | sort -u || true)
  if [ -n "$leaked" ]; then
    echo "::error::$(basename "$o") exports names outside the fdb_ ABI"
    printf '  %s\n' $leaked
    status=1
  else
    echo "  $(basename "$o"): ABI only"
  fi
done

if [ "$status" -ne 0 ]; then
  echo
  echo "Wrap the helper in extern \"C++\" { namespace { ... } }. Inside the"
  echo "extern \"C\" block an anonymous namespace alone does not make a name"
  echo "internal, so it is exported and can collide with another translation"
  echo "unit that chose the same name."
fi
exit "$status"
