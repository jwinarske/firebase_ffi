// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// Sign in, because everything else on the other pages needs a caller: rules
/// are written against one, and an unauthenticated read is refused rather than
/// answered empty.
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _token = TextEditingController();

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  FirebaseAuth get _auth => FirebaseAuth.instance;

  @override
  Widget build(BuildContext context) => Section(
    title: 'Authentication',
    subtitle:
        'Anonymous for a prototype, a custom token for a device that has '
        'an identity of its own.',
    children: [
      Panel(
        title: 'Current user',
        child: StreamBuilder<User?>(
          stream: _auth.authStateChanges(),
          initialData: _auth.currentUser,
          builder: (context, snapshot) {
            final user = snapshot.data;
            if (user == null) {
              return const Text('Nobody is signed in.');
            }
            return Rows({
              'uid': user.uid,
              'isAnonymous': '${user.isAnonymous}',
              'providers': user.providerData.isEmpty
                  ? '<none>'
                  : user.providerData.map((p) => p.providerId).join(', '),
            });
          },
        ),
      ),
      Panel(
        title: 'Anonymous',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A throwaway identity the backend mints on request. The desktop '
              'SDK persists it, so the same uid comes back on the next launch '
              'until something signs out.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Sign in anonymously',
                icon: Icons.login,
                filled: true,
                action: () async {
                  final cred = await _auth.signInAnonymously();
                  appLog.write('signed in as ${cred.user!.uid}');
                },
              ),
              RunButton(
                label: 'Sign out',
                icon: Icons.logout,
                action: () async {
                  await _auth.signOut();
                  appLog.write('signed out');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Custom token',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Minted by a backend holding the Admin SDK, after it has '
              'satisfied itself the device is what it claims to be. The uid is '
              'the backend\'s choice, so it survives a reflash — which is what '
              'a fleet needs and an anonymous identity cannot give.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            CodeField(controller: _token, label: 'JWT', minLines: 3),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Sign in with this token',
                icon: Icons.vpn_key,
                filled: true,
                action: () async {
                  final cred = await _auth.signInWithCustomToken(
                    _token.text.trim(),
                  );
                  appLog.write('custom token accepted for ${cred.user!.uid}');
                },
              ),
              RunButton(
                label: 'Load from a file',
                icon: Icons.folder_open,
                action: () async {
                  final path =
                      Platform.environment['FDB_CUSTOM_TOKEN'] ??
                      'custom-token.jwt';
                  final file = File(path);
                  if (!file.existsSync()) {
                    throw FileSystemException('no token file', path);
                  }
                  _token.text = file.readAsStringSync().trim();
                  appLog.write('read a token from $path');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'What is not bound',
        child: Text(
          'Email and password, phone, and the federated providers: the desktop '
          'C++ SDK has no UI to host them and no way to finish a flow that '
          'needs a browser. Calling one throws UnimplementedError naming the '
          'method rather than failing later somewhere else.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}
