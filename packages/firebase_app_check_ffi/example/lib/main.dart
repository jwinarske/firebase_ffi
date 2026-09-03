// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Registers a provider that supplies its own token.
//
// The only lines specific to Linux are the registerWith calls below. Every
// other line is ordinary firebase_app_check and would compile unchanged on Android.

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On Linux nothing registers these automatically yet, so an app says so
  // once at startup. Elsewhere the plugin registers itself and these are not
  // called.
  FirebaseCoreFfi.registerWith();
  FirebaseAppCheckFfi.registerWith();

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
    // A device that attests for itself supplies its own token. This one
    // makes a fake, which is the shape rather than the substance.
    FirebaseAppCheckFfi.useCustomProvider(
      () async => AppCheckTokenResult(
        token: 'a-token-your-device-would-attest-for',
        expirationTime: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    await FirebaseAppCheck.instance.activate();
    final token = await FirebaseAppCheck.instance.getToken();
    return 'App Check token: ${token?.substring(0, 12)}...';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('firebase_app_check on Linux')),
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
