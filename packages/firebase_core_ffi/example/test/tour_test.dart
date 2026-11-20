// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_core on Linux: what this implementation binds, and what it
// says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because firebase_core
// depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth \
//     'cd ../firebase_core_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
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
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  // ── The options an app was initialized with ─────────────────────────────
  _step('the app and its options');
  final app = Firebase.app();
  final o = app.options;
  _note('name              ${app.name}');
  _note('projectId         ${o.projectId}');
  _note('appId             ${o.appId}');
  _note('apiKey            ${o.apiKey.substring(0, 6)}…');
  _note('messagingSenderId ${o.messagingSenderId}');
  _note('databaseURL       ${o.databaseURL ?? '<unset>'}');
  _note('storageBucket     ${o.storageBucket ?? '<unset>'}');
  // These are what every other product reads. Database takes its URL from
  // here, Storage its bucket — a product that looks unreachable is usually an
  // option that was never set.

  _step('Firebase.apps');
  final names = Firebase.apps.map((a) => a.name).join(', ');
  _note('${Firebase.apps.length} app: $names');

  // ── Initializing twice ──────────────────────────────────────────────────
  _step('initializing again');
  // Re-initializing with the same options is a no-op rather than an error,
  // which is what lets a library and an app both call it without coordinating.
  final again = await Firebase.initializeApp(options: o);
  _note('same instance back: ${identical(again.name, app.name)}');

  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: o.apiKey,
        appId: o.appId,
        messagingSenderId: o.messagingSenderId,
        projectId: 'a-different-project',
      ),
    );
    _note('different options were unexpectedly accepted');
  } on FirebaseException catch (e) {
    _note(
      'different options: ${e.code} — a silent reconfiguration would be '
      'worse than this',
    );
  }

  // ── A second app ────────────────────────────────────────────────────────
  _step('a second, named app');
  // Its own firebase::App, with its own options. Auth runs on it, with a
  // user of its own. Database, Firestore and the rest still run on the
  // default app, and each refuses an instance on a named one rather than
  // quietly using the default app's project.
  final second = await Firebase.initializeApp(
    name: 'secondary',
    options: FirebaseOptions(
      apiKey: o.apiKey,
      appId: o.appId,
      messagingSenderId: o.messagingSenderId,
      projectId: 'a-second-project',
    ),
  );
  expect(second.name, 'secondary');
  expect(Firebase.app('secondary').options.projectId, 'a-second-project');
  expect(Firebase.app().options.projectId, o.projectId);
  _note('"${second.name}" for ${second.options.projectId}');
  _note('apps: ${Firebase.apps.map((a) => a.name).join(', ')}');

  // ── Lifetime ────────────────────────────────────────────────────────────
  _step('deleting an app');
  // A named app can go. The name is free again afterwards.
  await second.delete();
  expect(Firebase.apps.map((a) => a.name), isNot(contains('secondary')));
  _note('deleted "secondary"; apps: ${Firebase.apps.length}');
  final again2 = await Firebase.initializeApp(name: 'secondary', options: o);
  await again2.delete();
  _note('and created and deleted again under the same name');

  // The default app cannot: every product holds it for the life of the
  // process.
  try {
    await app.delete();
    _note('unexpectedly deleted');
  } on UnimplementedError catch (e) {
    _note('the default app: UnimplementedError — ${e.message}');
  }

  _step('the collection toggles');
  // Off is the state this implementation is in, so asking for off succeeds and
  // asking for on says it cannot. Accepting both and doing nothing would be
  // the worst of the three.
  await app.setAutomaticDataCollectionEnabled(false);
  _note('setAutomaticDataCollectionEnabled(false) — accepted');
  try {
    await app.setAutomaticDataCollectionEnabled(true);
    _note('enabling was unexpectedly accepted');
  } on UnimplementedError catch (e) {
    _note('enabling: UnimplementedError — ${e.message}');
  }
  _note(
    'isAutomaticDataCollectionEnabled = '
    '${app.isAutomaticDataCollectionEnabled}',
  );

  _step('what this package is for');
  _note(
    'nothing above mentions firebase_ffi: firebase_core_ffi is what makes '
    'Firebase.initializeApp reach the C++ SDK on Linux',
  );
  _note('every other *_ffi package registers against the app it built');
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
      // Database is told which emulator through this URL; there is no
      // emulator call that runs before initializeApp.
      databaseURL: _databaseUrl(host),
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

/// The Database emulator's url.
///
/// The desktop SDK takes the namespace from the first label of the host and
/// ignores `?ns=`, and the emulator keeps the rules in the project's
/// `-default-rtdb` instance. libcurl resolves a `.localhost` name to loopback
/// itself, so that name reaches an emulator on this machine. An emulator on
/// another host needs a name whose first label is the namespace; given only an
/// address, the namespace is its first number and no rules apply.
String _databaseUrl(String host) {
  final port = _port('DATABASE', 9000);
  return host == '127.0.0.1' || host == 'localhost'
      ? 'http://$_emulatorProject-default-rtdb.localhost:$port'
      : 'http://$host:$port';
}

void _step(String title) => print('\n── $title');
void _note(String line) => print('   $line');
