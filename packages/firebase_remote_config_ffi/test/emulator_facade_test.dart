// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// firebase_remote_config, unchanged. Nothing here mentions firebase_ffi.
//
// There is no Remote Config emulator, and this needs none: defaults are
// client-side, and so are the settings, the value sources and the fetch
// status. What a real project would add is a fetch, which is exactly the part
// that stays uncovered.
//
// Runs whenever the SDK is bound, which is what FIREBASE_EMULATOR_HOST stands
// in for here -- it marks a build that linked Firebase.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_remote_config_ffi/firebase_remote_config_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  if ((Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '').isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — Remote Config façade tests skipped');
    return;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    FirebaseRemoteConfigFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'nothing-here-reaches-a-backend',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
      ),
    );
    await FirebaseRemoteConfig.instance.ensureInitialized();
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('defaults come back through the typed getters', () async {
    await FirebaseRemoteConfig.instance.setDefaults(const {
      'greeting': 'hello',
      'retries': 3,
      'ratio': 1.5,
      'enabled': true,
    });

    final rc = FirebaseRemoteConfig.instance;
    expect(rc.getString('greeting'), 'hello');
    expect(rc.getInt('retries'), 3);
    expect(rc.getDouble('ratio'), closeTo(1.5, 1e-9));
    expect(rc.getBool('enabled'), isTrue);
  });

  test('a value knows it came from a default', () async {
    await FirebaseRemoteConfig.instance.setDefaults(const {'origin': 'local'});
    expect(
      FirebaseRemoteConfig.instance.getValue('origin').source,
      ValueSource.valueDefault,
    );
  });

  test('a key with no value gives the accessor default, not an error', () {
    final rc = FirebaseRemoteConfig.instance;
    expect(rc.getString('never_set'), '');
    expect(rc.getInt('never_set'), 0);
    expect(rc.getBool('never_set'), isFalse);
    expect(rc.getValue('never_set').source, ValueSource.valueStatic);
  });

  test('getAll carries every default that was set', () async {
    await FirebaseRemoteConfig.instance.setDefaults(const {'a': 1, 'b': 'two'});
    final all = FirebaseRemoteConfig.instance.getAll();
    expect(all.keys, containsAll(<String>['a', 'b']));
    expect(all['b']!.asString(), 'two');
  });

  test('settings round trip', () async {
    await FirebaseRemoteConfig.instance.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 23),
        minimumFetchInterval: const Duration(minutes: 7),
      ),
    );
    final s = FirebaseRemoteConfig.instance.settings;
    expect(s.fetchTimeout, const Duration(seconds: 23));
    expect(s.minimumFetchInterval, const Duration(minutes: 7));
  });

  test('nothing fetched yet reports as such, not as a success', () {
    // The SDK reports success with a zero fetch time before any fetch. Passed
    // through it would tell an app a fetch worked when none happened.
    expect(
      FirebaseRemoteConfig.instance.lastFetchStatus,
      RemoteConfigFetchStatus.noFetchYet,
    );
  });
}
