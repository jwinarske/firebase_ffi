// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The bootstrap every program beside this file shares.
///
/// All of them need the same three things before they can do anything
/// interesting: a project to talk to, a `firebase::App` built from it, and a
/// caller the rules will accept. Doing that once here keeps each example about
/// its own product rather than about configuration.
///
/// Where the project comes from:
///
/// * `FIREBASE_EMULATOR_HOST` set — the emulator suite, with each product
///   pointed at its port. This is how the examples run with no Firebase
///   project and no credentials at all:
///
///   ```
///   cd packages/firebase_ffi
///   firebase emulators:exec --project fdb-emulator \
///     --only auth,database,firestore,storage,functions \
///     'FIREBASE_EMULATOR_HOST=127.0.0.1 dart run example/database.dart'
///   ```
///
/// * otherwise — `google-services.json`, from `GOOGLE_SERVICES_JSON` or the
///   working directory. That is a real project, and the writes these programs
///   make are real writes.
library;

import 'dart:async';
import 'dart:io';

import 'package:firebase_ffi/app_check.dart';
import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:firebase_ffi/functions.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_ffi/remote_config.dart';
import 'package:firebase_ffi/storage.dart';

/// A product an example wants initialized. Auth and Database always are: the
/// app itself is built by [initDatabase], and the rules want a caller.
enum Product { firestore, storage, functions, remoteConfig, appCheck }

/// What [start] built, for a program that wants to report where it ran.
class ExampleApp {
  ExampleApp._(this.config, this.emulatorHost, this.uid);

  /// The project's values, whether from `google-services.json` or synthesized
  /// for the emulator.
  final GoogleServicesConfig config;

  /// Null when this is a real project rather than the emulator suite.
  final String? emulatorHost;

  /// The signed-in user, or null when [start] was asked not to sign in.
  final String? uid;

  bool get emulated => emulatorHost != null;

  /// A path prefix nothing else is using, so two runs at once do not collide
  /// and a failed run leaves its own debris rather than someone else's.
  final String run = 'x${DateTime.now().microsecondsSinceEpoch}';
}

/// Initializes the app, signs in, and initializes [use].
///
/// Exits with a diagnosis rather than a stack trace when the build has no
/// Firebase SDK or there is no project to reach: those are setup problems, and
/// a stack trace through the FFI layer says nothing about either.
Future<ExampleApp> start({
  Set<Product> use = const {},
  bool signIn = true,
}) async {
  if (!hasFirebase) {
    bail(
      'this build has no Firebase SDK.\n'
      'Point hooks.user_defines.firebase_ffi.firebase_sdk in example/'
      'pubspec.yaml at an install prefix — see the README beside it.',
    );
  }

  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  final emulated = host.isNotEmpty;
  final config = emulated ? _emulatorConfig(host) : _projectConfig();

  initDatabase(
    appId: config.appId,
    apiKey: config.apiKey,
    projectId: config.projectId,
    databaseUrl: config.databaseUrl,
    // Storage takes its bucket from the app options and has no per-call
    // override, so an app that omits it builds URLs with no bucket in them.
    storageBucket: config.storageBucket,
  );
  initAuth();
  if (emulated) useAuthEmulator(host, _port('AUTH', 9099));

  String? uid;
  if (signIn) {
    // Anonymous because it needs nothing provisioned. A device would use
    // signInWithCustomToken instead; example/auth.dart shows both.
    uid = (await signInAnonymously()).uid;
  }

  for (final p in use) {
    switch (p) {
      case Product.firestore:
        _require(hasFirestore, 'firestore');
        initFirestore();
        if (emulated) useFirestoreEmulator(host, _port('FIRESTORE', 8080));
      case Product.storage:
        _require(hasStorage, 'storage');
        initStorage();
        if (emulated) useStorageEmulator(host, _port('STORAGE', 9199));
      case Product.functions:
        _require(hasFunctions, 'functions');
        initFunctions();
        if (emulated) {
          useFunctionsEmulator('http://$host:${_port('FUNCTIONS', 5001)}');
        }
      case Product.remoteConfig:
        _require(hasRemoteConfig, 'remote_config');
        await initRemoteConfig();
      case Product.appCheck:
        _require(hasAppCheck, 'app_check');
      // initAppCheck is deliberately left to the example: which provider is
      // installed has to be decided before the first token is minted.
    }
  }

  final app = ExampleApp._(config, emulated ? host : null, uid);
  print(
    'project ${config.projectId}'
    '${emulated ? " (emulator at $host)" : ""}'
    '${uid == null ? "" : ", signed in as $uid"}',
  );
  return app;
}

/// A heading, so a long transcript can be read by section.
void step(String title) => print('\n── $title');

/// One line of a section's output.
void note(String line) => print('   $line');

/// Prints [message] and stops. Used for setup that cannot be recovered from,
/// where a stack trace would be noise.
Never bail(String message) {
  stderr.writeln('$message\n');
  exit(2);
}

/// Waits for [ready] rather than sleeping a guessed interval.
///
/// Every example that watches something needs this: a listener's first event
/// arrives when the backend sends it, not on a schedule.
Future<void> until(
  bool Function() ready,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void _require(bool bound, String product) {
  if (!bound) {
    bail(
      'this build did not bind $product.\n'
      'Add it to hooks.user_defines.firebase_ffi.products in '
      'example/pubspec.yaml and build again.',
    );
  }
}

int _port(String product, int fallback) =>
    int.tryParse(
      Platform.environment['FIREBASE_${product}_EMULATOR_PORT'] ?? '',
    ) ??
    fallback;

/// The emulator suite needs no real values: it checks the project id and
/// ignores the key. The database URL carries the namespace, which is how the
/// emulator is told which database is meant.
GoogleServicesConfig _emulatorConfig(String host) {
  final projectId =
      Platform.environment['FIREBASE_EMULATOR_PROJECT'] ?? 'fdb-emulator';
  return GoogleServicesConfig(
    appId: '1:1:android:1',
    apiKey: 'emulator-does-not-check-this',
    projectId: projectId,
    databaseUrl: 'http://$host:${_port('DATABASE', 9000)}/?ns=$projectId',
    storageBucket: '$projectId.appspot.com',
    messagingSenderId: '1',
  );
}

GoogleServicesConfig _projectConfig() {
  try {
    return GoogleServicesConfig.load();
  } on FileSystemException {
    bail(
      'no ${GoogleServicesConfig.defaultFileName} at '
      '${GoogleServicesConfig.resolvePath()}.\n'
      'Download it from the Firebase console and put it in the working '
      'directory, or set ${GoogleServicesConfig.envVar} to its path.\n'
      'To run against the emulator suite instead, set '
      'FIREBASE_EMULATOR_HOST — see the README beside this file.',
    );
  }
}
