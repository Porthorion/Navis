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
    version: '1.2.5',
    entries: [
      ChangelogEntry(
        'Offline mode now uses a calmer status treatment while Navis retries in the background',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library now opens Appearance settings directly when all library pages are disabled',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Sync Settings now uses a continuous workspace with a clear return to Settings',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Weekly playlists now keep their track layout visible while loading and offer clearer recovery when unavailable',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop weekly playlists keep their Back button without repeating the page title',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing artwork tint now changes more quickly and respects reduced-motion preferences',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search now clearly distinguishes no matches from a recoverable loading failure',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fullscreen artwork now keeps its preview visible until the full-resolution, zoom-ready image is ready',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album artwork no longer flashes when the opening or return animation settles',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'On phones, album details now fade in as a complete page without artwork motion',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navigation and album artwork return transitions now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home carousels now stop auto-advancing and switch instantly when reduced motion is enabled',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The selected mobile navigation destination now stays labeled for clearer orientation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Compact landscape navigation now has accessible destination names and hover labels',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Status messages now announce themselves to assistive technology',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Search now uses an integrated command strip and continuous results workspace',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Library is now a continuous workspace, and collapsed navigation stays available as an icon rail',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Home now uses a calmer continuous desktop workspace while keeping album cards easy to scan',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Downloads now keeps its Back action, tabs, and search together in one compact workspace strip',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop Settings now uses a focused preference list with clearer group hierarchy',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Settings labels are now ready for localization across desktop and mobile',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Status messages now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The expandable player now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The queue now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Like feedback now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fullscreen artwork now respects your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing metadata changes now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Wide Now Playing panels now respect your system reduced-motion preference',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Song action menus now group playback controls and clearly separate download removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album refresh and radio loading errors now give clear recovery guidance',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Playback Settings and Match Flow errors now offer clear retry guidance',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album action menus now clearly separate download removal',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Playlist track actions now use the same compact desktop menu for right-click and More, while phone keeps its touch sheet',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Long mobile album titles now size down when they can fit cleanly',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Album card titles and artists now fade in smoothly when returning from an album page',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Album artwork now opens with a steadier transition from Home, Library, Search, Artist, and Genre views',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates on mobile data now performs a bounded recent-album discovery, so new and changed albums can be found without downloading the full song index',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Recently Added now preserves known server album dates through full-library syncs, keeping its order stable without a cache reset',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library sync reliability has been improved.',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync now has stronger regression coverage for bounded mobile discovery and catalog-promotion date preservation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android background-sync reliability work now has a documented closure plan for truthful scheduling, worker failures, live network policy, and device certification',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.4',
    entries: [
      ChangelogEntry(
        'Check for updates on mobile data now safely finds recent changed albums instead of stopping at an unchanged server cursor',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library Recently Added order now stays stable after a full sync when a server omits an album creation date',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android can now recover eligible automatic library checks through the system scheduler after the app process exits, with Sync Settings showing the requested cadence and safe outcome',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Check for updates now always looks for recent new albums, even when a server reports no artist-library change',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Check for updates now scans a wider recent-album window, so new albums beyond the first server page are discovered',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'A Check for updates started offline now resumes its full new-album discovery after reconnecting instead of stopping at an unchanged server cursor',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library sync now honors the configured automatic interval instead of repeatedly forcing pending verification work every two minutes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic library checks now keep their next scheduled time across app restarts, so reopening Navis does not restart the sync interval',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening Liked now stays offline-first and no longer starts a background library synchronization',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library now uses the standard full-library song index and safely falls back to album details instead of resuming a legacy wildcard search',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Repair Library now clearly shows when a large server-side deletion needs your confirmation before changing the local library',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'You can now discard a pending Repair Library candidate without changing your current offline library',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library now completes song collection before evaluating server-missing tracks, preventing a false large-deletion warning on an existing library',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Liked music now stays visible after one incomplete server response; Navis waits for a second confirmed absence before removing a like locally',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening Navis no longer restarts a paused Repair Library operation; repairs resume only when you request them',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry('Already missing 1.2.3'),
      ChangelogEntry(
        'Returning to Navis no longer submits duplicate automatic sync checks for the same lifecycle event',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now shows when automatic catalog work is waiting for a retry cooldown after a failed sync',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'A partial server artist response can no longer remove an existing offline album during an incremental sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now shows the latest safe library removal and its aggregate counts, even after later no-op checks',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.3',
    entries: [
      ChangelogEntry('Loving you is as easy as 123'),
      ChangelogEntry(
        'Repeat repairs of very large libraries now reuse verified unchanged album tracks when a server caps its bulk song index, avoiding a long late album-by-album wait',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library recovery controls now clearly distinguish safe metadata repair from a cache reset that keeps downloaded music',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library now shows progress immediately and keeps its final album fallback faster while music is playing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large-library scans now continue correctly when a compatible server returns shorter catalog pages than requested',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library repair now distinguishes song-index scanning from the remaining album-detail fallback and shows a live indexed-song count',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.2',
    entries: [
      ChangelogEntry(
        'Home now keeps library-sync status on the Navis logo, while Library provides the detailed progress and recovery controls',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Startup sync now waits for its signed-in server connection to become ready instead of briefly showing a false metadata-sync failure',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Refreshing a large library now brings in newly added albums immediately instead of waiting for a long artist verification cycle',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Subsonic connections now identify Navis to work reliably with strict reverse proxies',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.1',
    entries: [
      ChangelogEntry(
        'Library sync is now more reliable: background, manual, and repair requests share one coordinated operation so progress and failures stay accurate instead of briefly disappearing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Missing rolling-cache files are now detected and removed immediately before playback safely falls back to streaming, without requiring a manual library repair',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'New connections stay on Home while the library is syncing, with persistent progress and retryable failure feedback',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Repair Library and full sync now coordinate safely with startup work for a more dependable recovery experience',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.2.0',
    entries: [
      ChangelogEntry(
        'New connections now open Home immediately while the initial library sync continues in the background with visible progress and retryable failures; failed automatic syncs remain visible until a meaningful retry result replaces them',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'First-time server connections now show a cancellable initial library setup with clear progress, offline retry, and mobile-data consent',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Signing back into the same server account now safely reuses its committed local library, while switching server or account requires confirmation before local data is replaced',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Signing out now reliably stops playback and radio, clears queues and pending server work, and waits for active syncs and downloads to stop',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Playback startup now keeps loading and automatically retries transient audio initialization failures',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Mini Player now opens at a balanced 720×405, returns to that size after mode prompts, keeps volume neatly beneath its controls, and shows both resize choices in short windows',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Mini Player controls are now compact transparent right-edge buttons with icon-only hover feedback and quick panel-aware fades; they stay clear of track details and hide for Queue, Lyrics, and other embedded panels. Queue now closes with a matching smooth reverse transition, and Linux Wayland clearly explains when its compositor cannot provide always-on-top',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Navis now always starts in Desktop View and restores your last Desktop window size, even if it was closed while Mini Player was active',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Favorite, Lyrics, Queue, Mini Player, and volume now stay directly visible across every supported Desktop View size',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop and Mini Player layouts now stay balanced at unusual aspect ratios, with centered compact metadata and a firm 560×360 Mini Player minimum',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Desktop now stays in a consistent workspace down to 800×600, with its volume-ready bottom player always present and no phone-layout fallbacks',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The new same-window Mini Player keeps playback, volume, pinning, and a quick return to Desktop View available in compact windows',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'The current or loading song is now highlighted consistently across library, Home, search, downloads, artist, playlist, and queue views without shifting queue track numbers',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop clients now reopen at your previous Navis volume, including mute, and Unmute restores the last audible level',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search now keeps the best matches first while preferring music already on your server, and remote results use clearer context-aware Remote labels',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Remote labels now appear consistently in weekly recommendations, Home song lists, liked songs, artist top tracks, Match Flow, queues, and downloads without changing row alignment',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote label tooltips no longer flood desktop logs or destabilize accessibility when repeatedly shown and hidden',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The update summary now keeps every change readable when it appears over an active player view',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library repairs now fall back to the server artist index when its separate artist-list endpoint is unavailable, so compatible servers can resume safely',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Large Library Repairs now keep a fast, bounded concurrent album fallback when a server search result window cannot return every song at once',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library Repairs now continue through server-capped song-search pages instead of needlessly falling back to slow album-by-album downloads',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Manual library refresh now includes liked music, playlist headers, and genres alongside catalog updates',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Manual library refresh now resumes queued catalog work while music is playing instead of deferring the refresh behind it',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library song hydration progress now advances only after song data is safely written, while catalog discovery uses an activity indicator instead of a misleading percentage',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library setup now waits for an already-running sync instead of briefly reporting a false failure, and completed syncs keep you on the page you are viewing',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'When a viewed album, artist, or playlist is confirmed removed, its page now stays open with a Back to Library action instead of navigating you away',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Release validation now exercises live app-owned screenshots, responsive desktop states, playback indicators, volume restoration, and authentication lifecycle in isolated profiles',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Navis now uses a refreshed, precisely centred logo and background-free circular platform icons',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.1.1',
    entries: [
      ChangelogEntry(
        'Seeking on desktop no longer hangs while a track is still caching; playback stays on a seekable stream while the rolling cache fills in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Seeking back into already-heard audio on desktop is smoother and no longer forces a full stream rebuild',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.1.0',
    entries: [
      ChangelogEntry(
        'Background library sync stays on unmetered networks by default, with updates-available notices and one-time mobile-data sync when you need it',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync is adaptive and resumable: low-data checks, targeted updates, safer full repairs that apply only real changes, and better liked and playlist reconciliation',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop playback is more responsive; streamed tracks now fill the rolling cache on Linux, Windows, and macOS',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Fixed interrupted library repairs, playback startup glitches, Home refreshes during sync, and unstable seek or duration updates',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.15',
    entries: [
      ChangelogEntry(
        'Metadata sync now keeps individual artist and album failures pending, retries only unfinished items, and preserves the server cursor until verification completes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Previous-track restarts and end-of-queue Next presses now use distinct replay and boundary feedback instead of looking like a track change',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto now opens with Liked, Recent, Playlists, and Library, with reliable search, queue order, resume, downloads, and genre browsing',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.14',
    entries: [
      ChangelogEntry(
        'Clearing the final queue item now closes the fullscreen player smoothly and leaves phone Back navigation responsive immediately',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Syncing while a cached remote song is playing now transfers its verified server identity without interrupting playback or invalidating the active cache file',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library update checks now verify 48 artists per pass and continue quietly, while preserving older unchecked artists when newer server changes arrive',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.13',
    entries: [
      ChangelogEntry(
        'Library refreshes now use the server sync cursor, verify newest albums, and continue large updates in bounded batches instead of requiring Force Full Sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Cached remote songs now move to their verified server identity when an exact match becomes available, preventing duplicate local entries without risky fuzzy matching',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Sync Settings now includes Check for updates and reports whether metadata is current, still being verified, or needs repair',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Previous track now reliably restarts the current song when there is no earlier queue item, including fullscreen artwork swipes and system media controls',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Mix and Same Vibes now start from a fresh queue rooted at the current song, then keep recommendations appending at the bottom',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Adding songs near the end of playback no longer leaves the player paused or stuck at the seek position when advancing to the next track',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Opening the queue during active playback no longer triggers a provider rebuild error',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queued remote tracks now recover from stream stalls by falling back to direct playback or skipping the failed track instead of staying stuck',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Downloaded songs now pre-cache standard-size cover art so offline album and track artwork is available more reliably',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The offline server banner now switches to a quiet offline mode after repeated retry failures while continuing background checks',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'The update changelog dialog now labels bug-fix-only releases clearly and always links to the full changelog in About',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Refreshed core networking, connectivity, caching, and notification components and simplified Linux desktop media integration',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.10',
    entries: [
      ChangelogEntry(
        'Search category filters now show only matching results, so Songs no longer includes albums or artists when cached and server results are mixed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'LRCLIB lyrics now prewarm first when songs play or enter the queue, with server lyrics used as fallback when LRCLIB has no match',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.9',
    entries: [
      ChangelogEntry(
        'Artist pages now include a virtual "This is" playlist powered by up to 50 Last.fm top tracks, with unmatched tracks kept visible for search',
        type: ChangelogEntryType.newFeature,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.8',
    entries: [
      ChangelogEntry(
        'Android stable releases now clean stale build outputs and verify APK contents before publishing so self-updates install the current app code',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Retired Listen Together and Voyage configuration strings are blocked from active Android release artifacts',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist Top Tracks with Album Queue keeps the ranked resolved queue and starts playback from the tapped track',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.7',
    entries: [
      ChangelogEntry(
        'Released a fresh stable version so older 1.0.6 installs detect the Listen Together retirement update correctly',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist Top Tracks with Album Queue now show the full ranked queue immediately on Android while playback finishes preparing in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Retired Listen Together and Voyage settings are cleared during migration, including stored custom Voyage servers',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.6',
    entries: [
      ChangelogEntry(
        'Artist Top Tracks now honor Album Queue by queueing the resolved ranked top tracks and starting at the tapped song',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Now Playing and queue metadata stay on the tapped song while album-style queues finish filling in the background',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed album art loading stalling after a few covers when cached or missing artwork responses were not fully drained',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together is retired for now: Voyage backend sync has been removed and visible app entry points are hidden until the feature is redesigned',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.5',
    entries: [
      ChangelogEntry(
        'Re-introduced smart in-app updates: Forgejo/sideload Android builds can self-update, Google Play installs are redirected to the Play Store, and desktop keeps the existing updater',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Update checks now respect the auto-check setting, throttle background Forgejo requests to once every 24 hours, and record update download usage in data-usage stats',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library metadata sync tolerates missing albums and transient per-album failures instead of failing the entire scan, and automatically retries after a failed sync',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Automatic library sync now avoids daily full-library rescans, bounds noisy server index fanout, and refreshes starred/genre/playlist metadata less often to reduce background data usage',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Instant Mix now honors the legacy Subsonic instant-mix setting in Playback Settings instead of routing to Same Vibes, and active mix sessions reconcile when you switch between modes',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together now validates stored sessions on app launch — valid rooms auto-resume without a prompt, and expired or invalid sessions are cleared silently instead of showing a stale resume dialog',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together upgrades to Voyage voyage-sync.v4alpha1 for tighter multi-device sync — connection.ready handshake, explicit command frames, member.status telemetry, and playback phase tracking',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Listen Together accepts Voyage voyage-sync.v4alpha1 and the legacy sync.v4alpha1 protocol alias during server rollout',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Voyage connection errors in Configuration now show the expected and supported protocol versions when Listen Together cannot negotiate a compatible server',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Instant Mix uses the server instant-mix endpoint for 50-track batches again, Same Vibes keeps its 5-track Last.fm fills, and both modes recover instead of staying stuck loading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Library resync and playlist refresh now trigger ListenBrainz weekly playlist discovery and rematching, including on fresh installs after token validation',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz weekly playlists stay visible after matching completes, even when none of the recommendations match your server yet',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'ListenBrainz weekly playlist details now keep unavailable recommendations aligned with playable tracks and include a Match action to retry matching for one weekly playlist',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Same Vibes and Instant Mix no longer loop through repeated startup errors when only part of a recommendation batch can be queued',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Remote search3 tracks start playing more reliably after tap, including when re-selected from the library or during Listen Together queue changes',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.4',
    entries: [
      ChangelogEntry(
        'You Might Like can now include your ListenBrainz weekly recommendations, and song likes sync to ListenBrainz recording feedback when connected',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Weekly Exploration and Weekly Jams now appear as read-only virtual playlists in the playlist library, with normal play, shuffle, queue, download, and song actions for matched server tracks',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'ListenBrainz weekly matching now checks cached local songs first, limits remote search concurrency, handles duplicate exact matches more accurately, and avoids unnecessary ambiguous results',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Desktop You Might Like panels now show complete scrollable song lists for albums and weekly recommendations instead of short previews',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library pages can now be reordered from Appearance settings, with per-page visibility controls including Albums across mobile tabs and desktop library navigation',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Weekly recommendation loading is smoother, with batched matching, database writes, and UI updates to reduce stalls while recommendations resolve',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queued downloads now react when Wi-Fi-only settings or network type change, and compatible cached files are reused instead of downloaded again',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Rolling cache files can now be promoted to permanent downloads from the queue, stale missing-file cache records are cleaned up, and lower-quality cached files no longer block higher-quality download requests',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'The Previous control now restarts the current track when appropriate and only skips to the prior track near the start of playback',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Updated package dependencies including file picker, local notifications, and JSON annotations',
        type: ChangelogEntryType.improvement,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.3',
    entries: [
      ChangelogEntry(
        'Android releases are now prepared for Google Play, with Android self-updates removed, Play release tooling added, privacy information added, and release safety checks documented',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'External scrobbling now supports Last.fm and ListenBrainz alongside Subsonic/OpenSubsonic, with secure credential storage, validation, reconnect handling, and provider-aware offline retries',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Listen Together now supports custom Voyage servers that can be added, edited, selected, and managed alongside bundled server defaults',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Voyage sync recovery is more robust, with protocol v2 support, clock-sync hardening, fewer duplicate queue seeks, and safer version negotiation',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Last.fm API key configuration has been restored in Server settings so builds can include a key while still allowing user-provided keys when needed',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Instant Mix and Same Vibes recommendations now insert after the current track so they keep your queue context instead of replacing what comes next',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Search can now prefer cached local results first, reducing network use and making repeat searches feel faster',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Mobile data usage is now tracked and reduced across artwork, sync, downloads, and playback flows, with clearer usage reporting in About',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Cached-first playback can now prefer downloaded or cached audio before remote streams when a local copy is available',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Navigation intents from album, artist, playlist, search, queue, and Now Playing actions are more stable across shell layouts and back-stack transitions',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Appearance settings, exact brand accent colors, icon rendering, and color picker behavior are more consistent across light and dark themes',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto browsing and real-car validation are more robust, with clearer media IDs, safer playback rules, diagnostic tooling, and dedicated test coverage',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Permanent downloads gained custom folders, readable artist/song paths, desktop folder actions, and safer cleanup of empty download directories',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Liked-tab play, shuffle, and queue-all actions include tracks from liked albums while deduplicating overlaps and respecting filters',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Listen Together rooms, Match Flow song chains, split artist releases, player polish, faster sync, and Android Auto reliability improvements from the 1.0 release are included',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Queue appends, cached-source seek recovery, Listen Together reconnects, room exits, and compact mini-player layout edge cases are more reliable',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.2',
    entries: [
      ChangelogEntry(
        'Custom download folders for permanent downloads — pick your own destination and Navis will move existing downloads there automatically',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Permanent downloads now use readable artist folders and song filenames instead of cache-style names, and existing downloads are migrated to match',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Downloaded-song actions now support desktop right-click and include a direct shortcut to open the containing download folder',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Removing downloads now cleans up empty artist folders without deleting your configured top-level download folder',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.1',
    entries: [
      ChangelogEntry(
        'Liked-tab play, shuffle, and queue-all actions now include tracks from liked albums, while deduplicating overlaps with individually liked songs and respecting current filters',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '1.0.0',
    entries: [
      // New
      ChangelogEntry(
        'Listen Together — host or join Voyage-backed synced rooms with shared queue control, live room status in the player bar, and collaborative or host-only room setups',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Experimental Match Flow — create song chains in Playback Settings so starting one track can automatically expand into follow-up songs',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Artist pages now split main releases from featured appearances for easier browsing',
        type: ChangelogEntryType.newFeature,
      ),
      // Improvements
      ChangelogEntry(
        'Now Playing, the mini player, and compact layouts are more polished, with richer metadata navigation and better desktop media integration',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Library sync is faster and smarter — song pages load in parallel and tracks deleted from the server are reconciled locally',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto media browsing and projection support are more reliable, and cover art loading now prioritizes visible items for smoother scrolling',
        type: ChangelogEntryType.improvement,
      ),
      // Fixes
      ChangelogEntry(
        'Listen Together recovery is much more resilient — rejoin/resume, room exits, sync recovery, and listener seeking behave more reliably during disconnects',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Queue appends stay in order, cached-source seek recovery is more reliable, and compact wide mini-player layout glitches are fixed',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.9',
    entries: [
      ChangelogEntry(
        'Playback stays responsive while songs, radio streams, and queue changes are loading — stuck remote sources no longer trap the app until restart',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Player recovery is more resilient on Android — timed-out cached stream loads now fall back cleanly and background artwork/network tasks are isolated from playback control',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Lyrics lookup is now more consistent across remote and local playback — LRCLIB fallback can reuse the active track metadata even when the local source metadata path differs',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Recently played logging no longer crashes on duplicate history writes while tracks are switching quickly',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.8',
    entries: [
      // New
      ChangelogEntry(
        'User-configurable Last.fm API key — enter your own key in Settings > Configuration; no build flags required',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Android Auto: Search tab for finding music directly from your car\'s head unit',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Android Auto: Instant Mix and Instant Radio controls added to the More tab, with an Instant Mix button in the player controls',
        type: ChangelogEntryType.newFeature,
      ),
      // Changes / improvements
      ChangelogEntry(
        'Settings page renamed from "Server" to "Configuration"',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Android Auto browse tree redesigned — Home, Recent, Playlists, and More tabs replace the previous flat layout; albums are shown at the root level',
        type: ChangelogEntryType.improvement,
      ),
      ChangelogEntry(
        'Artist top tracks section is now hidden when none of the tracks are found in your library, rather than showing entries that cannot be played',
        type: ChangelogEntryType.improvement,
      ),
      // Fixes
      ChangelogEntry(
        'Scrobbling now records the correct listen time instead of the time the scrobble was submitted',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist top tracks no longer show or play songs from the wrong artists — improved matching prevents title collisions between tracks from different artists',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android Auto album art now loads reliably — fixed a race condition that caused cover art to fail downloading',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Android Auto Instant Mix now correctly applies your album queue preference and shows accurate on/off state',
        type: ChangelogEntryType.fix,
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.9.7',
    entries: [
      // New
      ChangelogEntry(
        'New startup screen — the Navis logo appears centred with an animated ring that fills as the playback engine loads, then the logo flies up to its place on the home screen in a seamless transition',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Home screen quick controls redesigned — filter toggles (shuffle, favourites) sit on the left and action buttons (Instant Mix, Radio) sit on the right in a compact chip row below the Navis logo',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Album detail screen now lists all artists individually — each name is a tappable link that opens the corresponding artist page',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Full OpenSubsonic multi-artist support — albums tagged with multiple separate artists each get their own clickable chip; compound names like "Artist A & Artist B" are split into individual links even on standard Subsonic servers',
        type: ChangelogEntryType.newFeature,
      ),
      ChangelogEntry(
        'Library automatically performs a full resync on first launch after an app update so your library stays consistent with any data changes introduced by the new version',
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
        'Android Auto home screen now shows album art behind the media controls',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed Android Auto home widget showing no controls or track info after playback started',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Fixed audio downloads occasionally failing with a file-not-found error when the rolling cache was evicting files at the same time',
        type: ChangelogEntryType.fix,
      ),
      ChangelogEntry(
        'Artist names on the album detail screen no longer overflow — long or compound names wrap naturally across multiple lines',
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
