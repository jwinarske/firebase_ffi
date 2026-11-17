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
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:ffi/ffi.dart';

import 'database.dart' show hasFirebase;
import 'src/ffi/bindings.dart';
import 'src/internal/library_loader.dart';

// Whether this build bound the SDK at all, for a caller that imports only auth.
export 'database.dart' show hasFirebase;

/// What the SDK holds about one identity: the account itself, or the same
/// account as one of its providers sees it.
///
/// A field the account does not have is null. The SDK reports those as empty
/// strings, and they are dropped on the native side so that "no email" and
/// "an empty email" are not the same answer.
class AuthUserInfo {
  const AuthUserInfo({
    required this.uid,
    this.email,
    this.displayName,
    this.photoUrl,
    this.phoneNumber,
    this.providerId,
  });

  AuthUserInfo._fromMap(Map<Object?, Object?> map)
    : uid = map['uid'] as String? ?? '',
      email = map['email'] as String?,
      displayName = map['displayName'] as String?,
      photoUrl = map['photoUrl'] as String?,
      phoneNumber = map['phoneNumber'] as String?,
      providerId = map['providerId'] as String?;

  /// The Firebase uid for the account; for an entry in
  /// [AuthUser.providerData], the id the provider knows the user by.
  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;
  final String? phoneNumber;

  /// `password`, `google.com`, and so on; `firebase` for the account itself.
  final String? providerId;
}

/// The signed-in user, as the SDK reports it.
class AuthUser extends AuthUserInfo {
  const AuthUser({
    required super.uid,
    super.email,
    super.displayName,
    super.photoUrl,
    super.phoneNumber,
    super.providerId,
    this.isAnonymous = false,
    this.isEmailVerified = false,
    this.creationTime,
    this.lastSignInTime,
    this.providerData = const [],
  });

  AuthUser._fromMap(super.map)
    : isAnonymous = map['isAnonymous'] as bool? ?? false,
      isEmailVerified = map['isEmailVerified'] as bool? ?? false,
      creationTime = _time(map['creationTimestamp']),
      lastSignInTime = _time(map['lastSignInTimestamp']),
      providerData = [
        for (final entry in map['providerData'] as List? ?? const [])
          AuthUserInfo._fromMap(entry as Map<Object?, Object?>),
      ],
      super._fromMap();

  /// Decodes what the native side encodes. Throws [FormatException] when the
  /// bytes are not a CBOR map.
  factory AuthUser._decode(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = cborDecode(bytes).toObject();
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('malformed user payload: $e');
    }
    if (decoded is! Map) {
      throw const FormatException('user payload is not a map');
    }
    return AuthUser._fromMap(decoded);
  }

  static DateTime? _time(Object? millis) => millis is int
      ? DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
      : null;

  final bool isAnonymous;
  final bool isEmailVerified;

  /// When the account was created, or null if the SDK does not know.
  final DateTime? creationTime;
  final DateTime? lastSignInTime;

  /// One entry per provider linked to the account. Empty for an anonymous
  /// user, and for a custom token whose uid has no account behind it.
  final List<AuthUserInfo> providerData;
}

/// What a sign-in returned.
class AuthOutcome {
  const AuthOutcome({required this.uid, required this.user});

  /// The signed-in user id.
  final String uid;

  /// The signed-in user.
  final AuthUser user;
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
  ensureLibraryLoaded();
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
      final uid = parts[3]! as String;
      final encoded = parts[4] as Uint8List?;
      try {
        completer.complete(
          AuthOutcome(
            uid: uid,
            // Null only if the native side could not encode the user. The
            // sign-in still happened, so it is answered with what is known.
            user: encoded == null
                ? AuthUser(uid: uid)
                : AuthUser._decode(encoded),
          ),
        );
      } on FormatException catch (e) {
        completer.completeError(e);
      }
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

/// The signed-in user, or null.
///
/// Read from the SDK on every call rather than kept from the last sign-in: a
/// session restored from the secure store never passed through a sign-in here.
/// It is the SDK's cached copy, so a change made elsewhere shows up only after
/// the SDK has reloaded the account.
AuthUser? currentUser() {
  if (!hasFirebase) return null;
  var cap = 1024;
  while (true) {
    final buf = calloc<Uint8>(cap);
    try {
      final len = fdbAuthCurrentUser(buf, cap);
      if (len <= 0) return null;
      // Copied out: the buffer is freed below.
      if (len <= cap) {
        return AuthUser._decode(Uint8List.fromList(buf.asTypedList(len)));
      }
      cap = len;
    } finally {
      calloc.free(buf);
    }
  }
}

/// One of the SDK's two listeners, as a stream any number of callers can
/// listen to.
///
/// The native side has one port per kind, so the subscription to it is shared:
/// opened by the first listener, closed by the last. Each listener still gets
/// the current state first -- from the SDK for the one that opens it, replayed
/// from the last event for the ones that join.
class _AuthEvents {
  _AuthEvents(this._kind);

  final int _kind;
  RawReceivePort? _port;
  bool _seen = false;
  AuthUser? _last;

  late final StreamController<AuthUser?> _events =
      StreamController<AuthUser?>.broadcast(onListen: _open, onCancel: _close);

  Stream<AuthUser?> get stream => Stream<AuthUser?>.multi((listener) {
    if (!hasFirebase) {
      // No SDK is nobody signed in, as [currentUser] answers it.
      listener.add(null);
      return;
    }
    if (_seen) listener.add(_last);
    final sub = _events.stream.listen(
      listener.addSync,
      onError: listener.addErrorSync,
    );
    listener.onCancel = sub.cancel;
  }, isBroadcast: true);

  void _open() {
    final port = RawReceivePort();
    port.handler = (Object? message) {
      try {
        _last = message == null ? null : AuthUser._decode(message as Uint8List);
        _seen = true;
        _events.add(_last);
      } on FormatException catch (e) {
        _events.addError(e);
      }
    };
    final rc = fdbAuthListen(_kind, port.sendPort.nativePort);
    if (rc != 0) {
      port.close();
      _events.addError(
        StateError(
          rc == -1
              ? 'auth listener before initAuth'
              : 'auth listener rejected: $rc',
        ),
      );
      return;
    }
    _port = port;
  }

  void _close() {
    final port = _port;
    if (port == null) return;
    fdbAuthListen(_kind, 0);
    port.close();
    _port = null;
    _seen = false;
    _last = null;
  }
}

final _stateEvents = _AuthEvents(0);
final _tokenEvents = _AuthEvents(1);

/// Who is signed in, now and whenever that changes: a sign-in, a sign-out, a
/// different user. Null is nobody.
///
/// The first event is the current state. If the SDK is still restoring a
/// session from the secure store it arrives once that has finished, so this
/// answers what [restoredUid] polls for. [initAuth] must have run.
Stream<AuthUser?> authStateChanges() => _stateEvents.stream;

/// [authStateChanges], and an event when the signed-in user's ID token is
/// replaced -- by a forced refresh, or by the SDK refreshing one near expiry.
///
/// Listening turns the SDK's background refresh on, which is what keeps a
/// long-lived listener's token current.
Stream<AuthUser?> idTokenChanges() => _tokenEvents.stream;

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
