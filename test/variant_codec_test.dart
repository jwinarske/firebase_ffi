// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The payload is CBOR, so these no longer pin a private tag table. What is
// worth testing is the part this project still owns: the header boundary, the
// empty-payload convention, and that malformed input is refused rather than
// interpreted.
//
// The values themselves are round-tripped through the same package the decoder
// uses, which checks the framing rather than re-testing RFC 8949.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:firebase_ffi/src/variant_codec.dart';
import 'package:test/test.dart';

/// A snapshot buffer: a zeroed header followed by [value] encoded as CBOR.
Uint8List frame(CborValue value) => Uint8List.fromList(
  List<int>.filled(snapshotHeaderBytes, 0) + cborEncode(value),
);

void main() {
  test('null', () {
    expect(decodeSnapshotValue(frame(const CborNull())), isNull);
  });

  test('bool, int, double, string', () {
    expect(decodeSnapshotValue(frame(const CborBool(true))), isTrue);
    expect(decodeSnapshotValue(frame(CborSmallInt(-42))), -42);
    expect(decodeSnapshotValue(frame(CborFloat(1.5))), 1.5);
    expect(decodeSnapshotValue(frame(CborString('héllo ✅'))), 'héllo ✅');
  });

  test('bytes survive as bytes', () {
    // The previous encoding had no byte-string type and wrote null instead.
    final v = decodeSnapshotValue(frame(CborBytes([1, 2, 3, 250])));
    expect(v, isA<List<int>>());
    expect(v, [1, 2, 3, 250]);
  });

  test('array of mixed types', () {
    final v = decodeSnapshotValue(
      frame(CborList([CborSmallInt(7), CborString('x'), const CborNull()])),
    );
    expect(v, [7, 'x', null]);
  });

  test('map, with a nested container', () {
    final v = decodeSnapshotValue(
      frame(
        CborMap({
          CborString('a'): const CborBool(true),
          CborString('b'): CborList([CborSmallInt(9)]),
        }),
      ),
    );
    expect(v, {
      'a': true,
      'b': [9],
    });
  });

  test('an empty payload is a cancelled stream, not an error', () {
    expect(decodeSnapshotValue(Uint8List(snapshotHeaderBytes)), isNull);
  });

  test('a buffer shorter than the header is rejected', () {
    expect(
      () => decodeSnapshotValue(Uint8List(8)),
      throwsA(isA<FormatException>()),
    );
  });

  test('a malformed payload is refused rather than interpreted', () {
    // 0x9b announces an 8-byte array length that is not there.
    final bad = Uint8List.fromList(
      List<int>.filled(snapshotHeaderBytes, 0) + [0x9b, 0xff],
    );
    expect(() => decodeSnapshotValue(bad), throwsA(isA<FormatException>()));
  });
}
