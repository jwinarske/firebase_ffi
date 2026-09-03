// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Cloud Storage binding, end to end.
//
//   dart run example/storage.dart
//
// Uploads, downloads, metadata, download URLs and deletion — with the object's
// bytes checked rather than assumed, because a truncated or offset download is
// the failure worth catching.
//
// Storage takes its bucket from the app options, so a project whose
// google-services.json has no storage_bucket cannot run this; the program says
// so rather than building a URL with no bucket in it.

import 'dart:typed_data';

import 'package:firebase_ffi/storage.dart';

import 'setup.dart';

Future<void> main() async {
  final app = await start(use: {Product.storage});
  if ((app.config.storageBucket ?? '').isEmpty) {
    bail('this project has no storage bucket in its google-services.json');
  }
  note('bucket ${app.config.storageBucket}');

  final path = 'example/${app.run}/roundtrip.bin';

  try {
    await _roundTrip(path);
    await _metadata(path);
    await _url(path);
    await _deletion(path);
  } finally {
    // Deleting an object that is already gone is an error, so the cleanup asks
    // rather than assumes.
    try {
      await deleteObject(path);
      note('cleaned up $path');
    } on StorageException {
      // Already deleted by _deletion, which is the normal path.
    }
  }
}

Future<void> _roundTrip(String path) async {
  step('upload and download');

  // Big enough that a copy would show up in the timing, and patterned so a
  // truncated or offset download is visible rather than merely the wrong
  // length.
  final payload = Uint8List.fromList(
    List<int>.generate(256 * 1024, (i) => i % 251),
  );

  final started = DateTime.now();
  final meta = await putObject(
    path,
    payload,
    contentType: 'application/octet-stream',
  );
  note(
    'put ${meta.sizeBytes} bytes as ${meta.contentType} in '
    '${DateTime.now().difference(started).inMilliseconds}ms',
  );

  // Two round trips inside: a download needs its buffer sized before it
  // starts, and only the metadata knows how big the object is.
  final back = await getObject(path);
  note('downloaded ${back.length} bytes');

  if (back.length != payload.length) {
    note('LENGTH MISMATCH ${back.length} != ${payload.length}');
    return;
  }
  var firstBad = -1;
  for (var i = 0; i < payload.length; i++) {
    if (back[i] != payload[i]) {
      firstBad = i;
      break;
    }
  }
  note(
    firstBad < 0 ? 'every byte identical' : 'CONTENT DIFFERS at byte $firstBad',
  );
}

Future<void> _metadata(String path) async {
  step('metadata, without downloading the object');

  final m = await objectMetadata(path);
  note('bucket      ${m.bucket}');
  note('path        ${m.path}');
  note('name        ${m.name}');
  note('size        ${m.sizeBytes} bytes');
  note('type        ${m.contentType}');
  note('md5         ${m.md5Hash}');
  note('created     ${m.creationTime}');
  note('updated     ${m.updatedTime}');
  note('generation  ${m.generation} (metadata ${m.metadataGeneration})');
  note('custom      ${m.custom.isEmpty ? '<none>' : m.custom}');

  // A generation changes when the object's bytes change, and the metadata
  // generation when only its metadata does — which is how a cache decides
  // whether it has to download again.
  final again = await putObject(path, Uint8List.fromList([1, 2, 3]));
  note('after re-uploading, generation ${m.generation} -> ${again.generation}');
}

Future<void> _url(String path) async {
  step('a download URL');

  // The URL carries an access token, so it serves the object to anything that
  // has it — which is the point, and the reason it is worth treating as a
  // credential rather than as a path.
  final url = await downloadUrl(path);
  note('${url.split('?').first}?<access token>');
}

Future<void> _deletion(String path) async {
  step('deletion');

  await deleteObject(path);
  note('deleted');

  // The failure is the assertion: a delete that quietly succeeded on a missing
  // object would hide a delete that never happened.
  try {
    await deleteObject(path);
    note('a second delete unexpectedly succeeded');
  } on StorageException catch (e) {
    note('a second delete was refused: code ${e.code}, ${e.message}');
  }

  try {
    await getObject(path);
    note('downloading a deleted object unexpectedly succeeded');
  } on StorageException catch (e) {
    note('downloading it was refused too: code ${e.code}');
  }
}
