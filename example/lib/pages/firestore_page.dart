// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// A collection browser: the documents a query matches, live, and an editor for
/// whichever one is selected.
class FirestorePage extends StatefulWidget {
  const FirestorePage({super.key});

  @override
  State<FirestorePage> createState() => _FirestorePageState();
}

class _FirestorePageState extends State<FirestorePage> {
  final _collection = TextEditingController(text: 'demo');
  final _field = TextEditingController();
  final _value = TextEditingController();
  final _limit = TextEditingController(text: '25');
  final _document = TextEditingController(
    text: '{\n  "name": "kiosk-7",\n  "healthy": true\n}',
  );

  String _op = '==';
  String _collectionPath = 'demo';
  String? _selected;

  /// Held rather than rebuilt: a new stream on every build would resubscribe
  /// the query each time a document is selected, and the list would flicker.
  /// It is replaced only when [_apply] says the query changed.
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream = _query.snapshots();

  static const _ops = ['==', '!=', '<', '<=', '>', '>=', 'array-contains'];

  /// Points the list at whatever the fields now say.
  void _apply() {
    setState(() {
      _collectionPath = _collection.text.trim();
      _stream = _query.snapshots();
    });
  }

  @override
  void dispose() {
    _collection.dispose();
    _field.dispose();
    _value.dispose();
    _limit.dispose();
    _document.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> get _ref =>
      FirebaseFirestore.instance.collection(_collectionPath);

  /// The query the list below is showing.
  ///
  /// A filter is applied at the server, so the documents that do not match are
  /// never sent — the point of a query rather than a client-side filter.
  Query<Map<String, dynamic>> get _query {
    Query<Map<String, dynamic>> q = _ref;
    final field = _field.text.trim();
    if (field.isNotEmpty) {
      final value = _typed(_value.text);
      // where() takes its operator as a named argument, so the operator picks
      // the call rather than being passed as a value.
      q = switch (_op) {
        '!=' => q.where(field, isNotEqualTo: value),
        '<' => q.where(field, isLessThan: value),
        '<=' => q.where(field, isLessThanOrEqualTo: value),
        '>' => q.where(field, isGreaterThan: value),
        '>=' => q.where(field, isGreaterThanOrEqualTo: value),
        'array-contains' => q.where(field, arrayContains: value),
        _ => q.where(field, isEqualTo: value),
      };
    }
    return q.limit(int.tryParse(_limit.text) ?? 25);
  }

  /// "42" is a number, "true" is a bool, everything else is the string it is.
  ///
  /// Firestore's comparisons are typed: a document with n = 42 does not match
  /// a filter for "42", and a text field cannot say which was meant.
  Object? _typed(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    if (text == 'true' || text == 'false') return text == 'true';
    return num.tryParse(text) ?? text;
  }

  @override
  Widget build(BuildContext context) => Section(
    title: 'Cloud Firestore',
    subtitle:
        'A collection, filtered at the server, with an editor for one '
        'document.',
    children: [
      Panel(
        title: 'Query',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LineField(
              controller: _collection,
              label: 'Collection',
              hint: 'devices',
              onSubmitted: (_) => _apply(),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: LineField(
                    controller: _field,
                    label: 'Field (optional)',
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    initialValue: _op,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Operator',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final op in _ops)
                        DropdownMenuItem(value: op, child: Text(op)),
                    ],
                    onChanged: (v) {
                      _op = v ?? '==';
                      _apply();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: LineField(controller: _value, label: 'Value'),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: LineField(controller: _limit, label: 'Limit'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Run',
                icon: Icons.search,
                filled: true,
                action: () async {
                  _apply();
                  appLog.write('watching $_collectionPath');
                },
              ),
              RunButton(
                label: 'Count',
                icon: Icons.numbers,
                action: () async {
                  // Only the number crosses the wire: counting a large
                  // collection costs one round trip rather than one per
                  // document.
                  final count = (await _query.count().get()).count;
                  appLog.write('$_collectionPath matches $count documents');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Documents',
        child: SizedBox(
          height: 220,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _stream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(
                  '${snapshot.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                );
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return const Center(child: Text('no documents match'));
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final doc = docs[i];
                  return ListTile(
                    dense: true,
                    selected: doc.id == _selected,
                    title: Text(doc.id),
                    subtitle: Text(
                      doc.data().keys.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      setState(() => _selected = doc.id);
                      _document.text = pretty(doc.data());
                    },
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        try {
                          await doc.reference.delete();
                          appLog.write('deleted ${doc.reference.path}');
                        } on Object catch (e) {
                          appLog.fail(e);
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
      Panel(
        title: 'Document',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _selected == null
                  ? 'Nothing selected: writing creates a document with a '
                        'generated id.'
                  : 'Editing $_collectionPath/$_selected.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'The editor is JSON, so a timestamp, a geopoint, a blob or a '
              'reference shows as text here — they cross the FFI boundary as '
              'themselves, but JSON has no form for them.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            CodeField(controller: _document, label: 'JSON'),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: 'Save',
                icon: Icons.save,
                filled: true,
                action: () async {
                  final data = Map<String, dynamic>.from(
                    jsonDecode(_document.text) as Map,
                  );
                  // A generated id when nothing is selected: local, so the
                  // document can be written before the server names it.
                  final ref = _selected == null
                      ? _ref.doc()
                      : _ref.doc(_selected);
                  await ref.set(data);
                  setState(() => _selected = ref.id);
                  appLog.write('wrote ${ref.path}');
                },
              ),
              RunButton(
                // Only the fields named, leaving the rest of the document
                // alone — which is what a second writer needs.
                label: 'Merge',
                icon: Icons.merge,
                action: () async {
                  if (_selected == null) {
                    throw StateError('select a document to merge into');
                  }
                  await _ref
                      .doc(_selected)
                      .set(
                        Map<String, dynamic>.from(
                          jsonDecode(_document.text) as Map,
                        ),
                        SetOptions(merge: true),
                      );
                  appLog.write('merged into $_collectionPath/$_selected');
                },
              ),
              RunButton(
                label: 'New',
                icon: Icons.note_add_outlined,
                action: () async {
                  setState(() => _selected = null);
                  appLog.write('editing a new document');
                },
              ),
            ]),
          ],
        ),
      ),
    ],
  );
}
