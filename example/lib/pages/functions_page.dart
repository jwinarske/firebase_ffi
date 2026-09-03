// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// Calls a callable by name, with whatever JSON is in the box.
class FunctionsPage extends StatefulWidget {
  const FunctionsPage({super.key});

  @override
  State<FunctionsPage> createState() => _FunctionsPageState();
}

class _FunctionsPageState extends State<FunctionsPage> {
  final _name = TextEditingController(text: 'echo');
  final _region = TextEditingController();
  final _args = TextEditingController(
    text: '{\n  "text": "hello",\n  "n": 42,\n  "ratio": 1.5\n}',
  );
  String? _result;

  @override
  void dispose() {
    _name.dispose();
    _region.dispose();
    _args.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Section(
    title: 'Cloud Functions',
    subtitle: 'A callable, by name, with a JSON argument.',
    children: [
      Panel(
        title: 'Call',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LineField(controller: _name, label: 'Name'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LineField(
                    controller: _region,
                    label: 'Region (optional)',
                    hint: 'us-central1',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            CodeField(controller: _args, label: 'Argument (JSON, or empty)'),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Call',
                icon: Icons.play_arrow,
                filled: true,
                action: () async {
                  // A region is how a callable is addressed: one deployed
                  // outside us-central1 is unreachable from the default
                  // instance.
                  final functions = _region.text.trim().isEmpty
                      ? FirebaseFunctions.instance
                      : FirebaseFunctions.instanceFor(
                          region: _region.text.trim(),
                        );
                  final raw = _args.text.trim();
                  final result = await functions
                      .httpsCallable(_name.text.trim())
                      .call<Object?>(raw.isEmpty ? null : jsonDecode(raw));
                  setState(() => _result = pretty(result.data));
                  appLog.write(
                    '${_name.text.trim()} answered '
                    '${result.data.runtimeType}',
                  );
                },
              ),
            ]),
            if (_result != null) ...[
              const SizedBox(height: 16),
              SelectableText(
                _result!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      Panel(
        title: 'Against the emulator',
        child: Text(
          'The suite in packages/firebase_ffi/test/emulator/functions deploys '
          'three: echo(data) answers {received: data}, add({a, b}) answers a '
          'number rather than a map, and boom() throws — which arrives here as '
          'FirebaseFunctionsException carrying the code the function chose.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      Panel(
        title: 'What is not bound',
        child: Text(
          'Streaming callables: they need a chunked response the desktop C++ '
          'SDK does not surface, so stream() throws UnimplementedError rather '
          'than handing back a stream that never emits.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}
