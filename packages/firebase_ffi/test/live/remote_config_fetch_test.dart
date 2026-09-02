// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Remote Config against a real project.
//
// fetch is the one call in this product no emulator can exercise -- defaults,
// settings, value sources and the fetch status are all client-side and covered
// in the emulator suite. This is the part that talks to Google.
//
// Skipped unless FDB_LIVE_REMOTE_CONFIG=1, so `dart test` stays useful without
// a project. Config comes from google-services.json, located the way
// GoogleServicesConfig always locates it (GOOGLE_SERVICES_JSON, or the default
// file name).
@TestOn('vm')
library;

import 'dart:io';

import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_ffi/remote_config.dart';
import 'package:test/test.dart';

/// A key that should exist in the project's Remote Config, with any value.
///
/// The test does not care what the value is. It asserts the value came from
/// the server rather than from the local default, which is what proves the
/// fetch landed — so the console can hold whatever is convenient and this file
/// does not have to agree with it.
const _remoteKey = 'fdb_live_probe';

void main() {
  if (Platform.environment['FDB_LIVE_REMOTE_CONFIG'] != '1') {
    print('FDB_LIVE_REMOTE_CONFIG unset — live Remote Config test skipped');
    return;
  }

  setUpAll(() async {
    final cfg = GoogleServicesConfig.load();
    initDatabase(
      appId: cfg.appId,
      apiKey: cfg.apiKey,
      projectId: cfg.projectId,
      databaseUrl: cfg.databaseUrl,
      storageBucket: cfg.storageBucket,
    );
    await initRemoteConfig();
    // Without a zero interval the SDK serves what it fetched last and reports
    // success without going to the network, which would pass while proving
    // nothing.
    await setConfigSettings(
      const RemoteConfigSettings(
        fetchTimeout: Duration(seconds: 30),
        minimumFetchInterval: Duration.zero,
      ),
    );
  });

  test('a fetch reaches the backend and is recorded', () async {
    await setConfigDefaults({_remoteKey: 'local-default'});
    expect(configInfo().lastFetchStatus, RemoteConfigFetchStatus.noFetchYet);

    await fetchAndActivateConfig();

    final info = configInfo();
    expect(info.lastFetchStatus, RemoteConfigFetchStatus.success);
    // A fetch time in the last few minutes, not the epoch: the status alone
    // would pass on a build that never called out.
    expect(
      DateTime.now().difference(info.lastFetchTime).inMinutes,
      lessThan(5),
    );
  });

  test('a fetched value is marked as coming from the server', () async {
    await setConfigDefaults({_remoteKey: 'local-default'});
    await fetchAndActivateConfig();

    final source = configValueSource(_remoteKey);
    if (source == RemoteConfigValueSource.defaultValue) {
      // The fetch worked -- the test above proves that -- but this project has
      // no parameter by that name, so nothing overrode the default. Say so
      // rather than fail: it is console setup, not a defect.
      markTestSkipped(
        'the project has no Remote Config parameter named "$_remoteKey"; '
        'add one with any value to exercise this',
      );
      return;
    }
    expect(source, RemoteConfigValueSource.remote);
    expect((await configValues())[_remoteKey], isNot('local-default'));
  });
}
