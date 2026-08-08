# Navis Architecture Documentation

## Provider Organization

Providers in Navis follow a feature-first organization pattern to improve maintainability and reduce coupling.

### Global Infrastructure Providers

Located in `lib/src/providers/app_providers.dart`:

- **Database & Storage**
  - `navisDatabaseProvider` - Singleton NavisDatabase instance
  - `settingsRepositoryProvider` - Settings persistence
  - `appSettingsProvider` - Reactive settings stream

- **Network & Connectivity**
  - `connectivityProvider` - Network connectivity state
  - `networkTypeProvider` - Resolved network type (wifi/cellular/offline)
  - `syncNetworkPolicyProvider` - Metering-aware sync policy (background vs
    interactive vs hard probe eligibility)
  - `subsonicApiProvider` - Configured Subsonic API client

- **Audio System**
  - `audioBootstrapControllerProvider` - Audio handler initialization state
  - `audioHandlerProvider` - Active audio handler instance
  - `audioHandlerStateProvider` - Audio handler state controller
  - `playbackSnapshotProvider` - Current playback state stream
  - `playerStateProvider` - Simplified playback state
  - Linux uses the app-owned `LinuxMprisBridge` over `dbus`; Windows uses the
    app-owned SMTC bridge; Android, iOS, and macOS use `audio_service`

- **Android Auto phone projection**
  - The canonical `com.ryanheise.audioservice.AudioService` is the exported
    native `MediaBrowserService`. The plugin binds and starts that exact
    component during playback bootstrap, then delegates browse requests to the
    shared `NavisAudioHandler`.
  - `AutoMediaTreeService` builds the local database-backed browse tree. Its
    four root tabs are Liked, Recent, Playlists, and Library. Liked exposes
    quick-play actions plus liked songs/albums; Library contains Downloads
    when available, followed by Albums, Artists, and Genres.
  - Song browse IDs are opaque and retain album, playlist, liked, recent,
    download, or genre context. `NavisAudioHandler` uses that context to build
    the expected collection queue while keeping raw Subsonic IDs in playback
    and persisted queues.
  - Search merges server artists/albums/songs with local playlists, prioritizes
    songs and playlists with exact matches first, times out server work after
    eight seconds, and falls back to local results.
  - See `docs/android-auto-testing.md` for DHU validation and
    `docs/android_auto_real_car_testing.md` for trusted-store real-car checks.

- **Cache Management**
  - `rollingCacheManagerProvider` - Rolling cache manager
  - `rollingCacheBudgetBytesProvider` - Live cache size budget read for every
    cache write
  - `rollingCacheActivityProvider` - Active single-pass cache write and
    optional progress before completed-file registration
  - `rollingCacheStatsProvider` - Cache statistics
  - `permanentCacheStatsProvider` - Permanent cache statistics
  - `cachedSongIdsProvider` - Set of cached song IDs

### Feature-Specific Providers

#### Player Feature (`lib/src/features/player/presentation/`)

**queue_provider.dart**:
- `queueProvider` - Current play queue controller
- `currentQueueSongIdProvider` - Currently playing song ID
- `playNextProvider` - Add song to play next
- `reorderQueueProvider` - Reorder queue items

**player_providers.dart** (re-exports):
- Re-exports queue providers for convenience
- `lyricsProvider` - Lyrics for a song
- `playerStateProvider` - Playback state

#### Library Feature (`lib/src/features/library/presentation/`)

**library_sync_provider.dart**:
- `librarySyncEngineProvider` - Sync engine instance
- `librarySyncControllerProvider` - Sync state and controls
- `syncStaleAfterProvider` - Sync staleness threshold
- `requiredLibrarySyncModelVersionProvider` - One-time sync model `56` repair
  gate for the schema-v56 candidate-catalog contract; app build updates do not
  force full sync, and a promoted catalog satisfies the gate even when
  unavailable albums remain queued for targeted hydration
- Fresh catalog candidates clear abandoned page checkpoints for the reused
  generation. Promotion validates checkpoint-to-row counts and refuses an
  empty album candidate when the artist snapshot reports albums, preserving
  the committed catalog instead of applying an incomplete replacement.
- Candidate apply queries chunk large song-ID sets below SQLite's variable
  limit. A rolled-back `applying` generation remains resumable, allowing a
  corrected retry to reuse its fully hydrated candidate. Promotion completes
  the durable broad work item in the same transaction, so a restart cannot
  repeat the catalog scan while independent auxiliary hydration is unfinished.
- Schema-v57 promotion first classifies hidden candidate rows in resumable,
  adaptive keyset pages. The atomic visibility transaction then writes only
  inserted or changed rows once, streams unseen-song anti-joins, applies an
  indexed provisional-song identity plan, and defers cache-file unlinking
  until after commit. Unchanged catalogs therefore avoid metadata rewrites and
  large in-memory ID collections.
- Native Drift access uses WAL plus one pooled reader. Candidate collection and
  classification stay on the writer while ordinary app reads can continue,
  without a second `NavisDatabase` or candidate visibility in reactive
  providers.
- Linux profile diagnostics are available only through
  `tool/sync_diagnostics.sh`. The launcher uses a bearer-authenticated loopback
  API, isolates cloned database/cache paths for fault testing, and permits only
  non-fault-injected operations during backed-up primary certification.
- API, playback, download, and artwork response accounting captures the
  long-lived network usage meter directly. It must not read through a disposed
  provider `Ref` when connectivity rebuilds the Subsonic client mid-request.

**library_providers.dart** (planned):
- Artist, album, song providers
- Genre providers
- Album list providers

#### Auth Feature (`lib/src/features/auth/presentation/`)

**server_config_provider.dart**:
- `serverConfigProvider` - Server configuration controller
- `serverConfigStateProvider` - Server config state
- `serverConfigRepositoryProvider` - Config repository

**server_reachability_provider.dart**:
- `serverReachabilityControllerProvider` - Server reachability state

#### Retired Listen Together Feature (`lib/src/features/group_listening/`)

Listen Together / Voyage is retired for now. There are no active Listen
Together UI entry points and no active Voyage HTTP, websocket, session,
playback sync, or queue coordination paths.

### Import Guidelines

1. **Feature code should import from feature providers first**:
   ```dart
   import 'package:navis/src/features/player/presentation/queue_provider.dart';
   ```

2. **Use global providers only for infrastructure**:
   ```dart
   import 'package:navis/src/providers/app_providers.dart';
   ```

3. **Avoid circular dependencies**:
   - Feature providers can import from `app_providers.dart`
   - `app_providers.dart` may import feature modules for dependency injection
   - Use exports in feature `*_providers.dart` files for convenience

### Provider Lifecycle

- **Auto-dispose**: Most providers auto-dispose when no longer watched
- **Keep-alive**: Database and API client providers kept alive for app lifetime
- **Explicit disposal**: Audio handler and cache managers have explicit cleanup

### Testing

- Feature providers should be tested in their feature test directory
- Mock dependencies using `ProviderContainer` overrides
- Test provider state transitions and error handling

## Agent Runtime Control Plane

The agent runtime API is a non-production control and observation plane for a
real Navis process. It complements automated tests; it does not replace the UI
or introduce a second implementation of feature behavior.

The current implementation starts from `SyncDiagnosticsServer` on Linux:

1. `main.dart` accepts diagnostics only in a Linux profile build with a valid
   mode and handshake path.
2. Clone mode opens an isolated database and cache tree. Primary certification
   uses the normal profile only with the launcher's backup and mutation
   restrictions.
3. After `runApp`, the server binds to IPv4 loopback on an ephemeral port,
   creates a random bearer token, and writes its port, token, process ID, and
   mode to a mode-`0600` handshake file.
4. Authenticated feature actions run through the root `ProviderContainer` and
   the same controllers, repositories, DAOs, and audio handler as production
   interactions. Status and report endpoints expose bounded, non-secret
   observations for assertions.
5. `POST /v1/shutdown` closes the server, removes the handshake, disposes the
   provider container and diagnostics database, and exits the process.

New control-plane capabilities should remain feature-scoped, expose separate
action and status/query contracts, return structured errors, and support
deterministic completion or bounded polling. They must have server contract
tests. Direct provider or database mutation is reserved for clearly named
isolated fixture setup and fault injection; normal actions must traverse the
production path.

The security boundary is invariant across future platform adapters: the API is
unavailable in release builds, loopback-only, bearer-authenticated, short-lived,
and must not expose credentials, tokens, private server URLs, stream URLs, or
raw cloned records. Native service APIs remain authoritative for platform
integration, including MPRIS on Linux, SMTC on Windows, and Android
media-session/MediaBrowser behavior. See `docs/development-workflow.md` for the
mandatory validation loop and target-selection rules.

## UI Component Organization

### Common Widgets (`lib/src/common_widgets/`)

Reusable UI components used across features:

- **Media Display**
  - `cover_art_image.dart` - Album/artist cover art with caching
  - `hero_cover_art.dart` - Cover art with hero animation
  - `track_list_tile.dart` - Track list item
  - `album_card.dart` - Album grid card
  - `artist_card.dart` - Artist list/grid card

- **Player UI**
  - `expandable_player_sheet.dart` - Mini player ↔ now playing transition
  - `lyrics_display_widget.dart` - Synced/unsynced lyrics display

- **State Widgets**
  - `empty_state.dart` - Empty state with icon and message
  - `error_state.dart` - Error state with retry
  - `shimmer_placeholder.dart` - Loading skeleton
  - `loading_indicator.dart` - Progress indicator

- **Actions**
  - `star_button.dart` - Star/unstar action
  - `cache_badge.dart` - Cache status indicator
  - `context_menu.dart` - Bottom sheet context menu

### Hero Animation Pattern

Use `HeroCoverArt` widget for cover art that animates between screens:

```dart
HeroCoverArt(
  coverArtId: album.coverArt,
  heroTag: buildCoverArtHeroTag(
    coverArtId: album.coverArt,
    context: 'album_grid',
  ),
  width: 180,
  height: 180,
)
```

Hero tags follow the pattern: `cover_art_{context}_{coverArtId}`

Contexts:
- `album_grid` - Album grid in library
- `album_detail` - Album detail screen
- `now_playing` - Now playing screen
- `mini_player` - Mini player

### Expandable Player Sheet

The `ExpandablePlayerSheet` widget handles the mini player ↔ now playing transition:

```dart
ExpandablePlayerSheet(
  miniPlayer: MiniPlayerWidget(),
  fullPlayer: NowPlayingWidget(),
  isExpanded: isNowPlayingExpanded,
  onToggleExpanded: () => setState(() {
    isNowPlayingExpanded = !isNowPlayingExpanded;
  }),
)
```

Features:
- Smooth height animation
- Drag gesture support
- Velocity-based snap
- Fade transition for content

### Lyrics Display

The `LyricsDisplayWidget` supports both synced and unsynced lyrics:

```dart
LyricsDisplayWidget(
  lyrics: lyricsList,
  currentPosition: playbackPosition,
  onSeek: (position) => audioHandler.seek(position),
)
```

Features:
- Auto-scroll to current line
- Tap to seek (synced lyrics)
- Manual scroll with re-center button
- Graceful fallback for unsynced/missing lyrics

## Routing Structure

Routes are defined in `lib/src/routing/app_router.dart`:

### Main Routes

- `/login` - Login screen (unauthenticated)
- `/` - Home screen (default after login)
- `/library` - Library tabs (albums, artists, playlists, liked albums)
- `/library/artists/:id` - Artist detail
- `/library/albums/:id` - Album detail
- `/library/playlists/:id` - Playlist detail
- `/library/liked-albums` - Liked albums list
- `/search` - Search screen
- `/settings` - Settings screen
- `/settings/server` - Server settings
- `/settings/cache` - Cache settings
- `/settings/downloads` - Downloads queue
- `/settings/playback` - Playback settings
- `/settings/sync` - Sync settings
- `/settings/appearance` - Appearance settings
- `/settings/about` - About / update checker
- `/settings/desktop-window` - Desktop window settings
- `/settings/shortcuts` - Keyboard shortcuts reference

The retired `/settings/group-listening` path redirects to Configuration and is
not shown in navigation.

### Shell Routes

The app uses `StatefulShellRoute.indexedStack` for persistent navigation. The shell composition
mode (bottom nav vs. navigation rail) is determined at runtime by `resolveAdaptiveShellMode`
based on the current `AdaptiveContext`. On desktop, a persistent side rail and now-playing bar
are shown instead of a bottom navigation bar. The expandable player sheet is embedded directly
in the shell on all platforms — there is no separate `/now-playing` route.

### Navigation Intent

Feature code should call `NavService` from `lib/src/routing/navigation_service.dart` instead
of raw GoRouter APIs for app-level movement. `push` means the user drilled into an album,
artist, playlist, or similar entity from the current context, so Back returns to that context.
`go` means the current route is being replaced, or the user is switching to a canonical shell
branch such as Home, Library, Search, or Settings. Local dialog and sheet dismissal can continue
to use `Navigator.pop`.

Desktop mouse back/forward is powered by `navigation_history_provider.dart`. It records
normalized GoRouter locations, represents Library root sections as `/library#section`, drops
duplicate emissions, and truncates forward history after new navigation.

Player overlays are logical shell state, separate from their visual exit
transition. When playback becomes inactive, the shell clears the queue and
now-playing overlay stack synchronously, and all back handlers read that live
state rather than a value captured during an earlier build. On phone and medium
tablet layouts, the last active player presentation is retained as an
`IgnorePointer` only until its slide-down animation finishes.

## Adaptive Shell Architecture

The adaptive shell is the central coordination surface between platform, window size, and input
modality. Its implementation lives in `lib/src/routing/desktop_layout.dart` and
`lib/src/routing/app_shell.dart`.

### Layout Classification

Width buckets are resolved by `resolveAdaptiveLayoutClass(double width)`:

| Width threshold | `AdaptiveLayoutClass` |
|---|---|
| ≥ 1200 dp | `desktopWide` (desktop-first workspace layout) |
| ≥ 840 dp | `tabletExpanded` |
| ≥ 550 dp | `tabletMedium` |
| < 550 dp | `phoneCompact` |

### Shell Composition

`resolveAdaptiveShellMode` maps layout class + runtime + orientation to a shell mode:

- **Desktop runtime + wide width** → `desktopWide` mode: persistent side rail + sidebar detail pane
- **Desktop runtime + narrow width** → `phoneBottomNav` mode: compact bottom-bar player, no sidebar
- **Phone/tablet, landscape, tabletExpanded** → navigation rail
- **All other cases** → bottom navigation bar

### AdaptiveContext

`AdaptiveContext` is a value object computed once per `AppShell` layout pass and propagated
downward via `AdaptiveContextScope`. It exposes:

- `desktopRuntime` — true on Linux/macOS/Windows
- `desktopWide` — true when width ≥ 1200 dp on desktop
- `desktopLayoutClass` — the `DesktopLayoutClass` bucket (narrow / standard / wide)
- `adaptiveLayoutClass` — the shared `AdaptiveLayoutClass` for non-desktop breakpoints
- `useCompactWideLandscape` — compact landscape mode flag for phone-wide layouts

Feature screens call `AdaptiveContextScope.maybeOf(context)` to read the context without
triggering rebuilds on unrelated dimension changes.

### AdaptiveInputPolicy

`AdaptiveInputPolicy` separates capability decisions from layout decisions:

- `enableKeyboardShortcuts` — whether global shortcuts are active
- `enableRightClickMenus` — whether right-click context menus appear
- `enableHoverEffects` — whether pointer-hover visual feedback is shown

The policy is resolved from `AdaptiveContext` by `AdaptiveShell` and propagated via
`AdaptiveInputPolicyScope`. This allows feature screens to adapt their affordances
independently of layout decisions.

### Desktop Command System

`DesktopCommands` (`lib/src/routing/desktop_commands.dart`) centralises keyboard shortcut
handling. Commands are guarded before dispatch:

- **Text input guard** — shortcuts are suppressed when focus is inside any `EditableText`
  descendent, preventing transport hotkeys from interfering with search/text fields
- **Route-current guard** — shortcuts that target a specific screen only fire when that
  screen is the active route in the navigator stack

## Update Checker

The in-app update checker lives in `lib/src/features/settings/`:

- `data/update_repository.dart` — fetches the Forgejo Releases API, filters by update
  channel, parses semver, and selects the correct platform artifact using
  `detectInstallMode()`. Returns `UpdateInfo` (with `downloadUrl` and `assetFileName`)
  when a newer version is available.
- `data/update_service.dart` — downloads the release artifact into the system temp
  directory and applies the update. Distribution is resolved at runtime:
  - **Forgejo/sideload Android APK builds** (`NAVIS_SELF_UPDATE=true`) download the
    APK and invoke the system installer via a gated `MethodChannel`.
  - **Google Play installs** (detected via install-source metadata, or Play AAB builds
    with `NAVIS_SELF_UPDATE=false`) open the Play Store listing instead of sideloading.
  - **Desktop** runs a platform-appropriate apply strategy:
  - **Linux deb:** `pkexec dpkg -i` + relaunch.
  - **Linux portable / Windows portable / macOS:** extracts the archive to a staging
    directory, writes a self-deleting shell/batch script with rollback logic, launches it
    detached, and exits. The script replaces the running bundle, relaunches the app, and
    cleans up automatically.
  - **Windows installer:** launches the Inno Setup installer with `/SILENT /CLOSEAPPLICATIONS`.
- `data/update_install_mode.dart` — `UpdateInstallMode` enum and `detectInstallMode()`
  function. Detects the current install type from filesystem heuristics (e.g. presence of
  `unins000.exe` for Windows installer mode; executable under `/opt/navis` for Linux deb).
- `data/archive_utils.dart` — cross-platform archive extraction (`tar`, `ditto`, PowerShell
  `Expand-Archive`).
- `data/update_scripts.dart` — generates the platform-specific updater scripts (`.sh` for
  Linux/macOS, `.bat` for Windows). Scripts include rollback on failure and self-delete
  after successful update.
- `domain/update_info.dart` — immutable value object with an `UpdateDelivery` mode.
  `downloadUrl` holds the direct asset URL for self-update paths; Play redirects omit it.
- `domain/update_delivery_resolver.dart` — maps platform, build capability, and Android
  install source to `UpdateDelivery`.

### Write-access guard

Before starting any download, `UpdateService.canApplyUpdate(mode)` probes the target
directory for write access. If the directory is not writable (e.g. app installed to
`/Applications` by an admin user, or a read-only portable location), the update dialog
shows a "Download Manually" prompt linking to the release page instead of attempting
a doomed automatic update.

### Startup cleanup

`UpdateService.cleanupStaledUpdates()` is called on every desktop app launch. It removes
any `.backup` directories and orphaned staging dirs left behind by a previous update
script, preventing accumulation of stale files.

### Update channel

The update channel (`stable` or `dev`) is baked in at compile time via
`--dart-define=NAVIS_UPDATE_CHANNEL=dev`. The `dev` channel matches release assets prefixed
with `navis-dev-`, while the `stable` channel matches assets prefixed with `navis-`. This
ensures sidecar/dev builds never suggest a stable release as an upgrade.

The Last.fm API key used by "Same Vibes" instant mix mode is injected at build time via
`--dart-define=NAVIS_LASTFM_API_KEY=...` and read from `AppConstants.lastFmApiKey`.

## Data Flow

### Playback Flow

1. User taps album/track → `QueueController.replace()`
2. Queue controller calls `NavisAudioHandler.replaceQueue()`
3. Audio handler resolves sources via `PlaybackSourceResolver`
4. Source resolver checks: permanent cache → rolling cache → stream
5. Audio handler updates structural state through `playbackSnapshotProvider`
   plus lightweight timeline updates through `positionStream` and the
   track-keyed `bufferStateStream`
6. UI reacts to structural snapshots without rebuilding for routine position
   or buffer ticks; timeline widgets subscribe to the lightweight streams

Linux, Windows, and macOS play remote audio via direct HTTPS (Range-seekable
through media_kit/libmpv) and fill the rolling cache with a sidecar download to
the same quality-keyed path. `LockCachingAudioSource` remains the mobile
single-pass path; its local byte-stream proxy is not reliably seekable under
libmpv. Ordinary direct HTTPS playback bypasses just_audio's request-header
proxy on desktop and passes the Navis user agent to media-kit. A completed
sidecar file is registered once and remains the authoritative cache byte and
track total. `rollingCacheActivityProvider` reports the in-progress write so
Cache & Storage does not look idle before registration.

Remote stream recovery is layered. If a lock-cached remote source stalls or
fails at runtime, the audio handler rebuilds playback with a one-shot direct
stream at the current index/position (without permanently bypassing later
lock-cache plays). If a direct stream fails, the song is marked as failed and
playback advances to the next playable queue item when available. Background
phase-2 queue fill failures must not clear the active start item.

Album-style queue replacement is lazy: the active transport queue prepares the
tapped song first, then fills the remaining sources in phase 2. While phase 2
is loading, `PlaybackSnapshot.queueSongIds` can represent the pending logical
queue rather than the prepared transport queue, with
`hasPendingLogicalQueue == true`. Queue UIs should display those IDs but avoid
remove, reorder, or play-index actions until the transport queue catches up.

Playback commands use prioritized intent. Play and pause bypass seek and queue
fill work, seeks are last-write-wins, and later seeks, skips, selections, or
pauses invalidate stale recovery so it cannot resume playback afterward.
Transport persistence is coalesced in the background. Lock-cache seek recovery
uses the same two-phase queue model: load the active song as a direct stream at
the requested position, then restore the remaining logical queue in cancellable
batches. `loadingSongId` acknowledges a selection before network startup ends.

The snapshot stored on the handler still receives every timeline update, but
the broadcast snapshot stream emits only structural changes. Linux MPRIS reads
position from `positionStream`; Windows SMTC coalesces routine timeline updates
to about one per second and sends track changes and seek discontinuities
immediately. Interactive seek bars render `bufferStateStream` as a subtle
secondary track and ignore states keyed to another song. For queued songs,
`MediaItem.duration` remains authoritative while a transcoded decoder reports a
growing partial duration; the decoder duration is only a fallback when metadata
is unavailable. The inactive crossfade deck exists only while crossfade is
enabled and is created, synchronized, or disposed as that setting changes.
Its clones of lock-cached sources use direct streams so two decks never rename
the same partial cache file.

Startup waits for cache maintenance before restoring or synthesizing a queue,
so stale partial-file cleanup cannot race a new lock-cache download. If the OS
sends duplicate Play requests while the queue is empty, both await the same
fallback queue preparation instead of cancelling each other.

Now Playing commits a full directional artwork transition only for an actual
queue-index change. Previous actions that restart the current track and Next
actions at the end of the queue use a short directional snapback with
replay/end-of-queue feedback instead.

### Sync Flow

1. Callers submit a `LibrarySyncRequest` with trigger, intent, and target.
   `LibrarySyncPlanner` selects the smallest safe plan: probe, targeted
   hydration, delta reconciliation, catalog snapshot, compatibility audit, or
   full repair.
2. `AdaptiveLibrarySyncCoordinator` serializes runs, persists the chosen plan
   and provider profile, deduplicates durable work, restores interrupted work,
   measures requests/bytes, and owns cooldown/circuit policy. Targeted work
   keys are namespaced by entity kind, so equal server IDs in different
   domains remain independent. The coordinator removes that namespace before
   passing an entity ID to a hydrator or server endpoint.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   check. The response is a conditional artist index, not a change feed, so its
   cursor advances only after every candidate and hydration completes.
4. Bulk-capable providers enumerate independent album/song pages with
   `getAlbumList2` and blank or wildcard `search3`. Full-snapshot pages are
   validated and checkpointed into generation-keyed candidate tables that no
   app provider watches. A restart skips collected pages while users continue
   reading the previous committed catalog. Incompatible providers fall back to
   bounded `getArtists → getArtist → getAlbum` work using the same candidate
   boundary.
5. Unhydrated artist, album, and playlist interactions upgrade matching work to
   interactive priority instead of starting parallel hydrators. Album hydration
   normally performs one `getAlbum` request plus one song transaction.
   Background detail work adapts from two workers up to eight on Wi-Fi, four on
   other unmetered networks, and one on cellular; active playback caps it at two.
6. The transport interceptor owns at most one immediate idempotent retry and
   honors `Retry-After`. Durable work owns later attempts with exponential
   cooldown. Three consecutive failures open the endpoint circuit; user,
   reconnect, and resume triggers may probe it early.
7. Complete snapshots are generation-based. Old rows remain visible and
   reactive queries receive no candidate-page churn until all pages and
   required hydration validate. Promotion is one database transaction that
   upserts the candidate, remaps proven song identities, preserves active
   playback/cache/download dependencies, removes confirmed unseen rows, and
   advances the committed generation. Local likes and ratings made during
   collection are journaled and win over the older candidate snapshot across
   restarts and the atomic apply boundary. After promotion, unavailable albums
   continue as targeted hydration instead of rerunning the broad snapshot. Large
   deletion candidates (over 10% of an entity type or over 500 songs) require
   the same fingerprint twice. Isolated detail 404s remain candidates until a
   parent or complete snapshot confirms deletion.
8. Search and discovery metadata stays provisional. Canonical hydration uses
   same ID, one unique recording MBID, or one unique compatible exact metadata
   match. Proven aliases are applied to playback before provisional cleanup, so
   cached remote songs auto-merge without interrupting the active source; late
   cache completion also resolves through the alias.
9. Metered automation is a true hard probe: one conditional `getIndexes`
   request with retries disabled. Interactive artist/album/playlist hydration
   remains allowed with 16 MiB/response and 32 MiB/interaction budgets.
   Enumeration, audits, starred/genres/playlist-header sync, pending broad
   hydration, and Repair Library stay deferred unless the user grants an
   ephemeral one-time mobile-data override. Live network policy is re-checked
   at page and hydration boundaries; unmetered-to-metered transitions
   checkpoint and return `deferred`. Cancellation returns work to the queue.
10. Starred content and playlist headers use the 12-hour auxiliary window and
    can also run as explicit targeted planner work. Starred reconciliation
    excludes queued local star/unstar actions until they reach the server.
    Playlist headers upsert without replacing parent rows, so an unchanged
    header refresh cannot cascade-delete cached membership. The authoritative
    header list prunes confirmed server deletions and queues new, count-changed,
    or metadata-changed playlist contents for resumable targeted hydration.
    Genres refresh after catalog change/repair or weekly. Reliable providers
    keep the 12-hour newest-album probe plus a weekly rotating audit;
    incompatible providers use one bounded daily partition, never a periodic
    full scan.
11. Home ListenBrainz discovery polls the startup sync gate and uses the sync
    completion bridge for refreshes instead of subscribing the stream to sync
    progress. Its derived showcase watches the discovery stream once, avoiding
    a reactive dependency diamond during large repairs.

The provider fast/compatibility split and explicit repair terminology follow
the public principles documented by
[Symfonium](https://docs.symfonium.app/wiki/providers/sync-media-provider-data/)
and its
[Subsonic compatibility modes](https://docs.symfonium.app/wiki/providers/subsonic-opensubsonic-media-provider-configuration/).
OpenSubsonic documents the conditional full-index semantics of
[`getIndexes`](https://opensubsonic.netlify.app/docs/endpoints/getindexes/).

### Cache Flow

1. Playback starts on any native platform → `LockCachingAudioSource` writes the
   consumed stream into the rolling cache without a second download
2. On completion → `RollingCacheManager.registerTrack()`
3. Cache manager reads the current budget and enforces it via LRU eviction
4. User pins content → Download to permanent cache
5. Permanent download completion and rolling→permanent promotion pre-cache
   cover art using `kCoverArtStandardSize`
6. Identity aliases transfer valid rolling/permanent ownership to a proven
   canonical server song ID; ambiguous permanent downloads remain local-only
7. Eviction removes orphan MIME sidecars and garbage-collects unreferenced
   provisional metadata while preserving active partial files and recent
   unowned audio files
8. Playback prefers permanent → rolling → stream

## Testing Strategy

Automated tests are only the first layer for runtime-affecting work. Completion
also requires launching Navis and repeating the app-API validation loop in
`docs/development-workflow.md` from a clean isolated state.

### Unit Tests
- Provider logic
- Data transformations
- Business rules

### Widget Tests
- Screen rendering
- User interactions
- State transitions

### Integration Tests
- End-to-end flows
- Multi-provider interactions
- Database + API + UI

See individual test files for examples.
