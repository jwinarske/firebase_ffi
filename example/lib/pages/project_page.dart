// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_core/firebase_core.dart';
// The only page that imports the binding directly: which products were
// compiled into the native library is a build fact, and no plugin has an API
// for it.
import 'package:firebase_ffi/app_check.dart' as fdb;
import 'package:firebase_ffi/database.dart' as fdb;
import 'package:firebase_ffi/firestore.dart' as fdb;
import 'package:firebase_ffi/functions.dart' as fdb;
import 'package:firebase_ffi/remote_config.dart' as fdb;
import 'package:firebase_ffi/storage.dart' as fdb;
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

class ProjectPage extends StatelessWidget {
  const ProjectPage({required this.connection, super.key});

  final Connection connection;

  @override
  Widget build(BuildContext context) {
    final options = Firebase.app().options;
    return Section(
      title: 'Project',
      subtitle: 'What this app connected to, and what the build can reach.',
      children: [
        Panel(
          title: 'Connection',
          child: Rows({
            'project': connection.projectId,
            'options from': connection.source,
            'apps': Firebase.apps.map((a) => a.name).join(', '),
          }),
        ),
        Panel(
          title: 'FirebaseOptions',
          child: Rows({
            'projectId': options.projectId,
            'appId': options.appId,
            // Shortened rather than hidden: it identifies a project, and a
            // reader comparing it to the console needs the first few
            // characters, not all of them.
            'apiKey': '${options.apiKey.substring(0, 8)}…',
            'messagingSenderId': options.messagingSenderId,
            'databaseURL': options.databaseURL ?? '<unset>',
            'storageBucket': options.storageBucket ?? '<unset>',
          }),
        ),
        Panel(
          title: 'Products in this build',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Products are opt-in per app: an app that does not name '
                'Firestore does not carry its 23 MB of gRPC, protobuf and '
                'abseil. This is what hooks.user_defines.firebase_ffi.products '
                'selected.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Bound('Firebase SDK', fdb.hasFirebase),
                  _Bound('Auth + Database', fdb.hasFirebase),
                  _Bound('Firestore', fdb.hasFirestore),
                  _Bound('Storage', fdb.hasStorage),
                  _Bound('Functions', fdb.hasFunctions),
                  _Bound('Remote Config', fdb.hasRemoteConfig),
                  _Bound('App Check', fdb.hasAppCheck),
                ],
              ),
              if (!fdb.hasFirebase) ...[
                const SizedBox(height: 12),
                Text(
                  'This build has no Firebase SDK at all — it is the '
                  'transport-only library. Point '
                  'hooks.user_defines.firebase_ffi.firebase_sdk at an install '
                  'prefix in pubspec.yaml and run again.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        Panel(
          title: 'What is not bound',
          child: Text(
            'Anything a plugin declares and this implementation does not bind '
            'throws the platform interface\'s own UnimplementedError, naming '
            'the method — so a gap says so at the call site rather than being '
            'silently absent. Each package\'s example/dart tour walks its own '
            'gaps.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _Bound extends StatelessWidget {
  const _Bound(this.label, this.bound);

  final String label;
  final bool bound;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(
      bound ? Icons.check_circle_outline : Icons.remove_circle_outline,
      size: 18,
      color: bound ? null : Theme.of(context).disabledColor,
    ),
    label: Text(label),
  );
}
