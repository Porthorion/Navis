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
    version: '0.9.4',
    entries: [
      ChangelogEntry(
        'Tapping a downloaded track in the Downloads page now plays it directly',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Download buttons now show "Remove Download" when a song is already saved offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added What\'s New page in About settings showing what changed in the current version',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'App now shows a What\'s New summary on first launch after an update',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Improved radio station switching reliability and reduced lag when stopping radio',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Swiping to remove a queue item no longer accidentally dismisses the queue, and dismissing no longer triggers item removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Update notifications now display actual release notes instead of a generic link',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fixed download button in the Now Playing settings panel not working',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed download action remaining visible while a song is already queued or downloading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed songs being re-downloaded automatically after library sync without user request',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed album art flickering during navigation transitions',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed playback controls freezing when Instant Mix is active',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed tooltip labels appearing on mobile after tapping icons',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.3.0',
    entries: [
      ChangelogEntry(
        'Added playback speed control in Now Playing and Playback Settings, with saved speed restored across sessions',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added ReplayGain playback settings with track/album modes and pre-amp control for supported libraries',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Improved synced lyrics with full-screen live tracking, faster auto-scroll recovery, and tap-to-seek',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Added a playback warning when crossfade and gapless settings conflict',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.12',
    entries: [
      ChangelogEntry(
        'Improved in-app update reliability by selecting only strictly newer '
        'release versions and deterministically preferring the matching APK '
        'asset for each tag',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Added APK pre-install validation for package/signature compatibility '
        'to prevent conflicting-package install attempts',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Hardened release pipeline with APK package/version/signature checks '
        'before publishing new assets',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.11',
    entries: [
      ChangelogEntry(
        'Fixed search/Now Playing navigation edge cases: closing queue no '
        'longer retriggers search, and expanding Now Playing no longer '
        'keeps the search keyboard active',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Added full-screen album art viewer from album detail with smoother '
        'open/close transitions and pinch-to-zoom',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Appearance toggle for Dynamic Album Color to theme app accent '
        'colors from currently playing album art (off by default)',
        type: ChangelogEntryType.newFeature,
      ),
    ],
  ),
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
