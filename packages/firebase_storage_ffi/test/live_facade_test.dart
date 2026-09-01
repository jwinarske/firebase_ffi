// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The façade against a real bucket, driven through firebase_storage.
//
// The emulator covers this path in emulator_facade_test.dart. This one runs
// against a real bucket, which is the only place production rules, real
// credentials and a real endpoint are exercised together. It needs a project,
// so it is skipped unless asked for:
//
//   FDB_LIVE_STORAGE=1 flutter test test/live_facade_test.dart
//
// Nothing here mentions firebase_ffi. Writes only under fdb_nc_probe/, which
// is the prefix the test project's rules allow.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (Platform.environment['FDB_LIVE_STORAGE'] != '1') {
    print('FDB_LIVE_STORAGE unset — live Storage façade test skipped');
    return;
  }
  test(
    'the Storage façade round trips against a real bucket',
    _run,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _run() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);

  FirebaseCoreFfi.registerWith();
  FirebaseAuthFfi.registerWith();
  FirebaseStorageFfi.registerWith();

  final cfg = GoogleServicesConfig.load();
  await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: cfg.apiKey,
      appId: cfg.appId,
      messagingSenderId: cfg.messagingSenderId ?? '',
      projectId: cfg.projectId,
      databaseURL: cfg.databaseUrl,
      storageBucket: cfg.storageBucket,
    ),
  );
  print('app: ${Firebase.app().options.projectId}');

  final cred = await FirebaseAuth.instance.signInAnonymously();
  print('auth: uid ${cred.user!.uid}');

  final ref = FirebaseStorage.instance.ref('fdb_nc_probe').child('facade.bin');
  final payload = Uint8List.fromList(
    List<int>.generate(128 * 1024, (i) => i % 251),
  );

  final task = ref.putData(
    payload,
    SettableMetadata(contentType: 'application/octet-stream'),
  );
  final done = await task;
  print('put: ${done.bytesTransferred} of ${done.totalBytes}, ${done.state}');

  final back = await ref.getData();
  expect(back, isNotNull);
  expect(back!.length, payload.length);
  expect(back, equals(payload));
  print('get: ROUND TRIP OK — ${back.length} bytes identical');

  final meta = await ref.getMetadata();
  print(
    'metadata: ${meta.size} bytes, ${meta.contentType}, md5 ${meta.md5Hash}',
  );
  print('fullPath: ${meta.fullPath}');

  final url = await ref.getDownloadURL();
  print('url: ${url.split('?').first}');

  await ref.delete();
  print('deleted');

  // A read that succeeds after a delete would mean the delete did not happen.
  await expectLater(ref.getMetadata(), throwsA(isA<FirebaseException>()));
  print('after delete: refused as it should be');
  print('all checks passed');
}
