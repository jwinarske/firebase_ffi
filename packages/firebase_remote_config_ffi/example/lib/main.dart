// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Sets a default, fetches, and shows whichever value wins.
//
// The only lines specific to Linux are the registerWith calls below. Every
// other line is ordinary firebase_remote_config and would compile unchanged on Android.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_remote_config_ffi/firebase_remote_config_ffi.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On Linux nothing registers these automatically yet, so an app says so
  // once at startup. Elsewhere the plugin registers itself and these are not
  // called.
  FirebaseCoreFfi.registerWith();
  FirebaseRemoteConfigFfi.registerWith();

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
    final rc = FirebaseRemoteConfig.instance;
    await rc.ensureInitialized();
    await rc.setDefaults(const {'greeting': 'hello from the default'});
    await rc.fetchAndActivate();
    return rc.getString('greeting');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('firebase_remote_config on Linux')),
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
