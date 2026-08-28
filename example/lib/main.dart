// Runs the transport benchmark inside a real bundle on the target, so the
// numbers come from the deployment that would ship rather than from a host.
//
// Results go to stdout, which the embedder's log carries — a board is usually
// read over ssh, not looked at.

import 'dart:io';

import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/google_services.dart';
import 'package:firebase_ffi/firebase_ffi.dart';
import 'package:flutter/material.dart';


void main() {
  runApp(const BenchApp());
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  List<String> _lines = const ['running…'];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final lines = await runBenchmarks();
      lines.addAll(await _exerciseDatabase());
      for (final l in lines) {
        // ignore: avoid_print
        print('BENCH $l');
      }
      if (mounted) setState(() => _lines = lines);
    } catch (e, st) {
      // ignore: avoid_print
      print('BENCH failed: $e\n$st');
      if (mounted) setState(() => _lines = ['failed: $e']);
    }
  }

  /// The v2 slice: authenticate, then a real set() and onValue() against a
  /// project we control.
  ///
  /// Sign-in comes first and is awaited. The database rules require an
  /// authenticated caller, and a listener opened before sign-in completes gets
  /// cancelled with "permission denied" rather than waiting — so the order
  /// here is load-bearing, not stylistic.
  Future<List<String>> _exerciseDatabase() async {
    if (!hasFirebase) {
      return ['db: build has no Firebase SDK — transport only'];
    }
    final out = <String>[];
    try {
      // Pointed at the console-generated file at launch: set
      // GOOGLE_SERVICES_JSON, or drop google-services.json in the bundle root.
      final cfg = GoogleServicesConfig.load();
      initDatabase(
        appId: cfg.appId,
        apiKey: cfg.apiKey,
        projectId: cfg.projectId,
        databaseUrl: cfg.databaseUrl,
      );
      out.add('db: app initialized from ${GoogleServicesConfig.resolvePath()} '
          '(${cfg.projectId})');

      initAuth();

      // A custom token, if one was staged, otherwise anonymous. The point of
      // the custom-token path on a device is that identity comes from a
      // credential the unit is given rather than from a cached blob, so the uid
      // is stable across boots with no secret store involved.
      final tokenFile = File(
        Platform.environment['FDB_CUSTOM_TOKEN'] ?? 'custom-token.jwt',
      );
      // Precedence: a provisioned token, then a restored session, then a new
      // anonymous user.
      //
      // The token comes first because it is an explicit statement of who this
      // unit is; letting a cached session win would mean a device that was ever
      // anonymous could never be given its real identity. A restored session is
      // still the fallback, so an expired token degrades to the last known
      // identity rather than silently minting a fresh one.
      final restored = await restoredUid();
      AuthOutcome who;
      if (tokenFile.existsSync()) {
        try {
          who = await signInWithCustomToken(tokenFile.readAsStringSync().trim());
          out.add('auth: signed in via custom token as ${who.uid}');
        } on AuthException catch (e) {
          if (restored == null) rethrow;
          out.add('auth: custom token rejected (${e.code}); '
              'falling back to restored session $restored');
          who = AuthOutcome(uid: restored);
        }
      } else if (restored != null) {
        who = AuthOutcome(uid: restored);
        out.add('auth: restored persisted session as $restored');
      } else {
        who = await signInAnonymously();
        out.add('auth: signed in anonymously as ${who.uid}');
      }

      const path = '/fdb_nc_probe/value';
      final stamp = DateTime.now().toUtc().toIso8601String();

      final seen = <Object?>[];
      final sub = onValue(path).listen(
        (snap) {
          final latencyUs = (nowNs() - snap.postedNs) / 1000;
          out.add('db: snapshot seq=${snap.seq} value=${snap.value} '
              'delivered in ${latencyUs.toStringAsFixed(1)}us');
          seen.add(snap.value);
        },
        onError: (Object e) => out.add('db: stream error $e'),
      );

      await Future<void>.delayed(const Duration(seconds: 3));
      setString(path, stamp);
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      out.add(seen.contains(stamp)
          ? 'db: ROUND TRIP OK — wrote and read back "$stamp"'
          : 'db: no echo of the write (saw ${seen.length} snapshots)');
    } catch (e) {
      out.add('db: failed $e');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Text(
              _lines.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      );
}
