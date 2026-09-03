// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// A Firebase workbench for desktop and embedded Linux.
//
//   flutter run -d linux
//
// Point it at a project by dropping a google-services.json beside it, or at
// the emulator suite by ticking the box — then sign in, browse and edit the
// Realtime Database and Firestore, move objects in and out of Storage, call a
// function, read Remote Config and mint an App Check token.
//
// Everything under lib/ is ordinary FlutterFire. The only lines that would not
// appear in the same app on Android are the registerWith() calls below and the
// *_ffi entries in pubspec.yaml.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_ffi/cloud_firestore_ffi.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_functions_ffi/cloud_functions_ffi.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:firebase_database_ffi/firebase_database_ffi.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_remote_config_ffi/firebase_remote_config_ffi.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_ffi/firebase_storage_ffi.dart';
import 'package:flutter/material.dart';

import 'pages/app_check_page.dart';
import 'pages/auth_page.dart';
import 'pages/database_page.dart';
import 'pages/firestore_page.dart';
import 'pages/functions_page.dart';
import 'pages/project_page.dart';
import 'pages/remote_config_page.dart';
import 'pages/storage_page.dart';
import 'src/app_state.dart';
import 'src/widgets.dart';

const _emulatorProject = 'fdb-emulator';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The Linux implementations, registered once. Everything after this line is
  // the plugin API and would compile unchanged on any other platform.
  FirebaseCoreFfi.registerWith();
  FirebaseAuthFfi.registerWith();
  FirebaseDatabaseFfi.registerWith();
  CloudFirestoreFfi.registerWith();
  FirebaseStorageFfi.registerWith();
  CloudFunctionsFfi.registerWith();
  FirebaseRemoteConfigFfi.registerWith();
  FirebaseAppCheckFfi.registerWith();

  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Firebase workbench',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFFF5820D),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFFF5820D),
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const _Home(),
  );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  Connection? _connection;

  @override
  Widget build(BuildContext context) {
    final connection = _connection;
    return connection == null
        ? _ConnectScreen(onConnected: (c) => setState(() => _connection = c))
        : _Workbench(connection: connection);
  }
}

// ── Connecting ────────────────────────────────────────────────────────────

/// The first screen: which project, and where its values come from.
///
/// A file rather than constants in the source, so the same build can be
/// pointed at staging or at a customer's project by dropping a different file
/// beside it — which is what a device in the field needs.
class _ConnectScreen extends StatefulWidget {
  const _ConnectScreen({required this.onConnected});

  final ValueChanged<Connection> onConnected;

  @override
  State<_ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<_ConnectScreen> {
  late final _path = TextEditingController(
    text: GoogleServicesConfig.resolvePath(),
  );
  late final _host = TextEditingController(
    text: Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '127.0.0.1',
  );
  bool _emulator =
      (Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '').isNotEmpty;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _path.dispose();
    _host.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final connection = _emulator
          ? await _connectToEmulator(_host.text.trim())
          : await _connectToProject(_path.text.trim());
      appLog.write(
        'connected to ${connection.projectId} (${connection.source})',
      );
      widget.onConnected(connection);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Firebase workbench',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Firebase for desktop and embedded Linux, through one FFI '
                    'code asset.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _emulator,
                    onChanged: (v) => setState(() => _emulator = v),
                    title: const Text('Use the local emulator suite'),
                    subtitle: const Text(
                      'No project and no credentials: firebase emulators:start',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_emulator)
                    LineField(
                      controller: _host,
                      label: 'Emulator host',
                      hint: '127.0.0.1',
                      onSubmitted: (_) => _connect(),
                    )
                  else
                    LineField(
                      controller: _path,
                      label: 'google-services.json',
                      hint: GoogleServicesConfig.defaultFileName,
                      onSubmitted: (_) => _connect(),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<Connection> _connectToProject(String path) async {
  final cfg = GoogleServicesConfig.load(path.isEmpty ? null : path);
  await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: cfg.apiKey,
      appId: cfg.appId,
      messagingSenderId: cfg.messagingSenderId ?? '1',
      projectId: cfg.projectId,
      databaseURL: cfg.databaseUrl,
      storageBucket: cfg.storageBucket,
    ),
  );
  return Connection(
    projectId: cfg.projectId,
    source: GoogleServicesConfig.resolvePath(path.isEmpty ? null : path),
    storageBucket: cfg.storageBucket,
    databaseUrl: cfg.databaseUrl,
  );
}

Future<Connection> _connectToEmulator(String host) async {
  const project = _emulatorProject;
  final databaseUrl = 'http://$host:9000/?ns=$project';
  await Firebase.initializeApp(
    options: FirebaseOptions(
      // The suite checks the project id and ignores the key.
      apiKey: 'emulator-does-not-check-this',
      appId: '1:1:android:1',
      messagingSenderId: '1',
      projectId: project,
      // Database is told which emulator and namespace through the URL: there
      // is no call that runs before initializeApp.
      databaseURL: databaseUrl,
      // Storage has no per-call override for its bucket.
      storageBucket: '$project.appspot.com',
    ),
  );
  await FirebaseAuth.instance.useAuthEmulator(host, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(host, 8080);
  await FirebaseStorage.instance.useStorageEmulator(host, 9199);
  FirebaseFunctions.instance.useFunctionsEmulator(host, 5001);
  return Connection(
    projectId: project,
    source: 'emulator suite on $host',
    emulatorHost: host,
    storageBucket: '$project.appspot.com',
    databaseUrl: databaseUrl,
  );
}

// ── The workbench ─────────────────────────────────────────────────────────

class _Workbench extends StatefulWidget {
  const _Workbench({required this.connection});

  final Connection connection;

  @override
  State<_Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<_Workbench> {
  int _index = 0;
  bool _transcript = true;

  @override
  Widget build(BuildContext context) {
    final pages = <(NavigationRailDestination, Widget)>[
      (
        const NavigationRailDestination(
          icon: Icon(Icons.info_outline),
          label: Text('Project'),
        ),
        ProjectPage(connection: widget.connection),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.person_outline),
          label: Text('Auth'),
        ),
        const AuthPage(),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.account_tree_outlined),
          label: Text('Database'),
        ),
        const DatabasePage(),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.table_rows_outlined),
          label: Text('Firestore'),
        ),
        const FirestorePage(),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.folder_outlined),
          label: Text('Storage'),
        ),
        StoragePage(connection: widget.connection),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.functions),
          label: Text('Functions'),
        ),
        const FunctionsPage(),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.tune),
          label: Text('Config'),
        ),
        const RemoteConfigPage(),
      ),
      (
        const NavigationRailDestination(
          icon: Icon(Icons.verified_user_outlined),
          label: Text('App Check'),
        ),
        const AppCheckPage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.connection.projectId),
            Text(
              widget.connection.source,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          const _SignedInAs(),
          IconButton(
            tooltip: _transcript
                ? 'Hide the transcript'
                : 'Show the transcript',
            onPressed: () => setState(() => _transcript = !_transcript),
            icon: Icon(_transcript ? Icons.expand_more : Icons.expand_less),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            destinations: [for (final p in pages) p.$1],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(child: pages[_index].$2),
                if (_transcript) const _Transcript(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The uid in the app bar, so no page has to say it twice.
class _SignedInAs extends StatelessWidget {
  const _SignedInAs();

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    initialData: FirebaseAuth.instance.currentUser,
    builder: (context, snapshot) {
      final uid = snapshot.data?.uid;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Chip(
          avatar: Icon(
            uid == null ? Icons.lock_outline : Icons.lock_open,
            size: 18,
          ),
          label: Text(uid ?? 'signed out'),
        ),
      );
    },
  );
}

/// Every call the app has made, and what it answered.
class _Transcript extends StatelessWidget {
  const _Transcript();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: AnimatedBuilder(
        animation: appLog,
        builder: (context, _) {
          final lines = appLog.lines.reversed.toList();
          return Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: 12),
                  Text('Transcript', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: appLog.clear,
                    child: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  // Newest first, so the last thing that happened is the thing
                  // in view without anyone having to scroll.
                  reverse: false,
                  itemCount: lines.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    child: SelectableText(
                      '${lines[i].stamp}  ${lines[i].text}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: lines[i].error ? theme.colorScheme.error : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
