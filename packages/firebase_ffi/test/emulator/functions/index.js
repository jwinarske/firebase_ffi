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
