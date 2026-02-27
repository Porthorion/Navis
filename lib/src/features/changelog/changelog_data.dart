/// Static changelog entries for each version.
///
/// When preparing a release, add a new [ChangelogVersion] at the top of
/// [changelogs] with a concise human-readable summary of the changes.
class ChangelogVersion {
  const ChangelogVersion({
    required this.version,
    required this.entries,
  });

  /// Semver string without the leading 'v' (e.g. '0.2.8').
  final String version;

  /// Bullet-point style change descriptions.
  final List<ChangelogEntry> entries;
}

class ChangelogEntry {
  const ChangelogEntry(this.text, {this.type = ChangelogEntryType.improvement});

  final String text;
  final ChangelogEntryType type;
}

enum ChangelogEntryType { fix, improvement, newFeature }

/// All changelogs, newest first.
const List<ChangelogVersion> changelogs = [
  ChangelogVersion(
    version: '0.2.10',
    entries: [
      ChangelogEntry(
        'Added configurable auto-sync interval (15m, 30m, 1h, 2h, 6h, 12h, '
        'or manual only) in Sync Settings',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Library now syncs automatically in the background on a periodic timer '
        'based on the chosen interval',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Sync staleness window is now driven by user settings instead of a '
        'hard-coded 1-hour window',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.9',
    entries: [
      ChangelogEntry(
        'Fixed version not being upgraded, causing an infinite update loop',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Refreshing the home screen now rescans for app updates and APK '
        'availability',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Release notes in the update dialog now render markdown formatting '
        'correctly (bold, headings, lists, etc.)',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.8',
    entries: [
      ChangelogEntry(
        'Fixed back button sometimes exiting the app instead of '
        'minimizing the Now Playing overlay',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Back button now consistently closes overlays before navigating',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Added double-press-to-exit confirmation when on the Home screen',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping the Home icon while already on Home now scrolls to the top',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Smoother Now Playing drag-to-dismiss gesture with better '
        'velocity and snap thresholds',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Refined player expand/collapse animations for a more natural feel',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Added version changelog dialog on first launch after update',
        type: ChangelogEntryType.newFeature,
      ),
    ],
  ),
];
