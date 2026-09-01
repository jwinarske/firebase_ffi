// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// Remote Config: defaults in, values out.
///
/// Values are read as one map rather than through a getter per type. The SDK's
/// typed getters coerce silently — asking for a long and getting a string back
/// gives 0 — and a map keeps whatever type the value actually has.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'database.dart' show hasFirebase;
import 'src/ffi/bindings.dart';
import 'src/variant_codec.dart';

/// A Remote Config operation that failed.
class RemoteConfigException implements Exception {
  const RemoteConfigException(this.code, this.message, this.operation);
  final int code;
  final String message;
  final String operation;

  @override
  String toString() => 'RemoteConfigException($operation, $code): $message';
}

/// True when the library was built with Remote Config bound.
bool get hasRemoteConfig {
  if (!hasFirebase) return false;
  try {
    return fdbHaveRemoteConfig() != 0;
  } on ArgumentError {
    return false;
  }
}

/// Binds Remote Config to the app already initialized by `initDatabase`.
///
/// Asynchronous because the SDK's values are only meaningful once the last
/// activated config has been brought into memory.
Future<void> initRemoteConfig() {
  if (!hasFirebase) {
    return Future.error(StateError('this build has no Firebase SDK'));
  }
  return _awaitOutcome(fdbRcInit, 'initRemoteConfig');
}

Future<void> _awaitOutcome(int Function(int port) start, String what) {
  final completer = Completer<void>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete();
    } else {
      completer.completeError(
        RemoteConfigException(parts[1]! as int, parts[2]! as String, what),
      );
    }
  };
  final rc = start(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(switch (rc) {
      -1 => StateError('$what before the Firebase app was initialized'),
      -2 => StateError('Remote Config instance could not be created'),
      -3 => ArgumentError('these defaults cannot be encoded'),
      _ => StateError('$what failed to start ($rc)'),
    });
  }
  return completer.future;
}

/// Sets the values a key reads as before any fetch has succeeded.
///
/// That is most of an appliance's life: a device that cannot reach the network
/// still has to behave.
Future<void> setConfigDefaults(Map<String, Object?> defaults) {
  final encoded = encodeVariant(defaults);
  final buf = calloc<Uint8>(encoded.isEmpty ? 1 : encoded.length);
  buf.asTypedList(encoded.length).setAll(0, encoded);
  return _awaitOutcome(
    (port) => fdbRcSetDefaults(buf, encoded.length, port),
    'setConfigDefaults',
  ).whenComplete(() => calloc.free(buf));
}

/// Every key and its current value: the activated one if a fetch supplied it,
/// otherwise the default.
Future<Map<String, Object?>> configValues() {
  final completer = Completer<Map<String, Object?>>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final bytes = message! as Uint8List;
    final seq = ByteData.sublistView(bytes).getInt64(8, Endian.host);
    if (seq < 0) {
      completer.completeError(
        const RemoteConfigException(-2, 'values could not be encoded', 'get'),
      );
      return;
    }
    final decoded = decodeSnapshotValue(bytes);
    completer.complete({
      for (final e in ((decoded as Map?) ?? const {}).entries)
        '${e.key}': e.value,
    });
  };
  final rc = fdbRcGetAll(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('configValues failed ($rc)'));
  }
  return completer.future;
}

/// How the last fetch ended.
enum RemoteConfigFetchStatus {
  /// The SDK's own order, which the values are read as: success, failure,
  /// pending. `noFetchYet` is not one of the SDK's -- it reports success with
  /// a zero fetch time before anything has been fetched, and a caller cannot
  /// tell that apart from a real success without being told.
  success,
  failure,
  pending,
  noFetchYet,
}

/// Where a value came from.
enum RemoteConfigValueSource {
  /// Nothing set it: no default, no fetch.
  static,

  /// A default supplied by [setConfigDefaults].
  defaultValue,

  /// A fetch brought it back and it has been activated.
  remote,
}

/// Where [key]'s current value came from.
///
/// A caller that cannot tell a default from a fetched value cannot tell
/// whether a fetch has taken effect.
RemoteConfigValueSource configValueSource(String key) {
  final k = key.toNativeUtf8();
  try {
    final rc = fdbRcValueSource(k.cast());
    if (rc < 0) {
      throw StateError(
        rc == -1 ? 'Remote Config is not initialized' : 'a key is required',
      );
    }
    // Mapped by name, not by index. The SDK orders these static, remote,
    // default; this enum orders them static, default, remote. Casting through
    // the index would swap the two that matter.
    return switch (rc) {
      0 => RemoteConfigValueSource.static,
      1 => RemoteConfigValueSource.remote,
      2 => RemoteConfigValueSource.defaultValue,
      _ => RemoteConfigValueSource.static,
    };
  } finally {
    calloc.free(k);
  }
}

/// What the SDK knows about the last fetch, read from memory.
class RemoteConfigInfo {
  const RemoteConfigInfo({
    required this.lastFetchTime,
    required this.lastFetchStatus,
    required this.throttledEndTime,
  });

  final DateTime lastFetchTime;
  final RemoteConfigFetchStatus lastFetchStatus;
  final DateTime throttledEndTime;
}

/// The fetch timeout and the shortest interval between fetches.
class RemoteConfigSettings {
  const RemoteConfigSettings({
    required this.fetchTimeout,
    required this.minimumFetchInterval,
  });

  final Duration fetchTimeout;
  final Duration minimumFetchInterval;
}

List<int> _readInts(int Function(Pointer<Int64>, int) read, int count) {
  final buf = calloc<Int64>(count);
  try {
    final rc = read(buf, count);
    if (rc < 0) {
      throw StateError(
        rc == -1 ? 'Remote Config is not initialized' : 'refused ($rc)',
      );
    }
    return List<int>.generate(rc, (i) => buf[i]);
  } finally {
    calloc.free(buf);
  }
}

/// What the SDK knows about the last fetch.
RemoteConfigInfo configInfo() {
  final v = _readInts(fdbRcInfo, 4);
  return RemoteConfigInfo(
    lastFetchTime: DateTime.fromMillisecondsSinceEpoch(v[0]),
    // A zero fetch time means nothing has been fetched. The SDK still reports
    // success there, which reads as a successful fetch that never happened.
    lastFetchStatus: v[0] == 0
        ? RemoteConfigFetchStatus.noFetchYet
        : RemoteConfigFetchStatus.values[v[1].clamp(0, 2)],
    throttledEndTime: DateTime.fromMillisecondsSinceEpoch(v[3]),
  );
}

/// The current fetch timeout and minimum interval.
RemoteConfigSettings configSettings() {
  final v = _readInts(fdbRcGetSettings, 2);
  return RemoteConfigSettings(
    fetchTimeout: Duration(milliseconds: v[0]),
    minimumFetchInterval: Duration(milliseconds: v[1]),
  );
}

/// Sets the fetch timeout and the shortest interval between fetches.
Future<void> setConfigSettings(RemoteConfigSettings settings) => _awaitOutcome(
  (port) => fdbRcSetSettings(
    settings.fetchTimeout.inMilliseconds,
    settings.minimumFetchInterval.inMilliseconds,
    port,
  ),
  'setConfigSettings',
);

/// Fetches from the backend without activating.
///
/// [cacheExpiration] null uses the configured minimum interval; [Duration.zero]
/// fetches unconditionally, which is a different thing and not the default.
Future<void> fetchConfig({Duration? cacheExpiration}) => _awaitOutcome(
  (port) => fdbRcFetch(cacheExpiration?.inSeconds ?? -1, port),
  'fetchConfig',
);

/// Activates what the last fetch brought back.
///
/// Answers false when there was nothing new, which is not a failure.
Future<bool> activateConfig() {
  final completer = Completer<bool>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete((parts[1]! as int) == 1);
    } else {
      completer.completeError(
        RemoteConfigException(
          parts[1]! as int,
          parts[2]! as String,
          'activate',
        ),
      );
    }
  };
  final rc = fdbRcActivate(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('activate failed ($rc)'));
  }
  return completer.future;
}

/// Fetches from the backend and activates what came back.
///
/// Answers false when the fetch succeeded but there was nothing new to
/// activate, which is not a failure.
Future<bool> fetchAndActivateConfig() {
  final completer = Completer<bool>();
  final receive = RawReceivePort();
  receive.handler = (Object? message) {
    receive.close();
    final parts = message! as List<Object?>;
    if (parts[0] == true) {
      completer.complete((parts[1]! as int) == 1);
    } else {
      completer.completeError(
        RemoteConfigException(
          parts[1]! as int,
          parts[2]! as String,
          'fetchAndActivate',
        ),
      );
    }
  };
  final rc = fdbRcFetchAndActivate(receive.sendPort.nativePort);
  if (rc != 0) {
    receive.close();
    return Future.error(StateError('fetchAndActivate failed ($rc)'));
  }
  return completer.future;
}
