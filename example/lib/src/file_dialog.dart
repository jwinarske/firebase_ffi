// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The desktop's file dialog, through the FileChooser portal.
//
// A board has paths and nothing else, so every path field stays. A desktop
// has a dialog, and in a flatpak it is the only way to a file outside the
// app's own directory: the portal hands the app the one file picked, or the
// one place chosen to save to, through the document portal, and grants
// nothing else. Pure Dart over D-Bus, so it needs no embedder plugin.

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xdg_desktop_portal/xdg_desktop_portal.dart';

/// Whether the desktop answered the probe for a file dialog. Set once, by the
/// connect screen, and read by every page that offers Browse.
final ValueNotifier<bool> fileDialogAvailable = ValueNotifier(false);

/// True when a FileChooser portal answers on the session bus. False on a
/// board with no session bus, and on a desktop without xdg-desktop-portal.
Future<bool> hasFileChooser() async {
  DBusClient? bus;
  try {
    bus = DBusClient.session();
    return await bus
        .nameHasOwner('org.freedesktop.portal.Desktop')
        .timeout(const Duration(seconds: 2));
  } on Object {
    return false;
  } finally {
    unawaited(bus?.close());
  }
}

/// Whether a file written at [path] ends up where the user can find it. Out of
/// a flatpak, always. In one, only under the app's own directory or a path the
/// file dialog handed over: anywhere else the write succeeds into the
/// sandbox's private copy of that directory and is gone when the app quits.
bool reachesHost(String path, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final id = env['FLATPAK_ID'];
  if (id == null || id.isEmpty) return true;
  final home = env['HOME'] ?? '';
  final runtime = env['XDG_RUNTIME_DIR'] ?? '';
  // Normalized, or `~/.var/app/<id>/../../x` would pass for the app's
  // directory and land in the sandbox's copy of the home directory.
  final abs = Uri.file(File(path).absolute.path).normalizePath().toFilePath();
  return (home.isNotEmpty && abs.startsWith('$home/.var/app/$id/')) ||
      (runtime.isNotEmpty && abs.startsWith('$runtime/doc/'));
}

/// A file to read, from the desktop's dialog. The path it answers is readable
/// from inside the sandbox; in a flatpak it is under `/run/user/<uid>/doc/`.
/// Null when the user cancels.
Future<String?> pickFileToOpen({
  required String title,
  Iterable<XdgFileChooserFilter> filters = const [],
}) => _ask(
  (portal) => portal
      .openFile(
        title: title,
        acceptLabel: 'Open',
        modal: true,
        filters: filters,
      )
      .map((r) => r.uris),
);

/// A file to write, from the desktop's save dialog, offering [name]. In a
/// flatpak the path it answers is writable from inside the sandbox, and the
/// bytes land where the user chose. Null when the user cancels.
Future<String?> pickFileToSave({required String title, String? name}) => _ask(
  (portal) => portal
      .saveFile(
        title: title,
        acceptLabel: 'Save',
        modal: true,
        currentName: name,
      )
      .map((r) => r.uris),
);

Future<String?> _ask(
  Stream<List<String>> Function(XdgFileChooserPortal) request,
) async {
  final client = XdgDesktopPortalClient();
  try {
    final uris = await request(client.fileChooser).first;
    if (uris.isEmpty) return null;
    return Uri.parse(uris.first).toFilePath();
  } on XdgPortalRequestCancelledException {
    return null;
  } finally {
    await client.close();
  }
}
