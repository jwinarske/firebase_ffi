// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Cloud Functions: calling a callable, on the app Auth already signed into.
///
/// Arguments and results travel as the same CBOR the Realtime Database uses,
/// so a map, a list, bytes or a number crosses without anything extra.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'database.dart' show hasFirebase;
import 'src/ffi/bindings.dart';
import 'src/internal/library_loader.dart';
import 'src/variant_codec.dart';

/// A callable that failed, carrying the SDK's own code and message.
class FunctionsException implements Exception {
  const FunctionsException(this.code, this.message, this.name);
  final int code;
  final String message;
  final String name;

  @override
  String toString() => 'FunctionsException($name, $code): $message';
}

/// True when the library was built with Functions bound.
bool get hasFunctions {
  ensureLibraryLoaded();
  if (!hasFirebase) return false;
  try {
    return fdbHaveFunctions() != 0;
  } on ArgumentError {
    return false;
  }
}

/// Binds Functions to the app already initialized by [initDatabase].
///
/// [region] selects a non-default region, as the other SDKs spell it
/// (`us-central1` and so on); empty means the default.
void initFunctions({String region = ''}) {
  ensureLibraryLoaded();
  if (!hasFirebase) {
    throw StateError('this build has no Firebase SDK');
  }
  final r = region.toNativeUtf8();
  try {
    final rc = fdbFunctionsInit(r.cast());
    if (rc != 0) {
      throw StateError(
        rc == -1
            ? 'initFunctions before the Firebase app was initialized'
            : 'Functions instance could not be created ($rc)',
      );
    }
  } finally {
    calloc.free(r);
  }
}

/// Points Functions at a local emulator. [origin] is a URL, not a host and
/// port — the SDK takes it whole.
void useFunctionsEmulator(String origin) {
  final o = origin.toNativeUtf8();
  try {
    final rc = fdbFunctionsUseEmulator(o.cast());
    if (rc != 0) {
      throw StateError('useFunctionsEmulator failed ($rc)');
    }
  } finally {
    calloc.free(o);
  }
}

/// Calls the callable named [name].
///
/// [data] is encoded as CBOR and arrives at the function as JSON-shaped data;
/// the result comes back decoded the same way.
Future<Object?> callFunction(String name, [Object? data]) {
  final completer = Completer<Object?>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final bytes = message! as Uint8List;
    final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
    if (seq < 0) {
      final reason = decodeSnapshotValue(bytes);
      completer.completeError(
        FunctionsException(
          seq.toInt(),
          seq == -2
              ? 'the result could not be encoded'
              : '${reason ?? "failed"}',
          name,
        ),
      );
      return;
    }
    completer.complete(decodeSnapshotValue(bytes));
  };

  final encoded = data == null
      ? Uint8List(0)
      : Uint8List.fromList(encodeVariant(data));
  final n = name.toNativeUtf8();
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  if (encoded.isNotEmpty) {
    buf.asTypedList(encoded.length).setAll(0, encoded);
  }
  final rc = fdbFunctionsCall(
    n.cast(),
    buf,
    encoded.length,
    receive.sendPort.nativePort,
  );
  calloc
    ..free(n)
    ..free(buf);
  if (rc != 0) {
    receive.close();
    return Future.error(
      rc == -3
          ? ArgumentError('these arguments cannot be encoded')
          : StateError('call $name failed to start ($rc)'),
    );
  }
  return completer.future;
}
