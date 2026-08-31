// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Storage exercise as a plain Dart program, so the round trip can be run
// against a real bucket without a display or a bundle. The app in lib/ runs
// the same sequence on the target.
//
// Its output is the result, so it prints: this is a command-line probe run
// by hand, not code in the app.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_ffi/storage.dart';

Future<void> main() async {
  final cfg = GoogleServicesConfig.load();
  initDatabase(
    appId: cfg.appId,
    apiKey: cfg.apiKey,
    projectId: cfg.projectId,
    databaseUrl: cfg.databaseUrl,
    storageBucket: cfg.storageBucket,
  );
  print('app: ${cfg.projectId}');

  initAuth();
  final who = await signInAnonymously();
  print('auth: uid ${who.uid}');

  if (!hasStorage) {
    print('storage: not bound in this build');
    exit(1);
  }
  initStorage();
  print('storage: initialized');

  const path = 'fdb_nc_probe/roundtrip.bin';
  final payload = Uint8List.fromList(
    List<int>.generate(256 * 1024, (i) => i % 251),
  );

  final meta = await putObject(
    path,
    payload,
    contentType: 'application/octet-stream',
  );
  print('storage: put ${meta.sizeBytes} bytes, ${meta.contentType}');

  final back = await getObject(path);
  if (back.length != payload.length) {
    print('storage: LENGTH MISMATCH ${back.length} != ${payload.length}');
    exit(1);
  }
  for (var i = 0; i < payload.length; i++) {
    if (back[i] != payload[i]) {
      print('storage: CONTENT DIFFERS at byte $i');
      exit(1);
    }
  }
  print('storage: ROUND TRIP OK — ${back.length} bytes identical');

  final fetched = await objectMetadata(path);
  print(
    'storage: metadata ${fetched.sizeBytes} bytes, md5 ${fetched.md5Hash}, '
    'updated ${fetched.updatedTime}',
  );

  final url = await downloadUrl(path);
  print('storage: url ${url.split('?').first}');

  await deleteObject(path);
  print('storage: deleted');

  try {
    await deleteObject(path);
    print('storage: SECOND DELETE UNEXPECTEDLY SUCCEEDED');
    exit(1);
  } on StorageException catch (e) {
    print('storage: second delete refused (${e.code}) as it should be');
  }
  print('storage: all checks passed');
}
