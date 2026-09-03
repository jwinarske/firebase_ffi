// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Remote Config binding, end to end.
//
//   dart run example/remote_config.dart
//
// Defaults, fetch and activate as two separate steps, where a value came from,
// and the settings that decide how often a fetch is allowed to happen.
//
// There is no Remote Config emulator: a fetch needs a real project, and this
// program says so and carries on with the half that works offline — which is
// most of it, because defaults are what an app runs on until a fetch lands.

import 'package:firebase_ffi/remote_config.dart';

import 'setup.dart';

Future<void> main() async {
  final app = await start(use: {Product.remoteConfig});

  await _defaults();
  await _settings();
  await _fetch(offline: app.emulated);
  _info();
}

Future<void> _defaults() async {
  step('defaults: what the app runs on before any fetch');

  // Compiled-in values, so the first launch on a device with no network
  // behaves rather than waiting. Everything a fetch can change should have one.
  await setConfigDefaults({
    'poll_interval_s': 30,
    'backend': 'https://api.example.com',
    'feature_x': false,
    'sample_rate': 0.25,
  });

  final values = await configValues();
  for (final e in values.entries) {
    note(
      '${e.key.padRight(16)} ${e.value.runtimeType.toString().padRight(8)} '
      '${e.value}   from ${configValueSource(e.key).name}',
    );
  }

  // A key nothing has set is not an error: it answers the type's zero, and
  // says its source is static so a caller can tell that from a real value.
  note(
    'a key never set: ${values['never_set']} '
    '(source ${configValueSource('never_set').name})',
  );
}

Future<void> _settings() async {
  step('settings: how long a fetch may take, and how often one may happen');

  final before = configSettings();
  note('fetch timeout   ${before.fetchTimeout}');
  note('minimum interval ${before.minimumFetchInterval}');

  // The minimum interval is the throttle: a fetch inside it is answered from
  // the last one rather than going out. Shortening it is a development
  // convenience — in production it is what keeps a fleet from fetching in
  // lockstep after a restart.
  await setConfigSettings(
    const RemoteConfigSettings(
      fetchTimeout: Duration(seconds: 30),
      minimumFetchInterval: Duration(minutes: 5),
    ),
  );
  final after = configSettings();
  note('now ${after.fetchTimeout} / ${after.minimumFetchInterval}');
}

Future<void> _fetch({required bool offline}) async {
  step('fetch and activate, which are two steps on purpose');

  if (offline) {
    note(
      'running against the emulator suite, which has no Remote Config: '
      'skipping the fetch',
    );
    note(
      'fetchConfig() downloads; activateConfig() makes what was downloaded '
      'the values the app reads',
    );
    note(
      'a value therefore never changes underneath a running screen — it '
      'changes when the app says so',
    );
    return;
  }

  try {
    // Duration.zero fetches unconditionally, ignoring the minimum interval.
    // That is a different thing from the default and not something to ship.
    await fetchConfig(cacheExpiration: Duration.zero);
    note('fetched');

    // Activation is separate so a fetch cannot change values mid-frame. It
    // answers whether anything actually changed.
    final changed = await activateConfig();
    note(
      changed
          ? 'activated: the fetched values are now live'
          : 'activated: nothing had changed since the last activation',
    );

    final values = await configValues();
    final remote = values.keys
        .where((k) => configValueSource(k) == RemoteConfigValueSource.remote)
        .toList();
    note(
      remote.isEmpty
          ? 'no key came from the backend — nothing is published for this app'
          : 'from the backend: ${remote.join(', ')}',
    );
    for (final k in remote) {
      note('  ${k.padRight(16)} ${values[k]}');
    }

    // The one-call version, for a screen that wants both without caring about
    // the distinction.
    note(
      'fetchAndActivate() did ${await fetchAndActivateConfig() ? '' : 'not '}'
      'change anything',
    );
  } on RemoteConfigException catch (e) {
    note('fetch failed: code ${e.code}, ${e.message}');
    note(
      'the app keeps running on its defaults, which is the point of having '
      'them',
    );
  }
}

void _info() {
  step('what the SDK knows about the last fetch');

  final info = configInfo();
  note('status         ${info.lastFetchStatus.name}');
  final fetched = info.lastFetchTime.millisecondsSinceEpoch == 0
      ? '<never>'
      : '${info.lastFetchTime}';
  note('last fetch     $fetched');
  // Zero means the SDK has never throttled a fetch, not 1970.
  final throttled = info.throttledEndTime.millisecondsSinceEpoch == 0
      ? '<not throttled>'
      : '${info.throttledEndTime}';
  note('throttled until $throttled');

  // noFetchYet is this binding's addition. The SDK reports success with a zero
  // fetch time before anything has been fetched, which reads as a fetch that
  // worked — so a caller that has to decide whether its values are stale
  // cannot use it.
  if (info.lastFetchStatus == RemoteConfigFetchStatus.noFetchYet) {
    note('nothing has been fetched: every value above is a default');
  }
}
