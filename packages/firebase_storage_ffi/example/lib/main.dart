// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Uploads a small object and downloads it again.
//
// The only lines specific to Linux are the registerWith calls below. Every
// other line is ordinary firebase_storage and would compile unchanged on Android.

import 'dart:typed_data';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On Linux nothing registers these automatically yet, so an app says so
  // once at startup. Elsewhere the plugin registers itself and these are not
  // called.
  FirebaseCoreFfi.registerWith();
  FirebaseStorageFfi.registerWith();

  await Firebase.initializeApp(
    // Replace with your project's values, or generate them with the FlutterFire
    // CLI. The C++ SDK reads them from here rather than from a plist.
    options: const FirebaseOptions(
      apiKey: 'replace-me',
      appId: '1:1:android:1',
      messagingSenderId: '1',
      projectId: 'replace-me',
    ),
  );

  runApp(const _ExampleApp());
}

class _ExampleApp extends StatefulWidget {
  const _ExampleApp();

  @override
  State<_ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<_ExampleApp> {
  String _status = 'press the button';

  Future<void> _run() async {
    setState(() => _status = 'working...');
    try {
      final message = await _work();
      setState(() => _status = message);
    } on Object catch (e) {
      // Shown rather than swallowed: a binding that cannot reach the SDK
      // fails here, and the reason is the useful part.
      setState(() => _status = 'failed: $e');
    }
  }

  Future<String> _work() async {
    final ref = FirebaseStorage.instance.ref('example/hello.txt');
    await ref.putData(Uint8List.fromList('hello'.codeUnits));
    final back = await ref.getData();
    return 'stored and fetched ${back!.length} bytes';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('firebase_storage on Linux')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_status, textAlign: TextAlign.center),
              ),
              FilledButton(onPressed: _run, child: const Text('Run')),
            ],
          ),
        ),
      ),
    );
  }
}
