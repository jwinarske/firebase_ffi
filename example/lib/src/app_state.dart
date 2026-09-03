// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

/// One line of the transcript at the bottom of the window.
///
/// Every call the app makes is written here, with what it answered. On a board
/// this is the only feedback there is — the alternative is reading a log over
/// ssh while looking at the screen.
@immutable
class LogLine {
  LogLine(this.text, {this.error = false}) : at = DateTime.now();

  final String text;
  final bool error;
  final DateTime at;

  String get stamp =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}

/// The shared transcript. A single instance rather than one per page, so a
/// failure on the Storage page is still visible after switching to Firestore.
class AppLog extends ChangeNotifier {
  final List<LogLine> _lines = [];

  List<LogLine> get lines => List.unmodifiable(_lines);

  void write(String text) => _add(LogLine(text));

  void fail(Object error) => _add(LogLine('$error', error: true));

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  void _add(LogLine line) {
    // Bounded: a listener left running for a day should not be a memory leak.
    _lines.add(line);
    if (_lines.length > 500) _lines.removeRange(0, _lines.length - 500);
    notifyListeners();
  }
}

final appLog = AppLog();

/// What the app connected to, so every page can say where its data went.
@immutable
class Connection {
  const Connection({
    required this.projectId,
    required this.source,
    this.emulatorHost,
    this.storageBucket,
    this.databaseUrl,
  });

  final String projectId;

  /// Where the options came from — a file path, or the emulator.
  final String source;

  final String? emulatorHost;
  final String? storageBucket;
  final String? databaseUrl;

  bool get emulated => emulatorHost != null;
}
