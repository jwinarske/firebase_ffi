// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_storage on Linux: what this implementation binds, and what
// it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// firebase_storage depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth,storage \
//     'cd ../firebase_storage_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
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
  FirebaseStorageFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final storage = FirebaseStorage.instance;
  if (host.isNotEmpty) {
    await storage.useStorageEmulator(host, _port('STORAGE', 9199));
    await FirebaseAuth.instance.useAuthEmulator(host, _port('AUTH', 9099));
  }
  _note('bucket ${Firebase.app().options.storageBucket ?? '<unset>'}');
  // Storage takes its bucket from the app options and has no per-call
  // override: an app that leaves it unset builds URLs with no bucket in them.
  _note(
    'signed in as '
    '${(await FirebaseAuth.instance.signInAnonymously()).user!.uid}',
  );

  final ref = storage.ref('example/${DateTime.now().microsecondsSinceEpoch}');
  _note('working under ${ref.fullPath}');

  try {
    // ── Upload ────────────────────────────────────────────────────────────
    _step('putData');
    final object = ref.child('roundtrip.bin');
    // Patterned rather than random, so a truncated or offset download shows up
    // as a byte index rather than as a length that happens to match.
    final payload = Uint8List.fromList(
      List<int>.generate(256 * 1024, (i) => i % 251),
    );

    final task = object.putData(
      payload,
      SettableMetadata(contentType: 'application/octet-stream'),
    );
    // The C++ SDK reports progress through a listener that is not bound, so
    // the task emits one running snapshot and then the terminal one. Saying it
    // had transferred everything before it had would be worse than reporting
    // nothing: a progress bar driven by that would be wrong rather than
    // absent.
    final states = <TaskState>[];
    final progress = task.snapshotEvents.listen((s) => states.add(s.state));
    final done = await task;
    // The terminal snapshot is delivered to the stream, so give it a moment to
    // land before unsubscribing — otherwise whether it was seen is a race.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await progress.cancel();
    _note('state    ${done.state.name}');
    _note('bytes    ${done.bytesTransferred} of ${done.totalBytes}');
    final seen = states.isEmpty
        ? '<none>'
        : states.map((s) => s.name).join(' -> ');
    _note('events   $seen');

    // ── Download ──────────────────────────────────────────────────────────
    _step('getData');
    final back = (await object.getData(payload.length))!;
    _note('downloaded ${back.length} bytes');
    var firstBad = -1;
    for (var i = 0; i < payload.length; i++) {
      if (back[i] != payload[i]) {
        firstBad = i;
        break;
      }
    }
    _note(
      firstBad < 0
          ? 'every byte identical'
          : 'CONTENT DIFFERS at byte $firstBad',
    );

    // The cap is a contract, not a suggestion: past it the answer is null
    // rather than a truncated object that looks complete.
    _note(
      'getData(1024) on a larger object: '
      '${await object.getData(1024) == null ? 'null, as promised' : 'bytes'}',
    );

    // ── Metadata ──────────────────────────────────────────────────────────
    _step('getMetadata');
    final m = await object.getMetadata();
    _note('bucket        ${m.bucket}');
    _note('fullPath      ${m.fullPath}');
    _note('name          ${m.name}');
    _note('size          ${m.size} bytes');
    _note('contentType   ${m.contentType}');
    _note('md5Hash       ${m.md5Hash}');
    _note('timeCreated   ${m.timeCreated}');
    _note('updated       ${m.updated}');
    // A generation changes when the bytes change, and the metadata generation
    // when only the metadata does — which is how a cache decides whether it
    // has to download again.
    _note(
      'generation    ${m.generation} / '
      '${m.metadataGeneration ?? '<none from this backend>'}',
    );

    // ── URLs ──────────────────────────────────────────────────────────────
    _step('getDownloadURL');
    final url = await object.getDownloadURL();
    // The URL carries an access token, so it serves the object to anything
    // holding it. That makes it a credential rather than a path.
    _note('${url.split('?').first}?<access token>');

    // ── Paths ─────────────────────────────────────────────────────────────
    _step('references are paths, and compose like them');
    _note('ref.fullPath        ${ref.fullPath}');
    _note('child               ${ref.child('a/b.txt').fullPath}');
    _note('name of that child  ${ref.child('a/b.txt').name}');

    // ── Deletion ──────────────────────────────────────────────────────────
    _step('delete');
    await object.delete();
    _note('deleted');
    // The failure is the assertion: a delete that quietly succeeded on a
    // missing object would hide a delete that never happened.
    try {
      await object.delete();
      _note('a second delete unexpectedly succeeded');
    } on FirebaseException catch (e) {
      _note('a second delete: FirebaseException(${e.code}) — ${e.message}');
    }

    // ── The gaps ──────────────────────────────────────────────────────────
    _step('what this implementation does not bind');
    // Listing is a REST call the desktop C++ SDK does not expose, so an app
    // that browses a bucket has to keep its own index — in Firestore or the
    // Realtime Database — rather than asking Storage what is there.
    try {
      await ref.listAll();
      _note('listAll() was unexpectedly implemented');
    } on UnimplementedError catch (e) {
      _note('listAll() -> UnimplementedError: ${e.message}');
    }
    _note(
      'pause/resume/cancel answer false: an upload here runs to completion '
      'or fails, and pretending otherwise would strand a caller awaiting a '
      'state that never arrives',
    );
  } finally {
    _step('cleaning up');
    try {
      await ref.child('roundtrip.bin').delete();
      _note('removed the object');
    } on FirebaseException {
      _note('nothing left to remove');
    }
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
