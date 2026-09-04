#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# The example tours, against the emulator suite.
#
# What this proves that the façade tests do not: the code a reader is pointed
# at runs. Every gap a tour names is exercised, so a binding that closes one
# fails here until the tour stops calling it unimplemented.
#
# Each example's pubspec must already name an SDK — see ci.yml's "Point the
# examples at the SDK", which does that the same way it does for the packages.
# Without it a tour reports no Firebase SDK and skips, which is a pass.
set -euo pipefail

cd "$(dirname "$0")/.."

. scripts/emulator_config.sh

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

# The emulator config lives with the package whose rules it carries.
config=$(emulator_config "$PWD/packages/firebase_ffi")

cd packages/firebase_ffi
exec firebase emulators:exec \
  --config "$config" \
  --project fdb-emulator \
  --only auth,database,firestore,storage,functions \
  "cd ../firebase_core_ffi/example && flutter test --reporter=expanded && \
   cd ../../firebase_auth_ffi/example && flutter test --reporter=expanded && \
   cd ../../firebase_database_ffi/example && flutter test --reporter=expanded && \
   cd ../../cloud_firestore_ffi/example && flutter test --reporter=expanded && \
   cd ../../firebase_storage_ffi/example && flutter test --reporter=expanded && \
   cd ../../cloud_functions_ffi/example && flutter test --reporter=expanded && \
   cd ../../firebase_remote_config_ffi/example && flutter test --reporter=expanded && \
   cd ../../firebase_app_check_ffi/example && flutter test --reporter=expanded"
