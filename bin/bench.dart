// Standalone runner: `dart run firebase_ffi:bench` on a host, or compiled to
// an AOT snapshot for a board.
import 'package:firebase_ffi/firebase_ffi.dart';

Future<void> main() async {
  for (final line in await runBenchmarks()) {
    print(line);
  }
}
