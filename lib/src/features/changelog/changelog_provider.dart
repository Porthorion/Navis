import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path_provider/path_provider.dart';

const _fileName = 'changelog_seen_version.txt';

/// Reads the last-seen changelog version from disk.
Future<String?> _readLastSeenVersion() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_fileName');
    if (file.existsSync()) {
      return file.readAsStringSync().trim();
    }
  } on Exception {
    // Silently ignore - treat as never-seen.
  }
  return null;
}

/// Writes the last-seen changelog version to disk.
Future<void> _writeLastSeenVersion(String version) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_fileName');
    file.writeAsStringSync(version);
  } on Exception {
    // Best-effort — ignore write errors.
  }
}

/// Provider that returns the [ChangelogVersion] to show, or `null` if the
/// user has already seen the current version's changelog.
///
/// This is an auto-dispose `FutureProvider` so it only runs once per app
/// session.
final changelogToShowProvider = FutureProvider.autoDispose<ChangelogVersion?>(
  (ref) async {
    if (changelogs.isEmpty) return null;

    final packageInfo = await ref.watch(packageInfoProvider.future);
    final currentVersion = packageInfo.version; // e.g. '0.2.8'

    final lastSeen = await _readLastSeenVersion();
    if (lastSeen == currentVersion) return null;

    // Find changelog matching the current app version.
    final match = changelogs.cast<ChangelogVersion?>().firstWhere(
      (c) => c?.version == currentVersion,
      orElse: () => null,
    );

    return match;
  },
);

/// Mark the given version's changelog as seen. After calling this the
/// [changelogToShowProvider] will return `null` for this version.
Future<void> markChangelogSeen(String version) async {
  await _writeLastSeenVersion(version);
}
