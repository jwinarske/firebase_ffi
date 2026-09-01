// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_app_check` implementation for desktop Linux.
///
/// Two ways to choose a provider, because the cross-platform `activate()` has
/// no Linux parameter:
///
///  * `activate(providerWindows: WindowsDebugProvider(...))`. That parameter
///    is named for Windows but describes the desktop C++ SDK's debug provider,
///    which is the same one Linux has — the two share the SDK. Honoring it is
///    what lets an app's `activate()` call stay unchanged.
///  * [FirebaseAppCheckFfi.useCustomProvider], which is Linux-only by
///    necessity: it takes a Dart callback, and no cross-platform parameter can
///    carry one. This is the provider that matters on an embedded target,
///    where there is no platform attestation to defer to.
///
/// `activate()` with neither is refused rather than defaulted to debug. A
/// debug provider attests to nothing, and installing one silently would look
/// like it worked.
library;

import 'dart:async';

import 'package:firebase_app_check_platform_interface/firebase_app_check_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/app_check.dart' as fdb;

/// Registered by Flutter on Linux via `dartPluginClass`.
class FirebaseAppCheckFfi extends FirebaseAppCheckPlatform {
  FirebaseAppCheckFfi({FirebaseApp? app}) : super(appInstance: app);

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseAppCheckPlatform.instance = FirebaseAppCheckFfi();
  }

  // The provider is process-wide in the SDK -- a static on AppCheck, not a
  // property of an App -- so this is too, rather than pretending otherwise.
  static bool _providerChosen = false;
  static bool _customChosen = false;
  static bool _initialized = false;

  /// Attests with [supply], which is called whenever the SDK needs a token.
  ///
  /// Call before [FirebaseAppCheckPlatform.activate] and before anything else
  /// makes a request: a provider installed afterwards has missed them.
  ///
  /// [supply] does the attesting — reads a TPM, calls a vendor service,
  /// unseals a provisioning record — and returns a token with its expiry.
  /// Throwing fails that one request; the SDK will ask again.
  static void useCustomProvider(Future<AppCheckTokenResult> Function() supply) {
    fdb.useCustomAppCheckProvider(() async {
      final r = await supply();
      return fdb.AppCheckToken(
        r.token,
        // The platform type allows a null expiry, for platforms whose SDK does
        // not report one. This one requires it, so an absent expiry becomes an
        // already-expired token rather than a token good until 1970.
        r.expirationTime ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
    _providerChosen = true;
    _customChosen = true;
  }

  @override
  FirebaseAppCheckPlatform delegateFor({required FirebaseApp app}) =>
      FirebaseAppCheckFfi(app: app);

  @override
  FirebaseAppCheckPlatform setInitialValues() => this;

  @override
  Future<void> activate({
    WebProvider? webProvider,
    AndroidProvider? androidProvider,
    AppleProvider? appleProvider,
    AndroidAppCheckProvider? providerAndroid,
    AppleAppCheckProvider? providerApple,
    WindowsAppCheckProvider? providerWindows,
  }) async {
    // A custom provider wins. providerWindows is not optional in the app-facing
    // activate() -- it defaults to const WindowsDebugProvider() -- so every
    // plain activate() call arrives here asking for debug. Taking it at face
    // value would replace a provider the app deliberately registered with one
    // that attests to nothing.
    if (!_customChosen && providerWindows is WindowsDebugProvider) {
      // Named for Windows, but it describes the desktop SDK's debug provider,
      // and Linux is the same SDK.
      fdb.useDebugAppCheckProvider(
        debugToken: providerWindows.debugToken ?? '',
      );
      _providerChosen = true;
    }
    if (!_providerChosen) {
      throw UnsupportedError(
        'App Check on Linux has no provider in activate(). Pass '
        'providerWindows: WindowsDebugProvider() for the SDK debug provider, '
        'or call FirebaseAppCheckFfi.useCustomProvider() first for a device '
        'that attests for itself. Neither was given, and defaulting to debug '
        'would attest to nothing while looking like it worked.',
      );
    }
    if (!_initialized) {
      fdb.initAppCheck();
      _initialized = true;
    }
  }

  @override
  Future<String?> getToken(bool forceRefresh) async =>
      (await fdb.appCheckToken(forceRefresh: forceRefresh)).token;

  @override
  Future<AppCheckTokenResult?> getTokenResult(bool forceRefresh) async {
    final t = await fdb.appCheckToken(forceRefresh: forceRefresh);
    return AppCheckTokenResult(token: t.token, expirationTime: t.expiresAt);
  }

  @override
  Future<String> getLimitedUseToken() async =>
      (await fdb.limitedUseAppCheckToken()).token;

  @override
  Future<void> setTokenAutoRefreshEnabled(
    bool isTokenAutoRefreshEnabled,
  ) async {
    fdb.setAppCheckAutoRefresh(isTokenAutoRefreshEnabled);
  }

  @override
  Stream<String?> get onTokenChange =>
      fdb.appCheckTokenChanges().map((t) => t.token);
}
