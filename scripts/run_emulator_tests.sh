#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# Run the binding tests against the Firebase emulator suite.
#
# CI otherwise builds and links without ever calling the SDK, and that is where
# the bugs have been: a use-after-free in a Storage completion callback crashed
# two runs in three and no build could have found it.
#
#   scripts/run_emulator_tests.sh            # needs firebase-tools + a JDK
#
# The rules mirror production in the one way that matters here: they require an
# authenticated caller, so a binding that loses the credential fails rather
# than passing against an open emulator.
set -euo pipefail

cd "$(dirname "$0")/../packages/firebase_ffi"

if ! command -v firebase >/dev/null 2>&1; then
  echo "firebase-tools not found: npm i -g firebase-tools" >&2
  exit 127
fi
if ! command -v java >/dev/null 2>&1; then
  echo "a JDK is required by the Firestore and Database emulators" >&2
  exit 127
fi
# firebase-tools refuses anything older, and its own message arrives only after
# the emulators have been downloaded.
jver=$(java -version 2>&1 | sed -nE '1s/.*"([0-9]+).*/\1/p')
if [ -n "$jver" ] && [ "$jver" -lt 21 ]; then
  echo "firebase-tools needs JDK 21 or newer; this is $jver" >&2
  exit 127
fi

export FIREBASE_EMULATOR_HOST="${FIREBASE_EMULATOR_HOST:-127.0.0.1}"
export FIREBASE_AUTH_EMULATOR_PORT="${FIREBASE_AUTH_EMULATOR_PORT:-9099}"
export FIREBASE_DATABASE_EMULATOR_PORT="${FIREBASE_DATABASE_EMULATOR_PORT:-9000}"
export FIREBASE_FIRESTORE_EMULATOR_PORT="${FIREBASE_FIRESTORE_EMULATOR_PORT:-8080}"
export FIREBASE_FUNCTIONS_EMULATOR_PORT="${FIREBASE_FUNCTIONS_EMULATOR_PORT:-5001}"

# emulators:exec runs the command with the suite up and tears it down after,
# propagating the command's exit status -- so a failed test fails the job
# rather than leaving emulators running.
exec firebase emulators:exec \
  --project fdb-emulator \
  --only auth,database,firestore,functions \
  "dart test test/emulator --reporter=expanded"
