// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_auth` implementation for desktop Linux.
///
/// What the C++ SDK gives us on desktop is a subset of what the plugin
/// exposes: anonymous and custom-token sign-in, sign-out, the current user,
/// and the emulator. Everything else keeps the platform interface's own
/// `UnimplementedError`, which names the method that is missing rather than
/// failing somewhere further down.
library;

import 'dart:async';

import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/auth.dart' as fdb;

/// Registered by Flutter on Linux via `dartPluginClass`.
class FirebaseAuthFfi extends FirebaseAuthPlatform {
  FirebaseAuthFfi({FirebaseApp? app}) : super(appInstance: app);

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseAuthPlatform.instance = FirebaseAuthFfi();
  }

  /// Emitted on every sign-in and sign-out. The C++ SDK has an auth state
  /// listener, but it is not bound yet, so this is driven by the calls that
  /// pass through here. A credential restored from the secure store before any
  /// call is therefore not announced -- see [currentUser], which reads it.
  final StreamController<UserPlatform?> _authState =
      StreamController<UserPlatform?>.broadcast();

  UserPlatform? _currentUser;

  /// firebase_auth has no "initialize auth" call -- FirebaseAuth.instance is
  /// expected to work once Firebase.initializeApp has run. The C++ SDK does
  /// need one, so it happens here, once, before anything that needs it.
  bool _authReady = false;

  void _ensureAuth() {
    if (_authReady) return;
    fdb.initAuth();
    _authReady = true;
  }

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) =>
      FirebaseAuthFfi(app: app);

  @override
  FirebaseAuthPlatform setInitialValues({
    InternalUserDetails? currentUser,
    String? languageCode,
  }) {
    if (currentUser != null) {
      _currentUser = _FfiUser(this, currentUser.userInfo.uid);
    }
    return this;
  }

  @override
  UserPlatform? get currentUser {
    // Asked of the native layer rather than cached: the SDK restores a session
    // from the secure store asynchronously, so a uid can appear without any
    // call through this class.
    // Not _ensureAuth(): reading the current user must not be the thing that
    // initializes Auth, or asking "is anyone signed in?" before
    // Firebase.initializeApp would throw instead of answering no.
    if (!_authReady) return _currentUser;
    final uid = fdb.currentUid();
    if (uid == null || uid.isEmpty) return _currentUser;
    if (_currentUser?.uid == uid) return _currentUser;
    return _currentUser = _FfiUser(this, uid);
  }

  @override
  set currentUser(UserPlatform? userPlatform) {
    _currentUser = userPlatform;
  }

  @override
  Stream<UserPlatform?> authStateChanges() => _authState.stream;

  @override
  Stream<UserPlatform?> idTokenChanges() => _authState.stream;

  @override
  Stream<UserPlatform?> userChanges() => _authState.stream;

  @override
  Future<void> useAuthEmulator(String host, int port) async {
    _ensureAuth();
    fdb.useAuthEmulator(host, port);
  }

  @override
  Future<UserCredentialPlatform> signInAnonymously() =>
      _signIn(fdb.signInAnonymously);

  @override
  Future<UserCredentialPlatform> signInWithCustomToken(String token) =>
      _signIn(() => fdb.signInWithCustomToken(token));

  @override
  Future<void> signOut() async {
    // Not _ensureAuth(): signing out when Auth was never initialized has
    // nothing to undo, and initializing it in order to do nothing would turn a
    // harmless call into a failure on a build with no SDK.
    if (_authReady) fdb.signOut();
    _currentUser = null;
    _authState.add(null);
  }

  Future<UserCredentialPlatform> _signIn(
    Future<fdb.AuthOutcome> Function() start,
  ) async {
    final fdb.AuthOutcome outcome;
    try {
      _ensureAuth();
      outcome = await start();
    } on fdb.AuthException catch (e) {
      // Translated so callers catch FirebaseAuthException, as they would on
      // any other platform. The SDK's own code and message are carried through
      // rather than being remapped to a guess at the nearest plugin code.
      throw FirebaseAuthException(code: '${e.code}', message: e.message);
    }
    final user = _FfiUser(this, outcome.uid);
    _currentUser = user;
    _authState.add(user);
    return _FfiUserCredential(this, user);
  }
}

/// Multi-factor is not bound. The base class is abstract, so a subclass is
/// required to construct a user at all; this one adds nothing, leaving every
/// call to the interface's own UnimplementedError, which names the method.
class _FfiMultiFactor extends MultiFactorPlatform {
  _FfiMultiFactor(super.auth);
}

class _FfiUser extends UserPlatform {
  _FfiUser(FirebaseAuthPlatform auth, String uid)
    : super(
        auth,
        _FfiMultiFactor(auth),
        InternalUserDetails(
          userInfo: InternalUserInfo(
            uid: uid,
            // True for both sign-ins this implementation offers: a custom
            // token identifies a device, not a federated account, and the
            // C++ SDK reports neither as having provider data.
            isAnonymous: true,
            isEmailVerified: false,
          ),
          providerData: const [],
        ),
      );
}

class _FfiUserCredential extends UserCredentialPlatform {
  _FfiUserCredential(FirebaseAuthPlatform auth, UserPlatform user)
    : super(auth: auth, user: user);
}
