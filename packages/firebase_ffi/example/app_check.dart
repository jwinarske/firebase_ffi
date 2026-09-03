// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The App Check binding, end to end.
//
//   dart run example/app_check.dart
//
// App Check answers "is this request coming from my app?". The attestation
// providers Firebase ships are for phones and browsers — there is no Play
// Integrity on a Linux board — so desktop has two options, and this program
// runs both:
//
//   * the debug provider, for development: a token registered by hand in the
//     console, which the backend then trusts.
//   * a custom provider, for a fleet: the device supplies a token it obtained
//     however it can attest itself, which is the only honest answer on
//     hardware whose integrity nothing else can vouch for.

import 'dart:io';

import 'package:firebase_ffi/app_check.dart';

import 'setup.dart';

Future<void> main() async {
  await start(use: {Product.appCheck});

  await _customProvider();
  _debugProvider();

  // A custom provider's port stays open for the life of the isolate: the SDK
  // may ask for a token at any moment, and there is no call that withdraws the
  // provider. Nothing else keeps this program alive, so it says when it is
  // done rather than sitting at a prompt that never returns.
  exit(0);
}

Future<void> _customProvider() async {
  step('a custom provider: the device supplies its own token');

  var minted = 0;
  DateTime expiry() => DateTime.now().add(const Duration(hours: 1));

  // The callback runs whenever the SDK needs a token — on first use, on
  // refresh, and for every limited-use token. It is asynchronous because a
  // real one would ask a TPM, a secure element or a provisioning service.
  useCustomAppCheckProvider(() async {
    minted++;
    return AppCheckToken('device-token-$minted', expiry());
  });

  // The provider has to be installed before this: initAppCheck is when the SDK
  // takes it, and one installed afterwards has missed the requests already in
  // flight. Nothing is minted yet — the first token is made when something
  // first asks for one, which the counter below shows.
  initAppCheck();
  note('initialized with a custom provider');

  final first = await appCheckToken();
  note('token   ${first.token}');
  note('expires ${first.expiresAt}');

  // Served from the cache: the callback is not asked again while the token is
  // still good.
  final cached = await appCheckToken();
  note('a second read returned ${cached.token} after $minted mint(s)');

  final forced = await appCheckToken(forceRefresh: true);
  note('forceRefresh minted ${forced.token}');

  // A limited-use token is for a single call to a backend that redeems it, so
  // it is never served from the cache — that is the whole distinction.
  final before = minted;
  final once = await limitedUseAppCheckToken();
  note(
    'limited-use token ${once.token} '
    '(minted ${minted - before} more, never cached)',
  );

  // The stream is how an app follows refreshes it did not ask for, which is
  // what auto-refresh produces.
  final seen = <String>[];
  final sub = appCheckTokenChanges().listen((t) => seen.add(t.token));
  await appCheckToken(forceRefresh: true);
  await until(() => seen.isNotEmpty, 'a token change event');
  await sub.cancel();
  note('the change stream saw ${seen.join(', ')}');

  // Auto-refresh keeps a token valid without the app asking. Off is the right
  // default for a device that is usually idle: it stops a background refresh
  // waking a radio for a token nothing is going to use.
  setAppCheckAutoRefresh(false);
  note('auto refresh disabled');
}

void _debugProvider() {
  step('the debug provider, for development');

  // Installing it here would replace the custom provider, and the token it
  // produces is only accepted once it has been registered in the console —
  // App Check > Apps > Manage debug tokens. So this is shown rather than run:
  //
  //   useDebugAppCheckProvider();                  // the SDK prints a token
  //   useDebugAppCheckProvider(debugToken: '...'); // or supply a known one
  //   initAppCheck();
  //
  // Passing a token that was registered once is what makes CI repeatable: the
  // generated one changes per run and would have to be registered again.
  note('useDebugAppCheckProvider() prints a token to register in the console');
  note(
    'useDebugAppCheckProvider(debugToken: ...) reuses one already '
    'registered, which is what CI wants',
  );
  note(
    'a debug token is a bearer credential for your project: it does not '
    'belong in a repository',
  );
}
