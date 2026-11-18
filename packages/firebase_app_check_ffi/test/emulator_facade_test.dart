// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// firebase_app_check, unchanged, with the token followed to a backend.
//
// facade_test.dart reads the token back from the SDK. This asks where it
// went: a callable in the Functions emulator reports the X-Firebase-AppCheck
// header it was sent. The emulator decodes that token without verifying it,
// so the provider here mints an unsigned one.
//
// A custom provider, not the debug one. The debug provider exchanges its
// token at firebaseappcheck.googleapis.com, the SDK takes no other host for
// it, and there is no App Check emulator to point it at.
//
// Its own file because the provider is process-wide: once installed, every
// product in the process asks it for tokens.
//
// Skipped without FIREBASE_EMULATOR_HOST.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_functions_ffi/cloud_functions_ffi.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';
const _appId = '1:1:android:1';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — App Check emulator tests skipped');
    return;
  }
  final fnPort =
      int.tryParse(
        Platform.environment['FIREBASE_FUNCTIONS_EMULATOR_PORT'] ?? '',
      ) ??
      5001;

  var asked = 0;
  var supplied = '';

  Future<Map> attested({bool limitedUse = false}) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable(
          'attested',
          options: HttpsCallableOptions(limitedUseAppCheckToken: limitedUse),
        )
        .call<Map<String, dynamic>>();
    return result.data;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    FirebaseAppCheckFfi.registerWith();
    CloudFunctionsFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: _appId,
        messagingSenderId: '1',
        projectId: _projectId,
      ),
    );

    // Before anything makes a request, or the request goes without a token.
    FirebaseAppCheckFfi.useCustomProvider(() async {
      asked++;
      supplied = _unsignedToken(_appId, asked);
      return AppCheckTokenResult(
        token: supplied,
        expirationTime: DateTime.now().add(const Duration(hours: 1)),
      );
    });
    await FirebaseAppCheck.instance.activate();
    FirebaseFunctions.instance.useFunctionsEmulator(host, fnPort);
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('a callable is sent the token the device supplied', () async {
    final token = await FirebaseAppCheck.instance.getToken(true);
    expect(token, supplied);

    final seen = await attested();
    expect(seen['header'], token);
    // The emulator's reading of it: the app the token names.
    expect(seen['appId'], _appId);
  });

  test('a refreshed token replaces the one requests carry', () async {
    final first = await FirebaseAppCheck.instance.getToken(true);
    expect((await attested())['header'], first);

    final second = await FirebaseAppCheck.instance.getToken(true);
    expect(second, isNot(first));
    expect((await attested())['header'], second);
  });

  test('a cached token is sent without asking the device again', () async {
    await FirebaseAppCheck.instance.getToken(true);
    final before = asked;

    await attested();
    await attested();
    expect(asked, before);
  });

  test('a limited-use call is sent a token minted for it', () async {
    final cached = await FirebaseAppCheck.instance.getToken(true);
    final before = asked;

    final seen = await attested(limitedUse: true);
    expect(asked, before + 1);
    expect(seen['header'], supplied);
    expect(seen['header'], isNot(cached));
  });
}

/// An App Check token with no signature, which only the emulator accepts.
/// [n] makes each one different.
String _unsignedToken(String appId, int n) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'none', 'typ': 'JWT'})}.${part({
    'sub': appId,
    'aud': ['projects/$_projectId'],
    'iat': now,
    'exp': now + 3600,
    'jti': '$n',
  })}.';
}
