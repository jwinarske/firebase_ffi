// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Firestore value mapping, both directions, without Firestore linked.
//
// The tags are shared with native/include/firebase_bridge.h by number, so
// these pin the numbers as well as the behaviour: a tag renumbered on one side
// only will fail here.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:test/test.dart';

Object? roundTrip(Object? v) =>
    decodeFirestoreValue(cborDecode(cborEncode(encodeFirestoreValue(v))));

void main() {
  test('tag numbers match the C ABI', () {
    // firebase_bridge.h: 40000 timestamp, 40001 geopoint, 40002 reference,
    // 40010..40015 sentinels.
    expect(FirestoreTag.timestamp, 40000);
    expect(FirestoreTag.geoPoint, 40001);
    expect(FirestoreTag.reference, 40002);
    expect(FirestoreTag.delete, 40010);
    expect(FirestoreTag.serverTimestamp, 40011);
    expect(FirestoreTag.arrayUnion, 40012);
    expect(FirestoreTag.arrayRemove, 40013);
    expect(FirestoreTag.incrementInt, 40014);
    expect(FirestoreTag.incrementDouble, 40015);
  });

  test('plain values survive a round trip', () {
    expect(roundTrip(null), isNull);
    expect(roundTrip(true), isTrue);
    expect(roundTrip(-42), -42);
    expect(roundTrip(1.5), 1.5);
    expect(roundTrip('héllo ✅'), 'héllo ✅');
    expect(roundTrip([1, 'x', null]), [1, 'x', null]);
    expect(roundTrip({'a': 1}), {'a': 1});
  });

  test('bytes stay bytes', () {
    expect(roundTrip(Uint8List.fromList([1, 2, 250])), [1, 2, 250]);
  });

  test('timestamp keeps nanoseconds', () {
    // The reason for two integers rather than RFC 8949 tag 1: a float64 epoch
    // cannot represent this without rounding.
    const t = FirestoreTimestamp(1735689600, 123456789);
    final back = roundTrip(t)! as FirestoreTimestamp;
    expect(back.seconds, 1735689600);
    expect(back.nanoseconds, 123456789);
    expect(back, t);
  });

  test('geopoint and reference', () {
    expect(roundTrip(const FirestoreGeoPoint(51.5, -0.12)),
        const FirestoreGeoPoint(51.5, -0.12));
    expect(roundTrip(const FirestoreReference('users/abc')),
        const FirestoreReference('users/abc'));
  });

  test('nested containers keep their tagged values', () {
    final doc = {
      'when': const FirestoreTimestamp(1, 2),
      'where': const FirestoreGeoPoint(1.0, 2.0),
      'tags': ['a', 'b'],
      'nested': {'ref': const FirestoreReference('x/y')},
    };
    final back = roundTrip(doc)! as Map<String, Object?>;
    expect(back['when'], const FirestoreTimestamp(1, 2));
    expect(back['where'], const FirestoreGeoPoint(1.0, 2.0));
    expect(back['tags'], ['a', 'b']);
    expect((back['nested']! as Map)['ref'], const FirestoreReference('x/y'));
  });

  test('sentinels encode, and are refused on the way back', () {
    // They are instructions to the server. Firestore never returns one, so
    // decoding one means the payload is not a document.
    for (final s in [
      FirestoreSentinel.delete,
      FirestoreSentinel.serverTimestamp,
      FirestoreSentinel.arrayUnion(['a']),
      FirestoreSentinel.arrayRemove(['b']),
      FirestoreSentinel.increment(1),
      FirestoreSentinel.increment(1.5),
    ]) {
      final encoded = cborEncode(encodeFirestoreValue(s));
      expect(encoded, isNotEmpty);
      expect(
        () => decodeFirestoreValue(cborDecode(encoded)),
        throwsA(isA<FormatException>()),
        reason: 'a sentinel must not decode as a value',
      );
    }
  });

  test('an unmappable type is refused rather than guessed at', () {
    expect(() => encodeFirestoreValue(DateTime.now()), throwsArgumentError);
  });
}
