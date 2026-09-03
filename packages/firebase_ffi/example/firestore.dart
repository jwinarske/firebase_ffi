// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Cloud Firestore binding, end to end.
//
//   dart run example/firestore.dart
//
// Documents, the value types CBOR has no native form for, server-side
// sentinels, queries and their cursors, live listeners, transactions, batches
// and the aggregates the server computes.
//
// Everything is written under one throwaway collection and deleted on the way
// out.

import 'dart:typed_data';

import 'package:firebase_ffi/firestore.dart';

import 'setup.dart';

Future<void> main() async {
  final app = await start(use: {Product.firestore});
  final root = 'example_${app.run}';

  try {
    await _documents(root);
    await _types(root);
    await _sentinels(root);
    await _queries(root);
    await _listeners(root);
    await _transactions(root);
    await _batches(root);
    await _aggregates(root);
    await _collectionGroup(app.run);
  } finally {
    step('cleaning up');
    final left = await queryCollection(root);
    for (final doc in left) {
      await deleteDocument(doc.path);
    }
    note(
      left.isEmpty
          ? 'nothing left under $root: each section removed its own'
          : 'deleted ${left.length} documents under $root',
    );
  }
}

// ── Documents ─────────────────────────────────────────────────────────────

Future<void> _documents(String root) async {
  step('set, merge, get, delete');

  final path = '$root/kiosk-7';
  await setDocument(path, {
    'name': 'kiosk-7',
    'firmware': '1.4.2',
    'uptime': 0,
    'healthy': true,
    'tags': ['lobby', 'north'],
    'site': {'building': 'A', 'floor': 2},
  });
  note('wrote $path');

  // Without merge, a write replaces the document. With it, only the named
  // fields change — the difference matters when a second writer owns fields
  // this one knows nothing about.
  await setDocument(path, {'uptime': 4210}, merge: true);
  final doc = (await getDocument(path))!;
  note('after a merge, ${doc.length} fields survive: ${doc.keys.join(', ')}');
  note('uptime = ${doc['uptime']}, firmware still ${doc['firmware']}');

  // A missing document is null, not an empty map: "absent" and "present but
  // empty" are different answers and an app usually treats them differently.
  note('a document that was never written: ${await getDocument('$root/nope')}');

  await deleteDocument(path);
  note('after delete: ${await getDocument(path)}');
}

// ── The value types ───────────────────────────────────────────────────────

Future<void> _types(String root) async {
  step('the tagged types, which are the interesting part of the codec');

  final path = '$root/types';
  final when = FirestoreTimestamp.fromDateTime(
    DateTime.utc(2026, 8, 31, 9, 30),
  );
  await setDocument(path, {
    'text': 'hello',
    'count': 42,
    'ratio': 1.5,
    'flag': true,
    'nothing': null,
    'when': when,
    'where': const FirestoreGeoPoint(51.5074, -0.1278),
    'other': FirestoreReference('$root/kiosk-7'),
    'bytes': Uint8List.fromList([1, 2, 250]),
    'list': [1, 'two', null],
    'nested': {'deep': true},
  });

  final back = (await getDocument(path))!;
  for (final e in back.entries) {
    note(
      '${e.key.padRight(8)} ${e.value.runtimeType.toString().padRight(20)} '
      '${e.value}',
    );
  }

  // These travel as tagged CBOR rather than being flattened into strings and
  // numbers. Without the tags a blob arrives as a list of small integers and a
  // geopoint as a two-element array — both indistinguishable from data that
  // really was a list.
  note('timestamp survived to the nanosecond: ${back['when'] == when}');
  note(
    'bytes came back as bytes, not as a list of ints: '
    '${back['bytes'] is List<int>}',
  );

  await deleteDocument(path);
}

// ── Sentinels ─────────────────────────────────────────────────────────────

Future<void> _sentinels(String root) async {
  step('sentinels: instructions to the server, not values');

  final path = '$root/counters';
  await setDocument(path, {
    'hits': 1,
    'tags': ['a'],
    'stale': 'remove me',
  });

  // The increment happens at the server, so two clients incrementing at once
  // both land — which a read-modify-write from either would not.
  await setDocument(path, {
    'hits': FirestoreSentinel.increment(41),
    'tags': FirestoreSentinel.arrayUnion(['b', 'a']),
    'seen': FirestoreSentinel.serverTimestamp,
    'stale': FirestoreSentinel.delete,
  }, merge: true);

  final doc = (await getDocument(path))!;
  note('hits  ${doc['hits']}  (1 + 41, computed by the server)');
  note('tags  ${doc['tags']}  ("a" was already there and was not duplicated)');
  note('seen  ${doc['seen']}  (the server\'s clock, not this one)');
  note('stale ${doc.containsKey('stale') ? doc['stale'] : '<field removed>'}');

  await setDocument(path, {
    'tags': FirestoreSentinel.arrayRemove(['a']),
  }, merge: true);
  note('after arrayRemove: ${(await getDocument(path))!['tags']}');

  await deleteDocument(path);
}

// ── Queries ───────────────────────────────────────────────────────────────

Future<void> _queries(String root) async {
  step('queries: filters, ordering, limits and cursors');

  final fleet = '${root}_fleet';
  for (var i = 0; i < 5; i++) {
    await setDocument('$fleet/unit$i', {
      'n': i,
      'site': i.isEven ? 'north' : 'south',
      'temp': 20.0 + i,
      'tags': ['fleet', if (i < 2) 'pilot'],
    });
  }

  final all = await queryCollection(fleet);
  note('all: ${all.map((d) => d.id).join(', ')}');

  final north = await queryCollection(
    fleet,
    where: const [Where.equalTo('site', 'north')],
  );
  note('site == north: ${north.map((d) => d.id).join(', ')}');

  final warm = await queryCollection(
    fleet,
    where: const [Where.greaterThanOrEqualTo('temp', 22.0)],
    orderBy: const [OrderBy('temp', descending: true)],
  );
  note(
    'temp >= 22, hottest first: '
    '${warm.map((d) => d.data['temp']).join(', ')}',
  );

  final pilots = await queryCollection(
    fleet,
    where: const [Where.arrayContains('tags', 'pilot')],
  );
  note('tags contains "pilot": ${pilots.map((d) => d.id).join(', ')}');

  final some = await queryCollection(
    fleet,
    where: const [
      Where.whereIn('site', ['north']),
      Where.lessThan('n', 3),
    ],
    orderBy: const [OrderBy('n')],
  );
  note('two filters together: ${some.map((d) => d.id).join(', ')}');

  // Paging: the second page starts after the last document of the first, using
  // its ordered field's value as the cursor. This is the idiom an app writes
  // rather than an offset, which Firestore does not have.
  final page1 = await queryCollection(
    fleet,
    orderBy: const [OrderBy('n')],
    limit: 2,
  );
  final page2 = await queryCollection(
    fleet,
    orderBy: const [OrderBy('n')],
    startAfter: [page1.last.data['n']],
    limit: 2,
  );
  note('page 1: ${page1.map((d) => d.id).join(', ')}');
  note('page 2: ${page2.map((d) => d.id).join(', ')}');

  final bounded = await queryCollection(
    fleet,
    orderBy: const [OrderBy('n')],
    startAt: [1],
    endBefore: [4],
  );
  note('startAt 1, endBefore 4: ${bounded.map((d) => d.data['n']).join(', ')}');

  final last = await queryCollection(
    fleet,
    orderBy: const [OrderBy('n')],
    limitToLast: 2,
  );
  note('limitToLast 2: ${last.map((d) => d.data['n']).join(', ')}');

  for (final d in await queryCollection(fleet)) {
    await deleteDocument(d.path);
  }
}

// ── Listeners ─────────────────────────────────────────────────────────────

Future<void> _listeners(String root) async {
  step('listeners: a document and a query, watched');

  final path = '$root/watched';
  final seen = <Map<String, Object?>?>[];
  final docSub = onDocument(path).listen(seen.add);

  // The first event is the current state — for a document that does not exist,
  // null. That is an event, not a missing one.
  await until(() => seen.isNotEmpty, 'the initial document snapshot');
  note('first event: ${seen.first}');

  await setDocument(path, {'n': 1});
  await until(() => seen.last?['n'] == 1, 'the write to arrive');
  await setDocument(path, {'n': 2});
  await until(() => seen.last?['n'] == 2, 'the second write');
  note('saw ${seen.length} events, last ${seen.last}');
  await docSub.cancel();

  final coll = '${root}_live';
  final pages = <List<QueryDocument>>[];
  final querySub = onQuery(
    coll,
    where: const [Where.equalTo('site', 'north')],
  ).listen(pages.add);

  await until(() => pages.isNotEmpty, 'the initial query snapshot');
  await setDocument('$coll/a', {'site': 'north'});
  await setDocument('$coll/b', {'site': 'south'});
  await until(() => pages.last.length == 1, 'the matching document');
  // b never appears: the filter is applied at the server, so a document that
  // does not match is not sent and then discarded here.
  note('the filtered listener holds ${pages.last.map((d) => d.id).join(', ')}');
  await querySub.cancel();

  await deleteDocument(path);
  await deleteDocument('$coll/a');
  await deleteDocument('$coll/b');
}

// ── Transactions ──────────────────────────────────────────────────────────

Future<void> _transactions(String root) async {
  step('transactions: read, decide, write, atomically');

  final path = '$root/ledger';
  await setDocument(path, {'balance': 100});

  await runTransaction((tx) async {
    // Firestore requires every read to happen before any write, and this
    // binding enforces it at the call site rather than letting the commit be
    // rejected later.
    final current = await tx.get(path);
    final balance = current!['balance']! as int;
    tx.set(path, {'balance': balance - 30}, merge: true);
  });
  note('after a transfer: ${(await getDocument(path))!['balance']}');

  // A handler that throws aborts: nothing it recorded is written. This is how
  // an app expresses "on second thoughts, no" without a compensating write.
  try {
    await runTransaction((tx) async {
      final current = await tx.get(path);
      if ((current!['balance']! as int) < 100) {
        throw StateError('not enough balance');
      }
      tx.set(path, {'balance': 0}, merge: true);
    });
  } on StateError catch (e) {
    note('the handler refused: ${e.message}');
  }
  note('the balance is untouched: ${(await getDocument(path))!['balance']}');

  await deleteDocument(path);
}

// ── Batches ───────────────────────────────────────────────────────────────

Future<void> _batches(String root) async {
  step('batches: several writes, one commit');

  final coll = '${root}_batch';
  final batch = FirestoreBatch()
    ..set('$coll/a', {'n': 1})
    ..set('$coll/b', {'n': 2})
    ..update('$coll/a', {'n': 10})
    ..delete('$coll/b');
  await batch.commit();

  final docs = await queryCollection(coll);
  note(
    'after one commit: ${docs.map((d) => '${d.id}=${d.data['n']}').join(', ')}',
  );
  note(
    'a batch has no reads and no retry — that is the difference from a '
    'transaction',
  );

  for (final d in docs) {
    await deleteDocument(d.path);
  }
}

// ── Aggregates ────────────────────────────────────────────────────────────

Future<void> _aggregates(String root) async {
  step('aggregates: computed by the server, not by reading every document');

  final coll = '${root}_agg';
  for (var i = 1; i <= 4; i++) {
    await setDocument('$coll/d$i', {'n': i, 'site': i.isEven ? 'a' : 'b'});
  }

  note('count           ${await countCollection(coll)}');
  final inA = await countCollection(
    coll,
    where: const [Where.equalTo('site', 'a')],
  );
  note('count where a   $inA');
  note('sum of n        ${await sumCollection(coll, 'n')}');
  note('average of n    ${await averageCollection(coll, 'n')}');
  // Only the answer crosses the wire, which is the point: counting a large
  // collection this way costs one round trip rather than one per document.
  note('a document with no numeric n is skipped rather than counted as zero');

  for (final d in await queryCollection(coll)) {
    await deleteDocument(d.path);
  }
}

// ── Collection groups ─────────────────────────────────────────────────────

Future<void> _collectionGroup(String run) async {
  step('collection group: every collection with this id, at any depth');

  final id = 'readings_$run';
  await setDocument('sites_$run/north/$id/r1', {'c': 21.5});
  await setDocument('sites_$run/south/$id/r2', {'c': 22.5});

  final group = await queryCollection(id, collectionGroup: true);
  final sites = group.map((d) => d.path.split('/')[1]).join(' and ');
  note('${group.length} documents from $sites');

  await deleteDocument('sites_$run/north/$id/r1');
  await deleteDocument('sites_$run/south/$id/r2');
}
