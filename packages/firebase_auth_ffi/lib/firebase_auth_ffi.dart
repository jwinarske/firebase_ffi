// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_auth` implementation for desktop Linux.
///
/// What the C++ SDK gives us on desktop is a subset of what the plugin
/// exposes: anonymous and custom-token sign-in, sign-out, the current user
/// with its profile and provider data, and the emulator. Everything else keeps the platform interface's own
/// `UnimplementedError`, which names the method that is missing rather than
/// failing somewhere further down.
library;

import 'dart:async';
import 'dart:convert';

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
      _currentUser = _FfiUser(this, currentUser);
    }
    return this;
  }

  @override
  UserPlatform? get currentUser {
    // Asked of the native layer rather than cached: the SDK restores a session
    // from the secure store asynchronously, so a user can appear without any
    // call through this class, and the profile it holds can change under one
    // that is already here.
    // Not _ensureAuth(): reading the current user must not be the thing that
    // initializes Auth, or asking "is anyone signed in?" before
    // Firebase.initializeApp would throw instead of answering no.
    if (!_authReady) return _currentUser;
    final user = fdb.currentUser();
    if (user == null) return _currentUser;
    return _currentUser = _FfiUser(this, _detailsOf(user));
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
    final user = _FfiUser(this, _detailsOf(outcome.user));
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

/// The SDK's user in the shape the platform interface carries one.
InternalUserDetails _detailsOf(fdb.AuthUser user) => InternalUserDetails(
  userInfo: InternalUserInfo(
    uid: user.uid,
    email: user.email,
    displayName: user.displayName,
    photoUrl: user.photoUrl,
    phoneNumber: user.phoneNumber,
    providerId: user.providerId,
    isAnonymous: user.isAnonymous,
    isEmailVerified: user.isEmailVerified,
    creationTimestamp: user.creationTime?.millisecondsSinceEpoch,
    lastSignInTimestamp: user.lastSignInTime?.millisecondsSinceEpoch,
  ),
  providerData: [
    for (final info in user.providerData)
      {
        'uid': info.uid,
        'email': info.email,
        'displayName': info.displayName,
        'photoUrl': info.photoUrl,
        'phoneNumber': info.phoneNumber,
        'providerId': info.providerId,
        // Not facts about a provider, but UserInfo.fromJson casts both to a
        // non-null bool, so they are the account's.
        'isAnonymous': user.isAnonymous,
        'isEmailVerified': user.isEmailVerified,
      },
  ],
);

class _FfiUser extends UserPlatform {
  _FfiUser(FirebaseAuthPlatform auth, InternalUserDetails details)
    : super(auth, _FfiMultiFactor(auth), details);

  @override
  Future<String?> getIdToken(bool forceRefresh) async {
    try {
      return await fdb.idToken(forceRefresh: forceRefresh);
    } on fdb.AuthException catch (e) {
      // The SDK's own code and message, as every other call here carries them.
      throw FirebaseAuthException(code: '${e.code}', message: e.message);
    }
  }

  @override
  Future<IdTokenResult> getIdTokenResult(bool forceRefresh) async {
    final token = await getIdToken(forceRefresh);
    if (token == null) {
      throw FirebaseAuthException(
        code: 'no-token',
        message: 'the SDK returned no ID token',
      );
    }
    final claims = _claimsOf(token);
    int? millis(String claim) {
      final value = claims[claim];
      return value is num ? value.toInt() * 1000 : null;
    }

    // Read from the token rather than tracked alongside it: the claims are
    // what a backend verifying it will see, and a second account of the same
    // facts could disagree with the first.
    return IdTokenResult(
      InternalIdTokenResult(
        token: token,
        expirationTimestamp: millis('exp'),
        authTimestamp: millis('auth_time'),
        issuedAtTimestamp: millis('iat'),
        signInProvider:
            (claims['firebase'] as Map?)?['sign_in_provider'] as String?,
        claims: claims,
      ),
    );
  }

  /// A JWT's payload, decoded but not verified.
  ///
  /// Verification needs the signing key and belongs to whoever receives the
  /// token; what a client can honestly report is what was signed.
  static Map<String, dynamic> _claimsOf(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return const {};
    try {
      final payload = base64Url.decode(base64Url.normalize(parts[1]));
      final decoded = jsonDecode(utf8.decode(payload));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on Object {
      // A token this cannot read is still one the backend may accept, so the
      // claims are empty rather than the call being a failure.
      return const {};
    }
  }
}

class _FfiUserCredential extends UserCredentialPlatform {
  _FfiUserCredential(FirebaseAuthPlatform auth, UserPlatform user)
    : super(auth: auth, user: user);
}
