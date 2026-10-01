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

/// What the Home "What's New" card shows after an update.
class ChangelogDiscovery {
  const new({required this.current, this.featured});

  /// The release matching the running app version.
  final ChangelogVersion current;

  /// The newest major release the user has not seen yet, up to and including
  /// [current]. A user who jumps from 1.3.1 to 1.4.1 still sees 1.4.
  final ChangelogVersion? featured;

  /// The version the Home card marks as seen: always [current].
  String get seenVersion => current.version;
}

List<int>? _semver(String? version) {
  if (version == null) return null;
  final parts = version.split('.');
  if (parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  if (numbers.any((n) => n == null)) return null;
  return numbers.cast<int>();
}

int _compareSemver(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final diff = a[i] - b[i];
    if (diff != 0) return diff;
  }
  return 0;
}

/// Resolves what to announce for [currentVersion], or null when there is
/// nothing to show: the version was already seen or has no changelog entry.
///
/// A malformed or missing [lastSeen] counts as nothing seen.
ChangelogDiscovery? resolveChangelogDiscovery({
  required List<ChangelogVersion> versions,
  required String currentVersion,
  required String? lastSeen,
}) {
  if (lastSeen == currentVersion) return null;
  final current = versions
      .where((v) => v.version == currentVersion)
      .firstOrNull;
  final currentParts = _semver(currentVersion);
  if (current == null || currentParts == null) return null;
  final seenParts = _semver(lastSeen);

  ChangelogVersion? featured;
  for (final candidate in versions) {
    final parts = _semver(candidate.version);
    if (!candidate.isMajor || parts == null) continue;
    if (_compareSemver(parts, currentParts) > 0) continue;
    if (seenParts != null && _compareSemver(parts, seenParts) <= 0) continue;
    if (featured == null ||
        _compareSemver(parts, _semver(featured.version)!) > 0) {
      featured = candidate;
    }
  }
  return ChangelogDiscovery(current: current, featured: featured);
}

/// Provider that returns what the Home card should announce, or `null` if
/// the user has already seen the current version's changelog.
///
/// This is an auto-dispose `FutureProvider` so it only runs once per app
/// session.
final changelogToShowProvider = FutureProvider.autoDispose<ChangelogDiscovery?>(
  (ref) async {
    if (changelogs.isEmpty) return null;

    final packageInfo = await ref.watch(packageInfoProvider.future);
    return resolveChangelogDiscovery(
      versions: changelogs,
      currentVersion: packageInfo.version,
      lastSeen: await _readLastSeenVersion(),
    );
  },
);

/// Mark the given version's changelog as seen. After calling this the
/// [changelogToShowProvider] will return `null` for this version.
Future<void> markChangelogSeen(String version) async {
  await _writeLastSeenVersion(version);
}
