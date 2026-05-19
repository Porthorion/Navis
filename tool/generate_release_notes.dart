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
  _Version('1.0.1', [
    _Entry(
      'Liked-tab play, shuffle, and queue-all actions now include tracks from liked albums, while deduplicating overlaps with individually liked songs and respecting current filters',
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
