#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# Assert that the emb manifest applies the same patches the build script does.
#
# There are two paths to one SDK -- scripts/build_firebase_sdk.sh globs the
# patch directories, and example/.emb/base.emb.yaml names each patch by hand.
# Only the first picks up a new patch on its own. They drifted: 0007 was added
# to common/ and the manifest went on listing 0001 through 0005, and nothing
# said so, because 0007 only fails a cold macOS build and emb builds Linux.
#
# The defines drifted once before this and cost a release-shaped bug. This is
# the same failure with a different field.
#
#   check_emb_patches.sh
set -euo pipefail

cd "$(dirname "$0")/.."
manifest="example/.emb/base.emb.yaml"
root="example/.emb/patches/firebase-cpp-sdk"

# What a Linux build applies: common/ and linux/, ordered by filename across
# both, which is the order build_firebase_sdk.sh uses.
on_disk=$(
  for dir in common linux; do
    [ -d "$root/$dir" ] || continue
    for f in "$root/$dir"/*.patch; do
      [ -e "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "patches/firebase-cpp-sdk/$dir/$(basename "$f")"
    done
  done | sort -k1,1 | cut -f2
)

status=0
# Every patch block in the manifest has to carry the same set. There is more
# than one -- the Firestore ON and OFF cells -- and they have drifted from each
# other before, so each is checked rather than just the first.
blocks=$(grep -c '^      patches:$' "$manifest" || true)
if [ "$blocks" -eq 0 ]; then
  echo "::error::no patch blocks found in $manifest"
  exit 1
fi

for n in $(seq 1 "$blocks"); do
  listed=$(awk -v want="$n" '
    /^      patches:$/ { seen++; if (seen == want) { inblock = 1; next } }
    inblock && /^        - / { sub(/^        - /, ""); print; next }
    inblock { exit }
  ' "$manifest")

  if [ "$listed" != "$on_disk" ]; then
    echo "::error::patch block $n in $manifest does not match $root"
    echo "--- manifest block $n ---"; echo "$listed"
    echo "--- on disk (common + linux) ---"; echo "$on_disk"
    diff <(echo "$listed") <(echo "$on_disk") || true
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "emb manifest patch list matches $root ($blocks block(s))"
fi
exit "$status"
