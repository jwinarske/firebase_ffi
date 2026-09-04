// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_auth on Linux: what this implementation binds, and what it
// says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because firebase_auth
// depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth \
//     'cd ../firebase_auth_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
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
  FirebaseAuthFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final auth = FirebaseAuth.instance;
  if (host.isNotEmpty) {
    await auth.useAuthEmulator(host, _port('AUTH', 9099));
    _note('pointed at the auth emulator on $host');
  }

  // ── Who is signed in ────────────────────────────────────────────────────
  _step('currentUser, before anything');
  // The desktop SDK persists its session, so on a machine that has run this
  // before there is already a user here. Signing in again would mint a second
  // anonymous identity and strand the first one's data.
  _note('currentUser = ${auth.currentUser?.uid ?? '<nobody>'}');

  _step('the auth-state streams');
  final states = <String>[];
  final sub = auth.authStateChanges().listen(
    (u) => states.add(u?.uid ?? '<signed out>'),
  );
  // idTokenChanges() and userChanges() are the same stream here: this
  // implementation has no profile updates and no background token refresh to
  // report separately, so three streams that agreed by accident would be
  // worse than three that agree by construction.

  // ── Anonymous ───────────────────────────────────────────────────────────
  _step('signInAnonymously');
  final cred = await auth.signInAnonymously();
  _note('uid          ${cred.user!.uid}');
  _note('isAnonymous  ${cred.user!.isAnonymous}');
  _note(
    'currentUser is that user: '
    '${auth.currentUser?.uid == cred.user!.uid}',
  );
  _note(
    'every device gets a distinct throwaway identity, which rules cannot '
    'tell apart — fine for a prototype, not for a fleet',
  );

  // ── The ID token ────────────────────────────────────────────────────────
  _step('the ID token');
  // What an app sends to its own backend, which verifies it with the Admin SDK
  // rather than trusting a uid the client claims.
  //
  // Against the emulator this fails, and the reason is worth knowing: the
  // desktop SDK refreshes through SecureTokenRequest, which builds
  // securetoken.googleapis.com from a compile-time host and overwrites the
  // emulator URL its base class applied. Sign-in honours the emulator; a
  // refresh does not.
  try {
    final token = await cred.user!.getIdToken();
    _note('${token!.length} characters, ${token.split('.').length} JWT parts');
    final result = await cred.user!.getIdTokenResult();
    _note(
      'provider ${result.signInProvider}, expires ${result.expirationTime}',
    );
    _note('claims   ${result.claims!.keys.take(6).join(', ')}');
  } on FirebaseAuthException catch (e) {
    _note('getIdToken failed: ${e.code} — ${e.message}');
    _note('expected against the emulator, which cannot answer a refresh');
  }

  // ── Custom tokens ───────────────────────────────────────────────────────
  _step('signInWithCustomToken');
  // The shape a fleet wants: a backend holding the Admin SDK satisfies itself
  // the device is what it claims to be and mints a token for a uid it chose,
  // so identity survives a reflash instead of being whatever the device
  // happened to cache.
  final tokenFile = File(
    Platform.environment['FDB_CUSTOM_TOKEN'] ?? 'custom-token.jwt',
  );
  if (tokenFile.existsSync()) {
    final who = await auth.signInWithCustomToken(
      tokenFile.readAsStringSync().trim(),
    );
    _note('signed in as ${who.user!.uid}, a uid this device did not choose');
  } else {
    _note('no ${tokenFile.path} — skipped');
    _note(
      'mint one with admin.auth().createCustomToken(uid) and point '
      'FDB_CUSTOM_TOKEN at it',
    );
  }

  _step('a credential the backend refuses');
  // The type matters as much as the failure: an app catching
  // FirebaseAuthException on Android catches the same thing here, which is
  // what makes this an implementation of the plugin rather than a lookalike.
  try {
    await auth.signInWithCustomToken('not.a.token');
    _note('unexpectedly accepted');
  } on FirebaseAuthException catch (e) {
    _note('FirebaseAuthException(${e.code}): ${e.message}');
  }

  // ── Sign-out ────────────────────────────────────────────────────────────
  _step('signOut');
  await auth.signOut();
  _note('currentUser = ${auth.currentUser?.uid ?? '<nobody>'}');
  await _until(() => states.length >= 2, 'the sign-out event');
  await sub.cancel();
  _note('authStateChanges saw: ${states.join(' -> ')}');
  _note('the persisted session is gone too: the next run restores nothing');

  // ── What is not bound ───────────────────────────────────────────────────
  _step('what this implementation does not do');
  // Email/password, phone and the federated providers are not bound: the
  // desktop C++ SDK has no UI to host them and no way to finish a flow that
  // needs a browser. Calling one is not silently ignored.
  try {
    await auth.createUserWithEmailAndPassword(
      email: 'nobody@example.com',
      password: 'nothing',
    );
    _note('unexpectedly implemented');
  } on UnimplementedError catch (e) {
    _note('createUserWithEmailAndPassword -> UnimplementedError: ${e.message}');
  }
  _note(
    'a missing method names itself, rather than failing somewhere else '
    'later',
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
