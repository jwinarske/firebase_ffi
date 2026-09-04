// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// A live view of one node of the Realtime Database, and the writes that change
/// it.
///
/// The value pane is a listener, not a read: it is what the node is now, and it
/// changes while you watch — which is the whole reason to use this database
/// rather than Firestore.
class DatabasePage extends StatefulWidget {
  const DatabasePage({super.key});

  @override
  State<DatabasePage> createState() => _DatabasePageState();
}

class _DatabasePageState extends State<DatabasePage> {
  final _path = TextEditingController(text: '/demo');
  final _value = TextEditingController(text: '{\n  "hello": "world"\n}');
  late String _watching = _path.text;

  /// Held rather than rebuilt: onValue hands back a new stream on every call,
  /// and a new one on every build would tear the listener down and reattach it
  /// each time anything on this page changed.
  late Stream<DatabaseEvent> _events = _ref.onValue;

  void _watch() {
    setState(() {
      _watching = _path.text.trim();
      _events = _ref.onValue;
    });
  }

  @override
  void dispose() {
    _path.dispose();
    _value.dispose();
    super.dispose();
  }

  DatabaseReference get _ref => FirebaseDatabase.instance.ref(_watching);

  /// The editor holds JSON, which is the shape this database stores anyway.
  Object? get _parsed => jsonDecode(_value.text);

  @override
  Widget build(BuildContext context) => Section(
    title: 'Realtime Database',
    subtitle: 'One node, watched live, with the writes that change it.',
    children: [
      Panel(
        title: 'Node',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LineField(
              controller: _path,
              label: 'Path',
              hint: '/devices/kiosk-7',
              onSubmitted: (_) => _watch(),
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Watch',
                icon: Icons.visibility,
                filled: true,
                action: () async {
                  _watch();
                  appLog.write('watching $_watching');
                },
              ),
              RunButton(
                label: 'Read once',
                icon: Icons.download,
                action: () async {
                  final snap = await _ref.get();
                  _value.text = pretty(snap.value);
                  final what = snap.exists
                      ? '${snap.children.length} children'
                      : 'nothing there';
                  appLog.write('read $_watching: $what');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Live value',
        child: StreamBuilder<DatabaseEvent>(
          stream: _events,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                '${snapshot.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              );
            }
            if (!snapshot.hasData) {
              return const LinearProgressIndicator();
            }
            final value = snapshot.data!.snapshot.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The first event is the current state, which for a node never
                // written is null. That is an event, not a missing one.
                Text(
                  value == null
                      ? 'nothing at $_watching'
                      : '$_watching, as of the last event',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  pretty(value),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
      Panel(
        title: 'Write',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CodeField(controller: _value, label: 'JSON'),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Set',
                icon: Icons.save,
                filled: true,
                action: () async {
                  await _ref.set(_parsed);
                  appLog.write('set $_watching');
                },
              ),
              RunButton(
                // update() touches only the children it names, which is what
                // lets two writers own different fields of one node.
                label: 'Update children',
                icon: Icons.edit,
                action: () async {
                  await _ref.update(Map<String, Object?>.from(_parsed! as Map));
                  appLog.write('updated the named children of $_watching');
                },
              ),
              RunButton(
                // The key is generated on the client from the clock, so the
                // child can be written before the server has heard of it.
                label: 'Push a child',
                icon: Icons.add,
                action: () async {
                  final child = _ref.push();
                  await child.set(_parsed);
                  appLog.write('pushed ${child.key} under $_watching');
                },
              ),
              RunButton(
                label: 'Remove',
                icon: Icons.delete_outline,
                action: () async {
                  await _ref.remove();
                  appLog.write('removed $_watching');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Presence',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'onDisconnect registers a write the server performs when this '
              'connection drops — including when the process is killed, which '
              'is the case a goodbye write from the client cannot cover.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Mark online, offline on disconnect',
                icon: Icons.wifi_tethering,
                action: () async {
                  await _ref.set({'online': true});
                  await _ref.onDisconnect().set({'online': false});
                  appLog.write(
                    '$_watching is online, and will be marked '
                    'offline when this app stops',
                  );
                },
              ),
              RunButton(
                label: 'Cancel it',
                icon: Icons.cancel_outlined,
                action: () async {
                  await _ref.onDisconnect().cancel();
                  appLog.write('nothing is scheduled for the next disconnect');
                },
              ),
              RunButton(
                label: 'Go offline / online',
                icon: Icons.wifi_off,
                action: () async {
                  FirebaseDatabase.instance.goOffline();
                  appLog.write('offline: writes queue locally');
                  await Future<void>.delayed(const Duration(seconds: 1));
                  FirebaseDatabase.instance.goOnline();
                  appLog.write('online: the queue is sent');
                },
              ),
            ]),
          ],
        ),
      ),
    ],
  );
}
