// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Decoder for the tagged flat encoding the native side writes a
/// `firebase::Variant` into.
///
/// The buffer is one depth-first pass: a tag byte, then that node's payload,
/// with containers writing a count and then their children inline. There are no
/// child offsets, so this walks rather than seeks — adding offsets is what
/// would let a caller read one subtree without touching the rest, and is the
/// next step if profiling says materializing is the cost.
///
/// The `Uint8List` handed in is the C allocation itself (`kExternalTypedData`),
/// so reads here touch native memory directly. Only the Dart objects this
/// builds are new.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Tags, matching the enum in native/src/firebase_impl.cpp. Kept in step by
/// hand: a mismatch shows up as [FormatException] on the first snapshot rather
/// than as silently wrong data, because unknown tags are rejected.
abstract final class VariantTag {
  static const nul = 0;
  static const boolean = 1;
  static const integer = 2;
  static const float = 3;
  static const string = 4;
  static const vector = 5;
  static const map = 6;
}

/// Byte offset of the payload within a snapshot buffer, past FdbSnapshotHeader.
const snapshotHeaderBytes = 32;

/// Decodes the Variant a snapshot buffer carries.
///
/// [bytes] is the whole buffer including the header; decoding starts at
/// [snapshotHeaderBytes].
Object? decodeSnapshotValue(Uint8List bytes) {
  if (bytes.length < snapshotHeaderBytes) {
    throw const FormatException('snapshot shorter than its header');
  }
  final r = _Reader(ByteData.sublistView(bytes), bytes, snapshotHeaderBytes);
  if (r.atEnd) return null; // an empty payload is a cancelled stream
  final value = r.readValue();
  return value;
}

class _Reader {
  _Reader(this.data, this.bytes, this.offset);
  final ByteData data;
  final Uint8List bytes;
  int offset;

  bool get atEnd => offset >= data.lengthInBytes;

  int _u8() => data.getUint8(offset++);

  int _u32() {
    final v = data.getUint32(offset, Endian.host);
    offset += 4;
    return v;
  }

  int _i64() {
    final v = data.getInt64(offset, Endian.host);
    offset += 8;
    return v;
  }

  double _f64() {
    final v = data.getFloat64(offset, Endian.host);
    offset += 8;
    return v;
  }

  String _string() {
    final len = _u32();
    // A view over the same backing store, decoded once. utf8.decode copies
    // into a Dart String — unavoidable, since a Dart String cannot alias
    // foreign memory.
    final s = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + len),
      allowMalformed: true,
    );
    offset += len;
    return s;
  }

  Object? readValue() {
    final tag = _u8();
    switch (tag) {
      case VariantTag.nul:
        return null;
      case VariantTag.boolean:
        return _u8() != 0;
      case VariantTag.integer:
        return _i64();
      case VariantTag.float:
        return _f64();
      case VariantTag.string:
        return _string();
      case VariantTag.vector:
        final n = _u32();
        return List<Object?>.generate(n, (_) => readValue(), growable: false);
      case VariantTag.map:
        final n = _u32();
        final out = <String, Object?>{};
        for (var i = 0; i < n; i++) {
          // Keys are written with their own tag so a non-string key is
          // representable rather than corrupting the stream.
          final keyTag = _u8();
          final key = keyTag == VariantTag.string ? _string() : null;
          final value = readValue();
          if (key != null) out[key] = value;
        }
        return out;
      default:
        throw FormatException('unknown variant tag $tag at ${offset - 1}');
    }
  }
}
