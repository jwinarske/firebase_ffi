// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// firebase_app_check, unchanged, with a custom provider. Nothing here mentions
// firebase_ffi except the provider registration, which is Linux-only by
// necessity: it takes a Dart callback, and no cross-platform parameter can
// carry one.
//
// No backend. A custom provider's token is the App Check token -- the desktop
// SDK returns it unchanged -- so the whole path is checkable offline. What a
// real project would add is the debug provider's exchange, which is the part
// that stays uncovered.
//
// FIREBASE_EMULATOR_HOST stands in for "this build linked Firebase".
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if ((Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '').isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — App Check façade tests skipped');
    return;
  }

  DateTime later() => DateTime.now().add(const Duration(hours: 1));
  var asked = 0;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    FirebaseAppCheckFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'nothing-here-reaches-a-backend',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: 'fdb-app-check',
      ),
    );

    FirebaseAppCheckFfi.useCustomProvider(() async {
      asked++;
      return AppCheckTokenResult(
        token: 'device-$asked',
        expirationTime: later(),
      );
    });
    await FirebaseAppCheck.instance.activate();
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('the token an app reads is the one the device supplied', () async {
    final token = await FirebaseAppCheck.instance.getToken(true);
    expect(token, 'device-$asked');
  });

  test('a token result carries its expiry', () async {
    final r = await FirebaseAppCheck.instance.getTokenResult(true);
    expect(r!.token, isNotEmpty);
    expect(r.expirationTime!.isAfter(DateTime.now()), isTrue);
  });

  test('a limited-use token is not served from the cache', () async {
    await FirebaseAppCheck.instance.getToken(true);
    final before = asked;
    final token = await FirebaseAppCheck.instance.getLimitedUseToken();

    // The whole point of a limited-use token: it is minted for one use rather
    // than handed out from whatever is cached.
    expect(asked, greaterThan(before));
    expect(token, 'device-$asked');
  });

  test('auto refresh is accepted', () async {
    await expectLater(
      FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(false),
      completes,
    );
  });
}
