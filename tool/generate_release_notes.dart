#!/usr/bin/env dart
// Reads changelog_data.dart and outputs markdown release notes for a given
// version. Used by release.sh to populate the Forgejo release body.
//
// Usage:
//   dart tool/generate_release_notes.dart v0.3.0
//
// Exit codes:
//   0 – success, markdown written to stdout
//   1 – missing or invalid version argument
//   2 – no changelog entry found for the requested version

// ignore_for_file: avoid_print // CLI tool — stdout is the intended output channel

import 'dart:io';

// ---------------------------------------------------------------------------
// Inline copy of the data model from changelog_data.dart so this script can
// run without `dart pub get` and without importing package paths.
// The actual content is sourced from the canonical changelog_data.dart — keep
// both in sync when making structural changes to the model.
// ---------------------------------------------------------------------------

enum _EntryType { fix, improvement, newFeature }

class _Entry {
  const _Entry(this.text, {this.type = _EntryType.improvement});
  final String text;
  final _EntryType type;
}

class _Version {
  const _Version(this.version, this.entries);
  final String version;
  final List<_Entry> entries;
}

// ---------------------------------------------------------------------------
// Section labels per entry type.
// ---------------------------------------------------------------------------
String _label(_EntryType t) {
  switch (t) {
    case _EntryType.fix:
      return 'Fix';
    case _EntryType.improvement:
      return 'Improved';
    case _EntryType.newFeature:
      return 'New';
  }
}

// ---------------------------------------------------------------------------
// Canonical changelog — keep in sync with
// lib/src/features/changelog/changelog_data.dart.
// Newest version first.
// ---------------------------------------------------------------------------
const List<_Version> _changelogs = [
  _Version('1.0.9', [
    _Entry(
      'Artist pages now include a virtual "This is" playlist powered by up to 50 Last.fm top tracks, with unmatched tracks kept visible for search',
      type: _EntryType.newFeature,
    ),
  ]),
  _Version('1.0.8', [
    _Entry(
      'Android stable releases now clean stale build outputs and verify APK contents before publishing so self-updates install the current app code',
      type: _EntryType.fix,
    ),
    _Entry(
      'Retired Listen Together and Voyage configuration strings are blocked from active Android release artifacts',
      type: _EntryType.fix,
    ),
    _Entry(
      'Artist Top Tracks with Album Queue keeps the ranked resolved queue and starts playback from the tapped track',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.7', [
    _Entry(
      'Released a fresh stable version so older 1.0.6 installs detect the Listen Together retirement update correctly',
      type: _EntryType.fix,
    ),
    _Entry(
      'Artist Top Tracks with Album Queue now show the full ranked queue immediately on Android while playback finishes preparing in the background',
      type: _EntryType.fix,
    ),
    _Entry(
      'Retired Listen Together and Voyage settings are cleared during migration, including stored custom Voyage servers',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.6', [
    _Entry(
      'Artist Top Tracks now honor Album Queue by queueing the resolved ranked top tracks and starting at the tapped song',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Now Playing and queue metadata stay on the tapped song while album-style queues finish filling in the background',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed album art loading stalling after a few covers when cached or missing artwork responses were not fully drained',
      type: _EntryType.fix,
    ),
    _Entry(
      'Listen Together is retired for now: Voyage backend sync has been removed and visible app entry points are hidden until the feature is redesigned',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.5', [
    _Entry(
      'Re-introduced smart in-app updates: Forgejo/sideload Android builds can self-update, Google Play installs are redirected to the Play Store, and desktop keeps the existing updater',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Update checks now respect the auto-check setting, throttle background Forgejo requests to once every 24 hours, and record update download usage in data-usage stats',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library metadata sync tolerates missing albums and transient per-album failures instead of failing the entire scan, and automatically retries after a failed sync',
      type: _EntryType.fix,
    ),
    _Entry(
      'Automatic library sync now avoids daily full-library rescans, bounds noisy server index fanout, and refreshes starred/genre/playlist metadata less often to reduce background data usage',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Instant Mix now honors the legacy Subsonic instant-mix setting in Playback Settings instead of routing to Same Vibes, and active mix sessions reconcile when you switch between modes',
      type: _EntryType.fix,
    ),
    _Entry(
      'Listen Together now validates stored sessions on app launch — valid rooms auto-resume without a prompt, and expired or invalid sessions are cleared silently instead of showing a stale resume dialog',
      type: _EntryType.fix,
    ),
    _Entry(
      'Listen Together upgrades to Voyage voyage-sync.v4alpha1 for tighter multi-device sync — connection.ready handshake, explicit command frames, member.status telemetry, and playback phase tracking',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Listen Together accepts Voyage voyage-sync.v4alpha1 and the legacy sync.v4alpha1 protocol alias during server rollout',
      type: _EntryType.fix,
    ),
    _Entry(
      'Voyage connection errors in Configuration now show the expected and supported protocol versions when Listen Together cannot negotiate a compatible server',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Instant Mix uses the server instant-mix endpoint for 50-track batches again, Same Vibes keeps its 5-track Last.fm fills, and both modes recover instead of staying stuck loading',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library resync and playlist refresh now trigger ListenBrainz weekly playlist discovery and rematching, including on fresh installs after token validation',
      type: _EntryType.fix,
    ),
    _Entry(
      'ListenBrainz weekly playlists stay visible after matching completes, even when none of the recommendations match your server yet',
      type: _EntryType.fix,
    ),
    _Entry(
      'ListenBrainz weekly playlist details now keep unavailable recommendations aligned with playable tracks and include a Match action to retry matching for one weekly playlist',
      type: _EntryType.fix,
    ),
    _Entry(
      'Same Vibes and Instant Mix no longer loop through repeated startup errors when only part of a recommendation batch can be queued',
      type: _EntryType.fix,
    ),
    _Entry(
      'Remote search3 tracks start playing more reliably after tap, including when re-selected from the library or during Listen Together queue changes',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.4', [
    _Entry(
      'You Might Like can now include your ListenBrainz weekly recommendations, and song likes sync to ListenBrainz recording feedback when connected',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Weekly Exploration and Weekly Jams now appear as read-only virtual playlists in the playlist library, with normal play, shuffle, queue, download, and song actions for matched server tracks',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'ListenBrainz weekly matching now checks cached local songs first, limits remote search concurrency, handles duplicate exact matches more accurately, and avoids unnecessary ambiguous results',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop You Might Like panels now show complete scrollable song lists for albums and weekly recommendations instead of short previews',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library pages can now be reordered from Appearance settings, with per-page visibility controls including Albums across mobile tabs and desktop library navigation',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Weekly recommendation loading is smoother, with batched matching, database writes, and UI updates to reduce stalls while recommendations resolve',
      type: _EntryType.fix,
    ),
    _Entry(
      'Queued downloads now react when Wi-Fi-only settings or network type change, and compatible cached files are reused instead of downloaded again',
      type: _EntryType.fix,
    ),
    _Entry(
      'Rolling cache files can now be promoted to permanent downloads from the queue, stale missing-file cache records are cleaned up, and lower-quality cached files no longer block higher-quality download requests',
      type: _EntryType.fix,
    ),
    _Entry(
      'The Previous control now restarts the current track when appropriate and only skips to the prior track near the start of playback',
      type: _EntryType.fix,
    ),
    _Entry(
      'Updated package dependencies including file picker, local notifications, and JSON annotations',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.3', [
    _Entry(
      'Android releases are now prepared for Google Play, with Android self-updates removed, Play release tooling added, privacy information added, and release safety checks documented',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'External scrobbling now supports Last.fm and ListenBrainz alongside Subsonic/OpenSubsonic, with secure credential storage, validation, reconnect handling, and provider-aware offline retries',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Listen Together now supports custom Voyage servers that can be added, edited, selected, and managed alongside bundled server defaults',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Voyage sync recovery is more robust, with protocol v2 support, clock-sync hardening, fewer duplicate queue seeks, and safer version negotiation',
      type: _EntryType.fix,
    ),
    _Entry(
      'Last.fm API key configuration has been restored in Server settings so builds can include a key while still allowing user-provided keys when needed',
      type: _EntryType.fix,
    ),
    _Entry(
      'Instant Mix and Same Vibes recommendations now insert after the current track so they keep your queue context instead of replacing what comes next',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Search can now prefer cached local results first, reducing network use and making repeat searches feel faster',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Mobile data usage is now tracked and reduced across artwork, sync, downloads, and playback flows, with clearer usage reporting in About',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Cached-first playback can now prefer downloaded or cached audio before remote streams when a local copy is available',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Navigation intents from album, artist, playlist, search, queue, and Now Playing actions are more stable across shell layouts and back-stack transitions',
      type: _EntryType.fix,
    ),
    _Entry(
      'Appearance settings, exact brand accent colors, icon rendering, and color picker behavior are more consistent across light and dark themes',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Android Auto browsing and real-car validation are more robust, with clearer media IDs, safer playback rules, diagnostic tooling, and dedicated test coverage',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Permanent downloads gained custom folders, readable artist/song paths, desktop folder actions, and safer cleanup of empty download directories',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Liked-tab play, shuffle, and queue-all actions include tracks from liked albums while deduplicating overlaps and respecting filters',
      type: _EntryType.fix,
    ),
    _Entry(
      'Listen Together rooms, Match Flow song chains, split artist releases, player polish, faster sync, and Android Auto reliability improvements from the 1.0 release are included',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Queue appends, cached-source seek recovery, Listen Together reconnects, room exits, and compact mini-player layout edge cases are more reliable',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.2', [
    _Entry(
      'Custom download folders for permanent downloads — pick your own destination and Navis will move existing downloads there automatically',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Permanent downloads now use readable artist folders and song filenames instead of cache-style names, and existing downloads are migrated to match',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Downloaded-song actions now support desktop right-click and include a direct shortcut to open the containing download folder',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Removing downloads now cleans up empty artist folders without deleting your configured top-level download folder',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.1', [
    _Entry(
      'Liked-tab play, shuffle, and queue-all actions now include tracks from liked albums, while deduplicating overlaps with individually liked songs and respecting current filters',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.0', [
    _Entry(
      'Listen Together — host or join Voyage-backed synced rooms with shared queue control, live room status in the player bar, and collaborative or host-only room setups',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Experimental Match Flow — create song chains in Playback Settings so starting one track can automatically expand into follow-up songs',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Artist pages now split main releases from featured appearances for easier browsing',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Now Playing, the mini player, and compact layouts are more polished, with richer metadata navigation and better desktop media integration',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library sync is faster and smarter — song pages load in parallel and tracks deleted from the server are reconciled locally',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Android Auto media browsing and projection support are more reliable, and cover art loading now prioritizes visible items for smoother scrolling',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Listen Together recovery is much more resilient — rejoin/resume, room exits, sync recovery, and listener seeking behave more reliably during disconnects',
      type: _EntryType.fix,
    ),
    _Entry(
      'Queue appends stay in order, cached-source seek recovery is more reliable, and compact wide mini-player layout glitches are fixed',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.9.7', [
    // Fixed
    _Entry(
      'Cover art images no longer stop loading after a large amount of music is cached — fixed a background conflict that caused images to get permanently stuck until the app was restarted',
      type: _EntryType.fix,
    ),
    _Entry(
      'Pressing play after the queue finishes now restarts playback from the beginning of the queue',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.9.6', [
    // New
    _Entry(
      'Android Auto support — browse artists, albums, playlists, favourites, and podcasts directly from your car\'s head unit',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Android Auto now playing screen adapts to car displays — large album art, oversized transport controls, and a seek bar sized for in-car interaction',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Added Album Queue setting in Playback Settings — when enabled, tapping a track in an album queues the full album and starts at that track',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Added Liked Queue sub-setting — when enabled alongside Album Queue, tapping a track on the Liked page queues all liked songs and starts at that track',
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Redesigned login screen — new Material 3 card layout with app icon, password visibility toggle, and an insecure HTTP warning',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Login screen adapts to any screen size — portrait, landscape phone, wide tablet, and desktop each get a purpose-built layout',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Tapping a song now starts playback almost instantly — the app no longer waits for the full queue to load before you hear audio',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Tapping a different song while one is still loading now cancels the previous load and plays the new song immediately',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library sync no longer blocks playback — large song batches are broken into smaller database writes so reads can interleave',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Login fields scroll up above the keyboard when tapped so the text you are typing is always visible',
      type: _EntryType.fix,
    ),
    _Entry(
      'Album, artist, and playlist screens stay fully interactive while a queue action is in progress',
      type: _EntryType.fix,
    ),
    _Entry(
      'Cached and offline songs now play immediately even while a library sync is running in the background',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.9.5', [
    // New
    _Entry(
      'Added "Add to Queue" option in the downloaded track menu',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Artist detail screen now has Play and Shuffle buttons',
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Download search is now shared — one search bar filters both Queue and Downloaded tabs',
      type: _EntryType.improvement,
    ),
    _Entry(
      '"Re-Download" replaced with "Change Download Quality" — pick Original, 320, 192 or 128 kbps and see your current quality highlighted',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Album detail screen has a new scroll-driven header — cover art shrinks into the toolbar as you scroll, with a gradient overlay and album name animation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Rating button now smoothly expands into a star-picker pill and collapses back with an animation',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Fixed search bar keeping keyboard active after pressing back',
      type: _EntryType.fix,
    ),
    _Entry(
      'Removed emojis from release notes for better cross-platform compatibility',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed cover art flash and hero animation glitches on album detail screen',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed back button closing the app when at the root of a navigation branch',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.9.4', [
    // New
    _Entry(
      'Tapping a downloaded track in the Downloads page now plays it directly',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Download buttons now show "Remove Download" when a song is already saved offline',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Added search to the Downloads page — filter your queue and downloaded songs by title or artist',
      type: _EntryType.newFeature,
    ),
    _Entry(
      "Added What's New page in About settings showing what changed in the current version",
      type: _EntryType.newFeature,
    ),
    _Entry(
      "App now shows a What's New summary on first launch after an update",
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Improved radio station switching reliability and reduced lag when stopping radio',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Swiping to remove a queue item no longer accidentally dismisses the queue, and dismissing no longer triggers item removal',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Update notifications now display actual release notes instead of a generic link',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Fixed download button in the Now Playing settings panel not working',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed download action remaining visible while a song is already queued or downloading',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed songs being re-downloaded automatically after library sync without user request',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed album art flickering during navigation transitions',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed playback controls freezing when Instant Mix is active',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed tooltip labels appearing on mobile after tapping icons',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.3.0', [
    // New
    _Entry(
      'Added playback speed control in Now Playing and Playback Settings, with saved speed restored across sessions',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Added ReplayGain playback settings with track/album modes and pre-amp control for supported libraries',
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Improved synced lyrics with full-screen live tracking, faster auto-scroll recovery, and tap-to-seek',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Added a playback warning when crossfade and gapless settings conflict',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('0.2.12', [
    // Improved
    _Entry(
      'Hardened release pipeline with APK package/version/signature checks before publishing new assets',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Improved in-app update reliability by selecting only strictly newer release versions and deterministically preferring the matching APK asset for each tag',
      type: _EntryType.fix,
    ),
    _Entry(
      'Added APK pre-install validation for package/signature compatibility to prevent conflicting-package install attempts',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.2.11', [
    // New
    _Entry(
      'Added full-screen album art viewer from album detail with smoother open/close transitions and pinch-to-zoom',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Added Appearance toggle for Dynamic Album Color to theme app accent colors from currently playing album art (off by default)',
      type: _EntryType.newFeature,
    ),
    // Fixed
    _Entry(
      'Fixed search/Now Playing navigation edge cases: closing queue no longer retriggers search, and expanding Now Playing no longer keeps the search keyboard active',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.2.10', [
    // New
    _Entry(
      'Added configurable auto-sync interval (15m, 30m, 1h, 2h, 6h, 12h, or manual only) in Sync Settings',
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Library now syncs automatically in the background on a periodic timer based on the chosen interval',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Sync staleness window is now driven by user settings instead of a hard-coded 1-hour window',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('0.2.9', [
    // Improved
    _Entry(
      'Refreshing the home screen now rescans for app updates and APK availability',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Fixed version not being upgraded, causing an infinite update loop',
      type: _EntryType.fix,
    ),
    _Entry(
      'Release notes in the update dialog now render markdown formatting correctly (bold, headings, lists, etc.)',
      type: _EntryType.fix,
    ),
  ]),
  _Version('0.2.8', [
    // New
    _Entry(
      'Added version changelog dialog on first launch after update',
      type: _EntryType.newFeature,
    ),
    // Improved
    _Entry(
      'Added double-press-to-exit confirmation when on the Home screen',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Tapping the Home icon while already on Home now scrolls to the top',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Smoother Now Playing drag-to-dismiss gesture with better velocity and snap thresholds',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Refined player expand/collapse animations for a more natural feel',
      type: _EntryType.improvement,
    ),
    // Fixed
    _Entry(
      'Fixed back button sometimes exiting the app instead of minimizing the Now Playing overlay',
      type: _EntryType.fix,
    ),
    _Entry(
      'Back button now consistently closes overlays before navigating',
      type: _EntryType.fix,
    ),
  ]),
];

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart tool/generate_release_notes.dart <version>');
    stderr.writeln('Example: dart tool/generate_release_notes.dart v0.3.0');
    exit(1);
  }

  // Strip leading 'v' to normalise input.
  var requested = args[0].trim();
  if (requested.startsWith('v')) requested = requested.substring(1);

  final match = _changelogs.where((c) => c.version == requested).firstOrNull;
  if (match == null) {
    stderr.writeln(
      'No changelog found for version $requested. '
      'Add an entry to tool/generate_release_notes.dart and '
      'lib/src/features/changelog/changelog_data.dart before releasing.',
    );
    exit(2);
  }

  final buf = StringBuffer();
  buf.writeln("## What's New in Navis v${match.version}");
  buf.writeln();

  for (final entry in match.entries) {
    buf.writeln(
      '- **${_label(entry.type)}:** ${entry.text}',
    );
  }

  print(buf.toString().trimRight());
}
