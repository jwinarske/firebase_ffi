// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// firebase_storage, unchanged, against the Storage emulator. Nothing here
// mentions firebase_ffi.
//
// This suite could not exist until recently, on the belief that desktop
// Storage built its host from compile-time constants. Storage::UseEmulator is
// stock in 13.12.0; the belief came from reading an older checkout.
//
// Skipped without FIREBASE_EMULATOR_HOST.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — Storage façade tests skipped');
    return;
  }
  final stPort =
      int.tryParse(
        Platform.environment['FIREBASE_STORAGE_EMULATOR_PORT'] ?? '',
      ) ??
      9199;
  final authPort =
      int.tryParse(Platform.environment['FIREBASE_AUTH_EMULATOR_PORT'] ?? '') ??
      9099;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // See firebase_auth_ffi: a test binding reports Android, and firebase_core
    // rewrites emulator hosts on Android. This is the Linux implementation.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FirebaseCoreFfi.registerWith();
    FirebaseAuthFfi.registerWith();
    FirebaseStorageFfi.registerWith();

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
        // Storage has no url argument to override this with, the way Database
        // does: an empty bucket builds a URL with no bucket in it, which the
        // emulator answers slowly rather than rejecting.
        storageBucket: '$_projectId.appspot.com',
      ),
    );
    await FirebaseStorage.instance.useStorageEmulator(host, stPort);

    // The rules require an authenticated caller, as production's do. Signing
    // in here also exercises what put every product in one native library:
    // Auth and Storage share a firebase::App, so the credential reaches
    // Storage without being passed to it.
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
    await FirebaseAuth.instance.signInAnonymously();
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  String probe() => 'probe/${DateTime.now().microsecondsSinceEpoch}';

  test('an object round trips through firebase_storage', () async {
    final ref = FirebaseStorage.instance.ref(probe());
    final payload = Uint8List.fromList(List.generate(512, (i) => i & 0xff));

    await ref.putData(
      payload,
      SettableMetadata(contentType: 'application/x-test'),
    );
    expect(await ref.getData(), payload);
  });

  test('metadata comes back through firebase_storage', () async {
    final ref = FirebaseStorage.instance.ref(probe());
    await ref.putData(
      Uint8List.fromList([1, 2, 3]),
      SettableMetadata(contentType: 'text/plain'),
    );

    final meta = await ref.getMetadata();
    expect(meta.size, 3);
    expect(meta.contentType, 'text/plain');
  });

  test('a deleted object is gone', () async {
    final ref = FirebaseStorage.instance.ref(probe());
    await ref.putData(Uint8List.fromList([7]));
    await ref.delete();

    await expectLater(ref.getData(), throwsA(isA<FirebaseException>()));
  });
}
