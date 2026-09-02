// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Authentication for the module, on the same `firebase::App` the Database
/// uses.
///
/// There is no token to pass along: the SDK routes the credential through the
/// App, so signing in here is what makes an already-open `onValue` listener
/// re-authorize and stop failing with "permission denied".
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'database.dart' show hasFirebase;
import 'src/ffi/bindings.dart';

/// What a sign-in returned.
class AuthOutcome {
  const AuthOutcome({required this.uid});

  /// The signed-in user id.
  final String uid;
}

/// Raised when a sign-in fails, carrying the SDK's own code and message rather
/// than a generic failure — an auth error is nearly always actionable
/// (provider disabled, token malformed, clock skew) and only the SDK knows
/// which.
class AuthException implements Exception {
  const AuthException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'AuthException($code): $message';
}

/// Prepares Auth on the shared App. [initDatabase] must have run first.
/// Points Auth at a local emulator. Call after [initAuth] and before signing
/// in — the SDK reconfigures the endpoint rather than migrating a session that
/// already exists.
void useAuthEmulator(String host, int port) {
  if (!hasFirebase) {
    throw StateError(
      'this build has no Firebase SDK — nothing to point at an '
      'emulator',
    );
  }
  final h = host.toNativeUtf8();
  try {
    final rc = fdbAuthUseEmulator(h.cast(), port);
    if (rc != 0) {
      throw StateError('useAuthEmulator failed ($rc)');
    }
  } finally {
    calloc.free(h);
  }
}

void initAuth() {
  if (!hasFirebase) {
    throw StateError(
      'this build has no Firebase SDK — configure with FDB_WITH_FIREBASE=ON '
      'and an SDK on CMAKE_PREFIX_PATH (or an emb augment)',
    );
  }
  final rc = fdbAuthInit();
  if (rc != 0) {
    throw StateError(
      rc == -1
          ? 'auth init before app init — call initDatabase first'
          : 'Auth::GetAuth failed: $rc',
    );
  }
}

Future<AuthOutcome> _awaitSignIn(int Function(int port) start) {
  if (!hasFirebase) {
    return Future.error(
      StateError(
        'this build has no Firebase SDK — configure with FDB_WITH_FIREBASE=ON '
        'and an SDK on CMAKE_PREFIX_PATH (or an emb augment)',
      ),
    );
  }
  final port = ReceivePort();
  final completer = Completer<AuthOutcome>();

  port.listen((message) {
    final parts = message as List<Object?>;
    final ok = parts[0]! as bool;
    if (ok) {
      completer.complete(AuthOutcome(uid: parts[3]! as String));
    } else {
      completer.completeError(
        AuthException(parts[1]! as int, parts[2]! as String),
      );
    }
    port.close();
  });

  final rc = start(port.sendPort.nativePort);
  if (rc != 0) {
    port.close();
    return Future<AuthOutcome>.error(
      StateError(rc == -1 ? 'auth not initialized' : 'sign-in rejected: $rc'),
    );
  }
  return completer.future;
}

/// Anonymous sign-in. The project must have the Anonymous provider enabled.
///
/// Every device gets a distinct throwaway identity, so rules cannot tell them
/// apart — fine for a prototype or genuinely public data, not for a fleet.
Future<AuthOutcome> signInAnonymously() =>
    _awaitSignIn(fdbAuthSignInAnonymously);

/// Custom-token sign-in — the right shape for a device.
///
/// The token is minted by a backend holding the Admin SDK, after that backend
/// has satisfied itself the device is what it claims to be. Its claims are what
/// The signed-in user's ID token, for talking to a Firebase REST endpoint
/// directly.
///
/// Asynchronous because the SDK refreshes an expired token, which is a network
/// call. [forceRefresh] asks for a new one even when the current one is still
/// good.
Future<String> idToken({bool forceRefresh = false}) {
  final completer = Completer<String>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete(parts[2]! as String);
    } else {
      completer.completeError(
        AuthException(parts[1]! as int, parts[2]! as String),
      );
    }
  };
  final rc = fdbAuthIdToken(forceRefresh ? 1 : 0, receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(
      rc == -2
          ? StateError('nobody is signed in')
          : StateError('idToken before initAuth ($rc)'),
    );
  }
  return completer.future;
}

/// database rules key off, so a rule can say "this device" rather than "anyone
/// signed in".
Future<AuthOutcome> signInWithCustomToken(String token) {
  final t = token.toNativeUtf8();
  return _awaitSignIn(
    (port) => fdbAuthSignInWithCustomToken(t.cast(), port),
  ).whenComplete(() => calloc.free(t));
}

void signOut() {
  if (!hasFirebase) return;
  fdbAuthSignOut();
}

/// The signed-in uid, or null.
String? currentUid() {
  // A build with with_firebase: false contains no auth symbols, and the
  // resolver's "Couldn't resolve native function" says nothing about why.
  // Every entry point below checks first, so the answer names the cause.
  if (!hasFirebase) return null;
  const cap = 256;
  final buf = calloc<Uint8>(cap);
  try {
    final len = fdbAuthCurrentUid(buf.cast(), cap);
    if (len <= 0) return null;
    return buf.cast<Utf8>().toDartString(length: len);
  } finally {
    calloc.free(buf);
  }
}

/// Waits briefly for a persisted session to be restored, returning its uid.
///
/// `Auth::GetAuth` returns before the secure store has been read, so
/// `current_user()` is empty for a short window after init even when a session
/// exists. Signing in during that window mints a *new* anonymous user and
/// silently discards the persisted one — which looks exactly like persistence
/// not working.
///
/// Polling rather than an auth-state listener: the restore either lands within
/// a few hundred milliseconds or there is nothing stored, so a bounded wait
/// answers the question without a callback to unregister. Returns null if no
/// session was restored before [timeout].
Future<String?> restoredUid({
  Duration timeout = const Duration(seconds: 3),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final uid = currentUid();
    if (uid != null && uid.isNotEmpty) return uid;
    await Future<void>.delayed(interval);
  }
  return null;
}
