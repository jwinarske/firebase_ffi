// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A tour of firebase_database on Linux: what this implementation binds, and
// what it says about what it does not.
//
//   flutter test
//
// One linear program, in a single test() so a failure is reported rather than
// printed into a green run. `flutter test` is the runner because
// firebase_database depends on Flutter and cannot load on the Dart VM alone.
//
// It takes its project from google-services.json, or from the emulator suite,
// which needs neither project nor credentials. From packages/firebase_ffi:
//
//   export FIREBASE_EMULATOR_HOST=127.0.0.1
//   firebase emulators:exec --project fdb-emulator --only auth,database \
//     'cd ../firebase_database_ffi/example && flutter test'
//
// With neither, it says so and skips.
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database_ffi/firebase_database_ffi.dart';
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

/// The child keys in the order the query produced them.
String _keys(DataSnapshot snap) => snap.children.map((c) => c.key).join(', ');

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
  FirebaseDatabaseFfi.registerWith();
  await Firebase.initializeApp(options: options);
  _note('app "${Firebase.app().name}" for ${Firebase.app().options.projectId}');

  final db = FirebaseDatabase.instance;
  if (host.isNotEmpty) {
    await FirebaseAuth.instance.useAuthEmulator(host, _port('AUTH', 9099));
  }
  // The rules want a caller, as production's do. Signing in also exercises the
  // thing that put every product in one native library: Auth and Database
  // share a firebase::App, so the credential reaches Database without being
  // handed to it.
  final uid = (await FirebaseAuth.instance.signInAnonymously()).user!.uid;
  _note('signed in as $uid');

  // One throwaway subtree, removed on the way out.
  final root = db.ref('example/${DateTime.now().microsecondsSinceEpoch}');
  _note('working under ${root.path}');

  try {
    // ── Writing ───────────────────────────────────────────────────────────
    _step('set, update, remove');
    final device = root.child('device');
    await device.set({
      'name': 'kiosk-7',
      'firmware': '1.4.2',
      'uptime': 0,
      'tags': ['lobby', 'north'],
      'healthy': true,
    });
    _note('set: ${(await device.get()).value}');

    // update() touches only the children it names, which is what lets two
    // writers own different fields of one node without overwriting each other.
    await device.update({'uptime': 42, 'healthy': false});
    _note('after update: ${(await device.get()).value}');

    await device.child('tags').remove();
    _note('after removing tags: ${(await device.get()).value}');

    _step('a snapshot is more than its value');
    final snap = await device.get();
    _note('key      ${snap.key}');
    _note('exists   ${snap.exists}');
    _note('value    ${snap.value}');
    _note('children ${_keys(snap)}');
    _note('child    ${snap.child('firmware').value}');
    _note(
      'a child that was never written: '
      '${(await device.child('nothing').get()).exists}',
    );

    // ── push ──────────────────────────────────────────────────────────────
    _step('push: keys generated on the client, ordered by time');
    final readings = root.child('readings');
    for (final c in [21.5, 22.0, 22.4]) {
      // The key is derived locally — no round trip — so the child can be
      // written immediately rather than after the server agrees on a name.
      await readings.push().set({'c': c});
    }
    final pushed = await readings.get();
    final byKey = (pushed.value! as Map).values
        .map((v) => (v! as Map)['c'])
        .join(', ');
    _note(
      '${(pushed.value! as Map).length} readings, in the order they were '
      'pushed: $byKey',
    );

    // ── Listening ─────────────────────────────────────────────────────────
    _step('onValue: the whole node, on every change');
    final live = root.child('live');
    final seen = <Object?>[];
    final sub = live.onValue.listen((e) => seen.add(e.snapshot.value));
    // The first event is the current state, which for a node never written is
    // null. That is an event, not the absence of one.
    await _until(() => seen.isNotEmpty, 'the initial snapshot');
    _note('first event: ${seen.first}');

    await live.set({'n': 1});
    await _until(() => seen.length >= 2, 'the first write');
    await live.set({'n': 2});
    await _until(() => seen.length >= 3, 'the second write');
    await sub.cancel();
    _note('saw ${seen.length} snapshots, last ${seen.last}');

    _step('the child events, which say what changed');
    final queue = root.child('queue');
    final events = <String>[];
    final added = queue.onChildAdded.listen(
      (e) => events.add('added ${e.snapshot.key}'),
    );
    final changed = queue.onChildChanged.listen(
      (e) => events.add('changed ${e.snapshot.key}'),
    );
    final removed = queue.onChildRemoved.listen(
      (e) => events.add('removed ${e.snapshot.key}'),
    );

    await queue.child('a').set({'n': 1});
    await queue.child('b').set({'n': 2});
    await queue.child('a').set({'n': 9});
    await queue.child('b').remove();
    await _until(() => events.length >= 4, 'four child events');
    await added.cancel();
    await changed.cancel();
    await removed.cancel();
    // A value listener reports the whole node every time and leaves the app to
    // diff it; it cannot report a removal at all once the node is gone.
    _note(events.join(', '));

    // ── Queries ───────────────────────────────────────────────────────────
    _step('queries: ordered, bounded, limited — at the server');
    final scores = root.child('scores');
    await scores.set({
      'ana': {'score': 30, 'team': 'red'},
      'bo': {'score': 10, 'team': 'blue'},
      'cy': {'score': 20, 'team': 'red'},
      'di': {'score': 40, 'team': 'blue'},
    });

    // A bound or a limit means nothing without an ordering, and the SDK
    // requires the ordering to be applied first.
    final top = await scores.orderByChild('score').limitToLast(2).get();
    _note('two highest: ${_keys(top)}');

    final low = await scores.orderByChild('score').endAt(20).get();
    _note('score <= 20: ${_keys(low)}');

    final red = await scores.orderByChild('team').equalTo('red').get();
    _note('team == red: ${_keys(red)}');

    final fromBo = await scores
        .orderByKey()
        .startAt('bo')
        .limitToFirst(2)
        .get();
    _note('by key from "bo": ${_keys(fromBo)}');

    // A live query re-evaluates as the data changes, and the filtering happens
    // at the server: the client is not handed the whole node to narrow itself.
    final leaders = <String>[];
    final leaderSub = scores
        .orderByChild('score')
        .limitToLast(1)
        .onValue
        .listen(
          (e) => leaders.add((e.snapshot.value! as Map).keys.first as String),
        );
    await _until(() => leaders.isNotEmpty, 'the filtered listener');
    await scores.child('ev').set({'score': 99, 'team': 'red'});
    await _until(() => leaders.contains('ev'), 'the new leader');
    await leaderSub.cancel();
    _note('leader over time: ${leaders.join(' -> ')}');

    _step('a cursor this implementation does not have');
    // startAfter and endBefore are exclusive cursors the desktop ABI cannot
    // express. Refused by name rather than applied as their inclusive cousins,
    // which would return one row too many and no error.
    try {
      await scores.orderByChild('score').startAfter(20).get();
      _note('startAfter was unexpectedly applied');
    } on UnimplementedError catch (e) {
      _note('startAfter -> UnimplementedError: ${e.message}');
    }

    // ── Transactions ──────────────────────────────────────────────────────
    _step('transactions: read-modify-write against other writers');
    final counter = root.child('counter');
    await counter.set(0);
    for (var i = 0; i < 3; i++) {
      // The handler may run more than once — that is what makes it a
      // transaction — so it must be a function of the value it is given.
      await counter.runTransaction((current) {
        final n = (current as int?) ?? 0;
        return Transaction.success(n + 1);
      });
    }
    _note('after three increments: ${(await counter.get()).value}');

    final aborted = await counter.runTransaction((current) {
      _note('the handler saw $current and will abort');
      return Transaction.abort();
    });
    _note(
      'committed: ${aborted.committed}; '
      'value still ${(await counter.get()).value}',
    );

    // ── Priorities ────────────────────────────────────────────────────────
    _step('priorities: an ordering carried beside the value');
    final agenda = root.child('agenda');
    await agenda.child('second').setWithPriority({'title': 'later'}, 2);
    await agenda.child('first').setWithPriority({'title': 'sooner'}, 1);
    await agenda.child('second').setPriority(3);
    final ordered = await agenda.orderByPriority().get();
    _note('by priority: ${_keys(ordered)}');
    _note('a priority is not a field: it does not appear in the value');

    // ── onDisconnect ──────────────────────────────────────────────────────
    _step('onDisconnect: what the server does when this process stops');
    final presence = root.child('presence/$uid');
    await presence.set({'online': true});
    // Registered now, run by the server later — including when the process is
    // killed, which is the case a client-side goodbye write cannot cover.
    await presence.onDisconnect().set({'online': false});
    _note('registered; the server holds it until this connection drops');

    db.goOffline();
    db.goOnline();
    _note('after a drop and reconnect: ${(await presence.get()).value}');

    await presence.onDisconnect().cancel();
    _note('cancelled: nothing is scheduled for the next disconnect');

    // ── Connection and cache ──────────────────────────────────────────────
    _step('offline writes');
    db.goOffline();
    // The future is answered by the server's acknowledgement, which cannot
    // arrive while offline. The write is not lost — it is queued.
    final queued = root.child('queued').set('written while offline');
    _note('the write is queued and its future is still pending');
    db.goOnline();
    await queued;
    _note('after reconnect: ${(await root.child('queued').get()).value}');
    // purgeOutstandingWrites() is the other half: a device that has been
    // offline long enough for its data to be stale can drop what it was
    // holding rather than overwrite fresher values.
    await db.purgeOutstandingWrites();
    _note('purgeOutstandingWrites() discards a queue instead of sending it');

    _step('keepSynced and the on-disk cache');
    await scores.keepSynced(true);
    _note(
      'keepSynced(true): this node stays subscribed with no listener '
      'attached, so a later read is already local',
    );
    await scores.keepSynced(false);
    try {
      db.setPersistenceEnabled(true);
      _note('persistence was unexpectedly enabled');
    } on UnimplementedError catch (e) {
      _note('setPersistenceEnabled -> UnimplementedError: ${e.message}');
    }

    _step('ordering survives to the snapshot');
    // children is ordered by the query; the value is a map the SDK sorts by
    // key, so the two disagree whenever the ordering is not by key. Both are
    // shown because an app reading value.keys and expecting order would be
    // wrong and would not be told.
    final ranked = await scores.orderByChild('score').get();
    _note('children: ${_keys(ranked)}');
    _note('value:    ${(ranked.value! as Map).keys.join(', ')}');
  } finally {
    _step('cleaning up');
    await root.remove();
    _note('removed ${root.path}');
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
