// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// What the FFI transport costs, measured.
//
//   dart run firebase_ffi:bench
//
// Or compiled to an AOT snapshot and run on the board, which is where the
// numbers matter: p99 is a page fault or a migration, and a host will not
// reproduce it.
//
// Two channels, neither of which touches Firebase:
//
//   A   an FFI call that does nothing, and one that hands over a value — the
//       floor everything else sits on.
//   B1  a snapshot posted from an SDK thread and delivered to Dart, as
//       kExternalTypedData and again as a copy. The difference is what the
//       external handoff is worth at each size.
//
// No project, no credentials and no Firebase C++ SDK: what this measures is
// the transport, and this package's own pubspec builds it without Firebase.
// That is also why it is a plain Dart program — the numbers are the same from
// a Flutter app, and a benchmark that needs a display cannot be run over ssh
// on the board whose numbers you want.
//
// The results, and what they do and do not show, are in ../README.md.
import 'package:firebase_ffi/firebase_ffi.dart';

Future<void> main() async {
  for (final line in await runBenchmarks()) {
    print(line);
  }
}
