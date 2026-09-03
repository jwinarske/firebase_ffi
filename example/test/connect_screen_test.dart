// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The one screen that can be tested without a backend: everything past it
// needs an initialized Firebase app, and initializing one means reaching the
// C++ SDK.
//
// It is still worth a test. The connect screen is what decides whether the app
// talks to a real project or to the emulator suite, and a build where it does
// not render is a build nobody can use.

import 'package:firebase_ffi_demo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the connect screen offers a project or the emulator', (
    tester,
  ) async {
    await tester.pumpWidget(const DemoApp());

    expect(find.text('Firebase workbench'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    // The default is a project file, so the path field is the one showing and
    // the emulator host is not.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Emulator host'), findsNothing);

    // Switching swaps the one field for the other, rather than asking for both.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Emulator host'), findsOneWidget);
  });
}
