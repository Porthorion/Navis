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
  non-fault-injected operations during backed-up primary certification. The
  read-only `POST /v1/search/source-audit` route runs the real `search3` path
  and accepts bounded song-page count/offset inputs so diagnostics can verify
  server pagination. It returns only result counts plus kind, ID, display
  label, classified source, raw API flag, local-index presence, and provisional
  state; it never exposes credentials, URLs, or stream paths.
  Authenticated `POST /v1/presentation/search` drives the production Search
  providers, navigates to `/search`, waits for the final local/API merge, and
  returns only ordered IDs, relevance tiers, and source classifications for
  runtime and screenshot validation.
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
- **Keep-alive**: the database remains app-scoped; the Subsonic client is
  session-scoped and is force-closed during logout
- **Explicit disposal**: Audio handler and cache managers have explicit cleanup

### Authentication, initial catalog, and teardown

Navis retains one local server/account profile. Its stable identity is the
normalized server base URL plus trimmed username. Schema v61 stores
`server_config.is_authenticated` separately from the non-secret profile:
keep-data logout clears secure credentials and marks the row signed out without
discarding its committed catalog, sync generation, provider tuning, timestamps,
or Navis capability metadata. Reauthenticating the same identity updates that
row in place. A different identity must traverse the explicit destructive
replacement boundary before its credentials can be stored.

Routing derives a compact `SessionRoutePhase`. An authenticated profile with no
committed generation is confined to `/initial-sync`; the shell and ordinary
startup-sync owner are unavailable. `InitialServerSyncController` starts a
normal user-initiated catalog check on unmetered connectivity, waits offline,
or requests the ephemeral metered override. Completion requires a promoted
catalog and no candidate in `applying`; isolated hydration or auxiliary gaps
may continue after entry with a visible warning. Cancel awaits sync teardown,
uses the production server-data reset, signs out, and returns to login.

All logout callers use the injected, single-flight `SessionLifecycleService`.
Its ordering is API cancellation → awaited sync/download stop → playback/radio
session reset → transient UI/mix/timer reset → pending mutation/work cleanup →
optional server-data/file reset → authentication invalidation in `finally`.
`NavisPlaybackHandler.resetSession()` supersedes transport and queue work,
stops radio metadata, crossfade and cache sidecars, empties both decks and the
media session, persists an empty queue, and emits idle state. Download teardown
tracks progress writes and background cover-art/lyrics/notification tasks so
late completions cannot recreate queue state after `stopAndWait()`.

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

Clone diagnostics wrap the root Flutter application in a diagnostics-owned
`RepaintBoundary`. `GET /v1/presentation/status` reports the live route and
viewport plus post-bootstrap app readiness,
`POST /v1/presentation/navigate` drives the real `GoRouter`, and
`POST /v1/presentation/screenshot` waits for a completed, animation-settled
frame before writing a 1.0-ratio PNG below the validated artifact root. The
server creates filenames,
returns only relative path/dimension/digest metadata, and protects the
screenshots directory and files with modes `0700` and `0600`. Non-route UI uses
narrow production-controller actions such as the queue/Now Playing
`POST /v1/presentation/player-overlay`; the control plane has no generic
coordinate-click interface.
After a presentation search, clone-only
`POST /v1/presentation/search/play` can select one of that sanitized result
set through `QueueController.replaceWithSongs`; it exists only to validate the
same remote-result playback and Now Playing path used by the Search UI.

Desktop volume diagnostics use `GET /v1/playback/volume`,
`POST /v1/playback/volume`, and
`POST /v1/playback/volume/toggle-mute`. Mutations are clone-only and invoke
`PlaybackVolumeController`, which in turn applies the real audio handler and
persists through `SettingsRepository`; the control plane never writes the
settings table directly. `tool/volume_memory_diagnostics.sh` repeats this flow
across clean process restarts.

Song-row presentation diagnostics use the read-only
`GET /v1/presentation/song-indicator?songId=<id>` endpoint. It reads the same
production presentation provider as the UI and returns only indicator state,
selection, marker, app-owned semantic roles, and color roles. These values are
not a live accessibility-tree traversal. It does not return song metadata.
`tool/playback_indicator_diagnostics.sh clone` verifies current, inactive,
paused, switched-song, app-owned screenshots, and clean-restart behavior
against an isolated Linux profile.

Weekly-playlist presentation diagnostics can enable the clone-only
`cachedListenBrainzPresentation` override. The production discovery provider
then reads the most recent isolated `listenbrainz_weekly_cache` entry without
copying a secure token, making mixed local/remote rows available to app-owned
screenshots. The override never runs in primary-certification mode and neither
the API response nor runtime evidence exposes the cached username.

Authentication lifecycle diagnostics use bounded `GET /v1/session/status`
plus clone-only initial-sync retry/mobile/cancel, sign-out, and
`reset-initial-state` actions. The reset endpoint invokes production
cancellation/playback/reset services and `ServerDataResetService`; it does not
edit the database directly. `tool/auth_lifecycle_diagnostics.sh clone`
points each isolated clone at a deterministic loopback Subsonic fixture, seeds
its credential from a mode-600 diagnostics file, and exercises offline
recovery, safe promotion, screenshots, restart, real playback-to-sign-out
teardown, and setup cancellation. Clone-mode credential writes and clears stay
in memory, so these destructive actions can never clear or replace device
secure storage.

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
integration only, including MPRIS on Linux, SMTC on Windows, and Android
media-session/MediaBrowser behavior; they do not replace the Navis API for
Flutter state. AT-SPI and other external desktop/accessibility automation are
outside this control plane and prohibited unless the platform accessibility
bridge is explicitly under test with user authorization. See
`docs/development-workflow.md` for the mandatory validation loop and
target-selection rules.

## UI Component Organization

### Common Widgets (`lib/src/common_widgets/`)

Reusable UI components used across features:

- **Media Display**
  - `cover_art_image.dart` - Album/artist cover art with caching
  - `hero_cover_art.dart` - Cover art with hero animation
  - `track_list_tile.dart` - Playback-aware track list item
  - `song_playback_indicator.dart` - Shared current/loading row state, marker,
    tint, and semantics
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
- `/initial-sync` - blocking first-catalog setup for authenticated profiles
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

The app uses `StatefulShellRoute.indexedStack` for persistent navigation. On
non-desktop platforms, shell composition is selected by `resolveAdaptiveShellMode`.
Desktop runtime has only Desktop View and the dedicated same-window Mini Player;
it never renders the phone bottom navigation, expandable player sheet, or tablet
rail mini-player. Desktop View always reserves its bottom player bar, including
when playback is empty. Its right-side action region is stable from the 800 px
minimum upward: Favorite, Lyrics, Queue, and Mini Player remain directly
visible in a 44 px-target row, with mute and the full volume slider on the row
below. Contextually invalid actions keep their slots and expose localized
disabled semantics rather than changing player geometry. There is no separate
`/now-playing` route.

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

Non-desktop width buckets are resolved by `resolveAdaptiveLayoutClass`:

| Width threshold | `AdaptiveLayoutClass` |
|---|---|
| ≥ 840 dp | `tabletExpanded` |
| 600–839 dp | `tabletMedium` |
| < 600 dp | `phoneCompact` |

Desktop uses a separate classification:

| Width | `DesktopLayoutClass` |
|---|---|
| 800–1007 dp | `compactDesktop` |
| 1008–1599 dp | `standardDesktop` |
| ≥1600 dp | `ultraWideDesktop` |

### Shell Composition

`resolveAdaptiveShellMode` maps layout class + runtime + orientation to a shell mode:

- **Desktop runtime, Desktop View** → desktop workspace with persistent side navigation and bottom player
- **Desktop runtime, Mini Player** → dedicated playback surface, with no application navigation shell
- **Phone/tablet, landscape, tabletExpanded** → navigation rail
- **All other cases** → bottom navigation bar

### AdaptiveContext

`AdaptiveContext` is a value object computed once per `AppShell` layout pass and propagated
downward via `AdaptiveContextScope`. It exposes:

- `desktopRuntime` — true on Linux/macOS/Windows
- `desktopWide` — true for the desktop workspace; retained as a compatibility capability flag
- `desktopLayoutClass` — the `DesktopLayoutClass` bucket (narrow / standard / wide)
- `adaptiveLayoutClass` — the shared `AdaptiveLayoutClass` for non-desktop breakpoints
- `useCompactWideLandscape` — compact landscape mode flag for phone-wide layouts

Feature screens call `AdaptiveContextScope.maybeOf(context)` to read the context without
triggering rebuilds on unrelated dimension changes.

### AdaptiveInputPolicy

`AdaptiveInputPolicy` separates capability decisions from layout decisions:

- `enableDeterministicTraversal`
- `enableEscapeOverlayPriority`
- `enableDesktopPointerAffordances`
- `enableSecondaryClickMenus`
- `enableDesktopCommandShortcuts`

The policy is resolved from `AdaptiveContext` by `AdaptiveShell` and propagated via
`AdaptiveInputPolicyScope`. This allows feature screens to adapt their affordances
independently of layout decisions.

### Desktop window modes

`DesktopWindowController` owns `desktop` and `miniPlayer` modes above the
router-backed shell so branch stacks and playback survive mode changes. The OS
minimum is 560×360 logical pixels. Desktop View is valid at 800×600 or larger;
Mini Player defaults to 720×405 and uses both usable width and height to choose
its centered, constrained composition. Every Mini Player entry starts at that
canonical size while retaining the last Mini screen position; manual resizing
is allowed only for the current Mini session down to 560×360. Its volume row is
embedded below transport/actions and fills the metadata pane. A window-manager
size below 560×360 is blocked and automatically restored to 720×405. A 400 ms
settled resize across the Desktop boundary blocks the invalid surface and
requests an explicit mode decision. The last valid Desktop bounds, previous
maximized Desktop state, active mode, Mini position, and optional Mini Player
always-on-top preference are stored in `window_state.json` v3. Invalid Desktop
bounds and prompt-triggering expanded Mini sizes are never restoration targets.
Legacy Focus Player bounds/settings are imported once. `screen_retriever`
work areas select the display with greatest window intersection and keep the
title bar visible after display or DPI changes.

Clone-only authenticated diagnostics expose `GET /v1/presentation/window`
for mode, bounds, work area, availability, always-on-top, and pending-transition
state. `POST /v1/presentation/window` drives deterministic logical resizing,
mode selection, and transition resolution for the Linux runtime gate.

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

Desktop volume follows a parallel local-settings path:

1. Audio bootstrap hydrates current and last-audible volume from
   `app_settings`.
2. `PlaybackVolumeController` initializes the handler before queue restoration.
3. Slider changes apply immediately and persist after a short coalescing delay;
   drag completion and mute changes flush deterministically.
4. The next desktop launch restores the exact level, including zero, while
   mobile starts at the session default and does not persist volume.

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
   passing an entity ID to a hydrator or server endpoint. Automatic broad work
   defers while Navis is backgrounded or playing; an explicit user refresh may
   resume queued broad work in the foreground, including during playback.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   check. The response is a conditional artist index, not a change feed, so its
   cursor advances only after every candidate and hydration completes.
4. Bulk-capable providers enumerate independent album/song pages with
   `getAlbumList2` and blank or wildcard `search3`. Full-snapshot pages are
   validated and checkpointed into generation-keyed candidate tables that no
   app provider watches. A restart skips collected pages while users continue
   reading the previous committed catalog. Song pagination advances by each
   response's actual count rather than treating a short page as completion,
   since compatible servers can silently cap the requested result size.
   Incompatible providers fall back to
   bounded `getArtists → getArtist → getAlbum` work using the same candidate
   boundary.
   If `getArtists` is unsupported, the collector falls back to the compatible
   `getIndexes` artist index before treating the catalog as unavailable.
5. Unhydrated artist, album, and playlist interactions upgrade matching work to
   interactive priority instead of starting parallel hydrators. Album hydration
   normally performs one `getAlbum` request plus one song transaction.
   Background detail work adapts from two workers up to eight on Wi-Fi, four on
   other unmetered networks, and one on cellular; active playback caps it at two.
   A foreground full-catalog repair with no active playback starts its
   per-album fallback at eight workers and may ramp to 24 on Wi-Fi, so a server
   search-result window cannot turn the repair tail into a serial crawl.
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
   The Navis Search presentation path merges cached and API results by ID and
   orders artists, albums, and songs by relevance tier, source preference, and
   stable input order. Source preference only breaks relevance ties: exact
   remote results stay above weaker on-server matches. This ordering is not
   applied globally to `search3`, synchronization, discovery, or identity
   matching.
   External-catalog provenance is an independent persisted property:
   `isExternal: true` means the item is remote-only, while `false` means it is
   on-server even if Navis has not indexed it locally. Explicit API values win;
   only missing values use the `ext-*`, `remote-*`, and `pl-deezer-*` fallback.
   Broad snapshot candidates discard external rows. Targeted external detail
   trees remain provisional and are visible only through exact artist/album
   relationships; canonical promotion clears `is_external` when the server
   later imports the item. Cache and download ownership do not affect source.
   Remote status is rendered contextually: a neutral globe-and-Remote pill on
   browsing artwork, an inline label in dense rows and playback metadata, and
   a metadata chip on detail screens. Local/on-server media is intentionally
   unlabeled, and cache/download indicators remain separate availability
   states. Song lists use the shared `RemoteSourceMetadataLine`, which keeps
   the indicator on the subtitle line and lets long metadata truncate first.
   This contract covers Home, ListenBrainz weekly recommendations, liked
   songs, artist top tracks, Match Flow, queues, and downloads; those rows
   suppress artwork overlays and preserve the same height and alignment for
   local and remote entries. Each indicator owns one stable semantic node in
   the normal tree. The desktop hover explanation is a pointer-transparent,
   visual-only `OverlayEntry` with inherited themes and no semantic children;
   it intentionally avoids Material `Tooltip`/`RawTooltip` and their
   `OverlayPortal` semantics reparenting on Flutter 3.44.
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
