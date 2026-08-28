// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Reads the `google-services.json` the Firebase console generates, so the
/// project a build talks to is a deployed file rather than constants compiled
/// into the app.
///
/// This is the Android config file verbatim — the same one FlutterFire consumes
/// — which matters because the Linux desktop SDK is configured from the Android
/// options (there is no Linux-specific config file, and the console does not
/// emit one).
library;

import 'dart:convert';
import 'dart:io';

/// The four values `initDatabase` needs, plus the bucket for later use.
class GoogleServicesConfig {
  const GoogleServicesConfig({
    required this.appId,
    required this.apiKey,
    required this.projectId,
    required this.databaseUrl,
    this.storageBucket,
  });

  final String appId;
  final String apiKey;
  final String projectId;
  final String databaseUrl;
  final String? storageBucket;

  /// Where to look when no path is given: the environment variable first, then
  /// the working directory, which for a deployed bundle is the bundle root.
  static const envVar = 'GOOGLE_SERVICES_JSON';
  static const defaultFileName = 'google-services.json';

  static String resolvePath([String? path]) =>
      path ?? Platform.environment[envVar] ?? defaultFileName;

  /// Parses [path], or the default location.
  ///
  /// Throws [FormatException] naming the field that was missing, rather than
  /// letting a partial config reach the SDK and fail as an opaque init error.
  static GoogleServicesConfig load([String? path]) {
    final file = File(resolvePath(path));
    if (!file.existsSync()) {
      throw FileSystemException('no google-services.json', file.path);
    }
    return parse(file.readAsStringSync(), source: file.path);
  }

  static GoogleServicesConfig parse(String text, {String source = '<memory>'}) {
    final Object? decoded = json.decode(text);
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$source: expected a JSON object');
    }

    Map<String, Object?> obj(Map<String, Object?> from, String key) {
      final v = from[key];
      if (v is! Map<String, Object?>) {
        throw FormatException('$source: missing object "$key"');
      }
      return v;
    }

    String str(Map<String, Object?> from, String key) {
      final v = from[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('$source: missing string "$key"');
      }
      return v;
    }

    final info = obj(decoded, 'project_info');

    // One project can register several apps. Without a package name to match,
    // a single client is unambiguous; more than one is not, so say so instead
    // of silently taking the first.
    final clients = decoded['client'];
    if (clients is! List || clients.isEmpty) {
      throw FormatException('$source: no "client" entries');
    }
    if (clients.length > 1) {
      throw FormatException(
        '$source: ${clients.length} clients registered; this loader needs '
        'exactly one to pick without ambiguity',
      );
    }
    final client = clients.first;
    if (client is! Map<String, Object?>) {
      throw FormatException('$source: malformed "client" entry');
    }

    final keys = client['api_key'];
    if (keys is! List || keys.isEmpty || keys.first is! Map<String, Object?>) {
      throw FormatException('$source: no "api_key" for the client');
    }

    return GoogleServicesConfig(
      appId: str(obj(client, 'client_info'), 'mobilesdk_app_id'),
      apiKey: str(keys.first as Map<String, Object?>, 'current_key'),
      projectId: str(info, 'project_id'),
      // The console writes this only once a Realtime Database exists; its
      // absence is the actionable diagnosis, so name it.
      databaseUrl: () {
        final v = info['firebase_url'];
        if (v is! String || v.isEmpty) {
          throw FormatException(
            '$source: no "firebase_url" — the project has no Realtime '
            'Database, or the file predates its creation',
          );
        }
        return v;
      }(),
      storageBucket: info['storage_bucket'] as String?,
    );
  }

  @override
  String toString() => 'GoogleServicesConfig($projectId, $databaseUrl)';
}
