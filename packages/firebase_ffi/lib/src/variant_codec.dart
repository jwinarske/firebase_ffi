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

  // A view, not a copy: the payload stays in the buffer the native side posted.
  final payload = Uint8List.sublistView(bytes, snapshotHeaderBytes);
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
