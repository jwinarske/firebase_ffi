// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of cloud_firestore on Linux: what this implementation binds, and what
// it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// cloud_firestore depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth,firestore \
//     'cd ../cloud_firestore_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_ffi/cloud_firestore_ffi.dart';
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
  CloudFirestoreFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final fs = FirebaseFirestore.instance;
  if (host.isNotEmpty) {
    fs.useFirestoreEmulator(host, _port('FIRESTORE', 8080));
    await FirebaseAuth.instance.useAuthEmulator(host, _port('AUTH', 9099));
  }
  // The rules want a caller, as production's do. Signing in also exercises
  // what put every product in one native library: Auth and Firestore share a
  // firebase::App, so the credential reaches Firestore without being passed
  // to it.
  _note(
    'signed in as '
    '${(await FirebaseAuth.instance.signInAnonymously()).user!.uid}',
  );

  final root = 'example_${DateTime.now().microsecondsSinceEpoch}';
  _note('working in collection $root');

  try {
    // ── Documents ─────────────────────────────────────────────────────────
    _step('set, merge, get, delete');
    final doc = fs.collection(root).doc('kiosk-7');
    await doc.set({
      'name': 'kiosk-7',
      'firmware': '1.4.2',
      'uptime': 0,
      'healthy': true,
      'tags': ['lobby', 'north'],
      'site': {'building': 'A', 'floor': 2},
    });
    _note('wrote ${doc.path}');

    // Without merge a write replaces the document; with it only the named
    // fields change. The difference matters when a second writer owns fields
    // this one knows nothing about.
    await doc.set({'uptime': 4210}, SetOptions(merge: true));
    final snap = await doc.get();
    _note('id      ${snap.id}');
    _note('exists  ${snap.exists}');
    _note('fields  ${snap.data()!.keys.join(', ')}');
    _note(
      'uptime is ${snap.data()!['uptime']} and firmware survived as '
      '${snap.data()!['firmware']}',
    );

    // Absent and empty are different answers, and an app treats them
    // differently.
    final missing = await fs.collection(root).doc('not-there').get();
    _note(
      'a document never written: exists=${missing.exists}, '
      'data=${missing.data()}',
    );

    _step('ids');
    _note('a named document: ${fs.collection(root).doc('named').path}');
    // Generated locally, so a document can be written to before the server has
    // ever heard of it.
    _note('a generated id: ${fs.collection(root).doc().id} (20 characters)');

    // ── The value types ───────────────────────────────────────────────────
    _step('the types Firestore has and CBOR does not');
    final typed = fs.collection(root).doc('types');
    final when = Timestamp.fromDate(DateTime.utc(2026, 8, 31, 9, 30));
    await typed.set({
      'text': 'hello',
      'count': 42,
      'ratio': 1.5,
      'flag': true,
      'nothing': null,
      'when': when,
      'where': const GeoPoint(51.5074, -0.1278),
      'bytes': Blob(Uint8List.fromList([1, 2, 250])),
      'other': doc,
      'list': [1, 'two', null],
      'nested': {'deep': true},
    });
    final back = (await typed.get()).data()!;
    for (final e in back.entries) {
      _note(
        '${e.key.padRight(8)} '
        '${e.value.runtimeType.toString().padRight(18)} ${e.value}',
      );
    }
    // A Blob rather than a List<int>, and a DocumentReference rather than a
    // string: these cross as tagged CBOR, and the tags are what stop the two
    // from collapsing into shapes an app cannot tell apart.
    _note('bytes came back as a Blob: ${back['bytes'] is Blob}');
    _note(
      'the reference points at ${(back['other']! as DocumentReference).path}',
    );
    _note('the timestamp kept its nanoseconds: ${back['when'] == when}');

    // ── Queries ───────────────────────────────────────────────────────────
    _step('queries');
    final fleet = fs.collection('${root}_fleet');
    for (var i = 0; i < 5; i++) {
      await fleet.doc('unit$i').set({
        'n': i,
        'site': i.isEven ? 'north' : 'south',
        'temp': 20.0 + i,
        'tags': ['fleet', if (i < 2) 'pilot'],
      });
    }

    Future<String> ids(Query<Map<String, dynamic>> q) async =>
        (await q.get()).docs.map((d) => d.id).join(', ');

    _note('all                    ${await ids(fleet)}');
    _note(
      'site == north          '
      '${await ids(fleet.where('site', isEqualTo: 'north'))}',
    );
    final warm = fleet
        .where('temp', isGreaterThanOrEqualTo: 22.0)
        .orderBy('temp', descending: true);
    _note('temp >= 22 desc        ${await ids(warm)}');
    _note(
      'tags contains pilot    '
      '${await ids(fleet.where('tags', arrayContains: 'pilot'))}',
    );
    _note(
      'site in [north]        '
      '${await ids(fleet.where('site', whereIn: ['north']))}',
    );
    _note(
      'ordered, first two     '
      '${await ids(fleet.orderBy('n').limit(2))}',
    );
    _note(
      'ordered, last two      '
      '${await ids(fleet.orderBy('n').limitToLast(2))}',
    );

    _step('cursors, which is how paging is written');
    final page1 = await fleet.orderBy('n').limit(2).get();
    // Page forward from the last document of the page before, by the value it
    // was ordered on. Firestore has no offset, and this is why: a cursor stays
    // correct while the data changes underneath it.
    //
    // startAfterDocument() would say the same thing with the document itself,
    // and is not bound — see the last section.
    final page2 = await fleet
        .orderBy('n')
        .startAfter([page1.docs.last.data()['n']])
        .limit(2)
        .get();
    _note('page 1: ${page1.docs.map((d) => d.id).join(', ')}');
    _note('page 2: ${page2.docs.map((d) => d.id).join(', ')}');
    _note(
      'startAt(1), endBefore(4): '
      '${await ids(fleet.orderBy('n').startAt([1]).endBefore([4]))}',
    );

    _step('a collection group: every collection with this id, at any depth');
    final leaf = 'readings_${DateTime.now().microsecondsSinceEpoch}';
    await fs.doc('${root}_sites/north/$leaf/r1').set({'c': 21.5});
    await fs.doc('${root}_sites/south/$leaf/r2').set({'c': 22.5});
    final group = await fs.collectionGroup(leaf).get();
    _note(
      '${group.docs.length} documents, from '
      '${group.docs.map((d) => d.reference.path.split('/')[1]).join(' and ')}',
    );
    for (final d in group.docs) {
      await d.reference.delete();
    }

    // ── Listeners ─────────────────────────────────────────────────────────
    _step('snapshots()');
    final watched = fs.collection(root).doc('watched');
    final events = <Map<String, dynamic>?>[];
    final docSub = watched.snapshots().listen((s) => events.add(s.data()));
    // The first event is the current state — for a document that does not
    // exist, null. That is an event, not a missing one.
    await _until(() => events.isNotEmpty, 'the initial snapshot');
    _note('first event: ${events.first}');
    await watched.set({'n': 1});
    await _until(() => events.last?['n'] == 1, 'the write to arrive');
    await watched.delete();
    await _until(() => events.last == null, 'the delete to arrive');
    await docSub.cancel();
    _note('saw ${events.length} events, ending with the deletion');

    final pages = <int>[];
    final querySub = fleet
        .where('site', isEqualTo: 'north')
        .snapshots()
        .listen((s) => pages.add(s.docs.length));
    await _until(() => pages.isNotEmpty, 'the initial query snapshot');
    await fleet.doc('unit9').set({'n': 9, 'site': 'north', 'temp': 30.0});
    await _until(() => pages.last == 4, 'the new matching document');
    await querySub.cancel();
    // A document that does not match is never sent: the filter is applied at
    // the server rather than here.
    _note('the filtered listener held ${pages.join(' -> ')} documents');

    // ── Transactions and batches ──────────────────────────────────────────
    _step('runTransaction');
    final ledger = fs.collection(root).doc('ledger');
    await ledger.set({'balance': 100});
    final left = await fs.runTransaction((tx) async {
      // Firestore requires every read before any write; this implementation
      // enforces it at the call site rather than letting the commit be
      // rejected later.
      final current = await tx.get(ledger);
      final next = (current.data()!['balance']! as int) - 30;
      tx.set(ledger, {'balance': next});
      // The handler's return value reaches the caller, which is what
      // runTransaction is for beyond the atomicity.
      return next;
    });
    _note(
      'the handler returned $left, and the document agrees: '
      '${(await ledger.get()).data()!['balance']}',
    );

    try {
      await fs.runTransaction((tx) async {
        tx.set(ledger, {'balance': 0});
        throw StateError('changed my mind');
      });
    } on StateError catch (e) {
      _note('a handler that throws commits nothing: ${e.message}');
    }
    _note('balance untouched: ${(await ledger.get()).data()!['balance']}');

    _step('a write batch');
    final batch = fs.batch()
      ..set(fs.collection('${root}_batch').doc('a'), {'n': 1})
      ..set(fs.collection('${root}_batch').doc('b'), {'n': 2})
      ..update(fs.collection('${root}_batch').doc('a'), {'n': 10})
      ..delete(fs.collection('${root}_batch').doc('b'));
    await batch.commit();
    final batched = await fs.collection('${root}_batch').get();
    _note(
      'after one commit: '
      '${batched.docs.map((d) => '${d.id}=${d.data()['n']}').join(', ')}',
    );
    _note('no reads and no retry — that is the difference from a transaction');
    for (final d in batched.docs) {
      await d.reference.delete();
    }

    // ── Aggregates ────────────────────────────────────────────────────────
    _step('count()');
    _note('every unit:      ${(await fleet.count().get()).count}');
    _note(
      'north only:      '
      '${(await fleet.where('site', isEqualTo: 'north').count().get()).count}',
    );
    // Only the number crosses the wire, which is the point: counting a large
    // collection costs one round trip rather than one per document.

    // ── The gaps ──────────────────────────────────────────────────────────
    _step('what this implementation does not bind');
    // DocumentReference.update() is not bound; a batch and a transaction both
    // have update(), and set(merge: true) covers most of what it is used for.
    try {
      await doc.update({'uptime': 1});
      _note('update() was unexpectedly implemented');
    } on UnimplementedError catch (e) {
      _note('DocumentReference.update() -> UnimplementedError: ${e.message}');
    }

    // FieldValue sentinels are not translated either. The binding underneath
    // has them (fdb.FirestoreSentinel.increment and the rest), so this is a
    // gap in the mapping rather than in the SDK.
    try {
      await doc.set({
        'uptime': FieldValue.increment(1),
      }, SetOptions(merge: true));
      _note('FieldValue.increment was accepted');
    } on Object catch (e) {
      _note('FieldValue.increment -> ${e.runtimeType}');
    }
    _note(
      'anything not bound throws the platform interface\'s own '
      'UnimplementedError, naming the method',
    );
  } finally {
    _step('cleaning up');
    var removed = 0;
    for (final c in ['$root', '${root}_fleet', '${root}_batch']) {
      for (final d in (await fs.collection(c).get()).docs) {
        await d.reference.delete();
        removed++;
      }
    }
    _note('deleted $removed documents');
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
