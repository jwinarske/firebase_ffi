// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The decoder is kept in step with Serialize() in native/src/firebase_impl.cpp
// by hand. These build buffers to the wire format the C++ side writes, so a
// tag renumbered on one side and not the other fails here rather than showing
// up as quietly wrong data in a snapshot.

import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ffi/src/variant_codec.dart';
import 'package:test/test.dart';

/// Builds a payload the way the native encoder does, behind the 32-byte header.
class Payload {
  final _bytes = BytesBuilder();

  void u8(int v) => _bytes.addByte(v);

  void u32(int v) => _bytes.add(
    (ByteData(4)..setUint32(0, v, Endian.host)).buffer.asUint8List(),
  );

  void i64(int v) => _bytes.add(
    (ByteData(8)..setInt64(0, v, Endian.host)).buffer.asUint8List(),
  );

  void f64(double v) => _bytes.add(
    (ByteData(8)..setFloat64(0, v, Endian.host)).buffer.asUint8List(),
  );

  void str(String s) {
    final u = utf8.encode(s);
    u32(u.length);
    _bytes.add(u);
  }

  Uint8List build() => Uint8List.fromList(
    List<int>.filled(snapshotHeaderBytes, 0) + _bytes.takeBytes(),
  );
}

void main() {
  test('null', () {
    expect(decodeSnapshotValue((Payload()..u8(VariantTag.nul)).build()), isNull);
  });

  test('bool', () {
    expect(
      decodeSnapshotValue((Payload()..u8(VariantTag.boolean)..u8(1)).build()),
      isTrue,
    );
    expect(
      decodeSnapshotValue((Payload()..u8(VariantTag.boolean)..u8(0)).build()),
      isFalse,
    );
  });

  test('int, including negative', () {
    expect(
      decodeSnapshotValue((Payload()..u8(VariantTag.integer)..i64(-42)).build()),
      -42,
    );
  });

  test('double', () {
    expect(
      decodeSnapshotValue((Payload()..u8(VariantTag.float)..f64(1.5)).build()),
      1.5,
    );
  });

  test('string, including non-ASCII', () {
    expect(
      decodeSnapshotValue((Payload()..u8(VariantTag.string)..str('héllo ✅')).build()),
      'héllo ✅',
    );
  });

  test('vector of mixed types', () {
    final p = Payload()
      ..u8(VariantTag.vector)
      ..u32(3)
      ..u8(VariantTag.integer)
      ..i64(7)
      ..u8(VariantTag.string)
      ..str('x')
      ..u8(VariantTag.nul);
    expect(decodeSnapshotValue(p.build()), [7, 'x', null]);
  });

  test('map, with a nested container', () {
    final p = Payload()
      ..u8(VariantTag.map)
      ..u32(2)
      ..u8(VariantTag.string)
      ..str('a')
      ..u8(VariantTag.boolean)
      ..u8(1)
      ..u8(VariantTag.string)
      ..str('b')
      ..u8(VariantTag.vector)
      ..u32(1)
      ..u8(VariantTag.integer)
      ..i64(9);
    expect(decodeSnapshotValue(p.build()), {
      'a': true,
      'b': [9],
    });
  });

  test('a non-string map key is skipped, not treated as corruption', () {
    // The encoder writes kTagNull for a key it cannot represent; the value
    // still has to be consumed so the stream stays aligned.
    final p = Payload()
      ..u8(VariantTag.map)
      ..u32(2)
      ..u8(VariantTag.nul)
      ..u8(VariantTag.integer)
      ..i64(1)
      ..u8(VariantTag.string)
      ..str('kept')
      ..u8(VariantTag.integer)
      ..i64(2);
    expect(decodeSnapshotValue(p.build()), {'kept': 2});
  });

  test('an empty payload is a cancelled stream, not an error', () {
    expect(decodeSnapshotValue(Payload().build()), isNull);
  });

  test('an unknown tag is rejected rather than misparsed', () {
    expect(
      () => decodeSnapshotValue((Payload()..u8(99)).build()),
      throwsA(isA<FormatException>()),
    );
  });

  test('a buffer shorter than the header is rejected', () {
    expect(
      () => decodeSnapshotValue(Uint8List(8)),
      throwsA(isA<FormatException>()),
    );
  });
}
