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
  _Version('1.2.5', [
    _Entry(
      'Now Playing transport changes are smoother on mobile, with calmer automatic advances and clearer restart and queue-edge feedback',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Fixed Windows media controls so system playback, seeking, shuffle, and repeat reliably follow Navis playback',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed desktop More and right-click menus failing to open until after navigation',
      type: _EntryType.fix,
    ),
    _Entry(
      'Fixed Android Auto opening from a cold phone start and made media browse refreshes reliable',
      type: _EntryType.fix,
    ),
    _Entry(
      'Desktop Lyrics now keeps the current track visible',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist Top Tracks now has an artwork-led playlist detail view',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Home playlist song controls now have a clearer More label',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Liked song controls now use clearer, correctly anchored More menus',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Match Flow song controls now clearly label the remove action',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Search now clearly labels its query-clear control',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Sync Settings now presents desktop status in a clearer, safer summary',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Home recommendation actions now have clearer labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Recovery screens now remain usable with large text on small displays',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist view controls now clearly describe grid and list changes',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Weekly playlist recovery states are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library filtering and Playback headings are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist Top Tracks controls now have a clearer More label',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Add to Playlist controls now have a clearer close label',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Sign-in password controls now have clearer Show and Hide labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Queue controls now have a clearer close label',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Fullscreen artwork controls now have clearer close labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Phone Play and Pause controls now have clearer long-press labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Download failure notifications no longer expose internal track IDs',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library Sync notifications now provide safe recovery guidance',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Album navigation and actions now have clearer long-press labels on phones',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Now Playing Like feedback now respects reduced-motion preferences',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Match Flow recovery notices are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Update download failures now provide clear recovery without technical details',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Queue loading errors now explain how to recover without technical details',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library filters and sorting now remain readable with large system text',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Missing queue tracks now explain what happened without internal IDs',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Sync status messages now use clearer resume labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The Android exit prompt is now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Battery and playback prompt labels are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Compact desktop album pages now keep tracks visible alongside album actions',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Weekly playlist availability and playback actions are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist Top Tracks now keeps the artist name visible when no tracks are available',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop quick-search and Home action labels are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Playlist Detail now uses a full-width workspace header',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop About now uses a responsive overview for usage, links, and updates',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Privacy information now uses a clearer responsive desktop reading layout',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Match Flow now uses the full desktop workspace with New Flow in the header',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Appearance settings now use a focused workspace with a direct return to Settings',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Keyboard Shortcuts now uses a focused workspace with a direct return to Settings',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Window settings now use a focused workspace with a direct return to Settings',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Cache Settings now keeps storage controls focused with a direct return to Settings',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Configuration actions now stay reachable at larger system text sizes',
      type: _EntryType.fix,
    ),
    _Entry(
      'Configuration controls, validation feedback, and secret-field tooltips are now ready for translation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop Configuration now keeps independent external services side by side on wide windows',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist pages now keep their header, actions, and album layout visible while details first load',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist pages now keep their identity, album count, and More action stable while details refresh',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Older partial library migrations no longer prevent Android playback startup',
      type: _EntryType.fix,
    ),
    _Entry(
      'Error messages now stay visible until dismissed and keep their Dismiss action clear',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Radio filters now explain when no stations match and offer Show all stations',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Artist actions now offer Play, Shuffle, Add to Queue, and Like from More, long-press, or desktop right-click',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Fullscreen artwork now keeps its preview visible until the full-resolution, zoom-ready image is ready',
      type: _EntryType.fix,
    ),
    _Entry(
      'Album artwork no longer flashes when the opening or return animation settles',
      type: _EntryType.fix,
    ),
    _Entry(
      'On phones, album details now fade in as a complete page without artwork motion',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Navigation and album artwork return transitions now respect your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Home carousels now stop auto-advancing and switch instantly when reduced motion is enabled',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The selected mobile navigation destination now stays labeled for clearer orientation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Compact landscape navigation now has accessible destination names and hover labels',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Status messages now announce themselves to assistive technology',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Settings labels are now ready for localization across desktop and mobile',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Status messages now respect your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The expandable player now respects your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The queue now respects your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Like feedback now respects your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Fullscreen artwork now respects your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Now Playing metadata changes now respect your system reduced-motion preference',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Long mobile album titles now size down when they can fit cleanly',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Album card titles and artists now fade in smoothly when returning from an album page',
      type: _EntryType.fix,
    ),
    _Entry(
      'Album artwork now opens with a steadier transition from Home, Library, Search, Artist, and Genre views',
      type: _EntryType.fix,
    ),
    _Entry(
      'Check for updates on mobile data now performs a bounded recent-album discovery, so new and changed albums can be found without downloading the full song index',
      type: _EntryType.fix,
    ),
    _Entry(
      'Recently Added now preserves known server album dates through full-library syncs, keeping its order stable without a cache reset',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library sync reliability has been improved.',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Library sync now has stronger regression coverage for bounded mobile discovery and catalog-promotion date preservation',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Android background-sync reliability work now has a documented closure plan for truthful scheduling, worker failures, live network policy, and device certification',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.2.4', [
    _Entry(
      'Check for updates on mobile data now safely finds recent changed albums instead of stopping at an unchanged server cursor',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library Recently Added order now stays stable after a full sync when a server omits an album creation date',
      type: _EntryType.fix,
    ),
    _Entry(
      'Android can now recover eligible automatic library checks through the system scheduler after the app process exits, with Sync Settings showing the requested cadence and safe outcome',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Check for updates now always looks for recent new albums, even when a server reports no artist-library change',
      type: _EntryType.fix,
    ),
    _Entry(
      'Check for updates now scans a wider recent-album window, so new albums beyond the first server page are discovered',
      type: _EntryType.fix,
    ),
    _Entry(
      'A Check for updates started offline now resumes its full new-album discovery after reconnecting instead of stopping at an unchanged server cursor',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library sync now honors the configured automatic interval instead of repeatedly forcing pending verification work every two minutes',
      type: _EntryType.fix,
    ),
    _Entry(
      'Automatic library checks now keep their next scheduled time across app restarts, so reopening Navis does not restart the sync interval',
      type: _EntryType.fix,
    ),
    _Entry(
      'Opening Liked now stays offline-first and no longer starts a background library synchronization',
      type: _EntryType.fix,
    ),
    _Entry(
      'Repair Library now uses the standard full-library song index and safely falls back to album details instead of resuming a legacy wildcard search',
      type: _EntryType.fix,
    ),
    _Entry(
      'Repair Library now clearly shows when a large server-side deletion needs your confirmation before changing the local library',
      type: _EntryType.improvement,
    ),
    _Entry(
      'You can now discard a pending Repair Library candidate without changing your current offline library',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Repair Library now completes song collection before evaluating server-missing tracks, preventing a false large-deletion warning on an existing library',
      type: _EntryType.fix,
    ),
    _Entry(
      'Liked music now stays visible after one incomplete server response; Navis waits for a second confirmed absence before removing a like locally',
      type: _EntryType.fix,
    ),
    _Entry(
      'Opening Navis no longer restarts a paused Repair Library operation; repairs resume only when you request them',
      type: _EntryType.fix,
    ),
    _Entry('Already missing 1.2.3'),
    _Entry(
      'Returning to Navis no longer submits duplicate automatic sync checks for the same lifecycle event',
      type: _EntryType.fix,
    ),
    _Entry(
      'Sync Settings now shows when automatic catalog work is waiting for a retry cooldown after a failed sync',
      type: _EntryType.improvement,
    ),
    _Entry(
      'A partial server artist response can no longer remove an existing offline album during an incremental sync',
      type: _EntryType.fix,
    ),
    _Entry(
      'Sync Settings now shows the latest safe library removal and its aggregate counts, even after later no-op checks',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.2.3', [
    _Entry('Loving you is as easy as 123'),
    _Entry(
      'Repeat repairs of very large libraries now reuse verified unchanged album tracks when a server caps its bulk song index, avoiding a long late album-by-album wait',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library recovery controls now clearly distinguish safe metadata repair from a cache reset that keeps downloaded music',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Repair Library now shows progress immediately and keeps its final album fallback faster while music is playing',
      type: _EntryType.fix,
    ),
    _Entry(
      'Large-library scans now continue correctly when a compatible server returns shorter catalog pages than requested',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library repair now distinguishes song-index scanning from the remaining album-detail fallback and shows a live indexed-song count',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.2.2', [
    _Entry(
      'Home now keeps library-sync status on the Navis logo, while Library provides the detailed progress and recovery controls',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Startup sync now waits for its signed-in server connection to become ready instead of briefly showing a false metadata-sync failure',
      type: _EntryType.fix,
    ),
    _Entry(
      'Refreshing a large library now brings in newly added albums immediately instead of waiting for a long artist verification cycle',
      type: _EntryType.fix,
    ),
    _Entry(
      'Subsonic connections now identify Navis to work reliably with strict reverse proxies',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.2.1', [
    _Entry(
      'Library sync is now more reliable: background, manual, and repair requests share one coordinated operation so progress and failures stay accurate instead of briefly disappearing',
      type: _EntryType.fix,
    ),
    _Entry(
      'Missing rolling-cache files are now detected and removed immediately before playback safely falls back to streaming, without requiring a manual library repair',
      type: _EntryType.fix,
    ),
    _Entry(
      'New connections stay on Home while the library is syncing, with persistent progress and retryable failure feedback',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Repair Library and full sync now coordinate safely with startup work for a more dependable recovery experience',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.2.0', [
    _Entry(
      'First-time server connections now show a cancellable initial library setup with clear progress, offline retry, and mobile-data consent',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Signing back into the same server account now safely reuses its committed local library, while switching server or account requires confirmation before local data is replaced',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Signing out now reliably stops playback and radio, clears queues and pending server work, and waits for active syncs and downloads to stop',
      type: _EntryType.fix,
    ),
    _Entry(
      'Playback startup now keeps loading and automatically retries transient audio initialization failures',
      type: _EntryType.fix,
    ),
    _Entry(
      'Mini Player now opens at a balanced 720×405, returns to that size after mode prompts, keeps volume neatly beneath its controls, and shows both resize choices in short windows',
      type: _EntryType.fix,
    ),
    _Entry(
      'Mini Player controls are now compact transparent right-edge buttons with icon-only hover feedback and quick panel-aware fades; they stay clear of track details and hide for Queue, Lyrics, and other embedded panels. Queue now closes with a matching smooth reverse transition, and Linux Wayland clearly explains when its compositor cannot provide always-on-top',
      type: _EntryType.fix,
    ),
    _Entry(
      'Navis now always starts in Desktop View and restores your last Desktop window size, even if it was closed while Mini Player was active',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Favorite, Lyrics, Queue, Mini Player, and volume now stay directly visible across every supported Desktop View size',
      type: _EntryType.fix,
    ),
    _Entry(
      'Desktop and Mini Player layouts now stay balanced at unusual aspect ratios, with centered compact metadata and a firm 560×360 Mini Player minimum',
      type: _EntryType.fix,
    ),
    _Entry(
      'Desktop now stays in a consistent workspace down to 800×600, with its volume-ready bottom player always present and no phone-layout fallbacks',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The new same-window Mini Player keeps playback, volume, pinning, and a quick return to Desktop View available in compact windows',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'The current or loading song is now highlighted consistently across library, Home, search, downloads, artist, playlist, and queue views without shifting queue track numbers',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Desktop clients now reopen at your previous Navis volume, including mute, and Unmute restores the last audible level',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Search now keeps the best matches first while preferring music already on your server, and remote results use clearer context-aware Remote labels',
      type: _EntryType.newFeature,
    ),
    _Entry(
      'Remote labels now appear consistently in weekly recommendations, Home song lists, liked songs, artist top tracks, Match Flow, queues, and downloads without changing row alignment',
      type: _EntryType.fix,
    ),
    _Entry(
      'Remote label tooltips no longer flood desktop logs or destabilize accessibility when repeatedly shown and hidden',
      type: _EntryType.fix,
    ),
    _Entry(
      'The update summary now keeps every change readable when it appears over an active player view',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library repairs now fall back to the server artist index when its separate artist-list endpoint is unavailable, so compatible servers can resume safely',
      type: _EntryType.fix,
    ),
    _Entry(
      'Large Library Repairs now keep a fast, bounded concurrent album fallback when a server search result window cannot return every song at once',
    ),
    _Entry(
      'Library Repairs now continue through server-capped song-search pages instead of needlessly falling back to slow album-by-album downloads',
      type: _EntryType.fix,
    ),
    _Entry(
      'Manual library refresh now includes liked music, playlist headers, and genres alongside catalog updates',
      type: _EntryType.fix,
    ),
    _Entry(
      'Manual library refresh now resumes queued catalog work while music is playing instead of deferring the refresh behind it',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library song hydration progress now advances only after song data is safely written, while catalog discovery uses an activity indicator instead of a misleading percentage',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library setup now waits for an already-running sync instead of briefly reporting a false failure, and completed syncs keep you on the page you are viewing',
      type: _EntryType.fix,
    ),
    _Entry(
      'When a viewed album, artist, or playlist is confirmed removed, its page now stays open with a Back to Library action instead of navigating you away',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Release validation now exercises live app-owned screenshots, responsive desktop states, playback indicators, volume restoration, and authentication lifecycle in isolated profiles',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Navis now uses a refreshed, precisely centred logo and background-free circular platform icons',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.1.1', [
    _Entry(
      'Seeking on desktop no longer hangs while a track is still caching; playback stays on a seekable stream while the rolling cache fills in the background',
      type: _EntryType.fix,
    ),
    _Entry(
      'Seeking back into already-heard audio on desktop is smoother and no longer forces a full stream rebuild',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.1.0', [
    _Entry(
      'Background library sync stays on unmetered networks by default, with updates-available notices and one-time mobile-data sync when you need it',
    ),
    _Entry(
      'Library sync is adaptive and resumable: low-data checks, targeted updates, safer full repairs that apply only real changes, and better liked and playlist reconciliation',
    ),
    _Entry(
      'Desktop playback is more responsive; streamed tracks now fill the rolling cache on Linux, Windows, and macOS',
    ),
    _Entry(
      'Fixed interrupted library repairs, playback startup glitches, Home refreshes during sync, and unstable seek or duration updates',
      type: _EntryType.fix,
    ),
  ]),
  _Version('1.0.15', [
    _Entry(
      'Metadata sync now keeps individual artist and album failures pending, retries only unfinished items, and preserves the server cursor until verification completes',
      type: _EntryType.fix,
    ),
    _Entry(
      'Previous-track restarts and end-of-queue Next presses now use distinct replay and boundary feedback instead of looking like a track change',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Android Auto now opens with Liked, Recent, Playlists, and Library, with reliable search, queue order, resume, downloads, and genre browsing',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.14', [
    _Entry(
      'Clearing the final queue item now closes the fullscreen player smoothly and leaves phone Back navigation responsive immediately',
      type: _EntryType.fix,
    ),
    _Entry(
      'Syncing while a cached remote song is playing now transfers its verified server identity without interrupting playback or invalidating the active cache file',
      type: _EntryType.fix,
    ),
    _Entry(
      'Library update checks now verify 48 artists per pass and continue quietly, while preserving older unchecked artists when newer server changes arrive',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.13', [
    _Entry(
      'Library refreshes now use the server sync cursor, verify newest albums, and continue large updates in bounded batches instead of requiring Force Full Sync',
      type: _EntryType.fix,
    ),
    _Entry(
      'Cached remote songs now move to their verified server identity when an exact match becomes available, preventing duplicate local entries without risky fuzzy matching',
      type: _EntryType.fix,
    ),
    _Entry(
      'Sync Settings now includes Check for updates and reports whether metadata is current, still being verified, or needs repair',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Previous track now reliably restarts the current song when there is no earlier queue item, including fullscreen artwork swipes and system media controls',
      type: _EntryType.fix,
    ),
    _Entry(
      'Instant Mix and Same Vibes now start from a fresh queue rooted at the current song, then keep recommendations appending at the bottom',
      type: _EntryType.fix,
    ),
    _Entry(
      'Adding songs near the end of playback no longer leaves the player paused or stuck at the seek position when advancing to the next track',
      type: _EntryType.fix,
    ),
    _Entry(
      'Opening the queue during active playback no longer triggers a provider rebuild error',
      type: _EntryType.fix,
    ),
    _Entry(
      'Queued remote tracks now recover from stream stalls by falling back to direct playback or skipping the failed track instead of staying stuck',
      type: _EntryType.fix,
    ),
    _Entry(
      'Downloaded songs now pre-cache standard-size cover art so offline album and track artwork is available more reliably',
      type: _EntryType.fix,
    ),
    _Entry(
      'The offline server banner now switches to a quiet offline mode after repeated retry failures while continuing background checks',
      type: _EntryType.improvement,
    ),
    _Entry(
      'The update changelog dialog now labels bug-fix-only releases clearly and always links to the full changelog in About',
      type: _EntryType.improvement,
    ),
    _Entry(
      'Refreshed core networking, connectivity, caching, and notification components and simplified Linux desktop media integration',
      type: _EntryType.improvement,
    ),
  ]),
  _Version('1.0.10', [
    _Entry(
      'Search category filters now show only matching results, so Songs no longer includes albums or artists when cached and server results are mixed',
      type: _EntryType.fix,
    ),
    _Entry(
      'LRCLIB lyrics now prewarm first when songs play or enter the queue, with server lyrics used as fallback when LRCLIB has no match',
      type: _EntryType.fix,
    ),
  ]),
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
