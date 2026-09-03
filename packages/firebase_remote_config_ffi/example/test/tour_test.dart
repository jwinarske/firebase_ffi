// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_remote_config on Linux: what this implementation binds,
// and what it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// firebase_remote_config depends on Flutter and cannot load on the Dart VM
// alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth \
//     'cd ../firebase_remote_config_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_remote_config_ffi/firebase_remote_config_ffi.dart';
// Only to read google-services.json, so a real project can be reached without
// its values being pasted into this file. An app outside this repository would
// use the firebase_options.dart the FlutterFire CLI generates.
import 'package:firebase_ffi/google_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// print, because the output is the point of this program: debugPrint throttles
// it and truncates the long lines.
// ignore_for_file: avoid_print

const _emulatorProject = 'fdb-emulator';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // A test binding reports TargetPlatform.android, and firebase_core rewrites
  // emulator hosts to 10.0.2.2 there — the address an Android emulator uses
  // for its host. This implementation is the Linux one, so the tour says so.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  test('tour', _tour, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _tour() async {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  final options = _options(host);
  if (options == null) return;

  _step('registering the Linux implementation');
  // A Flutter app writes neither line: these plugins declare a
  // dartPluginClass, and Flutter's generated registrant calls it on Linux. A
  // test binding has no registrant, so the tour does it by hand.
  FirebaseCoreFfi.registerWith();
  FirebaseRemoteConfigFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final rc = FirebaseRemoteConfig.instance;
  await rc.ensureInitialized();
  _note('initialized');
  // There is no Remote Config emulator: defaults, settings and the value
  // sources all work offline, and a fetch needs a real project. The tour runs
  // everything that does not need one and says what it skipped.
  final canFetch = host.isEmpty;

  // ── Defaults ────────────────────────────────────────────────────────────
  _step('defaults: what the app runs on before any fetch');
  // Compiled-in values, so a first launch with no network behaves rather than
  // waiting. Everything a fetch can change should have one.
  await rc.setDefaults(const {
    'poll_interval_s': 30,
    'backend': 'https://api.example.com',
    'feature_x': false,
    'sample_rate': 0.25,
  });

  _note('getInt    poll_interval_s = ${rc.getInt('poll_interval_s')}');
  _note('getString backend         = ${rc.getString('backend')}');
  _note('getBool   feature_x       = ${rc.getBool('feature_x')}');
  _note('getDouble sample_rate     = ${rc.getDouble('sample_rate')}');

  _step('where a value came from');
  // An app that cannot tell a default from a fetched value cannot tell whether
  // a fetch has taken effect.
  for (final key in ['backend', 'never_set']) {
    final v = rc.getValue(key);
    _note('${key.padRight(16)} "${v.asString()}"  source ${v.source.name}');
  }
  _note(
    'a key nothing has set is not an error: it answers the type\'s zero '
    'and says its source is static',
  );

  _step('getAll');
  final all = rc.getAll();
  _note('${all.length} keys: ${all.keys.join(', ')}');

  // ── Settings ────────────────────────────────────────────────────────────
  _step('settings: how long a fetch may take, and how often one may happen');
  _note(
    'before: ${rc.settings.fetchTimeout} / ${rc.settings.minimumFetchInterval}',
  );
  // The minimum interval is the throttle: a fetch inside it is answered from
  // the last one rather than going out. Shortening it is a development
  // convenience — in production it is what stops a fleet fetching in lockstep
  // after a restart.
  await rc.setConfigSettings(
    RemoteConfigSettings(
      fetchTimeout: const Duration(seconds: 30),
      minimumFetchInterval: const Duration(minutes: 5),
    ),
  );
  _note(
    'after:  ${rc.settings.fetchTimeout} / ${rc.settings.minimumFetchInterval}',
  );

  // ── Fetch and activate ──────────────────────────────────────────────────
  _step('fetch and activate, which are two steps on purpose');
  _note('lastFetchStatus ${rc.lastFetchStatus.name}');
  // The SDK reports success with a zero fetch time before anything has been
  // fetched, which reads as a fetch that worked. This implementation reports
  // noFetchYet instead, so a caller deciding whether its values are stale has
  // an answer it can use.
  final fetched = rc.lastFetchTime.millisecondsSinceEpoch == 0
      ? '<never>'
      : '${rc.lastFetchTime}';
  _note('lastFetchTime   $fetched');

  if (!canFetch) {
    _note(
      'running against the emulator suite, which has no Remote Config: '
      'the fetch is skipped',
    );
    _note(
      'fetch() downloads; activate() makes what was downloaded the values '
      'the app reads — so a value never changes underneath a running screen',
    );
  } else {
    try {
      await rc.fetch();
      _note('fetched');
      // Activation is separate so a fetch cannot change values mid-frame. It
      // answers whether anything actually changed.
      final changed = await rc.activate();
      _note(
        changed
            ? 'activated: the fetched values are live'
            : 'activated: nothing had changed since the last activation',
      );

      final remote = rc
          .getAll()
          .entries
          .where((e) => e.value.source == ValueSource.valueRemote)
          .toList();
      _note(
        remote.isEmpty
            ? 'no key came from the backend — nothing is published for this app'
            : 'from the backend: ${remote.map((e) => e.key).join(', ')}',
      );
      for (final e in remote) {
        _note('  ${e.key.padRight(16)} ${e.value.asString()}');
      }
      _note(
        'fetchAndActivate() does both for a screen that does not care '
        'about the distinction: ${await rc.fetchAndActivate()}',
      );
      _note(
        'lastFetchStatus now ${rc.lastFetchStatus.name} at '
        '${rc.lastFetchTime}',
      );
    } on FirebaseException catch (e) {
      _note('fetch failed: ${e.code} — ${e.message}');
      _note(
        'the app keeps running on its defaults, which is the point of '
        'having them',
      );
    }
  }

  // ── The gaps ────────────────────────────────────────────────────────────
  _step('what this implementation does not bind');
  // The desktop SDK has no config-update listener, so there is nothing to
  // drive this stream. It names itself rather than being a stream that never
  // emits — which an app would read as "the config never changes".
  try {
    rc.onConfigUpdated.listen((_) {});
    _note('onConfigUpdated was unexpectedly implemented');
  } on UnimplementedError catch (e) {
    _note('onConfigUpdated -> UnimplementedError: ${e.message}');
  }
  _note(
    'poll with fetch() instead, on an interval the minimum fetch interval '
    'allows',
  );
}

// ── Where the project comes from ──────────────────────────────────────────

/// The emulator suite when [host] is set, otherwise google-services.json.
///
/// Null when there is neither, having said what to do about it: an example
/// with no backend has nothing to show, and a stack trace out of a file read
/// would not say that.
FirebaseOptions? _options(String host) {
  if (host.isNotEmpty) {
    return FirebaseOptions(
      // The emulator checks the project id and ignores the key.
      apiKey: 'emulator-does-not-check-this',
      appId: '1:1:android:1',
      messagingSenderId: '1',
      projectId: _emulatorProject,
      // Database is told which emulator and which namespace through this URL;
      // there is no emulator call that runs before initializeApp.
      databaseURL:
          'http://$host:${_port('DATABASE', 9000)}/?ns=$_emulatorProject',
      // Storage has no per-call override for its bucket: an empty one builds
      // a URL with no bucket in it, which the emulator answers slowly rather
      // than rejecting.
      storageBucket: '$_emulatorProject.appspot.com',
    );
  }
  try {
    final cfg = GoogleServicesConfig.load();
    return FirebaseOptions(
      apiKey: cfg.apiKey,
      appId: cfg.appId,
      messagingSenderId: cfg.messagingSenderId ?? '1',
      projectId: cfg.projectId,
      databaseURL: cfg.databaseUrl,
      storageBucket: cfg.storageBucket,
    );
  } on FileSystemException {
    _note('No backend to run against.');
    _note('Set FIREBASE_EMULATOR_HOST=127.0.0.1 and start the emulator suite,');
    _note(
      'or put google-services.json beside this file (or point '
      'GOOGLE_SERVICES_JSON at one).',
    );
    markTestSkipped('no emulator and no google-services.json');
    return null;
  }
}

int _port(String product, int fallback) =>
    int.tryParse(
      Platform.environment['FIREBASE_${product}_EMULATOR_PORT'] ?? '',
    ) ??
    fallback;

void _step(String title) => print('\n── $title');
void _note(String line) => print('   $line');
