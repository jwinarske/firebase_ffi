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

import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

// Big enough that an upload to an emulator on this machine is still going when
// the test reaches in to pause or cancel it.
const _bigUpload = 64 * 1024 * 1024;

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

  test('a file is uploaded from disk', () async {
    final dir = Directory.systemTemp.createTempSync('fdb-put-file');
    addTearDown(() => dir.deleteSync(recursive: true));
    final payload = Uint8List.fromList(
      List.generate(300 * 1024, (i) => (i * 7) & 0xff),
    );
    final file = File('${dir.path}/payload.bin')..writeAsBytesSync(payload);

    final ref = FirebaseStorage.instance.ref(probe());
    final done = await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/x-test'),
    );
    expect(done.state, TaskState.success);
    expect(done.totalBytes, payload.length);
    expect((await ref.getMetadata()).contentType, 'image/x-test');
    expect(await ref.getData(), payload);
  });

  test('listAll separates objects from prefixes', () async {
    final root = FirebaseStorage.instance.ref(
      'list/${DateTime.now().microsecondsSinceEpoch}',
    );
    final one = Uint8List.fromList([1]);
    await root.child('a.txt').putData(one);
    await root.child('b.txt').putData(one);
    await root.child('sub/c.txt').putData(one);

    final all = await root.listAll();
    expect(all.items.map((r) => r.name), unorderedEquals(['a.txt', 'b.txt']));
    expect(all.prefixes.map((r) => r.fullPath), ['${root.fullPath}/sub']);
    expect(all.nextPageToken, isNull);

    // A listed reference is an ordinary one.
    expect(await all.items.first.getData(), one);
    expect((await all.prefixes.single.listAll()).items.single.name, 'c.txt');
  });

  test('list is paged, and listAll follows the pages', () async {
    final root = FirebaseStorage.instance.ref(
      'list/${DateTime.now().microsecondsSinceEpoch}',
    );
    for (var i = 0; i < 5; i++) {
      await root.child('$i').putData(Uint8List.fromList([i]));
    }

    final first = await root.list(const ListOptions(maxResults: 2));
    expect(first.items.length, 2);
    expect(first.nextPageToken, isNotNull);
    final second = await root.list(
      ListOptions(maxResults: 2, pageToken: first.nextPageToken),
    );
    expect(second.items.map((r) => r.name), ['2', '3']);

    expect((await root.listAll()).items.length, 5);
  });

  test('an upload reports progress as it goes', () async {
    final payload = Uint8List(4 * 1024 * 1024);
    final task = FirebaseStorage.instance.ref(probe()).putData(payload);
    final seen = <TaskSnapshot>[];
    final sub = task.snapshotEvents.listen(seen.add);

    final done = await task;
    await sub.asFuture<void>();
    expect(done.state, TaskState.success);
    expect(done.bytesTransferred, payload.length);
    expect(seen.last.state, TaskState.success);
    expect(seen.where((s) => s.state == TaskState.running), isNotEmpty);
    // Finished, so there is nothing left to act on.
    expect(await task.pause(), isFalse);
    expect(await task.cancel(), isFalse);
  });

  test('an upload is paused, resumed and finishes', () async {
    final payload = Uint8List(_bigUpload);
    final task = FirebaseStorage.instance.ref(probe()).putData(payload);
    final running = Completer<void>();
    final paused = Completer<void>();
    final sub = task.snapshotEvents.listen((s) {
      if (s.state == TaskState.running && !running.isCompleted) {
        running.complete();
      }
      if (s.state == TaskState.paused && !paused.isCompleted) {
        paused.complete();
      }
    });

    await running.future;
    expect(await task.pause(), isTrue);
    await paused.future;
    expect(task.snapshot.state, TaskState.paused);

    // Nothing moves while it is paused, once a chunk already on its way has
    // landed.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = task.snapshot.bytesTransferred;
    expect(before, lessThan(payload.length));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(task.snapshot.bytesTransferred, before);
    expect(task.snapshot.state, TaskState.paused);

    expect(await task.resume(), isTrue);
    final done = await task;
    await sub.cancel();
    expect(done.state, TaskState.success);
    expect(done.bytesTransferred, payload.length);
  });

  test('a canceled upload ends canceled', () async {
    final ref = FirebaseStorage.instance.ref(probe());
    final task = ref.putData(Uint8List(_bigUpload));
    final failed = expectLater(
      Future.value(task),
      throwsA(
        isA<FirebaseException>().having((e) => e.code, 'code', 'canceled'),
      ),
    );
    // The stream carries the same failure; watched, so it is not unhandled.
    final streamed = expectLater(
      task.snapshotEvents.where((s) => s.state != TaskState.running),
      emitsError(isA<FirebaseException>()),
    );

    await task.snapshotEvents.first;
    expect(await task.cancel(), isTrue);
    await failed;
    await streamed;
    expect(task.snapshot.state, TaskState.canceled);
    await expectLater(ref.getMetadata(), throwsA(isA<FirebaseException>()));
  });
}
