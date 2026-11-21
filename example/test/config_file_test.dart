// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:firebase_ffi_demo/src/config_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = Platform.environment['HOME']!;

  test('a typed ~ is the home directory', () {
    expect(
      expandHome('~/a/google-services.json'),
      '$home/a/google-services.json',
    );
    expect(expandHome('~'), home);
  });

  test('anything else is left alone', () {
    expect(
      expandHome('/etc/google-services.json'),
      '/etc/google-services.json',
    );
    expect(expandHome('google-services.json'), 'google-services.json');
    // Another user's home is not ours to guess.
    expect(
      expandHome('~bob/google-services.json'),
      '~bob/google-services.json',
    );
  });
}
