// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Finding google-services.json, in and out of a sandbox. The dialog itself is
// file_dialog.dart's.

import 'dart:io';

import 'package:firebase_ffi/google_services.dart';
import 'package:xdg_desktop_portal/xdg_desktop_portal.dart';

import 'file_dialog.dart';

/// Running inside a flatpak.
final bool inFlatpak = File('/.flatpak-info').existsSync();

/// The user's config directory: `$XDG_CONFIG_HOME`, else `~/.config`. In a
/// flatpak it is the app's own, `~/.var/app/<id>/config`.
String? get _configHome {
  final env = Platform.environment;
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  final home = env['HOME'];
  return home == null || home.isEmpty ? null : '$home/.config';
}

/// Where the config is looked for when nothing names it, in order:
/// `$GOOGLE_SERVICES_JSON`, the working directory, then the config directory.
/// The first file that exists wins. When none does, the working directory's,
/// so the field shows the name to drop a file under.
String defaultConfigPath() {
  final named = Platform.environment[GoogleServicesConfig.envVar];
  if (named != null && named.isNotEmpty) return named;
  const name = GoogleServicesConfig.defaultFileName;
  if (File(name).existsSync()) return name;
  final home = _configHome;
  if (home != null && File('$home/$name').existsSync()) return '$home/$name';
  return name;
}

/// [path] with a leading `~` as `$HOME`. Typed paths start that way, and
/// nothing between the field and the file system expands it.
String expandHome(String path) {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return path;
  if (path == '~') return home;
  if (path.startsWith('~/')) return '$home${path.substring(1)}';
  return path;
}

/// A config file that is not there. In a flatpak the likely reason is that
/// the sandbox cannot see it, which the bare error does not say, so the
/// message says so and what to do.
class ConfigFileMissing implements Exception {
  ConfigFileMissing(this.path);

  final String path;

  @override
  String toString() {
    if (!inFlatpak) return 'No such file: $path';
    final home = _configHome ?? '~/.var/app/<id>/config';
    return 'No such file in the sandbox: $path\n'
        'This app sees only its own directory. Pick the file with Browse, or '
        'copy it to $home/${GoogleServicesConfig.defaultFileName}.';
  }
}

/// Asks the desktop's file dialog for a JSON file. Null when the user cancels.
Future<String?> pickConfigFile() => pickFileToOpen(
  title: 'Open google-services.json',
  filters: [
    XdgFileChooserFilter('JSON', [XdgFileChooserGlobPattern('*.json')]),
  ],
);
