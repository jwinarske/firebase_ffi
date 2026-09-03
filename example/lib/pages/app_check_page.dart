// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_app_check_ffi/firebase_app_check_ffi.dart';
import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/widgets.dart';

/// App Check with a provider the device supplies itself.
///
/// The attestation providers Firebase ships are for phones and browsers —
/// there is no Play Integrity on a Linux board — so the honest answer on this
/// hardware is a token the device obtained however it can attest itself, and a
/// custom provider is how that is handed to the SDK.
class AppCheckPage extends StatefulWidget {
  const AppCheckPage({super.key});

  @override
  State<AppCheckPage> createState() => _AppCheckPageState();
}

class _AppCheckPageState extends State<AppCheckPage> {
  final _token = TextEditingController(text: 'device-token');
  bool _activated = false;
  bool _autoRefresh = false;
  int _minted = 0;
  String? _last;
  DateTime? _expires;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  FirebaseAppCheck get _appCheck => FirebaseAppCheck.instance;

  @override
  Widget build(BuildContext context) => Section(
    title: 'App Check',
    subtitle: 'A token that says a request came from this app.',
    children: [
      Panel(
        title: 'Provider',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The callback below runs whenever the SDK needs a token — first '
              'use, refresh, and every limited-use token. A real one would ask '
              'a TPM, a secure element or a provisioning service; this one '
              'hands back what is in the box, with a counter so you can see '
              'when it was asked.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            LineField(controller: _token, label: 'Token this device supplies'),
            const SizedBox(height: 12),
            ButtonRow([
              RunButton(
                label: _activated ? 'Activated' : 'Activate',
                icon: Icons.verified_user_outlined,
                filled: true,
                action: () async {
                  if (_activated) {
                    appLog.write('already activated for this process');
                    return;
                  }
                  FirebaseAppCheckFfi.useCustomProvider(() async {
                    _minted++;
                    return AppCheckTokenResult(
                      token: '${_token.text.trim()}-$_minted',
                      expirationTime: DateTime.now().add(
                        const Duration(hours: 1),
                      ),
                    );
                  });
                  // Registered before activate(), which is what makes it
                  // stick: activate()'s providerWindows argument defaults to
                  // the desktop SDK's debug provider, and a provider chosen
                  // here wins over that default rather than being overwritten
                  // by it.
                  await _appCheck.activate();
                  setState(() => _activated = true);
                  appLog.write('App Check activated with a custom provider');
                },
              ),
            ]),
          ],
        ),
      ),
      Panel(
        title: 'Tokens',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ButtonRow([
              RunButton(
                label: 'Get token',
                icon: Icons.badge_outlined,
                action: () async {
                  final r = (await _appCheck.getTokenResult(false))!;
                  setState(() {
                    _last = r.token;
                    _expires = r.expirationTime;
                  });
                  appLog.write('token ${r.token}, expires ${r.expirationTime}');
                },
              ),
              RunButton(
                label: 'Force refresh',
                icon: Icons.refresh,
                action: () async {
                  final r = (await _appCheck.getTokenResult(true))!;
                  setState(() {
                    _last = r.token;
                    _expires = r.expirationTime;
                  });
                  appLog.write('refreshed to ${r.token}');
                },
              ),
              RunButton(
                // Minted for one call to a backend that redeems it, so it is
                // never served from the cache. That is the whole distinction.
                label: 'Limited-use token',
                icon: Icons.confirmation_number_outlined,
                action: () async {
                  final token = await _appCheck.getLimitedUseToken();
                  setState(() => _last = token);
                  appLog.write('limited-use token $token');
                },
              ),
            ]),
            const SizedBox(height: 16),
            Rows({
              'provider asked': '$_minted time(s)',
              'last token': _last ?? '<none yet>',
              'expires': _expires == null ? '<none yet>' : '$_expires',
            }),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoRefresh,
              title: const Text('Refresh the token in the background'),
              subtitle: const Text(
                'Off suits a device that is usually idle: a background refresh '
                'wakes a radio for a token nothing is going to use.',
              ),
              onChanged: !_activated
                  ? null
                  : (v) async {
                      setState(() => _autoRefresh = v);
                      try {
                        await _appCheck.setTokenAutoRefreshEnabled(v);
                        appLog.write('auto refresh ${v ? 'on' : 'off'}');
                      } on Object catch (e) {
                        appLog.fail(e);
                      }
                    },
            ),
          ],
        ),
      ),
      Panel(
        title: 'What this is for',
        child: Text(
          'Once App Check is on, a token rides along with every Firestore, '
          'Database, Storage and Functions request. Enforcement is switched on '
          'per product in the console — until it is, an unattested request '
          'still succeeds, so turning this on here changes nothing you can see '
          'until it is turned on there.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}
