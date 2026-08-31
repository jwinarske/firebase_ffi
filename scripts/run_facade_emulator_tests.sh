#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# The FlutterFire-compatible layer, against the emulator suite.
#
# What this proves that the firebase_ffi emulator tests do not: an app using
# firebase_core and firebase_auth unchanged reaches the C++ SDK. The test file
# does not mention firebase_ffi, and would not compile if this were a lookalike
# API rather than the platform interface.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v firebase >/dev/null 2>&1; then
  echo "firebase-tools not found: npm i -g firebase-tools" >&2
  exit 127
fi
jver=$(java -version 2>&1 | sed -nE '1s/.*"([0-9]+).*/\1/p')
if [ -z "$jver" ] || [ "$jver" -lt 21 ]; then
  echo "firebase-tools needs JDK 21 or newer" >&2
  exit 127
fi

export FIREBASE_EMULATOR_HOST="${FIREBASE_EMULATOR_HOST:-127.0.0.1}"
export FIREBASE_AUTH_EMULATOR_PORT="${FIREBASE_AUTH_EMULATOR_PORT:-9099}"
export FIREBASE_DATABASE_EMULATOR_PORT="${FIREBASE_DATABASE_EMULATOR_PORT:-9000}"
export FIREBASE_FIRESTORE_EMULATOR_PORT="${FIREBASE_FIRESTORE_EMULATOR_PORT:-8080}"

# The emulator config lives with the package whose rules it carries.
cd packages/firebase_ffi
exec firebase emulators:exec \
  --project fdb-emulator \
  --only auth,database,firestore \
  "cd ../firebase_auth_ffi && flutter test test/emulator_facade_test.dart --reporter=expanded && \
   cd ../cloud_firestore_ffi && flutter test test/emulator_facade_test.dart --reporter=expanded"
