// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `firebase_remote_config` implementation for desktop Linux.
///
/// The platform interface reads values synchronously — `getString`, `getAll`,
/// `lastFetchTime` are plain getters — while the binding answers on a port. So
/// values are cached, and the cache is refreshed at exactly the points that
/// can change them: `ensureInitialized`, `setDefaults`, `activate` and
/// `fetchAndActivate`.
///
/// Real-time updates (`onConfigUpdated`) keep the platform interface's own
/// `UnimplementedError`: the desktop SDK has no config-update listener.
library;

import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/remote_config.dart' as fdb;
import 'package:firebase_remote_config_platform_interface/firebase_remote_config_platform_interface.dart';

/// Registered by Flutter on Linux via `dartPluginClass`.
class FirebaseRemoteConfigFfi extends FirebaseRemoteConfigPlatform {
  FirebaseRemoteConfigFfi({FirebaseApp? app}) : super(appInstance: app);

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseRemoteConfigPlatform.instance = FirebaseRemoteConfigFfi();
  }

  // One Remote Config instance per process in the binding, so the cache is
  // shared rather than per-delegate. A second delegate reading a stale copy of
  // its own would be worse than sharing one.
  static final Map<String, RemoteConfigValue> _values = {};
  static bool _initialized = false;

  @override
  FirebaseRemoteConfigPlatform delegateFor({required FirebaseApp app}) =>
      FirebaseRemoteConfigFfi(app: app);

  @override
  FirebaseRemoteConfigPlatform setInitialValues({
    required Map<dynamic, dynamic> remoteConfigValues,
  }) => this;

  @override
  Future<void> ensureInitialized() async {
    if (!_initialized) {
      await fdb.initRemoteConfig();
      _initialized = true;
    }
    await _refresh();
  }

  // Reads every value and its source in one pass. Sources come one key at a
  // time because that is how the SDK reports them -- GetAll has no source --
  // and it is an in-memory read, not a request.
  Future<void> _refresh() async {
    final values = await fdb.configValues();
    _values
      ..clear()
      ..addEntries(
        values.entries.map(
          (e) => MapEntry(
            e.key,
            RemoteConfigValue(
              _encode(e.value),
              _sourceOf(fdb.configValueSource(e.key)),
            ),
          ),
        ),
      );
  }

  // RemoteConfigValue holds UTF-8 bytes and parses them on demand, so every
  // value has to be written the way its accessor will read it back. asBool
  // accepts 'true' or '1'; asInt and asDouble parse the text.
  static List<int> _encode(Object? v) => switch (v) {
    null => const <int>[],
    bool b => utf8.encode(b ? 'true' : 'false'),
    _ => utf8.encode('$v'),
  };

  static ValueSource _sourceOf(fdb.RemoteConfigValueSource s) => switch (s) {
    fdb.RemoteConfigValueSource.static => ValueSource.valueStatic,
    fdb.RemoteConfigValueSource.defaultValue => ValueSource.valueDefault,
    fdb.RemoteConfigValueSource.remote => ValueSource.valueRemote,
  };

  @override
  Future<void> setDefaults(Map<String, dynamic> defaultParameters) async {
    await fdb.setConfigDefaults(defaultParameters);
    await _refresh();
  }

  @override
  Future<bool> activate() async {
    final changed = await fdb.activateConfig();
    await _refresh();
    return changed;
  }

  @override
  Future<void> fetch() => fdb.fetchConfig();

  @override
  Future<bool> fetchAndActivate() async {
    final changed = await fdb.fetchAndActivateConfig();
    await _refresh();
    return changed;
  }

  @override
  Map<String, RemoteConfigValue> getAll() => Map.of(_values);

  // A key with no value is not an error here, as it is not on other platforms:
  // the accessor's own default is the answer. RemoteConfigValue(const [], ...)
  // is what produces it, rather than a literal repeated per type.
  RemoteConfigValue _valueOf(String key) =>
      _values[key] ?? RemoteConfigValue(const <int>[], ValueSource.valueStatic);

  @override
  RemoteConfigValue getValue(String key) => _valueOf(key);

  @override
  bool getBool(String key) => _valueOf(key).asBool();

  @override
  int getInt(String key) => _valueOf(key).asInt();

  @override
  double getDouble(String key) => _valueOf(key).asDouble();

  @override
  String getString(String key) => _valueOf(key).asString();

  @override
  DateTime get lastFetchTime => fdb.configInfo().lastFetchTime;

  @override
  RemoteConfigFetchStatus get lastFetchStatus => switch (fdb
      .configInfo()
      .lastFetchStatus) {
    fdb.RemoteConfigFetchStatus.noFetchYet =>
      RemoteConfigFetchStatus.noFetchYet,
    fdb.RemoteConfigFetchStatus.success => RemoteConfigFetchStatus.success,
    fdb.RemoteConfigFetchStatus.failure => RemoteConfigFetchStatus.failure,
    // The SDK has no throttled status of its own; it reports a failure and a
    // throttled-until time. Reported as failure rather than invented.
    fdb.RemoteConfigFetchStatus.pending => RemoteConfigFetchStatus.failure,
  };

  @override
  RemoteConfigSettings get settings {
    final s = fdb.configSettings();
    return RemoteConfigSettings(
      fetchTimeout: s.fetchTimeout,
      minimumFetchInterval: s.minimumFetchInterval,
    );
  }

  @override
  Future<void> setConfigSettings(RemoteConfigSettings remoteConfigSettings) =>
      fdb.setConfigSettings(
        fdb.RemoteConfigSettings(
          fetchTimeout: remoteConfigSettings.fetchTimeout,
          minimumFetchInterval: remoteConfigSettings.minimumFetchInterval,
        ),
      );
}
