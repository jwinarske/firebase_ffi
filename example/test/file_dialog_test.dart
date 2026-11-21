// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_ffi_demo/src/file_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const flatpak = {
    'FLATPAK_ID': 'io.example.App',
    'HOME': '/home/u',
    'XDG_RUNTIME_DIR': '/run/user/1000',
  };

  test('out of a flatpak every path reaches the host', () {
    expect(reachesHost('/tmp/x', environment: const {}), isTrue);
  });

  test('in a flatpak, the app directory and the document portal do', () {
    expect(
      reachesHost(
        '/home/u/.var/app/io.example.App/data/x',
        environment: flatpak,
      ),
      isTrue,
    );
    expect(
      reachesHost('/run/user/1000/doc/abc/x.bin', environment: flatpak),
      isTrue,
    );
  });

  test('in a flatpak, anywhere else is the sandbox\'s own copy', () {
    expect(reachesHost('/home/u/x.bin', environment: flatpak), isFalse);
    expect(reachesHost('/tmp/x.bin', environment: flatpak), isFalse);
    // Another app's directory is not this one's.
    expect(
      reachesHost('/home/u/.var/app/io.example.Other/x', environment: flatpak),
      isFalse,
    );
  });
}
