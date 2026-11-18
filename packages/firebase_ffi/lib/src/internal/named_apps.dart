// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// What to run when a named app is deleted, by whoever holds something for it
/// on this side. Called with the app's name, before the native app goes.
///
/// A product library adds to this rather than being imported by the one that
/// deletes apps, so an app that uses only the Database does not pull Auth in.
final namedAppDeleted = <void Function(String name)>[];
