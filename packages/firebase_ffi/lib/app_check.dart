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
import 'src/internal/library_loader.dart';
import 'src/internal/named_apps.dart';
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
  ensureLibraryLoaded();
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
///
/// Every app is answered by [supply] alike. To tell them apart, use
/// [useCustomAppCheckProviderForApps].
void useCustomAppCheckProvider(Future<AppCheckToken> Function() supply) =>
    useCustomAppCheckProviderForApps((_) => supply());

/// [useCustomAppCheckProvider], with [supply] told which app is asking: null
/// for the default app, else the name `initNamedApp` was given.
///
/// Which provider is installed is process-wide, as it is in the SDK: this
/// replaces a debug provider on every app, not on one.
void useCustomAppCheckProviderForApps(
  Future<AppCheckToken> Function(String? app) supply,
) {
  if (!hasFirebase) throw StateError('this build has no Firebase SDK');
  _providerPort?.close();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    // The id is in the header's seq field and the app's name is the payload,
    // empty for the default app.
    final bytes = message! as Uint8List;
    final id = ByteData.sublistView(bytes).getInt64(8, Endian.host);
    final name = utf8.decode(Uint8List.sublistView(bytes, snapshotHeaderBytes));
    unawaited(_answer(id, () => supply(name.isEmpty ? null : name)));
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
    // -1 when the request is no longer parked: its app was deleted while
    // [supply] ran, and the request was failed then.
    fdbAcSupplyToken(id, t.cast(), expiry, code, m.cast());
  } finally {
    calloc
      ..free(t)
      ..free(m);
  }
}

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

String _on(String? app) => app == null || app.isEmpty ? '' : ' on "$app"';

/// Binds App Check to an app: the default one, or the named one [app].
/// `initDatabase` or `initNamedApp` must have made the app first.
///
/// Only needed for [appCheckToken], [setAppCheckAutoRefresh],
/// [limitedUseAppCheckToken] and [appCheckTokenChanges]; the other products
/// attach tokens without it.
void initAppCheck({String? app}) {
  ensureLibraryLoaded();
  if (!hasFirebase) throw StateError('this build has no Firebase SDK');
  final rc = _onApp(app, fdbAcInit);
  if (rc != 0) {
    throw StateError(
      rc != -1
          ? 'App Check instance could not be created ($rc)'
          : app == null || app.isEmpty
          ? 'initAppCheck before the Firebase app was initialized'
          : 'initAppCheck on "$app", which is not an app — call '
                'initNamedApp first',
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

// A token request answered on a port of its own.
Future<AppCheckToken> _request(
  String operation,
  String? app,
  int Function(Pointer<Char> app, int port) start,
) {
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
  final rc = _onApp(app, (a) => start(a, receive.sendPort.nativePort));
  if (rc != 0) {
    receive.close();
    return Future.error(
      StateError('$operation before initAppCheck${_on(app)} ($rc)'),
    );
  }
  return completer.future;
}

/// The current token, for attaching to something this library does not speak —
/// a backend of your own.
///
/// [forceRefresh] asks the provider again rather than answering from cache.
Future<AppCheckToken> appCheckToken({bool forceRefresh = false, String? app}) =>
    _request(
      'appCheckToken',
      app,
      (a, port) => fdbAcGetToken(a, forceRefresh ? 1 : 0, port),
    );

/// Whether the SDK refreshes a token on its own before it expires.
///
/// Off is the right default for a device that attests expensively — a TPM
/// signature on a timer is not free — so this is the app's decision.
void setAppCheckAutoRefresh(bool enabled, {String? app}) {
  final rc = _onApp(app, (a) => fdbAcSetAutoRefresh(a, enabled ? 1 : 0));
  if (rc != 0) {
    throw StateError(
      'setAppCheckAutoRefresh before initAppCheck${_on(app)} ($rc)',
    );
  }
}

/// A token for a single use: not cached, not shared.
///
/// A custom provider serves this without implementing anything further — the
/// SDK's limited-use path falls back to the ordinary one.
Future<AppCheckToken> limitedUseAppCheckToken({String? app}) =>
    _request('limitedUseAppCheckToken', app, fdbAcLimitedUseToken);

/// Tokens as they are issued, including the refreshes the SDK makes on its own.
///
/// One listener per app. `deleteNamedApp` ends a named app's stream.
Stream<AppCheckToken> appCheckTokenChanges({String? app}) {
  _watchDeletes();
  final name = app == null || app.isEmpty ? null : app;
  RawReceivePort? receive;
  void Function()? end;
  late StreamController<AppCheckToken> controller;
  void drop() {
    receive?.close();
    receive = null;
    if (name != null && end != null) _changes[name]?.remove(end);
  }

  controller = StreamController<AppCheckToken>(
    onListen: () {
      final port = RawReceivePort();
      port.handler = (Object? message) {
        try {
          controller.add(_readToken(message! as Uint8List));
        } on Object catch (e) {
          controller.addError(e);
        }
      };
      final rc = _onApp(
        name,
        (a) => fdbAcAddListener(a, port.sendPort.nativePort),
      );
      if (rc != 0) {
        port.close();
        controller.addError(
          StateError(
            rc == -3
                ? 'a token listener is already registered${_on(name)}'
                : 'appCheckTokenChanges before initAppCheck${_on(name)} ($rc)',
          ),
        );
        return;
      }
      receive = port;
      if (name != null) {
        final ended = end = () {
          drop();
          unawaited(controller.close());
        };
        (_changes[name] ??= <void Function()>{}).add(ended);
      }
    },
    onCancel: () {
      // Null once the app was deleted: its listener went with it.
      if (receive == null) return;
      _onApp(name, fdbAcRemoveListener);
      drop();
    },
  );
  return controller.stream;
}

// What ends each named app's token streams when the app is deleted. The
// native listener went with the app.
final _changes = <String, Set<void Function()>>{};
bool _watchingDeletes = false;

void _watchDeletes() {
  if (_watchingDeletes) return;
  _watchingDeletes = true;
  namedAppDeleted.add((deleted) {
    final ends = _changes.remove(deleted);
    if (ends == null) return;
    for (final end in ends.toList()) {
      end();
    }
  });
}
