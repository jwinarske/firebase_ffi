// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// App Check: attesting that a request comes from this app.
///
/// The token is not passed around by hand. Once a provider is installed, the
/// desktop SDK's Firestore, Database, Storage and Functions pick it up
/// themselves — so installing a provider is most of what this library does.
///
/// Desktop has two providers and no third. App Attest, DeviceCheck and Play
/// Integrity are stubs off iOS and Android, and none of them would mean
/// anything on an embedded board:
///
///   * [useDebugAppCheckProvider] — the SDK's own, for development.
///   * [useCustomAppCheckProvider] — the token comes from your callback. This
///     is the one that matters here: a device attesting by some means of its
///     own has nowhere else to put the result.
///
/// Install before [initDatabase] and before anything else makes a request. A
/// provider installed afterwards has missed the requests already sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'database.dart' show hasFirebase;
import 'src/ffi/bindings.dart';
import 'src/variant_codec.dart' show snapshotHeaderBytes;

/// An App Check operation that failed.
class AppCheckException implements Exception {
  const AppCheckException(this.code, this.message, this.operation);
  final int code;
  final String message;
  final String operation;

  @override
  String toString() => 'AppCheckException($operation, $code): $message';
}

/// A token and the moment it stops being valid.
class AppCheckToken {
  const AppCheckToken(this.token, this.expiresAt);

  final String token;

  /// Absolute, not a duration: it is what the SDK caches against.
  final DateTime expiresAt;

  @override
  String toString() =>
      'AppCheckToken(${token.length} chars, expires $expiresAt)';
}

/// True when the library was built with App Check bound.
bool get hasAppCheck {
  if (!hasFirebase) return false;
  try {
    return fdbHaveAppCheck() != 0;
  } on ArgumentError {
    return false;
  }
}

/// Installs the SDK's debug provider.
///
/// For development: the token has to be registered in the Firebase console,
/// and it attests to nothing. An empty [debugToken] leaves the SDK reading
/// `APP_CHECK_DEBUG_TOKEN` from the environment itself.
void useDebugAppCheckProvider({String debugToken = ''}) {
  if (!hasFirebase) throw StateError('this build has no Firebase SDK');
  final t = debugToken.toNativeUtf8();
  try {
    final rc = fdbAcUseDebugProvider(t.cast());
    if (rc != 0) {
      throw StateError('the debug provider could not be installed ($rc)');
    }
  } finally {
    calloc.free(t);
  }
}

RawReceivePort? _providerPort;

/// Installs a provider that asks [supply] whenever the SDK needs a token.
///
/// [supply] does the attesting — reads a TPM, calls a vendor service, unseals
/// a provisioning record — and returns the token with its expiry. Throwing
/// fails that one request; the SDK will ask again.
///
/// The SDK waits for an answer and nothing here times it out, so [supply] must
/// return or throw. It runs on the Dart isolate that installed the provider,
/// not on the SDK thread that asked.
void useCustomAppCheckProvider(Future<AppCheckToken> Function() supply) {
  if (!hasFirebase) throw StateError('this build has no Firebase SDK');
  _providerPort?.close();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    // The request carries nothing but its id, in the header's seq field.
    final bytes = message! as Uint8List;
    final id = ByteData.sublistView(bytes).getInt64(8, Endian.host);
    unawaited(_answer(id, supply));
  };
  _providerPort = receive;
  final rc = fdbAcUseCustomProvider(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    _providerPort = null;
    throw StateError('the custom provider could not be installed ($rc)');
  }
}

Future<void> _answer(int id, Future<AppCheckToken> Function() supply) async {
  String token = '';
  int expiry = 0;
  int code = 0;
  String message = '';
  try {
    final result = await supply();
    token = result.token;
    expiry = result.expiresAt.millisecondsSinceEpoch;
  } on Object catch (e) {
    // 5 is the SDK's unknown-error code. Whatever went wrong attesting, the
    // request has to be failed rather than left parked.
    code = 5;
    message = '$e';
  }
  final t = token.toNativeUtf8();
  final m = message.toNativeUtf8();
  try {
    fdbAcSupplyToken(id, t.cast(), expiry, code, m.cast());
  } finally {
    calloc
      ..free(t)
      ..free(m);
  }
}

/// Binds App Check to the app already initialized by `initDatabase`.
///
/// Only needed for [appCheckToken] and [appCheckTokenChanges]; the other
/// products attach tokens without it.
void initAppCheck() {
  if (!hasFirebase) throw StateError('this build has no Firebase SDK');
  final rc = fdbAcInit();
  if (rc != 0) {
    throw StateError(
      rc == -1
          ? 'initAppCheck before the Firebase app was initialized'
          : 'App Check instance could not be created ($rc)',
    );
  }
}

AppCheckToken _readToken(Uint8List bytes) {
  final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
  final payload = Uint8List.sublistView(bytes, snapshotHeaderBytes);
  if (seq < 0) {
    throw AppCheckException(-seq, utf8.decode(payload), 'getToken');
  }
  return AppCheckToken(
    utf8.decode(payload),
    DateTime.fromMillisecondsSinceEpoch(seq),
  );
}

/// The current token, for attaching to something this library does not speak —
/// a backend of your own.
///
/// [forceRefresh] asks the provider again rather than answering from cache.
Future<AppCheckToken> appCheckToken({bool forceRefresh = false}) {
  final completer = Completer<AppCheckToken>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    try {
      completer.complete(_readToken(message! as Uint8List));
    } on Object catch (e) {
      completer.completeError(e);
    }
  };
  final rc = fdbAcGetToken(forceRefresh ? 1 : 0, receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('appCheckToken before initAppCheck ($rc)'));
  }
  return completer.future;
}

/// Tokens as they are issued, including the refreshes the SDK makes on its own.
Stream<AppCheckToken> appCheckTokenChanges() {
  late RawReceivePort receive;
  late StreamController<AppCheckToken> controller;
  controller = StreamController<AppCheckToken>(
    onListen: () {
      receive = RawReceivePort();
      receive.handler = (Object? message) {
        try {
          controller.add(_readToken(message! as Uint8List));
        } on Object catch (e) {
          controller.addError(e);
        }
      };
      final rc = fdbAcAddListener(receive.sendPort.nativePort);
      if (rc != 0) {
        receive.close();
        controller.addError(
          StateError(
            rc == -3
                ? 'a token listener is already registered'
                : 'appCheckTokenChanges before initAppCheck ($rc)',
          ),
        );
      }
    },
    onCancel: () {
      fdbAcRemoveListener();
      receive.close();
    },
  );
  return controller.stream;
}
