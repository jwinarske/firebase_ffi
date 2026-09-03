// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Realtime Database binding, end to end.
//
//   dart run example/database.dart
//
// Writes and reads, listeners, child events, queries, transactions,
// priorities, and the onDisconnect actions that make a device's absence
// visible without polling it.
//
// Everything this program writes lives under one throwaway path and is removed
// on the way out.

import 'dart:async';

import 'package:firebase_ffi/database.dart';

import 'setup.dart';

Future<void> main() async {
  final app = await start();
  final root = '/example/${app.run}';

  try {
    await _writes(root);
    await _listeners(root);
    await _childEvents(root);
    await _queries(root);
    await _transactions(root);
    await _priorities(root);
    await _onDisconnect(root);
    await _connection(root);
  } finally {
    step('cleaning up');
    await removeValue(root);
    note('removed $root');
  }
}

// ── Writing and reading ───────────────────────────────────────────────────

Future<void> _writes(String root) async {
  step('set, update, remove');

  // A whole subtree in one call. Maps, lists, numbers, strings, bools and null
  // travel as themselves; there is no JSON string in the middle.
  await setValue('$root/device', {
    'name': 'kiosk-7',
    'firmware': '1.4.2',
    'uptime': 0,
    'tags': ['lobby', 'north'],
    'healthy': true,
  });
  note('set: ${await readValue('$root/device')}');

  // update() touches only the children it names. The difference from set()
  // matters when two writers own different fields of the same node.
  await updateChildren('$root/device', {'uptime': 42, 'healthy': false});
  note('after update: ${await readValue('$root/device')}');

  // A single leaf, with no encoding step. setString is the narrow path for the
  // common case of writing a string to one node.
  setString('$root/device/firmware', '1.4.3');
  // setString does not answer: it hands the write to the SDK and returns. The
  // read below is what confirms it landed.
  note('firmware now ${await readValue('$root/device/firmware')}');

  await removeValue('$root/device/tags');
  note('after removing tags: ${await readValue('$root/device')}');

  // push() generates a key locally — no round trip — so a client can write to
  // the child it just named without waiting for the server to agree.
  step('push: server-ordered keys, generated on the client');
  for (final level in [21.5, 22.0, 22.4]) {
    final key = pushChild('$root/readings');
    await setValue('$root/readings/$key', {'c': level});
  }
  final readings = (await readValue('$root/readings'))! as Map;
  note('three pushed keys, already in time order: ${readings.keys.join(', ')}');
}

// ── Listeners ─────────────────────────────────────────────────────────────

Future<void> _listeners(String root) async {
  step('onValue: the node, on every change');

  final seen = <Object?>[];
  final sub = onValue('$root/live').listen((snap) {
    // postedNs is when the native side handed the snapshot over, so the
    // difference is delivery cost rather than round-trip time.
    final us = (nowNs() - snap.postedNs) / 1000;
    seen.add(snap.value);
    note('seq ${snap.seq}: ${snap.value}  (delivered in ${us.round()}us)');
  });

  // The first event is the current state, which for a path never written is
  // null. That is an event, not the absence of one.
  await until(() => seen.isNotEmpty, 'the initial snapshot');

  await setValue('$root/live', {'n': 1});
  await until(() => seen.length >= 2, 'the first write');
  await setValue('$root/live', {'n': 2});
  await until(() => seen.length >= 3, 'the second write');

  await sub.cancel();
  note('cancelled after ${seen.length} snapshots');

  // A read is a listener that waits for the value to stop changing: the
  // desktop SDK has no server read, and GetValue answers from an empty local
  // cache. readValue is the honest version of that, and says so in its docs.
  note('readValue agrees: ${await readValue('$root/live')}');
}

Future<void> _childEvents(String root) async {
  step('onChildEvent: which child changed, and where it sits');

  final events = <String>[];
  final sub = onChildEvent('$root/queue').listen((e) {
    events.add('${e.event.name} ${e.key}');
    note(
      '${e.event.name.padRight(7)} ${e.key}  after=${e.previousKey}  '
      '${e.value}',
    );
  });

  await setValue('$root/queue/a', {'n': 1});
  await setValue('$root/queue/b', {'n': 2});
  await setValue('$root/queue/a', {'n': 9});
  await removeValue('$root/queue/b');
  await until(() => events.length >= 4, 'four child events');

  await sub.cancel();
  // A value listener would have reported four whole-node snapshots and left
  // the app to diff them; it cannot report a removal at all once the node is
  // gone.
  note('a list can be maintained from these without re-reading the node');
}

// ── Queries ───────────────────────────────────────────────────────────────

Future<void> _queries(String root) async {
  step('queries: ordering, bounds and limits, applied at the server');

  await setValue('$root/scores', {
    'ana': {'score': 30, 'team': 'red'},
    'bo': {'score': 10, 'team': 'blue'},
    'cy': {'score': 20, 'team': 'red'},
    'di': {'score': 40, 'team': 'blue'},
  });

  // A bound or a limit is meaningless without an ordering, and the SDK
  // requires the ordering to be applied first.
  final top = await readValue(
    '$root/scores',
    query: const DbQuery().orderByChild('score').limitToLast(2),
  );
  note('two highest scores: ${(top! as Map).keys.join(', ')}');

  final low = await readValue(
    '$root/scores',
    query: const DbQuery().orderByChild('score').endAt(20),
  );
  note('score <= 20: ${(low! as Map).keys.join(', ')}');

  final red = await readValue(
    '$root/scores',
    query: const DbQuery().orderByChild('team').equalTo('red'),
  );
  note('team == red: ${(red! as Map).keys.join(', ')}');

  final byKey = await readValue(
    '$root/scores',
    query: const DbQuery().orderByKey().startAt('bo').limitToFirst(2),
  );
  note('by key from "bo": ${(byKey! as Map).keys.join(', ')}');

  // The filtering happens at the server: a limit means what it says, and the
  // client is not handed the whole node to narrow itself.
  final watched = <int>[];
  final sub =
      onQueryValue(
        '$root/scores',
        const DbQuery().orderByChild('score').limitToLast(1),
      ).listen(
        (s) => watched.add(
          ((s.value! as Map).values.first as Map)['score'] as int,
        ),
      );
  await until(() => watched.isNotEmpty, 'the filtered listener');
  await setValue('$root/scores/ev', {'score': 99, 'team': 'red'});
  await until(() => watched.contains(99), 'the new leader');
  await sub.cancel();
  note('a filtered listener re-evaluates as the data changes: $watched');

  // A query the ABI cannot express is refused rather than run with the clause
  // dropped — a dropped filter returns more rows and no error, which reads as
  // data.
  try {
    await onQueryValue(
      '$root/scores',
      const DbQuery().orderByChild('score').limitToFirst(1).limitToLast(1),
    ).first;
    note('both limits at once: unexpectedly accepted');
  } on ArgumentError catch (e) {
    note('both limits at once: refused — ${e.message}');
  }
}

// ── Transactions ──────────────────────────────────────────────────────────

Future<void> _transactions(String root) async {
  step('transactions: read-modify-write against concurrent writers');

  await setValue('$root/counter', 0);

  // The handler may run more than once — that is what makes it a transaction —
  // so it must be a pure function of the value it is given.
  for (var i = 0; i < 3; i++) {
    await runDbTransaction('$root/counter', (current) {
      final n = (current as int?) ?? 0;
      return DbTransactionResult.commit(n + 1);
    });
  }
  note('after three increments: ${await readValue('$root/counter')}');

  // Aborting leaves the value alone. An app uses this when the value it read
  // says the write is no longer wanted.
  await runDbTransaction('$root/counter', (current) {
    note('handler saw $current, and will abort');
    return const DbTransactionResult.abort();
  });
  note('after an aborted attempt: ${await readValue('$root/counter')}');
}

// ── Priorities ────────────────────────────────────────────────────────────

Future<void> _priorities(String root) async {
  step('priorities: an ordering carried beside the value');

  await setValueWithPriority('$root/agenda/second', {'title': 'later'}, 2);
  await setValueWithPriority('$root/agenda/first', {'title': 'sooner'}, 1);
  await setPriority('$root/agenda/second', 3);

  final ordered = await readValue(
    '$root/agenda',
    query: const DbQuery().orderByPriority(),
  );
  note('ordered by priority: ${(ordered! as Map).keys.join(', ')}');
  note('a priority is not a field: it does not appear in the value');
}

// ── onDisconnect ──────────────────────────────────────────────────────────

Future<void> _onDisconnect(String root) async {
  step('onDisconnect: what the server does when this process stops');

  final presence = OnDisconnect('$root/presence/self');
  await setValue('$root/presence/self', {'online': true});

  // Registered now, run by the server later — including when the process is
  // killed, which is the case a client-side "goodbye" write cannot cover.
  await presence.setValue({'online': false, 'left': 'unexpectedly'});
  note('registered; the server holds it until this connection drops');

  // goOffline drops the connection, which is what makes the registration
  // observable without pulling the power.
  goOffline();
  goOnline();
  // readValue settles before it answers, so the reconnect and the server's
  // reply are both covered without a guessed sleep.
  note('after a drop and reconnect: ${await readValue('$root/presence/self')}');

  // A registration can be withdrawn while the connection is still up.
  await presence.setValue({'online': false});
  await presence.cancel();
  note('cancelled: nothing is scheduled for the next disconnect');
}

Future<void> _connection(String root) async {
  step('offline writes');

  // Writes made offline are queued locally and sent on reconnect, which is why
  // a device that loses its link keeps working rather than throwing.
  goOffline();
  // The future does not complete while offline: it is answered by the server's
  // acknowledgement, which cannot arrive. The write is not lost — it is queued.
  final queued = setValue('$root/queued', 'written while offline');
  note('the write is queued, and its future is still pending');

  goOnline();
  await queued;
  note('after reconnect it completed: ${await readValue('$root/queued')}');

  // The other half of the same story: a queue that should not be sent. A
  // device that has been offline long enough for its data to be stale can drop
  // what it was holding rather than overwrite fresher values.
  note('purgeOutstandingWrites() discards a queue instead of sending it');
}
