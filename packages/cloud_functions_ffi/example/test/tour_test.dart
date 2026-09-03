// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of cloud_functions on Linux: what this implementation binds, and what
// it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// cloud_functions depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only functions \
//     'cd ../cloud_functions_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_functions_ffi/cloud_functions_ffi.dart';
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
  CloudFunctionsFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final functions = FirebaseFunctions.instance;
  if (host.isNotEmpty) {
    functions.useFunctionsEmulator(host, _port('FUNCTIONS', 5001));
    _note('pointed at the functions emulator on $host');
  }
  // The callables below are the fixtures in
  // packages/firebase_ffi/test/emulator/functions/index.js:
  //
  //   echo(data) -> {received: data}
  //   add({a, b}) -> a + b
  //   boom()     -> throws
  //
  // Against a real project, deploy equivalents or change the names here.

  // ── Arguments ───────────────────────────────────────────────────────────
  _step('what can be sent');
  // The argument is encoded as CBOR and handed to the SDK as a Variant, so the
  // function receives the shape that was sent rather than a JSON string.
  final echoed = await functions
      .httpsCallable('echo')
      .call<Map<String, dynamic>>({
        'text': 'hello',
        'n': 42,
        // A double, written in the narrowest float that holds it. Reading that
        // width back wrongly once turned 1.5 into 0.0, which is why it is here.
        'ratio': 1.5,
        'flag': true,
        'nothing': null,
        'list': [1, 'two', null],
        'nested': {'deep': true},
      });
  final received = echoed.data['received'] as Map;
  for (final e in received.entries) {
    _note(
      '${'${e.key}'.padRight(8)} '
      '${e.value.runtimeType.toString().padRight(16)} ${e.value}',
    );
  }
  _note(
    'with no argument at all: '
    '${(await functions.httpsCallable('echo').call()).data}',
  );

  // ── Results ─────────────────────────────────────────────────────────────
  _step('what can come back');
  // Not every callable answers a map. A bare number is a valid result and
  // arrives as one rather than as a single-entry envelope.
  final sum = await functions.httpsCallable('add').call({'a': 20, 'b': 22});
  _note('add(20, 22) = ${sum.data} (${sum.data.runtimeType})');

  // ── Failures ────────────────────────────────────────────────────────────
  _step('a callable that throws');
  // The type matters as much as the failure: an app catching
  // FirebaseFunctionsException on Android catches the same thing here.
  try {
    await functions.httpsCallable('boom').call();
    _note('boom() unexpectedly succeeded');
  } on FirebaseFunctionsException catch (e) {
    _note('FirebaseFunctionsException(${e.code}): ${e.message}');
  }

  _step('a name nothing is deployed under');
  try {
    await functions
        .httpsCallable('not_deployed_${DateTime.now().microsecondsSinceEpoch}')
        .call();
    _note('unexpectedly succeeded');
  } on FirebaseFunctionsException catch (e) {
    _note('reported rather than ignored: ${e.code} — ${e.message}');
  }

  // ── Regions ─────────────────────────────────────────────────────────────
  _step('regions');
  // A callable is addressed by region and the default is us-central1, so a
  // function deployed elsewhere is unreachable until an instance is asked for
  // by region.
  final eu = FirebaseFunctions.instanceFor(region: 'europe-west1');
  _note(
    'FirebaseFunctions.instanceFor(region: "europe-west1") is '
    '${eu == functions ? 'the same instance' : 'a separate instance'}',
  );
  _note(
    'useFunctionsEmulator() overrides the origin instead, which is what '
    'this tour does when FIREBASE_EMULATOR_HOST is set',
  );

  // ── The gaps ────────────────────────────────────────────────────────────
  _step('what this implementation does not bind');
  // Streaming callables need a chunked response the desktop C++ SDK does not
  // surface. Calling one names itself rather than hanging on a stream that
  // will never produce an event.
  try {
    functions.httpsCallable('echo').stream(null);
    _note('stream() was unexpectedly implemented');
  } on UnimplementedError catch (e) {
    _note('HttpsCallable.stream() -> UnimplementedError: ${e.message}');
  }
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
