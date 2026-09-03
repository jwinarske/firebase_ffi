// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_state.dart';

/// A page: a title, a short line about what it is for, and the body.
class Section extends StatelessWidget {
  const Section({
    required this.title,
    required this.subtitle,
    required this.children,
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        ...children,
      ],
    );
  }
}

/// A group of controls under a heading.
class Panel extends StatelessWidget {
  const Panel({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A button whose action is asynchronous and might fail.
///
/// Everything a Firebase call can do — take a while, throw with a code — shows
/// up here rather than in each page: the button spins while it runs, and the
/// outcome goes to the transcript either way. A page that swallowed the error
/// would leave a user looking at a screen that did not change.
class RunButton extends StatefulWidget {
  const RunButton({
    required this.label,
    required this.action,
    this.icon,
    this.filled = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool filled;
  final Future<void> Function() action;

  @override
  State<RunButton> createState() => _RunButtonState();
}

class _RunButtonState extends State<RunButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.action();
    } on Object catch (e) {
      appLog.fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(widget.label);
    final onPressed = _busy ? null : _run;
    if (widget.filled) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(widget.icon ?? Icons.play_arrow),
        label: child,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(widget.icon ?? Icons.play_arrow),
      label: child,
    );
  }
}

/// A row of buttons that wraps rather than overflowing on a narrow screen.
class ButtonRow extends StatelessWidget {
  const ButtonRow(this.children, {super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: children);
}

/// A labelled single-line field.
class LineField extends StatelessWidget {
  const LineField({
    required this.controller,
    required this.label,
    this.hint,
    this.onSubmitted,
    this.obscure = false,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    obscureText: obscure,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}

/// A multi-line monospace editor, which is what a JSON document wants.
class CodeField extends StatelessWidget {
  const CodeField({
    required this.controller,
    required this.label,
    this.minLines = 6,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final int minLines;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    minLines: minLines,
    maxLines: minLines * 3,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    decoration: InputDecoration(
      labelText: label,
      alignLabelWithHint: true,
      border: const OutlineInputBorder(),
    ),
  );
}

/// Key and value, for the many places this app shows one.
class Rows extends StatelessWidget {
  const Rows(this.entries, {super.key});

  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 170,
                  child: Text(
                    e.key,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(child: SelectableText(e.value, style: mono)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Pretty JSON, for values that came back from a backend.
String pretty(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on JsonUnsupportedObjectError {
    // Firestore's own types — a Timestamp, a GeoPoint, a Blob, a reference —
    // have no JSON form. Showing what they are beats refusing to show the
    // document at all.
    return _describe(value);
  }
}

String _describe(Object? value) {
  if (value is Map) {
    final fields = value.entries
        .map((e) => '  "${e.key}": ${_describe(e.value)}')
        .join(',\n');
    return '{\n$fields\n}';
  }
  if (value is List) return '[${value.map(_describe).join(', ')}]';
  if (value is String) return jsonEncode(value);
  if (value == null || value is num || value is bool) return '$value';
  return '"$value"  // ${value.runtimeType}';
}
