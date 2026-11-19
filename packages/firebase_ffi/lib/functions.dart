// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Cloud Functions: calling a callable, on the default app or a named one, as
/// whoever is signed in on that app.
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

/// What a call can vary besides its arguments.
class CallOptions {
  const CallOptions({
    this.region = '',
    this.limitedUseAppCheckToken = false,
    this.app,
  });

  /// The region whose instance makes the call. It has to have been through
  /// [initFunctions] on [app]. Empty means the first region initialized on it.
  final String region;

  /// The app that makes the call: the name `initNamedApp` was given, or null
  /// for the default app.
  final String? app;

  /// Asks App Check for a limited-use token for this call rather than sending
  /// the cached one. Needs an App Check provider; without one no token is sent
  /// either way.
  final bool limitedUseAppCheckToken;
}

/// Prepares Functions on an app: the default one, or the named one [app].
/// `initDatabase` or `initNamedApp` must have made the app first.
///
/// [region] is spelled as the other SDKs spell it (`us-central1` and so on);
/// empty means `us-central1`. Each region is its own instance, so call this
/// once per region the app uses. The first one initialized on an app is what
/// an empty region means on it everywhere else.
void initFunctions({String region = '', String? app}) {
  ensureLibraryLoaded();
  if (!hasFirebase) {
    throw StateError('this build has no Firebase SDK');
  }
  final r = region.toNativeUtf8();
  try {
    final rc = _onApp(app, (a) => fdbFunctionsInit(a, r.cast()));
    if (rc != 0) {
      throw StateError(
        rc != -1
            ? 'Functions instance could not be created ($rc)'
            : app == null || app.isEmpty
            ? 'initFunctions before the Firebase app was initialized'
            : 'initFunctions on "$app", which is not an app — call '
                  'initNamedApp first',
      );
    }
  } finally {
    calloc.free(r);
  }
}

/// Points one region's Functions at a local emulator. [origin] is a URL, not a
/// host and port — the SDK takes it whole.
///
/// Each app and region keeps its own origin. A call by URL ignores it.
void useFunctionsEmulator(String origin, {String region = '', String? app}) {
  final r = region.toNativeUtf8();
  final o = origin.toNativeUtf8();
  try {
    final rc = _onApp(
      app,
      (a) => fdbFunctionsUseEmulator(a, r.cast(), o.cast()),
    );
    if (rc != 0) {
      throw StateError(
        rc == -1
            ? 'useFunctionsEmulator before initFunctions${_forRegion(region)}'
            : 'useFunctionsEmulator failed ($rc)',
      );
    }
  } finally {
    calloc
      ..free(r)
      ..free(o);
  }
}

/// Calls the callable named [name].
///
/// [data] is encoded as CBOR and arrives at the function as JSON-shaped data;
/// the result comes back decoded the same way.
Future<Object?> callFunction(
  String name, [
  Object? data,
  CallOptions options = const CallOptions(),
]) => _call(name, data, options, 0);

/// Calls the callable at [url], for one that is not at the address its name
/// and region would give.
///
/// The URL is used as given: neither the region nor an emulator origin
/// changes it.
Future<Object?> callFunctionAtUrl(
  String url, [
  Object? data,
  CallOptions options = const CallOptions(),
]) => _call(url, data, options, _flagUrl);

// FDB_FUNCTIONS_CALL_* in firebase_bridge.h.
const _flagUrl = 1;
const _flagLimitedUse = 2;

String _forRegion(String region) => region.isEmpty ? '' : ' for $region';

// The app a call acts on, as the native side takes it: null for the default
// app, else its name for the length of the call.
T _onApp<T>(String? app, T Function(Pointer<Char> app) call) {
  if (app == null || app.isEmpty) return call(nullptr);
  final native = app.toNativeUtf8();
  try {
    return call(native.cast());
  } finally {
    calloc.free(native);
  }
}

Future<Object?> _call(
  String target,
  Object? data,
  CallOptions options,
  int flags,
) {
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
          target,
        ),
      );
      return;
    }
    completer.complete(decodeSnapshotValue(bytes));
  };

  final encoded = data == null
      ? Uint8List(0)
      : Uint8List.fromList(encodeVariant(data));
  final r = options.region.toNativeUtf8();
  final t = target.toNativeUtf8();
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  if (encoded.isNotEmpty) {
    buf.asTypedList(encoded.length).setAll(0, encoded);
  }
  final rc = _onApp(
    options.app,
    (a) => fdbFunctionsCall(
      a,
      r.cast(),
      t.cast(),
      flags | (options.limitedUseAppCheckToken ? _flagLimitedUse : 0),
      buf,
      encoded.length,
      receive.sendPort.nativePort,
    ),
  );
  calloc
    ..free(r)
    ..free(t)
    ..free(buf);
  if (rc != 0) {
    receive.close();
    return Future.error(switch (rc) {
      -1 => StateError(
        'call $target before initFunctions${_forRegion(options.region)}',
      ),
      -3 => ArgumentError('these arguments cannot be encoded'),
      _ => StateError('call $target failed to start ($rc)'),
    });
  }
  return completer.future;
}
