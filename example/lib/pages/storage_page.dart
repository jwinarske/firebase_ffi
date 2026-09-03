// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// Objects in and out of a bucket, by path.
///
/// Local paths rather than a file picker: this app runs on boards where there
/// is no desktop file dialog, and a path is what a deployment script has
/// anyway.
class StoragePage extends StatefulWidget {
  const StoragePage({required this.connection, super.key});

  final Connection connection;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  final _object = TextEditingController(text: 'demo/hello.txt');
  final _local = TextEditingController();
  final _text = TextEditingController(text: 'hello from the workbench\n');

  FullMetadata? _metadata;
  String? _url;

  @override
  void dispose() {
    _object.dispose();
    _local.dispose();
    _text.dispose();
    super.dispose();
  }

  Reference get _ref => FirebaseStorage.instance.ref(_object.text.trim());

  @override
  Widget build(BuildContext context) => Section(
    title: 'Cloud Storage',
    subtitle: 'Bucket ${widget.connection.storageBucket ?? '<unset>'}',
    children: [
      if ((widget.connection.storageBucket ?? '').isEmpty)
        Panel(
          title: 'No bucket',
          child: Text(
            'This project\'s options carry no storage bucket. Storage takes '
            'its bucket from there and has no per-call override, so every '
            'request below would build a URL with no bucket in it.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Panel(
        title: 'Object',
        child: LineField(
          controller: _object,
          label: 'Path in the bucket',
          hint: 'firmware/1.4.3.bin',
        ),
      ),
      Panel(
        title: 'Upload',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CodeField(controller: _text, label: 'Text to upload', minLines: 3),
            const SizedBox(height: 12),
            LineField(
              controller: _local,
              label: 'Or a local file to upload or download to',
              hint: '/tmp/firmware.bin',
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Upload the text',
                icon: Icons.upload,
                filled: true,
                action: () async {
                  final task = _ref.putData(
                    // A content type, so what comes back through a download
                    // URL is served as what it is.
                    Uint8List.fromList(_text.text.codeUnits),
                    SettableMetadata(contentType: 'text/plain'),
                  );
                  final done = await task;
                  appLog.write(
                    'uploaded ${done.bytesTransferred} bytes to '
                    '${_ref.fullPath}',
                  );
                },
              ),
              RunButton(
                label: 'Upload the file',
                icon: Icons.file_upload_outlined,
                action: () async {
                  final file = File(_local.text.trim());
                  if (!file.existsSync()) {
                    throw FileSystemException('no such file', file.path);
                  }
                  final bytes = await file.readAsBytes();
                  await _ref.putData(bytes);
                  appLog.write(
                    'uploaded ${bytes.length} bytes from '
                    '${file.path}',
                  );
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Download',
        child: ButtonRow([
          RunButton(
            label: 'Download to the transcript',
            icon: Icons.download,
            action: () async {
              // The cap is a contract: past it the answer is null rather than
              // a truncated object that looks complete.
              final bytes = await _ref.getData(64 * 1024);
              if (bytes == null) {
                appLog.write('larger than 64 KiB — download it to a file');
                return;
              }
              appLog.write(
                '${_ref.fullPath}: '
                '${String.fromCharCodes(bytes).trim()}',
              );
            },
          ),
          RunButton(
            label: 'Download to the file',
            icon: Icons.save_alt,
            action: () async {
              final bytes = await _ref.getData(64 * 1024 * 1024);
              if (bytes == null) {
                throw StateError('object is larger than 64 MiB');
              }
              final file = File(_local.text.trim());
              await file.writeAsBytes(bytes);
              appLog.write('wrote ${bytes.length} bytes to ${file.path}');
            },
          ),
        ]),
      ),
      Panel(
        title: 'Metadata and URL',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ButtonRow([
              RunButton(
                label: 'Metadata',
                icon: Icons.info_outline,
                action: () async {
                  final m = await _ref.getMetadata();
                  setState(() => _metadata = m);
                  appLog.write(
                    '${m.fullPath}: ${m.size} bytes, '
                    '${m.contentType}',
                  );
                },
              ),
              RunButton(
                label: 'Download URL',
                icon: Icons.link,
                action: () async {
                  final url = await _ref.getDownloadURL();
                  setState(() => _url = url);
                  // The URL carries an access token, so it serves the object to
                  // anything holding it — a credential rather than a path.
                  appLog.write('URL: ${url.split('?').first}?<access token>');
                },
              ),
              RunButton(
                label: 'Delete',
                icon: Icons.delete_outline,
                action: () async {
                  await _ref.delete();
                  setState(() {
                    _metadata = null;
                    _url = null;
                  });
                  appLog.write('deleted ${_ref.fullPath}');
                },
              ),
            ]),
            if (_metadata != null) ...[
              const SizedBox(height: 16),
              Rows({
                'bucket': _metadata!.bucket ?? '',
                'fullPath': _metadata!.fullPath,
                'size': '${_metadata!.size} bytes',
                'contentType': _metadata!.contentType ?? '',
                'md5Hash': _metadata!.md5Hash ?? '',
                'timeCreated': '${_metadata!.timeCreated}',
                'updated': '${_metadata!.updated}',
                'generation': '${_metadata!.generation}',
              }),
            ],
            if (_url != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                _url!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      Panel(
        title: 'What is not bound',
        child: Text(
          'listAll(): the desktop C++ SDK does not expose the REST listing, so '
          'an app that browses a bucket keeps its own index — in Firestore or '
          'the Realtime Database — rather than asking Storage what is there.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}
