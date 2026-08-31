// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_core` implementation for desktop Linux.
///
/// Apps depend on `firebase_core` and call `Firebase.initializeApp()` as they
/// would anywhere else; this registers itself as the platform implementation
/// and routes that to the Firebase C++ SDK through `firebase_ffi`.
library;

import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:firebase_ffi/database.dart' as fdb;
import 'package:firebase_ffi/google_services.dart';

/// Registered by Flutter on Linux via `dartPluginClass`, so an app that
/// depends on this package does not call anything to enable it.
class FirebaseCoreFfi extends FirebasePlatform {
  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebasePlatform.instance = FirebaseCoreFfi();
  }

  final Map<String, FirebaseAppPlatform> _apps = {};

  @override
  List<FirebaseAppPlatform> get apps => _apps.values.toList(growable: false);

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) {
    final app = _apps[name];
    if (app == null) {
      throw noAppExists(name);
    }
    return app;
  }

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    final appName = name ?? defaultFirebaseAppName;

    // A second named app would need a second firebase::App, and the native
    // layer holds exactly one — every product shares it, which is why they
    // share one credential. Refusing is better than returning an app that
    // silently aliases the first.
    if (appName != defaultFirebaseAppName) {
      throw UnimplementedError(
        'firebase_core_ffi supports only the default app: the native layer '
        'holds one firebase::App, which is what lets Auth, Database, '
        'Firestore and Storage share a credential',
      );
    }

    final existing = _apps[appName];
    if (existing != null) {
      // Matching FlutterFire: re-initializing with the same options is a
      // no-op, and with different ones is an error rather than a silent
      // reconfiguration.
      if (options != null && options != existing.options) {
        throw duplicateApp(appName);
      }
      return existing;
    }

    final resolved = options ?? _optionsFromGoogleServices();
    fdb.initDatabase(
      appId: resolved.appId,
      apiKey: resolved.apiKey,
      projectId: resolved.projectId,
      databaseUrl: resolved.databaseURL ?? '',
      storageBucket: resolved.storageBucket,
    );

    final app = _FfiFirebaseApp(appName, resolved);
    _apps[appName] = app;
    return app;
  }

  /// Options from the console's `google-services.json`, for the call that
  /// passes none.
  ///
  /// This is what `Firebase.initializeApp()` does on Android, and desktop
  /// Linux has no config file of its own, so the Android one is what the C++
  /// SDK is configured from either way.
  FirebaseOptions _optionsFromGoogleServices() {
    final GoogleServicesConfig cfg;
    try {
      cfg = GoogleServicesConfig.load();
    } on Exception catch (e) {
      throw ArgumentError(
        'Firebase.initializeApp() was called without options and no '
        'google-services.json could be read ($e). Pass FirebaseOptions, or '
        'set GOOGLE_SERVICES_JSON.',
      );
    }
    return FirebaseOptions(
      apiKey: cfg.apiKey,
      appId: cfg.appId,
      // Unused by the C++ SDK on desktop, but required by FirebaseOptions.
      messagingSenderId: cfg.messagingSenderId ?? '',
      projectId: cfg.projectId,
      databaseURL: cfg.databaseUrl,
      storageBucket: cfg.storageBucket,
    );
  }
}

class _FfiFirebaseApp extends FirebaseAppPlatform {
  _FfiFirebaseApp(super.name, super.options);

  @override
  Future<void> delete() async {
    // The native App lives for the process: firebase::App::Create registers in
    // a global registry that Auth, Database, Firestore and Storage all hold
    // instances from, and tearing it down under them is not something the
    // C++ SDK supports cleanly. Saying so beats pretending it worked.
    throw UnimplementedError(
      'deleting an app is not supported: the native firebase::App is shared '
      'by every bound product for the life of the process',
    );
  }

  @override
  bool get isAutomaticDataCollectionEnabled => false;

  @override
  Future<void> setAutomaticDataCollectionEnabled(bool enabled) async {
    if (enabled) {
      throw UnimplementedError(
        'automatic data collection is not configurable through this '
        'implementation',
      );
    }
  }

  @override
  Future<void> setAutomaticResourceManagementEnabled(bool enabled) async {
    if (enabled) {
      throw UnimplementedError(
        'automatic resource management is not configurable through this '
        'implementation',
      );
    }
  }
}
