// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Decoder for the snapshot payloads the native side posts.
///
/// The payload is CBOR (RFC 8949), decoded here by a conformant package rather
/// than by a reader written to match one particular encoder. That matters more
/// than it sounds: the previous encoding was private, so both halves were kept
/// in step by hand and a mistake on either side produced plausible-looking
/// wrong data. A standard format moves that failure into a decoder this project
/// did not write, which rejects malformed input instead of interpreting it.
///
/// The [Uint8List] handed in is the C allocation itself (`kExternalTypedData`),
/// so the bytes are read from native memory directly. Only the Dart objects
/// this produces are new.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// Byte offset of the payload within a snapshot buffer, past FdbSnapshotHeader.
const snapshotHeaderBytes = 32;

/// Decodes the value a snapshot buffer carries.
///
/// [bytes] is the whole buffer including the header; decoding starts at
/// [snapshotHeaderBytes]. Returns null for an empty payload, which is how a
/// canceled stream arrives.
///
/// Throws [FormatException] if the buffer is shorter than its header, or if the
/// payload is not well-formed CBOR.
Object? decodeSnapshotValue(Uint8List bytes) {
  if (bytes.length < snapshotHeaderBytes) {
    throw const FormatException('snapshot shorter than its header');
  }
  if (bytes.length == snapshotHeaderBytes) return null;

  // Bounded by value_len, not by the end of the buffer: a Database snapshot
  // carries its child order after the value.
  final valueLen = ByteData.sublistView(bytes).getUint32(24, Endian.host);
  final end = valueLen == 0 ? bytes.length : snapshotHeaderBytes + valueLen;

  // A view, not a copy: the payload stays in the buffer the native side posted.
  final payload = Uint8List.sublistView(bytes, snapshotHeaderBytes, end);
  try {
    return cborDecode(payload).toObject();
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    // The package throws its own types for malformed input; present them as the
    // one kind of failure a caller has to handle.
    throw FormatException('malformed CBOR payload: $e');
  }
}

/// A plain Dart value as CBOR, for the products that speak `firebase::Variant`
/// rather than Firestore's tagged types.
///
/// Kept here rather than reusing Firestore's encoder: that one attaches tags a
/// Variant has no meaning for, and importing it would make a Functions-only
/// build depend on Firestore.
CborValue encodeVariantValue(Object? v) {
  if (v == null) return const CborNull();
  if (v is bool) return CborBool(v);
  if (v is int) return CborInt(BigInt.from(v));
  if (v is double) return CborFloat(v);
  if (v is String) return CborString(v);
  if (v is Uint8List) return CborBytes(v);
  if (v is List) return CborList(v.map(encodeVariantValue).toList());
  if (v is Map) {
    return CborMap({
      for (final e in v.entries)
        encodeVariantValue(e.key): encodeVariantValue(e.value),
    });
  }
  throw ArgumentError.value(v, 'value', 'has no CBOR representation');
}

/// [encodeVariantValue], encoded to bytes.
Uint8List encodeVariant(Object? v) =>
    Uint8List.fromList(cborEncode(encodeVariantValue(v)));

/// The child keys a Database snapshot carries, in the order the query produced
/// them, or null when the buffer has none.
///
/// The value alone cannot answer this: it is a Variant map, which the C++ SDK
/// sorts by key, so `orderByChild` is gone from it by the time it is encoded.
/// The native side reads `DataSnapshot::children()` and appends this.
DbChildOrder? decodeSnapshotOrder(Uint8List bytes) {
  if (bytes.length < snapshotHeaderBytes) return null;
  final view = ByteData.sublistView(bytes);
  final valueLen = view.getUint32(24, Endian.host);
  final orderLen = view.getUint32(28, Endian.host);
  if (orderLen == 0) return null;

  final start = snapshotHeaderBytes + valueLen;
  if (start + orderLen > bytes.length) return null;
  try {
    return DbChildOrder._decode(
      cborDecode(
        Uint8List.sublistView(bytes, start, start + orderLen),
      ).toObject(),
    );
  } on Object {
    // An order that will not decode is not worth failing a snapshot over: the
    // value is still good, and children falls back to the map's own order.
    return null;
  }
}

/// The order of one node's children, and of theirs.
class DbChildOrder {
  const DbChildOrder(this.keys, this.children);

  /// Child keys, in the order the query produced them.
  final List<String> keys;

  /// The order within each child that has one of its own.
  final Map<String, DbChildOrder> children;

  static DbChildOrder? _decode(Object? encoded) {
    if (encoded is! List) return null;
    final keys = <String>[];
    final children = <String, DbChildOrder>{};
    for (final entry in encoded) {
      if (entry is! List || entry.length != 2) continue;
      final key = '${entry[0]}';
      keys.add(key);
      final sub = _decode(entry[1]);
      if (sub != null) children[key] = sub;
    }
    return DbChildOrder(keys, children);
  }
}
