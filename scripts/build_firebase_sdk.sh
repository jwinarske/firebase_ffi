#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0
#
# The build lives in the package, beside the patches it applies, so that a
# consumer who installed firebase_ffi from pub can run it too:
#
#   dart run firebase_ffi:build_sdk <install-prefix>
#
# This is the same thing by the path CI and the READMEs already name.
set -euo pipefail
exec "$(dirname "$0")/../packages/firebase_ffi/tool/build_firebase_sdk.sh" "$@"
