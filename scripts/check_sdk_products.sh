#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# Assert that an installed Firebase C++ SDK contains the products it was asked
# for, and nothing else.
#
# build_firebase_sdk.sh selects products with FIREBASE_INCLUDE_LIBRARY_DEFAULT
# =OFF plus one flag each. Nothing checked that the result matched: an SDK
# built with the wrong set still installs, still links, and only announces
# itself later -- as a missing symbol, or as a library carrying twenty
# megabytes for products nothing references. Both have happened here.
#
#   check_sdk_products.sh <prefix> <product>...
#
# Products are the archive infixes (app, auth, database, firestore, storage).
# `app` and `rest_lib` are always expected: everything is built on them.
set -euo pipefail

prefix="${1:?usage: check_sdk_products.sh <prefix> <product>...}"
shift
expected=(app rest_lib "$@")

libdir="$prefix/lib/firebase-cpp-sdk"
if [ ! -d "$libdir" ]; then
  echo "::error::no SDK at $libdir"
  exit 1
fi

# .lib on MSVC, .a everywhere else. No -printf: that is GNU find, and this
# runs on macOS too.
found=$(find "$libdir" \( -name 'libfirebase_*.a' -o -name 'firebase_*.lib' \) 2>/dev/null \
        | sed -E 's|.*/||; s/^(lib)?firebase_//; s/\.(a|lib)$//' | sort -u)

echo "installed: $(echo "$found" | tr '\n' ' ')"
echo "expected:  ${expected[*]}"

status=0
for want in "${expected[@]}"; do
  if ! grep -qx "$want" <<<"$found"; then
    echo "::error::$want was asked for and is not installed"
    status=1
  fi
done

# The other direction matters as much: a product nothing selected is build time
# spent and, if something later links it, size in every consumer.
while read -r have; do
  [ -z "$have" ] && continue
  if ! printf '%s\n' "${expected[@]}" | grep -qx "$have"; then
    echo "::error::$have was installed and nothing asked for it"
    status=1
  fi
done <<<"$found"

if [ "$status" -eq 0 ]; then
  echo "SDK product set matches the request"
fi
exit "$status"
