// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_app_check on Linux: what this implementation binds, and
// what it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// firebase_app_check depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth \
//     'cd ../firebase_app_check_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
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
  FirebaseAppCheckFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final appCheck = FirebaseAppCheck.instance;
  // App Check answers "is this request coming from my app?". The attestation
  // providers Firebase ships are for phones and browsers — there is no Play
  // Integrity on a Linux board — so this implementation offers the two things
  // that are honest on desktop: the SDK's debug provider, and a token the
  // device supplies itself.

  // ── Choosing a provider ─────────────────────────────────────────────────
  _step('which provider activate() installs');
  // activate()'s providerWindows parameter is not nullable and defaults to
  // WindowsDebugProvider — named for Windows, but it describes the desktop
  // SDK's debug provider and Linux is the same SDK. So every plain activate()
  // arrives asking for debug, which is right for development and wrong for a
  // device in the field: a debug token attests to nothing until it has been
  // registered in the console by hand.
  //
  // Registering a custom provider first is what makes activate() keep it —
  // the implementation takes a custom provider over the default rather than
  // letting the default overwrite what the app deliberately chose. The
  // platform interface refuses activation with no provider at all, but the
  // plugin's own signature cannot express that, so it is not reachable from
  // here.
  _note('activate() defaults to the debug provider');
  _note('a custom provider registered first wins over that default');

  // ── A custom provider ───────────────────────────────────────────────────
  _step('a custom provider: the device supplies its own token');
  var minted = 0;
  // The callback runs whenever the SDK needs a token — first use, refresh, and
  // every limited-use token. It is asynchronous because a real one would ask a
  // TPM, a secure element, or a provisioning service.
  FirebaseAppCheckFfi.useCustomProvider(() async {
    minted++;
    return AppCheckTokenResult(
      token: 'device-token-$minted',
      expirationTime: DateTime.now().add(const Duration(hours: 1)),
    );
  });
  await appCheck.activate();
  _note('activated; the provider has been asked $minted time(s)');

  _step('getToken');
  _note('token ${await appCheck.getToken(false)}');
  // Served from the cache: the provider is not asked again while the token it
  // gave is still good.
  final before = minted;
  await appCheck.getToken(false);
  _note('a second read minted ${minted - before} more');
  _note('forceRefresh: ${await appCheck.getToken(true)}');

  _step('getTokenResult');
  final result = (await appCheck.getTokenResult(false))!;
  _note('token   ${result.token}');
  _note('expires ${result.expirationTime}');

  _step('getLimitedUseToken');
  // A limited-use token is minted for one call to a backend that redeems it,
  // so it is never served from the cache. That is the whole distinction.
  final beforeLimited = minted;
  final once = await appCheck.getLimitedUseToken();
  _note('$once, after ${minted - beforeLimited} fresh mint(s)');

  _step('onTokenChange');
  // How an app follows refreshes it did not ask for, which is what auto
  // refresh produces.
  final seen = <String?>[];
  final sub = appCheck.onTokenChange.listen(seen.add);
  await appCheck.getToken(true);
  await _until(() => seen.isNotEmpty, 'a token change');
  await sub.cancel();
  _note('the stream saw ${seen.join(', ')}');

  _step('setTokenAutoRefreshEnabled');
  // Off is the right default for a device that is usually idle: a background
  // refresh would wake a radio for a token nothing is going to use.
  await appCheck.setTokenAutoRefreshEnabled(false);
  _note('auto refresh disabled');

  // ── The debug provider ──────────────────────────────────────────────────
  _step('the debug provider, for development');
  // Not run here, because it would replace the custom provider above and its
  // token is only accepted once registered in the console under
  // App Check > Apps > Manage debug tokens:
  //
  //   await FirebaseAppCheck.instance.activate(
  //     providerWindows: WindowsDebugProvider(debugToken: '...'),
  //   );
  //
  // Passing a token that was registered once is what makes CI repeatable: the
  // generated one changes per run and would have to be registered again.
  _note(
    'activate(providerWindows: WindowsDebugProvider()) installs it — the '
    'desktop SDKs share that provider',
  );
  _note(
    'a debug token is a bearer credential for your project: it does not '
    'belong in a repository',
  );

  _step('what App Check is for');
  _note(
    'a token rides along with every Firestore, Database, Storage and '
    'Functions request once this is on',
  );
  _note(
    'enforcement is switched on per product in the console, and until it '
    'is, an unattested request still succeeds',
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

/// Polls until [ready] rather than sleeping a guessed interval: a listener's
/// first event arrives when the backend sends it, not on a schedule.
Future<void> _until(
  bool Function() ready,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void _step(String title) => print('\n── $title');
void _note(String line) => print('   $line');
