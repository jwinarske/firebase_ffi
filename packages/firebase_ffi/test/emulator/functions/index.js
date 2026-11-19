// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0
//
// The callables the emulator serves for the binding tests. Deliberately tiny:
// these exist to prove the round trip and the error path, not to test Cloud
// Functions itself.
const {onCall, HttpsError} = require("firebase-functions/v2/https");

// Echoes what it was sent, so the test can assert the shape survived both ways.
exports.echo = onCall((request) => ({received: request.data}));

// Adds, so a numeric round trip is checked rather than just a string one.
exports.add = onCall((request) => request.data.a + request.data.b);

// Fails on purpose, so the error path carries a real code and message.
exports.boom = onCall(() => {
  throw new HttpsError("failed-precondition", "deliberate failure");
});

// Who the request came from, so a test can tell which app's user called.
exports.whoami = onCall((request) => request.auth?.uid ?? null);

// Answers after `ms`, so a test can have a call still running.
exports.slow = onCall(async (request) => {
  await new Promise((resolve) => setTimeout(resolve, request.data.ms));
  return "done";
});

// Reports the App Check token the request carried: the header as sent, and the
// app id the emulator read out of it. The emulator decodes the token without
// verifying it, so a test can mint its own.
exports.attested = onCall((request) => ({
  header: request.rawRequest.header("X-Firebase-AppCheck") ?? null,
  appId: request.app?.appId ?? null,
}));

// Deployed somewhere other than the default region, so a test can tell which
// region a call went to: the emulator serves this under europe-west1 only.
exports.where = onCall({region: "europe-west1"}, () => "europe-west1");
