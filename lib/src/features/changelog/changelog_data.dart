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
    version: '0.9.7',
    entries: [
      // New
      ChangelogEntry(
        'New startup screen — the Navis logo appears centred with an animated ring that fills as the playback engine loads, then the logo flies up to its place on the home screen in a seamless transition',
        type: ChangelogEntryType.newFeature,
      ),
      // Fixed
      ChangelogEntry(
        "Album art on the home page's Recently Liked and Liked Tracks sections, and on the Liked page, now loads correctly — fixed a startup race condition that caused the cover art cache to crash before its database had finished opening",
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cover art images no longer stop loading after a large amount of music is cached — fixed a background conflict that caused images to get permanently stuck until the app was restarted',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Pressing play after the queue finishes now restarts playback from the beginning of the queue',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.6',
    entries: [
      // New
      ChangelogEntry(
        'Android Auto support — browse artists, albums, playlists, favourites, and podcasts directly from your car\'s head unit',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Android Auto now playing screen adapts to car displays — large album art, oversized transport controls, and a seek bar sized for in-car interaction',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Album Queue setting in Playback Settings — when enabled, tapping a track in an album queues the full album and starts at that track',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added Liked Queue sub-setting — when enabled alongside Album Queue, tapping a track on the Liked page queues all liked songs and starts at that track',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Redesigned login screen — new Material 3 card layout with app icon, password visibility toggle, and an insecure HTTP warning',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Login screen adapts to any screen size — portrait, landscape phone, wide tablet, and desktop each get a purpose-built layout',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping a song now starts playback almost instantly — the app no longer waits for the full queue to load before you hear audio',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Tapping a different song while one is still loading now cancels the previous load and plays the new song immediately',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync no longer blocks playback — large song batches are broken into smaller database writes so reads can interleave',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Login fields scroll up above the keyboard when tapped so the text you are typing is always visible',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album, artist, and playlist screens stay fully interactive while a queue action is in progress',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cached and offline songs now play immediately even while a library sync is running in the background',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.5',
    entries: [
      // New
      ChangelogEntry(
        'Added "Add to Queue" option in the downloaded track menu',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Artist detail screen now has Play and Shuffle buttons',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
      ChangelogEntry(
        'Download search is now shared — one search bar filters both Queue and Downloaded tabs',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        '"Re-Download" replaced with "Change Download Quality" — pick Original, 320, 192 or 128 kbps and see your current quality highlighted',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album detail screen has a new scroll-driven header — cover art shrinks into the toolbar as you scroll, with a gradient overlay and album name animation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Rating button now smoothly expands into a star-picker pill and collapses back with an animation',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed search bar keeping keyboard active after pressing back',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Removed emojis from release notes for better cross-platform compatibility',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed cover art flash and hero animation glitches on album detail screen',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed back button closing the app when at the root of a navigation branch',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.4',
    entries: [
      // New
      ChangelogEntry(
        'Tapping a downloaded track in the Downloads page now plays it directly',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Download buttons now show "Remove Download" when a song is already saved offline',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added search to the Downloads page — filter your queue and downloaded songs by title or artist',
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
      // Improved
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
      // Fixed
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
      // New
      ChangelogEntry(
        'Added playback speed control in Now Playing and Playback Settings, with saved speed restored across sessions',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Added ReplayGain playback settings with track/album modes and pre-amp control for supported libraries',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
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
      // Improved
      ChangelogEntry(
        'Hardened release pipeline with APK package/version/signature checks '
        'before publishing new assets',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
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
    ],
  ),
  ChangelogVersion(
    version: '0.2.11',
    entries: [
      // New
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
      // Fixed
      ChangelogEntry(
        'Fixed search/Now Playing navigation edge cases: closing queue no '
        'longer retriggers search, and expanding Now Playing no longer '
        'keeps the search keyboard active',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.2.10',
    entries: [
      // New
      ChangelogEntry(
        'Added configurable auto-sync interval (15m, 30m, 1h, 2h, 6h, 12h, '
        'or manual only) in Sync Settings',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
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
      // Improved
      ChangelogEntry(
        'Refreshing the home screen now rescans for app updates and APK '
        'availability',
        type: ChangelogEntryType.improvement,
      ),
      // Fixed
      ChangelogEntry(
        'Fixed version not being upgraded, causing an infinite update loop',
        type: ChangelogEntryType.fix,
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
      // New
      ChangelogEntry(
        'Added version changelog dialog on first launch after update',
        type: ChangelogEntryType.newFeature,
      ),
      // Improved
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
      // Fixed
      ChangelogEntry(
        'Fixed back button sometimes exiting the app instead of '
        'minimizing the Now Playing overlay',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Back button now consistently closes overlays before navigating',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
];
