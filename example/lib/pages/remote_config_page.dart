// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// Defaults, a fetch, an activation, and where each value came from.
///
/// The source column is the useful part: an app that cannot tell a default
/// from a fetched value cannot tell whether a fetch has taken effect.
class RemoteConfigPage extends StatefulWidget {
  const RemoteConfigPage({super.key});

  @override
  State<RemoteConfigPage> createState() => _RemoteConfigPageState();
}

class _RemoteConfigPageState extends State<RemoteConfigPage> {
  final _defaults = TextEditingController(
    text:
        '{\n'
        '  "poll_interval_s": 30,\n'
        '  "backend": "https://api.example.com",\n'
        '  "feature_x": false\n'
        '}',
  );
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void dispose() {
    _defaults.dispose();
    super.dispose();
  }

  FirebaseRemoteConfig get _rc => FirebaseRemoteConfig.instance;

  Future<void> _ensure() async {
    try {
      await _rc.ensureInitialized();
      if (mounted) setState(() => _ready = true);
    } on Object catch (e) {
      appLog.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) => Section(
    title: 'Remote Config',
    subtitle: 'What the app runs on, and where each value came from.',
    children: [
      if (!_ready)
        const Panel(title: 'Starting', child: LinearProgressIndicator()),
      Panel(
        title: 'Defaults',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compiled-in values, so a first launch with no network behaves '
              'rather than waiting. Everything a fetch can change should have '
              'one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            CodeField(controller: _defaults, label: 'JSON'),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Set defaults',
                icon: Icons.save,
                filled: true,
                action: () async {
                  final map = Map<String, dynamic>.from(
                    jsonDecode(_defaults.text) as Map,
                  );
                  await _rc.setDefaults(map);
                  setState(() {});
                  appLog.write('set ${map.length} defaults');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Fetch',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fetch and activate are two steps on purpose: a fetch cannot '
              'change values underneath a screen that is already reading them.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Fetch',
                icon: Icons.cloud_download_outlined,
                action: () async {
                  await _rc.fetch();
                  setState(() {});
                  appLog.write('fetched at ${_rc.lastFetchTime}');
                },
              ),
              RunButton(
                label: 'Activate',
                icon: Icons.play_circle_outline,
                action: () async {
                  final changed = await _rc.activate();
                  setState(() {});
                  appLog.write(
                    changed
                        ? 'activated: the fetched values are live'
                        : 'activated: nothing had changed',
                  );
                },
              ),
              RunButton(
                label: 'Fetch and activate',
                icon: Icons.refresh,
                filled: true,
                action: () async {
                  final changed = await _rc.fetchAndActivate();
                  setState(() {});
                  appLog.write(
                    'fetchAndActivate: '
                    '${changed ? 'values changed' : 'nothing changed'}',
                  );
                },
              ),
            ]),
            const SizedBox(height: 16),
            Rows({
              'lastFetchStatus': _rc.lastFetchStatus.name,
              'lastFetchTime': _rc.lastFetchTime.millisecondsSinceEpoch == 0
                  ? '<never>'
                  : '${_rc.lastFetchTime}',
              'fetchTimeout': '${_rc.settings.fetchTimeout}',
              'minimumFetchInterval': '${_rc.settings.minimumFetchInterval}',
            }),
            const SizedBox(height: 8),
            Text(
              // The SDK reports success with a zero fetch time before anything
              // has been fetched, which reads as a fetch that worked. This
              // implementation says noFetchYet instead.
              'noFetchYet means nothing has been fetched: every value below is '
              'a default.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      Panel(
        title: 'Values',
        child: Builder(
          builder: (context) {
            if (!_ready) return const Text('not initialized yet');
            final all = _rc.getAll();
            if (all.isEmpty) {
              return const Text('no values: set some defaults, or fetch');
            }
            return Rows({
              for (final e in all.entries)
                e.key: '${e.value.asString()}   (${e.value.source.name})',
            });
          },
        ),
      ),
      Panel(
        title: 'What is not bound',
        child: Text(
          'onConfigUpdated: the desktop SDK has no config-update listener, so '
          'the stream throws UnimplementedError rather than being one that '
          'never emits — which an app would read as a config that never '
          'changes. Poll with fetch() on an interval the minimum fetch '
          'interval allows.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}
