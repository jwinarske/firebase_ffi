// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Mints a Firebase custom token for a device uid.
//
// This runs where the service-account key lives — a build host or a
// provisioning service — never on the device. The device receives only the
// resulting token, which is a one-hour bearer credential for exactly one uid;
// the signing key stays behind.
//
// A custom token is an RS256 JWT signed by a service account, with Google's
// identity toolkit as the audience. Signing shells out to openssl rather than
// pulling in a JWT package, so this stays dependency-free.
//
// Usage:
//   dart tool/mint_custom_token.dart <service-account.json> <uid> [out.jwt]

import 'dart:convert';
import 'dart:io';

const _audience =
    'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.'
    'v1.IdentityToolkit';

/// Custom tokens are rejected beyond an hour; Google's own SDKs use exactly
/// this, so a device has to re-acquire rather than hold one indefinitely.
const _lifetime = Duration(hours: 1);

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Future<int> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'usage: dart tool/mint_custom_token.dart '
      '<service-account.json> <uid> [out.jwt]',
    );
    return 64;
  }
  final keyPath = args[0];
  final uid = args[1];
  final outPath = args.length == 3 ? args[2] : null;

  if (uid.isEmpty || uid.length > 128) {
    stderr.writeln('uid must be 1..128 characters');
    return 64;
  }

  final sa = json.decode(File(keyPath).readAsStringSync());
  if (sa is! Map<String, Object?>) {
    stderr.writeln('$keyPath: expected a service-account JSON object');
    return 65;
  }
  final email = sa['client_email'];
  final privateKey = sa['private_key'];
  if (email is! String || privateKey is! String) {
    stderr.writeln(
      '$keyPath: missing client_email/private_key — this needs a service '
      'account key, not google-services.json',
    );
    return 65;
  }

  final now = DateTime.now().toUtc();
  final iat = now.millisecondsSinceEpoch ~/ 1000;
  final claims = <String, Object?>{
    'iss': email,
    'sub': email,
    'aud': _audience,
    'iat': iat,
    'exp': iat + _lifetime.inSeconds,
    'uid': uid,
  };

  final signingInput = '${_b64url(utf8.encode(json.encode(
    <String, Object?>{'alg': 'RS256', 'typ': 'JWT'},
  )))}.${_b64url(utf8.encode(json.encode(claims)))}';

  // The key is written to a private temp file rather than passed as an
  // argument, so it never appears in the process table.
  final tmp = await Directory.systemTemp.createTemp('fdb_mint_');
  final keyFile = File('${tmp.path}/key.pem');
  try {
    keyFile.writeAsStringSync(privateKey);
    await Process.run('chmod', ['600', keyFile.path]);

    final proc = await Process.start(
      'openssl',
      ['dgst', '-sha256', '-sign', keyFile.path],
    );
    proc.stdin.add(utf8.encode(signingInput));
    await proc.stdin.close();
    final sig = await proc.stdout
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    final err = await proc.stderr.transform(utf8.decoder).join();
    if (await proc.exitCode != 0) {
      stderr.writeln('openssl failed: $err');
      return 70;
    }

    final token = '$signingInput.${_b64url(sig)}';
    if (outPath == null) {
      stdout.writeln(token);
    } else {
      File(outPath).writeAsStringSync(token);
      await Process.run('chmod', ['600', outPath]);
      stderr.writeln(
        'wrote $outPath for uid "$uid", valid until '
        '${now.add(_lifetime).toIso8601String()}',
      );
    }
    return 0;
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
