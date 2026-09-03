// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Authentication, end to end.
//
//   dart run example/auth.dart
//
// Anonymous and custom-token sign-in, the ID token an app hands to a REST
// endpoint, session restore across runs, and what a rejected credential looks
// like.
//
// Auth is the product every other example depends on: rules want a caller, and
// one firebase::App means signing in here is what lets Database, Firestore and
// Storage read anything in the programs beside this one.

import 'dart:convert';
import 'dart:io';

import 'package:firebase_ffi/auth.dart';

import 'setup.dart';

Future<void> main() async {
  // signIn: false — this program is about signing in, so it does it itself.
  await start(signIn: false);

  step('who is signed in before anything happens');
  // Not necessarily nobody: the desktop SDK persists its session, so a machine
  // that has run this before starts with a user already here.
  note('currentUid() = ${currentUid() ?? '<nobody>'}');

  // ── A session the SDK restored from the last run ────────────────────────
  //
  // The desktop SDK persists the signed-in user. On a device that has run
  // before, the identity is already there and signing in again would mint a
  // second anonymous user and strand the first one's data.
  step('a session left by an earlier run');
  final restored = await restoredUid(timeout: const Duration(seconds: 2));
  note(
    restored == null
        ? 'nothing restored — this is a first run, or the last one signed out'
        : 'restored $restored without a network call',
  );

  // ── Anonymous ───────────────────────────────────────────────────────────
  step('anonymous sign-in');
  final anon = await signInAnonymously();
  note('uid ${anon.uid}');
  note('currentUid() now ${currentUid()}');
  note(
    restored != null && restored == anon.uid
        ? 'the same uid: the restored session was reused'
        : 'a fresh throwaway identity, which rules cannot tell from any other',
  );

  // ── The ID token ────────────────────────────────────────────────────────
  //
  // What an app sends to a Firebase REST endpoint, or to its own backend for
  // verification. Asynchronous because an expired one is refreshed first.
  step('the ID token');
  // What an app sends to a Firebase REST endpoint, or to its own backend for
  // verification. Asynchronous because an expired one is refreshed first.
  //
  // It comes from the backend, so a backend that will not mint one says so
  // here rather than answering an empty string. The Auth emulator is one:
  // it refuses this call with an internal error, and the tour reports that
  // rather than stopping.
  try {
    final token = await idToken();
    note(
      '${token.length} characters, three dot-separated parts: '
      '${token.split('.').length}',
    );
    final forced = await idToken(forceRefresh: true);
    note(
      forced == token
          ? 'a forced refresh returned the same token (still fresh)'
          : 'a forced refresh minted a new one',
    );
    note('claims: ${_claims(token)}');
  } on AuthException catch (e) {
    note('idToken() failed: AuthException(${e.code}) ${e.message}');
  }

  // ── Custom token ────────────────────────────────────────────────────────
  //
  // The shape a fleet actually wants: a backend holding the Admin SDK decides
  // the device is what it claims to be and mints a token for a uid it chose,
  // so identity survives a reflash instead of being whatever the device
  // happened to cache.
  step('custom-token sign-in');
  final tokenFile = File(
    Platform.environment['FDB_CUSTOM_TOKEN'] ?? 'custom-token.jwt',
  );
  if (tokenFile.existsSync()) {
    final who = await signInWithCustomToken(
      tokenFile.readAsStringSync().trim(),
    );
    note('signed in as ${who.uid} from ${tokenFile.path}');
    note('the uid came from the token\'s claims, not from this device');
  } else {
    note('no ${tokenFile.path} — skipped');
    note(
      'mint one with the Admin SDK '
      '(auth.createCustomToken(uid)) and set FDB_CUSTOM_TOKEN to it',
    );
  }

  // ── A credential the backend refuses ────────────────────────────────────
  //
  // The failure is the interesting part: it arrives as AuthException with the
  // SDK's own code, not as a null user that reads as "not signed in yet".
  step('a token the backend refuses');
  try {
    await signInWithCustomToken('not.a.token');
    note('unexpectedly accepted');
  } on AuthException catch (e) {
    note('AuthException code ${e.code}: ${e.message}');
  }

  // ── Sign-out ────────────────────────────────────────────────────────────
  step('sign-out');
  signOut();
  note('currentUid() = ${currentUid()}');
  note(
    'the persisted session is gone too: the next run of this program '
    'restores nothing',
  );
}

/// The middle segment of a JWT, which is where a uid and expiry live.
///
/// Decoded rather than verified: this is a signed statement about the caller,
/// and reading it here only shows what was signed in. A backend receiving it
/// must verify the signature.
String _claims(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return '<not a JWT>';
  final body = parts[1].padRight((parts[1].length + 3) & ~3, '=');
  final json = String.fromCharCodes(base64Url.decode(body));
  // Only the fields worth showing; the rest is provider bookkeeping.
  final wanted = RegExp(r'"(user_id|sub|exp|provider_id|firebase)"\s*:');
  return json.split(',').where((f) => wanted.hasMatch(f)).take(3).join(', ');
}
