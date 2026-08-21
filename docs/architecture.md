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

- **Android background sync**
  - `androidBackgroundSyncSchedulerProvider` and
    `androidBackgroundSyncReconcilerProvider` own only native WorkManager
    scheduling reconciliation; sync domain logic remains in the library
    planner/coordinator.
  - `navisBackgroundSyncEntrypoint` is a retained, UI-free headless Dart
    entrypoint. It loads the active encrypted credentials and builds only the
    database/API/sync pipeline through `LibrarySyncExecutionBootstrap`, the
    same production bootstrap used by foreground sync. It validates the
    opaque native profile key before any request and holds the same durable
    execution lease as foreground catalog work, so a late worker cannot run a
    replaced account or overlap a visible sync.
  - Its `BackgroundNetworkPolicyTracker` observes connectivity changes and
    refreshes native metering during the pass. The coordinator and engine
    consume that current policy at their existing eligibility gates, so a
    metered transition defers later broad work instead of retaining startup
    Wi-Fi policy.
  - If engine bootstrap fails before Dart can update the database, the worker
    writes a bounded native fallback outcome under its opaque profile key. The
    next foreground reconciliation imports it once into `library_sync_state`;
    raw errors and profile identities never cross that boundary.
  - Android scheduler state is durable and redacted: opaque work identifiers,
    state, attempts, timing, and bounded terminal categories only. Sync
    Settings presents this as requested eventual cadence, never a guaranteed
    next OS execution time. Native schedule, catch-up, and cancellation calls
    resolve only after their WorkManager `Operation` is acknowledged; an
    acknowledgement failure records `platformFailure` without replacing a
    known-good cadence or work ID. Manual-only cancellation clears its
    persisted cadence only after that acknowledgement, while relevant
    enablement/policy changes enqueue one `KEEP` catch-up request.
  - `subsonicApiProvider` - Configured Subsonic API client

- **Audio System**
  - `audioBootstrapControllerProvider` - Audio handler initialization state
  - `audioHandlerProvider` - Active audio handler instance
  - `audioHandlerStateProvider` - Audio handler state controller
  - `playbackSnapshotProvider` - Current playback state stream
  - `playerStateProvider` - Simplified playback state
  - Linux uses the app-owned `LinuxMprisBridge` over `dbus`; Windows uses
    `WindowsSmtcBridge` backed by the local `navis_windows_smtc` Rust/WinRT
    manual-SMTC adapter; Android, iOS, and macOS use `audio_service`
  - Bootstrap retries every three seconds while initialization fails. Its
    startup gate exposes cache-reset and sign-out recovery after ten seconds;
    an unauthenticated user can continue to Login without waiting for audio.
    A teardown supersedes a hung native attempt without awaiting it, and any
    later handler is disposed. If audio remains unavailable after Login, the
    next playback action opens the same non-blocking recovery sheet.
  - Android Auto can invoke Dart before `MainActivity` exists. Navis creates
    the provider container and starts audio bootstrap immediately, while
    `AndroidUiBootstrapGate` defers `SystemChrome`, notification, diagnostics
    UI, and `runApp` work until the first Android `resumed` lifecycle state.

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
  - `AndroidAutoBrowseNotifier` owns non-null child-change streams for the
    root, recent, and system-recent parents. This replaces deprecated static
    `notifyChildrenChanged` calls whose null options are rejected by AndroidX.
  - `tool/android_auto_cold_start_diagnostics.sh` validates the service-first
    contract from an external MediaBrowser client on a phone emulator before
    the physical-phone DHU projection smoke test.
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
- `library_sync_operation_ledger` retains the last 50 safe aggregate catalog
  promotions and confirmed starred-absence removals per server. The entry is
  committed with the mutation and contains only reason, timestamp and
  before/after/removal counts. Diagnostics may expose this redacted evidence;
  no entity IDs, titles, URLs, filesystem paths, or credentials are stored.
  Sync Settings streams the ledger and presents the latest operation that
  actually removed local rows, rather than the merely latest sync, so a
  following no-op check does not hide the cause of a visible disappearance.
- Automatic catalog checks use the per-server durable
  `library_sync_state.next_automatic_check_at` deadline. The controller owns
  one foreground one-shot timer that re-arms from that value; startup,
  reconnect, resume, and UI reconstruction only ask whether the deadline is
  due. They do not create independent periodic schedules. Manual checks and
  repairs bypass this automatic deadline.
- Durable sync work uses terminal `completed`, `cancelled`, `failed`, and
  `awaitingConfirmation` states. The next app lifecycle event must not revive
  a cancelled operation; only a new compatible user action reactivates it.
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
- Linux and Windows profile diagnostics use the bearer-authenticated loopback
  control plane. The Linux launcher is `tool/sync_diagnostics.sh`; Windows
  launchers must use the same clone-only, isolated database/cache contract.
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
committed generation enters Home immediately while `LibrarySyncController`
starts the first catalog check on unmetered connectivity. The normal shell
shows its durable running or failed state on Home with a retry action; offline and metered conditions retain
their retry/consent behavior. A promoted catalog clears the first-sync phase,
while isolated hydration or auxiliary gaps continue with a visible warning.
The shell may observe an authenticated session before the credential-backed
sync engine is constructed. Its automatic startup and periodic passes wait for
that engine and retry their startup pass when it arrives; only an explicit
user-triggered retry exposes a persistent unavailable-engine failure.

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

The current implementation starts `SyncDiagnosticsServer` on Linux, Windows,
and Android profile builds:

1. `main.dart` accepts diagnostics only in a supported profile build with a
   valid mode and a desktop handshake path when applicable. Android supports
   read-only `primary-certification` observation with a handshake in the app-specific
   external files directory; host tooling reaches loopback through `adb
   forward`. Clone diagnostics remain desktop-only because their isolated
   database/cache contract is filesystem-owned by the launcher.
2. Clone mode opens an isolated database and cache tree. Primary certification
   uses the normal profile only with the launcher's backup and mutation
   restrictions.
3. After `runApp`, the server binds to IPv4 loopback on an ephemeral port,
   creates a random bearer token, and writes its port, token, process ID, and
   mode to a handshake file. Linux/macOS profiles apply mode `0600`; Windows
   relies on its per-user diagnostics directory and does not invoke a POSIX
   permission command before starting the request loop. On Android, the host
   receives the handshake from the app-owned native bridge in
   `getExternalFilesDir()/navis-diagnostics`; raw Dart I/O cannot create the
   scoped-storage path. The bridge validates the bounded record and replaces
   it before the loopback server begins serving.
   The headless background-sync callback is also retained as a
   `@pragma('vm:entry-point')` root-library forwarder in `main.dart`: Android's
   named `DartEntrypoint` resolves from that root library in profile/release
   builds, then delegates to the UI-free library-sync entrypoint.
4. Authenticated feature actions run through the root `ProviderContainer` and
   the same controllers, repositories, DAOs, and audio handler as production
   interactions. Broad sync actions specifically join the production
   `LibrarySyncController`, so diagnostics cannot create a competing repair
   alongside startup or UI work. Status and report endpoints expose bounded, non-secret
   observations for assertions.
5. `POST /v1/shutdown` closes the server, removes the handshake, disposes the
   provider container and diagnostics database, and exits the process.

Clone diagnostics wrap the root Flutter application in a diagnostics-owned
`RepaintBoundary`. Android primary certification uses that same boundary only
for authenticated, read-only screenshot capture; its artifacts stay below the
sidecar's scoped external diagnostics directory, while all route and feature
controls remain disabled. `GET /v1/presentation/status` reports the live route and
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

Clone-only `POST /v1/session/connect` validates and saves a server session
through the production connection service but does not instantiate the legacy
initial-sync controller merely to build its response. The normal Home shell
therefore owns first-sync scheduling; observing a newly connected session must
not upgrade it into an interactive Repair Library request.

Cache diagnostics expose sanitized `GET /v1/cache/status`. Clone-only
`POST /v1/diagnostics/cache/corrupt` removes the backing file for a named
isolated cache entry, while `POST /v1/cache/maintenance` runs the production
cache-pruning path. Startup performs the same bulk sweep, and playback source
resolution removes an individual missing cache record before streaming fallback
so a live filesystem deletion cannot leave stale cached/downloaded UI state.
Neither endpoint returns local file paths.

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

Hero tags follow the pattern: `cover_art_{context}_{entityId-or-coverArtId}`.
Use an immutable entity ID for album art whenever one is available so shared
or missing cover art cannot create duplicate tags.

Contexts:
- `album_grid` - Album grid in library
- `album_detail` - Album detail screen
- `now_playing` - Now playing screen
- `mini_player` - Mini player

For album-detail navigation, the entry surface passes its already-rendered tag
to `NavService.openAlbumDetail(..., heroTag: tag)`. The router forwards that
tag to `AlbumDetailScreen`, which uses it verbatim so Home, Library, Search,
Artist, and Genre entry surfaces pair with the destination Hero. Deep links,
context menus, and other entries without visible source art omit the tag and
use the route-only fallback. `HeroCoverArt` preserves the source image's cache
size and clipping shape for both push and pop; destination-specific shuttles
and additional album-route travel must not replace that shared flight.

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
- `/initial-sync` - legacy recoverable first-catalog route; authenticated profiles redirect to Home
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

`appRouterProvider` owns one stable `GoRouter` instance. Authentication and
first-sync phase changes refresh its redirects in place rather than rebuilding
the router: timestamp and catalog-state updates during ordinary sync may
briefly re-evaluate session readiness, but they must preserve the current
location.

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
maximized Desktop state, Mini position, and optional Mini Player
always-on-top preference are stored in `window_state.json` v3. Navis always
starts in Desktop View, restoring those Desktop bounds even when the previous
shutdown occurred in Mini Player. Invalid Desktop
bounds and prompt-triggering expanded Mini sizes are never restoration targets.
When no valid Desktop record exists, Navis begins from the useful 1200×760
Desktop candidate and clamps it to the selected display's visible work area
(which already excludes system chrome); on a smaller work area this uses the
available area while retaining the 800×600 Desktop View minimum whenever the
area permits it. Diagnostics expose only the state-record version, restoration
source (`saved`, `fallback`, or `clamped`), and persistence completion—not file
paths or monitor identifiers.
Normal native close is intercepted until the controller has finished writing
the current state record, then released through `window_manager`; a resize
immediately followed by close must therefore retain the latest valid Desktop
bounds rather than relying on an unawaited callback.
The isolated Desktop-layout diagnostics deliberately shuts down from Mini
Player and verifies the following launch starts in Desktop View at the last
validated Desktop bounds.
Mini window controls float as compact transparent icon buttons at the top-right edge,
away from the metadata pane. They disappear whenever Queue, Lyrics, or another
embedded panel is active, so those surfaces retain unobstructed controls. The
controls fade quickly instead of popping when panel visibility changes, and
their hover feedback highlights only the icon glyph. The
compact Queue sheet remains mounted for its reverse slide/fade when closed, so
button, Back, and swipe dismissal match its entrance rather than popping away.
The
default 720×405 entry uses the richer Mini Player composition; the tight layout
is reserved for smaller usable viewports. Always-on-top is shown only when the
current platform can honour the request. Linux Wayland disables the control
because normal-window stacking is compositor-owned; its stored preference is
retained for a future supported session rather than presenting a non-functional
pin.
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
immediately. The Windows runner assigns `com.navis.app.navis` before Flutter
creates a window; the owned Rust adapter uses manual SMTC, retains and revokes
WinRT event tokens, serializes complete state writes, and omits unusable
artwork while retaining text metadata. Interactive seek bars render `bufferStateStream` as a subtle
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

Now Playing receives a handler-owned `TransportVisualCue` for every manual
Previous/Next outcome, regardless of whether it originated from touch, swipe,
keyboard, headset, or an external media session. Successful manual changes use
a 220 ms clean artwork handoff: the previous cover drops away, the new cover
settles without lateral travel, and metadata fades upward only after artwork
settles. Automatic advances use a short non-directional focus fade.
Restart-current and unavailable-edge requests retain the same artwork and use
one small dynamic-color edge pulse rather than a floating icon; no UI animation
delays audio transport. Reduced motion applies direct state changes with
accessible feedback only. The clone-only presentation API can drive these
states without starting audio or modifying a queue.

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
   `LibrarySyncController` also coalesces overlapping app-level requests onto
   one terminal result, so setup, startup, user, and reconnect callers cannot
   mistake an in-flight state for a failed sync. Pending durable work resumes
   only through the configured automatic interval or an explicit action; there
   is no short continuation timer. A queued full repair is the exception: it
   remains resumable but dormant until an explicit Repair Library action, never
   a startup, reconnect, resume, or periodic pass. Resume re-arms the periodic
   timer and submits at most its one staleness check; it never also schedules a
   startup pass. A startup or
   periodic caller also treats a not-yet-constructed credential-backed engine
   as pending rather than failure, then restarts its startup pass once the
   engine is available.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   automatic check. The response is a conditional artist index, not a change
   feed, so its cursor advances only after every candidate and hydration
   completes. An explicit refresh is not freshness-gated: it runs bounded
   delta reconciliation and always scans the first five
   `getAlbumList2(type=newest)` pages (500 entries), even when the artist
   cursor is unchanged. If that explicit request
   is made offline, its durable work remains delta reconciliation and resumes
   when an eligible connection returns; it must never be degraded to an
   indexes-only probe. On a metered connection, ordinary Check for updates
   inspects one bounded 50-album newest page and hydrates at most three changed
   albums; it never runs an artist sweep or bulk-song index. Remaining work
   waits for an unmetered connection or the user's one-time mobile-data consent
   for broad discovery. Discrepant on-server albums use ordinary song
   hydration and identity/cache reconciliation, so a new album does not wait
   behind a large rotating artist audit.
   The long-lived engine reads this policy directly from the root provider
   container at operation time; provider-local reads can retain the policy from
   an earlier offline operation after reconnect, while watching it would
   unnecessarily replace an in-flight coordinator.
4. Bulk-capable providers enumerate independent album/song pages with
   `getAlbumList2` and empty-query `search3` (the OpenSubsonic all-library
   form). Full-snapshot pages are
   validated and checkpointed into generation-keyed candidate tables that no
   app provider watches. A restart skips collected pages while users continue
   reading the previous committed catalog. Song pagination advances by each
   response's actual count rather than treating a short page as completion,
   since compatible servers can silently cap the requested result size.
   When a completed bulk index omits a stable tail because of that cap, a later
   repair can carry forward locally verified songs only when the candidate's
   core album metadata and expected song count exactly match. New, changed, or
   incomplete albums remain on the authoritative `getAlbum` fallback.
   Hydration progress advances only after an album has been written and marked
   hydrated; albums merely observed in a bulk search page are not presented as
   complete. Catalog discovery remains indeterminate because its page total is
   an estimate and does not share a stable denominator with song hydration.
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
   A foreground full-catalog repair starts its per-album fallback at eight
   workers and may ramp to 24 on idle Wi-Fi. During active playback, an
   explicit repair remains bounded at four to eight Wi-Fi workers rather than
   falling to the ordinary two-worker interactive cap, so a server
   search-result window cannot turn the repair tail into a serial crawl.
6. The transport interceptor owns at most one immediate idempotent retry and
   honors `Retry-After`. Durable work owns later attempts with exponential
   cooldown. Three consecutive failures open the endpoint circuit; user,
   reconnect, and resume triggers may probe it early. The cooldown is exposed
   as `LibrarySyncState.nextRetryAt`, populated both from persisted state at
   launch and from the terminal coordinator result. Sync Settings renders it
   separately from `nextAutomaticCheckAt`, so a normal interval and a
   failure-backoff wait cannot be mistaken for one another.
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
   the same fingerprint twice. The stale-song count is calculated only after
   candidate song collection/carry-forward; tracks belonging to an unresolved
   candidate album are retained until authoritative detail hydration succeeds.
   That fingerprint and its server-missing count are durable; Settings exposes
   the count and requires an explicit Apply library repair confirmation before
   it makes the second repair request.
   Isolated detail 404s and an album omitted from one artist-detail response
   remain candidates until a complete snapshot confirms deletion; incremental
   artist reconciliation may only add or update catalog rows.
   Starred reconciliation follows the same offline-safety principle: a local
   star absent from one successful `getStarred2` response becomes a durable
   absence candidate, not an immediate unstar. Only its second independent
   successful absence clears the local star; a returned server star or pending
   local mutation clears that candidate.
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
   Ordinary Desktop View song lists share `DesktopSongActions`: local songs
   receive direct Like and Download controls beside More at widths of at least
   1100 logical pixels, while compact widths retain More and remote-only songs
   receive no local-server controls. Whole-entity playback preserves a mixed
   supplied local/remote list without identity-canonicalizing it into local
   rows or applying ID-based Match Flow expansion, so a matched remote source
   remains in the requested queue.
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
    keep the 12-hour newest-album probe (also immediately after a changed
    cursor on an explicit refresh) plus a weekly rotating audit;
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
9. A profile migrated before library-cache-system version 2 must clear recoverable
   rolling cache and library metadata once before using the current contract.
   The app-owned modal can be dismissed, but returns on the next launch until
   successful reset and full library scan; `LibraryCacheResetService`
   deliberately preserves permanent downloads and their files. A failed scan
   leaves the upgrade pending so the app does not acknowledge an empty library.

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
