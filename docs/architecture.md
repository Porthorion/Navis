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
    when available, followed by Albums and Artists.
  - Song browse IDs are opaque and retain album, playlist, liked, recent,
    or download context. `NavisAudioHandler` uses that context to build the
    expected collection queue while keeping raw Subsonic IDs in playback and
    persisted queues.
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
  a cancelled operation immediately. A new compatible user action, changed
  evidence version, or a later due catalog observation after the configured
  interval can start new work; identical auxiliary evidence remains cancelled.
  Controller and coordinator queues also capture a cancellation generation:
  cancelling an active check invalidates a stronger repair waiting behind it.
  That waiting command cannot start after cancellation; a later explicit command
  is admitted as new intent. Only still-queued durable work is marked cancelled.
- Schema v71 adds a typed, redacted sync lifecycle beside the retained
  compatibility work mirror: `library_sync_run_request`,
  `library_sync_run_attempt`, `library_sync_run_outcome`,
  `library_sync_provider_profile`, and `library_sync_repair_session`.
  `SyncRunRequest` records a versioned origin, intent, target kind, priority,
  resumption provenance, and metered grant. The scheduler resolves it once
  into immutable `SyncExecutionPlan` endpoint/page/hydration/byte/concurrency
  limits before dispatch. Terminal history retains only enums, aggregate
  counts, and timestamps for 90 days; a target key is cleared on completion,
  so neither diagnostics nor Settings history retains IDs, titles, URLs,
  credentials, or filesystem paths.
- Schema v77 adds nullable, versioned attempt telemetry. Existing attempts retain
  unknown (`null`) evidence. The coordinator checkpoints safe counters and a
  bounded phase/transport timeline every five seconds, on phase changes, and at
  completion through the owning execution's SQL fence. Checkpoints coalesce and
  run outside nested delegate transactions; telemetry failure cannot fail a
  catalog publication. At most 32 phases and 128 transport attempts are retained,
  with omission counts and complete aggregate request/retry/byte/outcome counters.
  Preparing a new controller request clears the preceding attempt identity and
  request counters until the coordinator supplies the new correlation.
  Detail is pruned after seven days during normal terminal-run maintenance;
  aggregate outcomes retain the existing 90-day policy. Cleanup is opportunistic,
  not a guaranteed wall-clock deletion deadline. Request/attempt IDs correlate
  status and reports without including account IDs, entity IDs, URLs, parameters,
  media titles, response bodies or error messages. Routine status/history reads
  exclude the potentially larger telemetry JSON.
  `captureComplete` only means the recorder finished; the attempt row and terminal
  outcome remain authoritative, since process death can occur before terminal
  persistence. Recovered attempts retain their last checkpoint. Transport
  `envelopeAccepted` means protocol parsing succeeded, not that subsequent
  snapshot validation or database publication succeeded. Bytes are observed body
  bytes (with serialized-response fallback), not total network wire usage.
- Schema v78 stores `library_sync_state.initial_catalog_usable_at` separately
  from full-sync timestamps. A validated, promoted first catalog may be usable
  while isolated incomplete album details remain pending; the timestamp is
  written only after the full-screen controller verifies that outcome.
- `requiredLibrarySyncModelVersionProvider` - One-time sync model `57` repair
  gate. It rebuilds the complete server newest feed after the v73 external-row
  repair so persisted libraries receive authoritative Recently Added ranks.
  The repair waits for an unmetered connection, does not remove downloads, and
  a promoted catalog satisfies the gate even when unavailable albums remain
  queued for targeted hydration.
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
- Native Drift access uses WAL plus two pooled readers. Candidate collection
  and classification stay on the writer while an interactive read can proceed
  alongside a long catalog read, without a second `NavisDatabase` or candidate
  visibility in reactive providers.
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

**library_providers.dart**:
- Artist, album, song, and album-list providers shared by Library presentation
  screens.
- Route-local state and scroll/section coordination remain in the dedicated
  presentation providers beside their owning screens; do not recreate this
  former planned-file boundary in `app_providers.dart`.

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

Routing derives a compact `SessionRoutePhase`. A newly authenticated profile
without a usable catalog stays on the full-screen `/initial-sync` rebuild route.
Promotion alone does not admit Home. A complete run requires no pending album
hydration, artist verification, or candidate and durable full-sync evidence
(`server_config.last_synced` or `library_sync_state.last_catalog_synced_at`).
The sole partial exception is a validated catalog published in that run whose every
remaining canonical album was attempted in the current run and returned
incomplete detail. The controller then stores
`library_sync_state.initial_catalog_usable_at`; routing can admit onboarding
or Home across restarts without claiming full freshness. All full-screen rebuild
reasons share this partial exception. Other failed, deferred, or partial runs
keep retry and sign-out actions; offline and metered conditions retain their
retry/consent behavior. Pending albums continue through eligible incremental
checks. This policy is recorded in
[the full-screen partial-readiness decision](decisions/2026-09-20-fullscreen-sync-partial-readiness.md).
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
   scoped-storage path. Clone Android bootstrap now asks that existing native
   bridge to prepare the scoped directory before Drift opens, and checks the
   sidecar identity first. The bridge validates the bounded record and replaces
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
initial-sync controller merely to build its response. The required rebuild
screen owns the interactive first-sync request; the library controller coalesces
any overlapping automatic pass. Observing a newly connected session must not
upgrade it into an interactive Repair Library request.

Cache diagnostics expose sanitized `GET /v1/cache/status`, including whether a
mandatory cache renewal remains pending but never a cache-system version or a
file path. Clone-only
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

### Theme and design tokens (`lib/src/theme/`)

- `navis_theme.dart`: `buildLightTheme`, `buildDarkTheme` and
  `buildOledTheme` each choose a `ColorScheme` from the user's seed (or the
  dynamic album colour) and delegate to one shared builder. Typography,
  component themes and theme extensions are defined only in that builder.
  OLED differences are expressed there as surface overrides.
- `navis_tokens.dart`:
  - `NavisSpace` and `NavisRadius` are compile-time spacing and radius
    scales.
  - `NavisTokens` is a ThemeExtension for theme-dependent values: frame widths,
    hover/focus opacity, and colour roles `ColorScheme` lacks: the quiet
    warning container and the `success` foreground for completed or
    confirmed states. Read it with `NavisTokens.of(context)`.
  - Artwork radii follow the user's cover-shape preference, not these scales.
- `motion_policy.dart`: owns every duration, including the reduced-motion
  zero values.
- `dynamic_accent_provider.dart`: samples the current artwork to reseed the
  scheme when dynamic album colour is enabled.
- Fonts: the bundled Inter variable font (`assets/fonts/`, SIL OFL 1.1,
  licence registered in `main.dart`). Scripts Inter lacks use the platform's
  per-glyph fallback.
- Guard: `test/src/theme/design_token_guard_test.dart` ratchets literal radii,
  font sizes and colours per file outside `lib/src/theme/`.
- Decision record:
  [decisions/2026-09-30-design-foundation.md](decisions/2026-09-30-design-foundation.md).

### Home: You Might Like

`you_might_like_widgets.dart` (a part of `home_screen.dart`) renders the
recommendation showcase.

**Phones and tablets: a focused cover flow.**
- **Cover size:** square and uncropped, 62% of the width, capped at 260 px
  (300–320 px on tablets) and at 42% of the screen height so landscape
  still fits.
- **Neighbours:** the page controller's viewport fraction is derived from
  that size so neighbours peek. Their scale and opacity follow the page
  offset continuously.
- **Play:** only the focused cover shows Play, which calls
  `playAlbumById` in `album_context_menu.dart`. ListenBrainz picks open
  their weekly playlist instead.
- **Info panel:** `_ShowcaseInfoPanel` under the carousel crossfades the
  title (tap to open), the artist, and a line such as
  "2023 • 12 songs · Similar to your likes". `_showcaseReasonLabel` maps
  each `HomeRandomShowcaseSource` or ListenBrainz item to its reason.

**Desktop:** the art, track list and cover strip are unchanged. The panel
header adds the same reason line and a compact Play/Shuffle pair.

**Colour wash (`_ShowcaseColourWash`, both layouts):**
- `coverColourFieldProvider` (`cover_colour_field.dart`) decodes the cached
  600 px cover at 24 px (same URL and cache key as the cards, so no new
  request), averages it into a 3×3 colour grid, and keeps the result in a
  64-entry LRU.
- `CoverColourFieldPainter` draws the grid as a vertex-coloured mesh
  (`Canvas.drawVertices`). The GPU shades it smoothly at any width, where a
  stretched thumbnail pixelates on wide displays. The mesh overscans its box
  and is clipped to it.
- A veil of the page colour covers it (lighter in light themes and on
  desktop), so it needs no offscreen layer while idle.
- Changing covers interpolates the nine colours over 400 ms; reduced motion
  switches instantly.

Paging, auto-advance and the test/diagnostics keys
`home-random-hero-carousel(-page-N)` are unchanged.

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

Desktop and ordinary mobile album-detail navigation use the composed-page
180 ms `MotionPolicy.surface` fade in both directions; reduced motion is
immediate. Desktop requests omit the opening artwork tag, and the album route
enforces that policy for direct, replacement and legacy payloads too. Desktop
detail artwork uses the `album_detail` context so its fallback cannot match
the Library card's `album` tag, while the detail-to-artwork-viewer Hero remains
available. Compact mobile landscape retains its existing shared-artwork flight:
the entry passes its rendered tag to `NavService.openAlbumDetail(...,
heroTag: tag)` and the destination uses it verbatim. `HeroCoverArt` preserves
the source image's cache
size and clipping shape for both push and pop; destination-specific shuttles
and additional album-route travel must not replace that shared flight.

`CoverArtImage` applies the same aspect-preserving decode bounds to cached-file
and admitted network artwork. Ordinary thumbnails retain the existing 2× layout
budget (falling back to the requested size); hero source, flight and destination
retain their shared requested-size budget. Small source images are not upscaled
at decode time. Network rendering uses the existing `OctoImage` renderer with a
bounded `CachedNetworkImageProvider`, and returns its decoded child directly:
rebuilding an `Image` from the unresized provider would bypass the bound. URL,
disk-cache identity, load admission, clipping and provenance remain independent
of the memory decode size. `octo_image` is an explicit dependency at its existing
locked version; this introduces no new renderer or package version.

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
- `/initial-sync` - recoverable full-screen first-catalog route; it takes priority over versioned onboarding and opens Home only after complete catalog evidence
- `/library-rebuild` - mandatory and user-started recoverable library rebuilds
- `/onboarding` - full-screen, versioned first-run customization before normal authenticated routing
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

The cache-renewal gate observes a durable cache-system marker alongside the
authentication phase. An authenticated profile with an older marker is routed
to the mandatory full-screen cache rebuild before onboarding or the normal
shell. It clears only recoverable library and rolling-cache data, preserves
permanent downloads, performs a full catalog scan, and records the new marker
only after that scan promotes successfully. A failed or cancelled rebuild, or
an unreadable marker, keeps the renewal pending until it can be resolved.
Completion goes directly
to versioned onboarding when it is required; otherwise it opens Home. Ordinary
settings updates must not refresh the router.

When a successful required initial-library build or cache renewal immediately
leads to onboarding, the rebuild route carries only an internal eligibility
marker. It becomes the route-scoped `homeWarmup=1` handoff only after the
catalog has committed successfully.
After onboarding's first frame, that one session resolves the configured visible
Home order and filters, selects no more than six unique first-view covers, and
uses the same key and requested size as their Home surfaces. It uses the normal
bounded Home providers but never starts catalog sync, auxiliary refresh, or
ListenBrainz discovery. Artwork requests run one at a time at background
priority, decode only the first three covers into Flutter's image cache, and
stop scheduling when onboarding exits or the app backgrounds. The handoff is
not persisted, is skipped offline, and never runs for repair, reset, failed,
cancelled, or direct-to-Home flows.

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

Favorite, Lyrics, Queue, and Mini Player use the shared `NavisTooltip` hover
overlay, also used by Remote indicators. Their accessible label, enabled state,
and tap action stay on the stable target node. The pointer-transparent bubble
is a visual-only `OverlayEntry`: Material tooltips use `OverlayPortal`, which
can leave stale accessibility children when shown below excluded semantics
on Flutter 3.47.1. Removing or hiding the target removes and disposes its entry;
desktop action tooltips also retain long-press display. Other Material tooltips
remain outside excluded semantics subtrees.

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

### Collection pane geometry

`routing/content_layout.dart` owns pure geometry for bounded album/artist grids,
preview capacity, track-row modes, and station cards. Geometry takes the usable
content pane after navigation and padding; shell classification remains owned
by `AdaptiveContext`. Album and artist grids have no column ceiling: wider
panes add cards while minimum and maximum extents bound their size. Spare width
centers the grid, while sparse final rows retain leading alignment.
`ResponsiveContentSliverGrid` builds collection cells lazily and reserves
measured two-line artist labels at the current text scale.

Schema 81 adds `grid_artwork_size` (`auto`, `small`, `medium`, `large`) and
`home_recommendations_auto_advance` (default false). Migration translates the
legacy `album_grid_density` once: null/invalid → Auto, 1/2 → Large, 3 → Medium,
4/5 → Small. The legacy column remains for compatibility; current collection
grids use artwork size. Auto and Medium share the recommended geometry.
Settings remain installation-local. Targeted updates and full settings drafts
must preserve both new fields.

Home's recent-liked source watches the complete existing recent order; preview
callers filter downloaded content before deriving two screenfuls from pane
capacity. Liked uses one artist shelf and one album shelf before songs, and
keeps Play/Shuffle beside the song section even when only album tracks are
liked. `ContentShelf` preserves its controller on resize and shows pointer
arrows only when more content lies in that direction. Liked Albums suppresses
only its Next arrow's visual tooltip through `showNextTooltip: false`; its
localized accessible name and keyboard/paging behavior remain intact. Other
Home sampling limits remain unchanged. Album pagination checks the post-layout viewport
buffer as well as scroll events, including zero scroll extent, and stops on
loading, errors, incomplete responses, or collection exhaustion.

`AdaptiveTrackRow` and `AdaptiveTrackHeader` share pane/text-scale column
geometry. Compact rows stack metadata, medium rows separate Artist, wide rows
separate Artist and Album. Desktop columns reserve duration outside trailing
actions. Constrained mobile rows measure the formatted duration and place it at
the end of the secondary metadata line, retaining leading artwork/numbers and
48px action targets beside a flexible text block. Long metadata truncates first;
Remote labels, duration and badges may use additional lines inside that block.
Controls move below only when the remaining text area is narrower than 96px
scaled by the current text scaler, and align to the trailing edge. Duration
stays with the text. Normal artwork rows retain their 64px minimum height.
Rows with enough room keep their existing inline duration arrangement. Headers
appear only for full collections. Numbered collections set
`numberColumnExtent` to label their existing numeric area with `#` and the
accessible description Track number: 32px for album/playlist/genre/weekly
lists and 30px within the 82px Artist Top Tracks leading area. Artwork-only
lists leave it null, and compact headers stay hidden. Specialized callers
retain their queue and playlist occurrence callbacks. Artist previews explicitly
reserve 96px for their two mobile actions.
Downloaded library rows use the same presentation; transfer progress is separate.

Desktop recommendation artwork and previews are bounded; narrow desktop panes
use the existing cover card while retaining selected identity. Touch recommendations
are manual by default. The opt-in controller advances after eight eligible seconds
and pauses at least ten seconds after interaction. Home activity, route/modals,
quick search/player overlays, lifecycle, reduced motion, dragging and at-least-half
viewport visibility gate a single timer. Desktop remains manual. Data refresh
retains a stable item or chooses the nearest remaining index.

`DesktopPlaybackProgress` always presents elapsed/total times for ordinary media,
including seek previews. Measured labels sit beside the seek bar or below it;
long scaled labels can occupy separate lines. Unknown duration uses `--:--`;
radio displays LIVE. Accessibility can grow the normal 116px player without
altering transport-button sizes. Radio uses lazy bounded 280–360px station cards
(single full-width column in narrow panes), scaled name space, a safe hostname,
play/stop controls and explicit Now Playing text. Full credential-bearing stream
URLs remain playback inputs and are never displayed in cards.

The [responsive layout plan](completed-plans/Responsive_Layout_Overhaul_Plan.md)
records the completed implementation and validation evidence; implementation
is not a claim of native Android Automotive support.

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

Configurable bindings persist per action; a saved map that predates an action
keeps that action's default. Playback speed up/down/reset (`speedUp`,
`speedDown`, `speedReset`) default to the primary modifier with unshifted `.`,
`,` and `0`, because Shift changes the logical key of punctuation on many
layouts.

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

### Recommendation sessions

Song-based **Server Mix** and **Last.fm · Same Vibes** remain separate saved
choices. Server Mix calls the standard Subsonic `getSimilarSongs2` endpoint,
then the original `getSimilarSongs` when unsupported. The existing Navidrome
`getInstantMix` endpoint is a final compatibility fallback only when both
standard endpoints are unsupported. AudioMuse's installed Navidrome plugin
answers the standard similarity calls through the server; the client neither
calls AudioMuse directly nor attributes generic server results to it.

Home and Android Auto **Instant Radio** use `PersonalRadioNotifier` and the
queue-independent `RecommendationService`. Radio starts with likes and up to
60 distinct recent songs, combines server and Last.fm library matches with
familiar anchors, and fills remaining positions from eligible local songs.
Home captures Liked only and Downloaded only at start. Offline playback uses
verified permanent downloads and, unless Downloaded only is selected, valid
rolling cache files. Android Auto starts the same policy without Home filters.
The Home action awaits an actual queue insertion before opening Now Playing.

`RecommendationSessionCoordinator` owns one generation and cancellation token
across these automatic modes. Replacement queues, queue clear, internet radio,
server session changes, sign-out, or another recommendation activation
invalidate ownership. The queue controller checks ownership within its
serialized recommendation append and reports IDs actually inserted. A failed
initial fetch leaves the existing queue alone; failed initial queue commits
attempt to restore the previous queue and play state. Persisted recommendation
tracks restore as an ordinary queue after restart, without restarting refills.

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

Artist Play, Shuffle, and Add to Queue share `ArtistPlaybackController` and
`ArtistPlaybackResolver`. A transactional DAO snapshot applies the same primary
and Featured In release membership as the artist page, then selects all tracks
by album ID, including remote editions and directly credited loose tracks.
Artist metadata is refreshed through the existing targeted sync lane; only
incomplete albums request track hydration. Artist metadata refresh preserves
completed album track snapshots, including provisional remote albums. A larger
advertised track count reopens a previously complete album; mixed local/external
responses may validly contain more rows than the local count. Invalid
artist identities, duplicate release IDs, and underfilled advertised release
lists produce a partial result without replacing stored metadata.

An artist action publishes the first transactional local snapshot immediately;
known playable tracks start through the handler's existing two-phase load before
metadata hydration finishes. With no local tracks, the first available album
starts playback as soon as its target completes. Missing local releases are
hydrated first, then artist metadata is refreshed and newly advertised or enlarged
releases are hydrated. Each snapshot admits only new song IDs in a batch, so
background filling never replaces or restarts an already started queue. The
artist page shows compact progress and an optional stop-loading button; menus
close normally, navigation and playback controls remain available, and no
preparation or failure modal appears. Identical in-flight submissions coalesce;
a different artist or action starts a new selection.

The controller reserves the queue selection generation and rejects late work
after another selection, queue clear, recommendation/radio activation, session
change, or cancellation. Stopping loading preserves playback and stops further
admissions; already admitted native work and shared sync work may finish. Empty
results cannot clear the queue. Offline selection verifies permanent/rolling
cached audio through the storage locator abstraction; online remote tracks retain
direct streaming. A failed starting source advances to the next known track.
Identified tracks omitted by preparation stay in `retainedArtistQueueProvider`
as grey removable rows in both queue views, separate from native playable
indexes. These retained rows last for the current session and clear on queue
replacement/clear, radio, or account changes. Unresolved releases with no track
identities cannot create queue rows.

Play orders known releases chronologically and tracks by disc then track. Newly
loaded tracks join the upcoming queue in that order while keeping the current
song and played prefix in place: each admit is one `insertQueueRuns` edit with
one contiguous run per release. Shuffle randomizes available tracks and merges
each new batch at random upcoming positions with one `mergeIntoUpcoming` edit,
without restarting the current song. The current song and the next two keep
their place; the rest of the upcoming queue is merged in Dart after one native
range removal, so an admit costs O(1) native operations however many songs it
carries (per-song moves made a remote-heavy artist's Shuffle quadratic and
flooded the media session). After a hydrated release, the resolver re-reads
only that album (`getArtistPlaybackAlbum`) instead of the whole catalogue.
Once a user edits the queue, filling preserves that order and appends subsequent
batches. Removed song IDs are not reintroduced by later snapshots. Artist Add to
Queue uses the same incremental batches and preserves every existing occurrence;
ordering applies only to the new suffix. Native append prepares sources
independently and continues past an unavailable source or failed insertion,
then persists successful entries. Upcoming reorders also persist through the
native handler without resetting playback position.
These whole-artist actions disable Match Flow expansion to preserve the selected set
and remote source identities.

Android Auto artist playback still uses its separate local-only album traversal;
sharing this preparation policy and an appropriate car failure surface is a
follow-up, outside this phone/desktop change.

Equalizer state lives in `equalizerProvider` / `EqController`, with a dedicated
`EqRepository` and v85 `eq_presets` / singleton `eq_state` storage. The singleton
atomically persists selection, current curve, and per-preset/per-mode workspaces.
Saved presets, drafts, temporary previews, and applied audio state are separate;
master bypass does not mark a preset modified. The graph editor owns only selection
and temporary text input. Identity-bound graph sessions publish immediate working
curves, coalesce native previews, checkpoint at most every 250 ms, and flush the
final atomic workspace on release or backgrounding. Numeric previews become a
persistent draft only on Done; cancel restores the previous curve. One gesture is
one Undo step. Graph geometry maps authored parameters independently of headroom
and resolves overlapping pointer targets; import previews reuse its renderer.
`EqualizerScreen` composes presentation-only pieces — `EqGraphEditor` with its
`EqGraphPainter`, `EqBandInspector`, `EqNumberEditor`, and `EqActionBar` — and
chooses stacked or side-by-side layouts from `AdaptiveContext` and constraints;
none of them own persistent state or issue native commands directly. The root
hydrates EQ before audio creation; general settings saves omit its fields.
The handler applies typed configurations to both decks and reports desired
versus applied status. Android uses the vendored just_audio Media3 PCM processor;
Linux's tracked media-kit adapter owns a combined EQ/tempo chain. Unsupported
backends disable the entry. Modes, exact preset semantics, AutoEQ provenance,
headroom, migration, and validation limits are maintained in
[equalizer.md](equalizer.md).

Speed and pitch share a long-lived `playbackAdjustmentsProvider` controller.
Speed is stored and displayed as a multiplier (`1.00×`); independent pitch uses
signed semitones. `PlaybackAdjustments` owns `lockPitchToSpeed` and derives the
effective pitch centrally: locked engine pitch equals speed exactly, while the
readout is `12 × log₂(speed)` rounded to two decimals. Unlocking captures the
full-precision derived semitone value, preserving the sound. Speed-only reset
retains lock; combined reset applies the immutable built-in preset shown as
Normal (stored id `none`: 1×, zero pitch, lock off); new presets cannot use the
names None or Normal. The lock is labelled "Pitch Lock" ("Match pitch to speed.").

Player quick panels share `showQuickPanel`/`QuickPanelScaffold`
(`common_widgets/quick_panel.dart`): a pinned title with a live summary, an
optional header control, a scrolling body with edge fades that appear only
where more content lies, and an optional pinned footer. Desktop runtimes host it
in `showDesktopAnchoredPopover`, which grows from the anchor, draws a tail at it,
and lets the transparent barrier swallow the next click so pressing the same
button again closes the panel. Touch layouts use a content-sized bottom sheet
capped at 88% of the screen; because sheets extend behind Android's navigation
bar, the last pinned row adds the live bottom padding (3-button, gesture or
none) plus any keyboard inset.

`showPlaybackAdjustmentQuickPanel` (`playback_quick_actions.dart`) puts the same
`PlaybackAdjustmentPanel` used in Playback Settings into that shell, with its own
header and combined reset moved to the pinned header and footer. Entry points are
`PlaybackSpeedQuickButton` beside Repeat in the Now Playing transport and desktop
player bar, the Speed & Pitch row of the Now Playing settings sheet/panel, and the
compact desktop Mini Player menu. The button shows the multiplier when speed is
not 1× and tints its icon for pitch-only changes. Both quick buttons share
`quickActionGlyphSlot`, so the transport row is symmetric and Play stays exactly
centred; backends without EQ keep an invisible same-size slot. Compact rows
narrower than 360 logical pixels switch to dense slots with no gaps, drop the
quick buttons only below 296 (440 non-compact), and yield to the desktop volume
slider; the desktop bar drops EQ first below its compact breakpoint.
The transport is symmetric around Play on every platform: Equalizer, Instant
Mix (or Same Vibes, via `togglePreferredMixMode`), Previous | Play | Next,
Repeat, Speed. Shuffle reorders the queue, so it lives in the queue header
(`QueueShuffleToggle` in `features/player/presentation/queue_shuffle_controls.dart`).
While shuffle is on, `QueueShuffleBadge` marks the phone and desktop Queue
buttons, and their accessible labels read "Queue, shuffle on". The compact
Mini Player keeps Shuffle in its More menu. The phone Now Playing action row
is Queue, Like, Lyrics and Settings.
Configurable desktop shortcuts (default Ctrl/Cmd+`.`, `,` and `0`) step speed by
0.10 or reset it through `nudgePlaybackSpeed`, preserving pitch settings, and
confirm with an app notice.

`EqualizerQuickButton` sits beside Instant Mix in both the Now Playing
transport and the desktop bar, and is hidden when `eqCapabilitiesProvider` is unsupported. It opens
`showEqualizerQuickPanel`, a mini equalizer built from `EqQuickControls`
(`features/equalizer/presentation/eq_quick_panel.dart`): the on/off switch in the
header, a read-only `EqGraphEditor` response (176 px in the panel, 136 px
inline, fitted to at least ±12 dB so gentle curves stay visible, dimmed while
off) that opens the full page, and a preset `DropdownMenu` ordered Custom (only
with a draft or while selected), your presets (imports marked with headphones),
then built-ins; its menu scrolls, so any number of AutoEQ profiles stays
compact. Choosing an entry selects it with
`selectPreset(enable: true)`, so picking a sound also turns the EQ on; drafts are
kept exactly as on the full page. The Now Playing settings sheet and the wide
settings panel show the same controls inline as `EqQuickCard` in a "Sound"
section; unsupported backends keep the disabled
`EqualizerEntry` explanation. The settings sheet is a draggable
`DraggableScrollableSheet` and returns a follow-up action, so Speed & Pitch or
the Equalizer page opens only after it has closed.

`NavService.openEqualizer` records whether Now Playing was expanded or Mini
Player active and restores that when the pushed page is popped back to the same
location (not when the person navigates elsewhere). Mini Player first returns to
the full view because `/settings/equalizer` lives in the Settings branch; when
it cannot, the page is pushed over Mini Player. `NavService.closeEqualizer`
flushes edits and pops (Settings when there is no history); the desktop back
arrow and the selected "Close Equalizer" state of `EqualizerQuickButton` (shown
while `GoRouter.state` is on the page) both use it.

Existing precise settings and presets stay exact until that
control is edited; approximation markers distinguish them from the hundredth grid.
New input uses integer hundredths: rulers/arrows/accessibility actions step 0.01,
Shift+Arrow and speed buttons step 0.10, independent pitch buttons step one
semitone; holding a − or + button repeats every 120 ms and persists once on
release. Speed quick-pick chips (0.5×, 0.75×, 1×, 1.25× and 1.5×, filtered by the
backend range) select values in one tap. The chips sit in equal-width slots, so
1× stays centred. Large text falls back to a centred wrap. Presets use a `DropdownMenu` (Custom while edited, Normal,
then saved presets; unsupported ones disabled) with a ⋮ menu to save, update,
rename or delete (with confirmation) the current or originating preset. Exact entry allows two decimals and decimal
commas, validated inline.

Rulers move continuously under a fixed marker with ticks at 0.01 and labels at
0.10 (eight logical pixels per minor tick). A recessed themed surface, center
highlight and outer 15% fades keep the center readable. Release settles onto the
nearest supported tick over 140 ms with ease-out motion; the animation never
writes to the engine. Values chosen elsewhere (chips, presets, reset, the − and +
buttons, or pitch following speed) cancel any gesture and glide to the new value.
The glide eases in and out over 160–480 ms, scaled to distance, and ticks for each
line it crosses as a drag would. A read-only (locked) ruler glides silently.
Reduced motion jumps immediately. Drag accumulators clamp at
finite bounds so reversing at an endpoint responds immediately. While dragging,
`rulerTickFeedback` reports the strongest ruler line crossed per update: every
0.01 line gives a selection click (throttled to one per 12 ms of pointer time),
0.10 lines a light impact and the neutral value a medium impact; release
settling and keyboard steps stay silent, and the platform touch-feedback setting
applies. Endpoint feedback and the
available bounds appear only once a limit is reached, explaining the disabled
button. With Pitch Lock on, the pitch heading shows a link icon ("Follows playback speed" as tooltip and label), the ruler is read-only at full contrast (`AdjustmentRuler.readOnly`) and still glides with speed, and the inert −/Reset/+ row is hidden; unsupported
backends hide the pitch control and lock and show a single availability note.

Capabilities follow the initialized backend, including debug macOS and fallback.
Android Media3 limits speed/pitch factors to 0.1–8. Desktop media-kit uses mpv
pitch (0.01–100) and scaletempo speed/pitch ratio (minimum 0.01). Selectable
ranges account for the other value and lock mode, rounding finite ends inward
onto hundredths while retaining genuinely unbounded ends. Invalid pairs are
rejected before native setters. Unsupported linked presets remain saved and
visibly unavailable. Restoration retains supported speed with unchanged pitch
and a notice; it does not rewrite presets.

The controller coalesces previews, serializes application and database writes,
and flushes on interaction completion and panel dismissal. Handler confirmed
adjustments streams (including platform wrappers) propagate outside/OS speed
changes into shared state and persistence without replaying setters or overwriting
newer previews. Legacy direct speed setters read the latest pair inside the
handler lane. Both decks, recreation, source recovery and swaps preserve the
pair and lock mode. Native failure rolls both values back; storage failure remains
visible and retryable. Queue clearing does not reset adjustments.

General settings saves omit controller-owned fields, preventing stale autosaves
from overwriting adjustments. Schema v82 introduced pitch, user preset JSON and
selected identity; the stepwise v82→83 migration adds lock defaulting to false.
Older JSON without the flag remains independent and preserves exact values.
Presets retain lock mode and use unique names ignoring case; None is reserved,
immutable and derived in code. Manual edits become Custom with an originating
preset for explicit Update. Deletion keeps the sound; settings reset retains
user presets.

The vendored media-kit adapter verifies the actual mpv pitch and filter scale
because upstream setter errors are logged rather than thrown. Verification failure
propagates to the handler's paired rollback and the UI. The existing progressive
stream force-seekable customization remains in place.

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

Remote stream recovery is generation- and song-scoped. A failed remote source
receives one retry at its current (or user-requested seek) position: a
lock-cached source rebuilds as a direct stream, while a direct stream reloads
at that position. A second failure marks the song failed and advances to the
next playable queue item when available. Seek recovery also detects a remote
seek that landed correctly but remains buffering. Background phase-2 queue
fill failures never reload or clear the active start item.

Album-style queue replacement is lazy: the active transport queue prepares the
tapped song first, then fills the remaining sources in phase 2. While phase 2
is loading, `PlaybackSnapshot.queueSongIds` can represent the pending logical
queue rather than the prepared transport queue, with
`hasPendingLogicalQueue == true`. Queue UIs should display those IDs but avoid
remove, reorder, or play-index actions until the transport queue catches up.
Player transport controls distinguish that background queue fill from an
unready selected remote source. They also show remote buffering after the
queue operation ends and use the pending target ID while the previous song's
metadata is still visible. A ready selected source keeps its play/pause icon
even if the rest of the queue is still filling.

#### Released queue window

Long queues are not handed to the native player whole. `NavisAudioHandler`
keeps `_queueItems` and the native playlist one to one (so a logical index is
the native index for everything the player holds) and keeps later songs in a
Dart-only deferred tail (`NavisQueueWindow`, `navis_queue_window.dart`).
Replacing, restoring, or rebuilding a queue longer than 256 songs materialises
the prefix and 32 songs after the start song; the rest is deferred. When fewer
than 12 materialised songs remain after the current one, one page of 32 is
released with a single `addAudioSources` append. Releases run as idle queue
lane work and never cancel a user command. `PlaybackSnapshot.queueSongIds`
always lists the whole logical queue, so the Queue UI shows and edits every
song; tapping a deferred song within 64 of the window releases through it and
seeks, farther taps rebuild the player around it, and removes and reorders
inside the tail are Dart-only. Songs that cannot be resolved when released are
dropped, except that a song that is only unplayable for now (offline without a
cached copy, or no server session) stays deferred with every song after it and
the release backs off and retries. Turning shuffle on releases the whole tail first (native shuffle
orders only what the player holds), and repeat-all stays off natively until
nothing is deferred, so the player never wraps early; the reported repeat mode
is the user's. `GET /v1/playback/status` reports `materializedLength`,
`deferredLength`, and release counters. Known limit: restoring at, or jumping
to, a far index still materialises the prefix before it. Remote rows keep
their own row whenever a materialised song returns to the tail (reorders,
deferred ranges, far jumps, seek recovery, crossfade deck sync): the
handler remembers the rows of materialised remote songs instead of re-reading
their ids, which would drop them or swap in a matched local song.

Every native queue edit runs under a timeout, including single removals and
moves. A timeout rebuilds both players, which leaves the active one empty, so
queue edits reload the materialised queue into the rebuilt player at the same
song, position and play state before the edit reports its failure, keeping
later edits in the lane consistent. Songs past the release window go back to
the tail. An edit the Dart queue applied first (remove, move) stays applied;
an insert that timed out is not applied.

The queue lane (`NavisSupersedingLane`) has four kinds of work. Replacements
supersede everything; navigation cancels replacements and idle work but lets
queued edits finish first; edits (add, play next, remove, reorder, merges,
alias updates) run in FIFO order and are never silently dropped; idle work
(tail releases) runs only on an empty lane. Edits apply one batched native
call where possible, fall back to per-song inserts only when a batch fails,
and coalesce their queue save (at most 2 s); navigation keeps a pending
coalesced save, so an edit followed at once by a skip is still persisted. A successful native call made by
an edit is always committed even if a newer command superseded it, so the
Dart queue never diverges from the player.

Phase 2 resolves sources concurrently within a batch (8 songs first, then 64)
and applies each batch with one `addAudioSources`/`insertAudioSources` call:
every native insert re-sends the whole shuffle order and rebuilds the player
sequence, so per-song inserts were quadratic in queue length. Songs after the
selection are appended before the prefix is inserted, so the next track is
ready for gapless playback first. The handler subscribes to just_audio's
shuffle and loop streams with `distinct()`: they are derived from the sequence
state and otherwise re-emit on every insert, each queueing a full queue-state
write. `GET /v1/playback/status` reports `queueFill` stage timings,
`playerSequenceLength`, and persistence-lane counts (`persistence`,
`slowPersistence`) without song identities. On desktop, media_kit/libmpv still
cost roughly linear time per inserted child; the released window keeps that
cost to the materialised part of a queue.

A saved queue larger than 64 songs is restored the same way at startup: the
current song is prepared at its saved position first, and the rest is filled
in the queue lane, so handler readiness and media-session Play do not wait for
every source. A restore timeout keeps the saved queue instead of deleting it.
Permanent-download pruning and orphan rolling-file cleanup still run before
readiness because they guard partial-file ownership.

On Android and Apple platforms audio_service is given
`RealTimeProjectionAudioHandler`, a `CompositeAudioHandler` around the real
handler; the app itself keeps the unwrapped handler. The app, lyrics and
seeking use track time with a separate speed, but Bluetooth AVRCP has no rate
field and many head units, headphones and lock screens tick at 1×. The
projection therefore publishes position, buffered position and duration
divided by the speed, reports 1×, and multiplies system seek requests back to
track time. At 1× it forwards values unchanged, and metadata is republished
only when the item or speed changes. The projection also publishes the system
queue as a window of about 100 songs around the current one, republished only
when those songs change, and maps system queue indices (`skipToQueueItem`,
`removeQueueItemAt`, `insertQueueItem`, `playbackState.queueIndex`) to the full
queue. audio_service sends the whole list over the platform channel on every
queue change, and on Android the platform thread is the UI thread. Linux MPRIS
keeps the spec's track-time
Position and publishes Rate on every speed change. Windows SMTC has no rate,
so `WindowsSmtcBridge` publishes its timeline in real listening time and
converts SMTC seek and skip requests back to track time.

A scrobble and play-history session belongs to the playing queue entry: songs
inserted, released, or moved before it shift its index without starting a new
session, and neither does refreshing its metadata in place.

Queue replacement prefetches lyrics only for the selected song and the next
two; batched artist admits prefetch none. `lyricsProvider` watches just the playing item's lookup metadata, so a
track change or artwork re-emit does not re-run every cached lookup.

Each selection keeps a bounded, redacted startup timeline in the handler. A
remote Search selection starts it before provisional database writes. The
handler then records source resolution, selected-source apply, player readiness,
and the first advancing position. `GET /v1/playback/status` exposes the latest
16 attempts as `startupAttempts` for authenticated diagnostics; those entries
contain elapsed milliseconds and source kind but no song ID, title, or URL.

Playback commands use prioritized intent. Play and pause bypass seek and queue
fill work, seeks are last-write-wins, and later seeks, skips, selections, or
pauses invalidate stale recovery so it cannot resume playback afterward.
Rapid manual Next/Previous requests update a handler-owned desired queue index
from the previous desired index. The queue mutation lane stays owned by one
handler for its lifetime and retains at most one pending replacement, so
cancelled queue work cannot overlap a newer queue mutation on the same player.
During lazy queue fill, manual navigation prepares the requested logical entry
first and then resumes filling the rest. Queue fill tracks the selected entry
by occurrence, so repeated song IDs keep the intended queue position. When
`just_audio` ignores an indexed seek during loading, the handler reloads the
complete source list at the requested index. The snapshot exposes
`pendingQueueIndex` until that transition is confirmed. Desktop sidecar cache
attempts use separate HTTP clients and partial files; cancellation closes the
old client before a new attempt can publish the same cache path.
Transport persistence is coalesced in the background. Queue and position writes
use one ordered persistence chain, so an older delayed position write cannot
commit after a newer queue replacement. The accepted logical queue is saved
after the selected source loads, before background playlist fill completes. On
cold start, the retained server session is hydrated before the audio handler
restores the queue; remote sources are not misclassified as unavailable while
credentials are still loading. Lock-cache seek recovery uses the same two-phase
queue model: load the active song as a direct stream at
the requested position, then restore the remaining logical queue in cancellable
batches. Completed-state Play restarts the queue only after the final prepared
item; it cannot restart a queue that is still filling. `loadingSongId`
acknowledges a selection before network startup ends.

The tracked desktop `just_audio_media_kit` adapter retires an old load waiter
when a new source replaces it. Its queue insertion moves the actual appended
index, keeping libmpv and just_audio playlist order aligned during rapid fill.

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

1. Callers submit a versioned `SyncRunRequest`; the current
   `LibrarySyncRequest` remains a one-release compatibility adapter at the
   outer boundary. The request distinguishes automatic catalog checks, manual
   catalog checks, Repair Library, target hydration, and auxiliary refreshes.
   `LibrarySyncPlanner` selects the smallest safe plan: probe, targeted
   hydration, delta reconciliation, catalog snapshot, compatibility audit, or
   full repair. The scheduler admits one immutable `SyncExecutionPlan` per
   run, including its endpoint allowlist and data/concurrency budget.
2. `AdaptiveLibrarySyncCoordinator` serializes runs, persists the typed
   request/attempt/outcome lifecycle and the chosen plan, mirrors legacy work
   during the compatibility release, restores interrupted attempts, and
   persists provider-profile and repair-session observations. It still uses a
   compatibility executor adapter internally; execution receives the selected
   immutable plan rather than reconstructing the operation from display text
   or checkpoints. The coordinator deduplicates durable work, measures
   requests/bytes, and owns cooldown/circuit policy. Targeted work
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
   engine is available. When an explicit Check for updates reaches a deliberate
   page, entity, request, byte, or duration limit after doing work, it returns
   `partial` and preserves its checkpoint for the next pass. The same limit on
   automatic work remains `deferred`; offline, metered, playback, and
   background policy gates always remain `deferred`.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   automatic check. The response is a conditional artist index, not a change
   feed, so its cursor advances only after every candidate and hydration
   completes. An explicit refresh is not freshness-gated: it runs bounded
   delta reconciliation and always scans the first five
   `getAlbumList2(type=newest)` pages (500 entries), even when the artist
   cursor is unchanged. Their server positions are the primary Recently Added
   order; entries outside the observed feed sort only by server `created`,
   never a device synchronization timestamp. A full repair pages the complete
   newest feed into the hidden candidate and rejects repeated pagination before
   atomically promoting its ranks. If that explicit request
   is made offline, its durable work remains delta reconciliation and resumes
   when an eligible connection returns; it must never be degraded to an
   indexes-only probe. A queued automatic probe also remains queued rather
   than replacing an explicit discovery request. On a metered connection,
   ordinary Check for updates inspects one bounded 50-album newest page and
   hydrates at most three changed albums; it never runs an artist sweep or
   bulk-song index. Remaining work
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
   interactive priority instead of starting parallel hydrators. Artist detail
   compares its visible album count with the server-advertised count and fetches
   `getArtist` when the artist is absent, incomplete, or has no advertised
   count; its explicit refresh always requests that exact artist rather than a
   broad catalog run. Artist hydration stores the complete release metadata
   tree, while album hydration remains lazy and normally performs one
   `getAlbum` request plus one song transaction. Releases retain their stable
   provider IDs even when titles match, so distinct editions are never hidden.
   Background detail work adapts from two workers up to eight on Wi-Fi, four on
   other unmetered networks, and one on cellular; active playback caps it at two.
   A foreground full-catalog repair starts its per-album fallback at eight
   workers and may ramp to 24 on idle Wi-Fi. During active playback, an
   explicit repair remains bounded at four to eight Wi-Fi workers rather than
   falling to the ordinary two-worker interactive cap, so a server
   search-result window cannot turn the repair tail into a serial crawl.
   Multi-album detail batches yield during song-row conversion while keeping
   reconciliation and identity matching on the complete fetched batch.
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
   Promotion creates review entries for retained unavailable songs without
   replacing existing review decisions, including when the promotion is retried.
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
   relationships; an individual album-detail response is content authority
   only and cannot override already persisted catalog membership or parent
   artist metadata that it omits or contradicts. Canonical promotion clears
   `is_external` only when a catalog-authoritative snapshot later observes the
   item on-server. Cache
   and download ownership do not affect source. Schema v73 repairs legacy
   `ext-*`, `remote-*`, and `pl-deezer-*` rows that were stored as local before
   provenance became reliable, so they no longer leak into Home or Albums.
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
   it uses the shared `NavisTooltip` to avoid Material `Tooltip`/`RawTooltip`
   and their `OverlayPortal` semantics reparenting on Flutter 3.47.1.
   Browsing song rows share `DesktopSongActions`: the enclosing adaptive row's
   wide mode shows local Like and Download beside More; compact and medium
   modes retain More. Mode depends on usable pane width and text scale. Generic
   callers without a row scope retain the 1100px window-width fallback.
   Remote-only songs receive no local-server controls. Whole-entity playback preserves a mixed
   supplied local/remote list without identity-canonicalizing it into local
   rows or applying ID-based Match Flow expansion, so a matched remote source
   remains in the requested queue.
9. Metered automation is a true hard probe: one conditional `getIndexes`
   request with retries disabled. Interactive artist/album/playlist hydration
   remains allowed with 16 MiB/response and 32 MiB/interaction budgets.
   Enumeration, audits, starred and playlist-header sync, pending broad
   hydration, and Repair Library stay deferred unless the user grants an
   ephemeral one-time mobile-data override. Live network policy is re-checked
   at page and hydration boundaries; unmetered-to-metered transitions
   checkpoint and return `deferred`. Cancellation returns work to the queue.
10. Starred content and playlist headers are independent auxiliary targets.
    Typed catalog checks and repairs do not update them as incidental work;
    their user-facing states are **Updating liked items** and
    **Updating playlists**, not catalog-sync progress. A scheduled catalog
    check drains each due target (12 hours), preserving its separate playback,
    foreground, offline, metered-network, retry, and backoff policy. An
    explicit Check for updates or Repair Library always drains both companion
    targets with explicit intent, including while playback is active, but still
    respects offline and metered-network limits. Durable per-target completion
    and backoff control freshness independently; a failed auxiliary target
    neither repeats a committed catalog nor suppresses the other target. The
    auxiliary freshness clock is the single
    `library_sync_state.lastAuxiliarySyncedAt` column: the typed coordinator
    advances it from completed starred/playlist-header work rows, the legacy
    combined-run path advances it through a monotonic
    `markAuxiliarySyncedAt` writer, and the retired per-server
    capabilities-JSON timestamp is no longer read or written. The
    catalog circuit breaker does not suppress these independent endpoints.
    Genre metadata is not a synchronized domain because Navis has no consumer
    for it. A legacy queued genre target is marked complete during recovery;
    cached genre rows remain untouched for compatibility and no `getGenres`
    request is scheduled.
    Starred reconciliation
    excludes queued local star/unstar actions until they reach the server.
    Playlist headers upsert without replacing parent rows, so an unchanged
    header refresh cannot cascade-delete cached membership. The authoritative
    header list prunes confirmed server deletions and queues new, count-changed,
    or metadata-changed playlist contents for resumable targeted hydration.
    Explicit favorites include referenced external/provisional identities while
    ordinary library enumeration remains canonical. Membership in a starred
    snapshot counts as a favorite even when its optional timestamp is absent.
    Eligible automatic catalog checks inspect at most two newest-album pages
    each configured due interval, even with an unchanged artist cursor; manual
    checks inspect at most five. A recorded discovery-debt streak
    (`libraryDiscoveryDebtStreak`, persisted per server when a check hits its
    page cap without ever reaching known, unchanged content) keeps the probe
    on schedule and widens the automatic window to five pages until known
    content is reached; a streak past the escalation threshold
    (`discoveryDebtEscalationStreak`) hands deep discovery to a queued delta
    reconciliation. Automatic discovery defers during playback or
    hidden foreground execution, and metered automation remains a hard probe.
    Reliable providers also run a weekly rotating audit;
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
[`getIndexes`](https://opensubsonic.netlify.app/docs/endpoints/getindexes/) and
the [`getScanStatus`](https://opensubsonic.netlify.app/docs/endpoints/getscanstatus/)
contract.

#### Scan awareness, catalog availability, and identity recovery

- **Scan detection.** The scheduled probe reads `getScanStatus` once per
  eligible check (no separate polling loop) through the typed
  `SubsonicApiClient.getScanStatus`. Standard `scanning`/`count` fields are
  supported; Navidrome's optional `lastScan` supplies the scan token. A newly
  completed token opens one pending reconciliation (`library_scan_observation`)
  that flows through the existing probe → snapshot path, and collection
  re-observes the token before promotion: if a scan landed mid-collection, the
  candidate's completeness evidence is withheld, the ledger records
  `scanChangedDuringCollection` (with a per-server deferral streak in
  `libraryScanDeferralStreak`), and the resumable planner recollects. After
  three consecutive deferrals the engine waits a bounded window for a running
  scan to finish and releases the promotion once the server is quiet
  (`scanChurnCapRelease` ledger entry) so a continuously rescanning server
  cannot defer full-sync promotion forever. Servers
  without the endpoint are recorded once as unsupported and stay on the
  existing discovery/audit mechanisms.
- **Catalog availability.** Songs, albums, and artists carry a typed
  `catalog_availability` (`present`/`suspectedMissing`/`confirmedMissing`).
  Transport, authentication, rate-limit, and decoding failures never advance
  availability toward missing; only validated catalog evidence does. Items
  that disappear from a validated snapshot but still own user state —
  favorites, ratings, history, queue/playlist references, download ownership,
  or pending mutations — are retained as confirmed-missing instead of being
  deleted (previously only permanent downloads survived). Their
  `serverDeletedAt` marker keeps them out of normal Play All, shuffle, and
  download selection while review entries in `library_recovery_review` keep
  them recoverable; the legacy `removeServerSongsForPromotion` contract is now
  `retainOrRemoveServerSongs`. An isolated media-fetch 404/410 during a
  download records `suspectedMissing` on rows still reading as present —
  suspicion never hides content or advances toward confirmed absence.
  Promotion rewrites re-observed rows with cleared absence markers, and bulk
  selection excludes only validated-absent rows without a complete local
  copy, so offline favorites stay selectable (`_selectableForBulkUse` in
  `LibraryDao`).
- **Identity recovery.** `SongIdentityReconciler` matches on same ID, unique
  recording MBID, then exact normalized title/artist/album with the existing
  three-second duration tolerance — with two hard rules: contradictory
  non-empty MBIDs prohibit metadata-only matching, and ambiguity never merges
  regardless of page order. Matched claims buffer during canonical paging and
  apply at `finalize()` only after the complete replacement set is observed:
  a candidate contended for by several canonical rows is ambiguous for every
  claimant, and a same-identity claim keeps precedence over contested weaker
  claims (targeted hydration finalizes per album batch; promotion finalizes
  across the full candidate set). Candidate sets include retained confirmed-missing
  rows so a later scan can relink them. `remapSongIdentity` merges user state
  with local precedence (a carried like keeps its original timestamp and is
  re-queued to the server through `star_sync_queue`), transfers absence
  evidence, local mutation journals, and writes both the legacy and the typed
  profile-scoped alias tables (`entity_identity_aliases`). Cache and download
  ownership validation is storage-kind aware: Android SAF content URIs are
  validated through the platform bridge, never `File.exists()`.
- **Album/artist relinking.** Candidate staging tables carry
  `release_mbid`/`artist_mbid` (schema 80) promoted from OpenSubsonic
  `musicBrainzId` fields; `EntityIdentityReconciler` runs inside the
  promotion transaction after rows are preserved and before stale-row
  deletion, and maps albums/artists only from a unique stable MBID on both
  sides or an unambiguous song-membership mapping with compatible metadata.
  `remapAlbumIdentity`/`remapArtistIdentity` move song and album references,
  transfer star queue entries, absence evidence, and local mutations, merge
  favorites and ratings with local precedence, and record typed aliases.
  Evidence-less or contested rows keep their user state as provisional rows
  and become review entries with typed reasons.
- **Recovery review.** Pending entries (with evidence generation, reason, and
  saved metadata) surface in Sync Settings → Unavailable items
  (`/settings/unavailable-items`) for songs, albums, and artists with typed
  reason labels. Find match searches the current catalog for any entity type;
  every selection opens a preview dialog showing old and new metadata plus
  the exact references the remap carries over (downloads, playlists, history,
  queue, pending annotations, following songs) before applying through the
  same transaction as automatic recovery, and apply-time revalidation rejects
  a selection whose replacement no longer exists. Entries with recorded
  replacement candidates offer a possible-replacements action. Keep for later
  and Remove from Liked are unchanged. Sync evidence never overwrites a user
  disposition.
- **Repair sessions.** Ordinary Repair Library runs non-blocking from Sync
  Settings. The coordinator owns an in-memory repair session whose
  mobile-data grant is applied at admission — before planning or durable work
  is joined — and survives retries and reconnects within the run. The grant is
  never persisted: completion, cancellation, sign-out, account change, and app
  restart all clear it. The blocking rebuild screen remains only for initial
  login, destructive cache reset, cache upgrade, and playback recovery, where
  no usable catalog exists.
- **Post-upgrade reconciliation.** Bumping `currentLibrarySyncModelVersion`
  arms the startup reconciliation for upgrading installations: the next
  launch schedules exactly one resumable full repair (deferred on cellular
  per policy), and the new version is stamped only when the repair finished
  with a promoted catalog, so a failed attempt retries on the next launch.
- **Artwork identity.** Cover-art cache keys compose cover ID, requested size,
  and a per-entity targeted refresh revision
  (`coverArtImageCacheKey(id, size, revision)`). Revision zero keeps the
  legacy key layout, so existing offline artwork survives the migration.
  Explicit repairs bump the revision only for entities whose server row
  changed — cards, queue surfaces, and the viewer pass the row's revision
  into `CoverArtImage`, so a bump refetches exactly those entries without
  global cache clearing — and the cover-art file service rejects
  HTTP-success payloads whose content type is not an image so error pages
  are never cached as artwork.
- **Artwork failure recovery.** Fetch failures carry a typed category
  (`CoverArtFailureCategory`): missing reference, auth rejection, network
  timeout, invalid payload, or decode failure. `CoverArtRecoveryCoordinator`
  evicts a corrupt or invalid cache entry exactly once per key for a single
  bounded refetch, and coalesces one entity-metadata refresh per missing
  cover reference (cooldown per cover identity per session) routed through
  the sync engine's targeted hydration so widgets retry the resulting cover
  identity.

### Cache Flow

1. Playback starts → on Android/iOS `LockCachingAudioSource` writes the
   consumed stream into the rolling cache without a second download. Desktop
   (media_kit) cannot seek that proxy, so it streams over HTTPS while a
   sidecar download fills the rolling cache: each uncached track is fetched
   twice (a FLAC is typically 25–50 MB, and transcoding runs twice on the
   server). This is a deliberate cost of seekable desktop playback.
2. On completion → `RollingCacheManager.registerTrack()`
3. Cache manager reads the current budget and enforces it via LRU eviction
4. User pins content → Download to permanent cache
5. Permanent download completion and rolling→permanent promotion pre-cache
   cover art using `kCoverArtStandardSize`
6. A custom permanent-download root is user-owned: Navis records known files
   in its root `.navis-downloads.sqlite` sidecar and can adopt existing files
   only after an explicit preview/confirmation. The sidecar maps relative file
   paths to a profile fingerprint and song ID. Paths inside a download folder
   are compared by key (`DownloadRootIdentity`): the path relative to the
   folder with `/` separators, reached through either the configured or the
   link-resolved spelling of the folder, and case-insensitive on Windows only.
   Sidecar keys written with `\` by older builds still match and are rewritten
   on the next write, and moves never treat the same file under another
   spelling as a separate destination. Supported media tags are a
   best-effort additional identity source. Unknown, ambiguous, and
   profile-mismatched files remain untouched. A transfer is written to
   `<final name>.navis-part` and renamed into place (with retries while
   Windows antivirus holds the new file) only after it completes, then
   tagged and registered, so an interrupted download never appears under a
   song's name. Startup after interrupted downloads removes `*.navis-part`
   files, and only those, from the active folder without following links;
   folder scans ignore them. Promoting a rolling-cache file reuses an
   existing destination only when its size matches. Resetting server data (a full
   sign-out or server switch) removes the library rows but deletes only
   Navis-owned audio files; files inside the custom folder and Android SAF
   documents stay where they are.
   Android uses a persisted Storage Access Framework tree URI rather than a
   filesystem path. The cached-track storage kind distinguishes Android SAF
   document locators from ordinary filesystem entries; SAF reads, writes,
   relocation, deletion, and offline playback go through the Android
   ContentResolver bridge and never overwrite unmanaged documents. Before a
   tree is activated Navis proves it can create, write, and remove a temporary
   Navis-owned probe document; a provider that fails that check remains
   unselected.
   Folder reconciliation first imports only unique manifest, embedded-identity,
   or indexed filename matches. Ambiguous and unknown files enter a transient
   manual-review screen; its local-song picker shows cover art and ranks exact
   title matches with liked songs (including liked-album tracks) first. Closing
   that review leaves unresolved user files untouched. Adopted files are never
   modified or moved: startup normalization leaves every file already inside a
   custom root where it is, the sidecar is their identity record, and adoption writes sidecar
   records in one transaction and cache rows in chunks of 250 (one
   `cached_tracks` notification per chunk). Only files Navis downloads itself
   carry identity tags; they are written to the local file, off the UI
   isolate and only when missing, before its single upload to a SAF folder.
   Legacy matching looks each distinct file title up in `song_search_text`
   (an indexed prefix read in the `normalizeSearchText` form, so titles in
   any script match) instead of normalizing the whole library, and FLAC
   identity reads are bounded to metadata rather than loading complete audio
   files; Android SAF reads identity metadata directly through
   `ContentResolver` without staging audio files. The Android storage channel
   runs on a background task queue (the platform thread is also Flutter's UI
   thread), lists a tree with one provider query per folder, and resolves the
   sidecar by path instead of listing the tree.
   The Downloads settings page retains the latest in-process scan's unresolved
   paths behind a disabled-or-enabled **Manual Matching** entry beneath Rescan.
   Its count badge and description expose how many files still need an explicit
   mapping; completing mappings reduces that count, while a new rescan replaces
   the transient queue.
7. Identity aliases transfer valid rolling/permanent ownership to a proven
   canonical server song ID; ambiguous permanent downloads remain local-only
8. Eviction removes orphan MIME sidecars and garbage-collects unreferenced
   provisional metadata while preserving active partial files and recent
   unowned audio files
9. Playback prefers permanent → rolling → stream
10. A profile migrated before library-cache-system version 2 must clear recoverable
   rolling cache and library metadata once before using the current contract.
   The upgrade prompt can be dismissed, but returns on the next launch until a
   successful reset and committed full catalog scan. **Repair Library** is the
   non-destructive server-catalog reconciliation: its candidate remains hidden
   until atomic promotion, and it preserves downloads, rolling cache, artwork,
   and the visible catalog until then. **Reset Caches & Rebuild Library** is
   the distinct device-storage recovery action: it deletes rolling cache,
   cover-art cache, and local library metadata, preserves permanent downloads,
   then starts a fresh catalog build. Settings keeps these actions in the
   separate **Library synchronization** and **Device Storage & Cache** groups;
   their metered confirmations, history origins, and full-screen progress
   states stay distinct even though both can collect a catalog. Choosing reset enters the
   shared full-screen required-library-rebuild route, which is also used for a
   first login, Repair Library, Settings cache reset, and playback recovery. It blocks ordinary
   navigation until the catalog is committed, keeps users in place with retry,
   metered-data, and sign-out recovery options on failure, and only then opens
   Home. `LibraryCacheResetService` deliberately preserves permanent downloads
   and their files; the upgrade marker is written only after that full scan.

Interactive Linux sync presets in `tool/dev_app.sh` run against a disposable
diagnostics clone. The cloned database drops cached-file references, outbound
queues, and any copied custom download root. Its rolling cache, cover-art
cache key, and default permanent-download directory are separate from the
primary profile, so testing first setup or a cache reset cannot delete the
primary profile's media. Initial offline/metered overrides are seeded before
the first sync decision; the authenticated diagnostics API can change them
while the scenario is running.

### Performance contracts

These rules keep the UI at 60 FPS and memory bounded with libraries of tens
of thousands of songs. `tool/perf_diagnostics.py` measures them (see
`docs/development-workflow.md`).

- Never load the whole songs table to pick a few rows. Use bounded DAO queries
  (`getSongsSorted`, `getRandomSongs`, `getSongsByIds`) or SQL aggregates.
- Local song search runs against `song_search_text`, a derived index of each
  song's normalized title, artist, and album. A row is current only while its
  `source` column equals the song's raw fields, so no song write path needs to
  maintain it: stale or missing rows are normalized by the search itself and
  rewritten by `scheduleSongSearchIndexRefresh`, which also runs from deferred
  startup maintenance. Normalization keeps letters and numbers from every
  script and folds Latin diacritics and common Arabic letter variants. The SQL
  prefilter requires each query token as an in-order subsequence, which every
  ranked match (exact, prefix, substring, token, fuzzy) satisfies, so ranking
  is unchanged. Since schema 87 each row also stores `match_title`,
  `match_artist`, and `match_album` in the `normalizeMetadata` form (rows
  without them count as stale). `getTrackMatchCandidates` selects only songs
  that could match a list of external tracks (Last.fm artist top tracks,
  ListenBrainz recommendations) under `LocalTrackMatchSnapshot` rules: equal
  title keys, or artist keys that are equal, contain or are contained, or
  share a word. A snapshot built from those makes the same matches as one
  built from the whole library. Deferred maintenance normalizes in an isolate.
- The artist page reads its albums through `album_artist_index`, a derived
  table of each album's artist keys (`i:<id>` for the album artist and each
  credit, `n:<normalized name>` for a name-only album artist and each credited
  name), current only while its `source` equals the album's raw artist id,
  name, and credits. Readers repair stale rows before querying, so no album
  write path maintains it. `watchArtistAlbumBuckets` re-reads only the
  artist's candidate albums (plus albums of the artist's songs) at most four
  times a second, classifies them with the same rules as before, and emits
  only changes; `getArtistPlaybackSnapshot` uses the same candidates.
- Per-song and per-page provider families (`songByIdProvider`,
  `songStarredProvider`, `songDownloadStateProvider`,
  `songPlaybackIndicatorStateProvider`, `pagedAlbumsProvider`, …) are
  auto-disposed. Row-level providers `select` their own entry from shared
  streams instead of opening one database watch per row.
- High-frequency values are published in bounded steps: sync progress through
  `LatestValueThrottle` (status and stage changes immediately, counts at most
  every 250 ms), download progress in whole-percent steps at most twice a
  second, and network usage records aggregated in memory and flushed every
  five seconds.
- Views derived from `cached_tracks` (cache stats, cached and downloaded id
  sets, cache types) emit only when their value changes, since most writes
  (a playback touch, download progress) leave them unchanged. The
  "Downloaded only" album and artist ids come from one join
  (`watchDownloadedContentIds`) instead of reloading every downloaded song
  on each write.
- Position ticks (5–10 Hz) are watched only by leaf widgets inside a
  `RepaintBoundary` (seek sliders, progress bars). The collapsed mobile Now
  Playing stays mounted under a disabled `TickerMode`, which pauses its
  animations and provider listeners.
- Database connections use WAL with `synchronous=NORMAL`, an 8 MiB page cache,
  in-memory temp storage, and a 64 MiB WAL size limit. Deferred startup
  maintenance runs a bounded `PRAGMA optimize`. Reverse-lookup indexes cover
  `songs(artist_id)`, `play_queue_items(song_id)`, `playlist_songs(song_id)`,
  and starred songs.
- Response byte accounting uses Dio's received-byte count; Navidrome gzips
  JSON without `Content-Length`, and re-encoding the decoded body cost two full
  JSON encodes of every large page on the UI isolate.
- Native and OS payloads stay bounded whatever the queue size: the native
  player holds a released window of the queue, the system media session a
  window of about 100 songs, and every queue edit is one batched native call
  (see "Released queue window"). On Android the platform thread is the UI
  thread (merged threads are Flutter's default), so any per-song platform call
  blocks frames.
- Queue changes publish one snapshot with a queue id list that is reused until
  the queue changes, so snapshot comparisons and `queueProvider` are
  identity checks for unchanged queues. The app shell ignores queue-only
  snapshot changes, and queue rows are keyed by song id and occurrence so
  inserting or releasing songs elsewhere does not remount rows.

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

### Sync snapshot write safety

Authoritative catalog and auxiliary responses require a present, typed response
container. Missing/malformed containers are failures, not empty snapshots.
Playlist mutation acknowledgements may legitimately omit a snapshot and retain
the protocol-compatible empty-success behavior.
Album detail replacement validates requested identity, unique track IDs, parent
membership and declared counts; unresolved detail retains committed tracks.
Validation compares the declared count with the complete wire response before
projecting canonical tracks. Explicit `isExternal=true` children may reference
their own remote album and are excluded from local membership. Targeted detail
also stores these children with provisional parents; catalog enumeration does
not import them as local entries. Missing provenance does not relax the parent
check. The album header retains the server's advertised count, which can include
remote references; stored local membership is a separate quantity.
Playlist detail validates counts and identities while allowing ordered duplicates.
Canonical writes route external metadata to provisional references; incremental
artist discovery does not schedule external albums for catalog hydration.

Server snapshot writes read pending annotation actions and local mutation markers
inside the commit transaction. A local like, unlike or rating newer than the
snapshot keeps its current value, including after successful outbox delivery.
The latest mutation marker per entity/field is retained across concurrent snapshots.
Canonical and provisional metadata upserts omit primary-key assignments from
their conflict-update clauses. Reassigning an unchanged artist/album/song ID
still makes SQLite recheck child foreign keys; metadata refresh must not invoke
identity changes. Inserts keep their IDs, and actual identity remapping remains
the responsibility of `SongIdentityDao`.
Recently Added reconciliation reads only canonical album IDs and existing ranks,
rather than decoding full album metadata. Both full replacement and bounded
prefix merging preserve their existing ordering rules and skip unchanged writes.
Album reconciliation defers cache unlinking until commit; callers composing an
outer transaction supply the deferred path collection and clean it after that
outer transaction succeeds. Full repair retains its separate confirmation and
atomic promotion contracts.

Promotion progress separates classification (`validatingCandidate`, candidate
status `ready`), publication (`applyingCandidate`, status `applying`) and
post-commit cleanup (`cleaningCandidate`, with the active candidate cleared).
Diagnostics also report separate bounded build, raster and vsync-to-raster-finish
frame windows alongside the historical build-plus-raster sum. These are engine
timings, not a hardware dropped-frame count.
Database-canary phase samples therefore distinguish those intervals. Historical
reports emitted before this separation labelled all three as `applying` and
cannot isolate a transaction stall. Persisted apply duration is sampled inside
the publication transaction; it excludes final ledger/commit overhead.

Sync execution uses a per-server lease for catalog and targeted writes. An opaque,
non-reused owner token is carried through the execution's async scope. The SQL
interceptor validates it while acquiring SQLite's writer lock before mutation,
and checks ownership/expiry again before transaction commit. This covers DAO
batches, custom statements, hidden candidates, publication and durable progress;
a late response from a replaced owner cannot publish. Nested writes roll back
with their outer transaction. Recovery and provider-reset writes use the same
fence. Heartbeat loss also cancels transport. Ordinary playback and local user
edits execute outside the sync scope. This uses the existing lease schema; token
equality plus the database writer lock provides fencing without a new counter.

Schema v74 extends `star_sync_queue` into a durable annotation outbox with a field
(`star` or `rating`), attempt count, next retry time and safe failure category.
Migration preserves existing star/unstar rows. Local favorite/rating writes and
the queued version commit in one transaction through `StarSyncDao`; replacing a
field allocates a new row ID, so an older acknowledgement cannot remove it.
Star and rating intents for the same item coexist. Snapshot application protects
pending ratings as well as favorites.

`AnnotationSyncDispatcher` is the sole production API writer for likes/ratings.
The shared Riverpod instance starts with audio initialization or the shell,
serializes delivery, observes queue changes, and schedules persisted backoff
without requiring a connectivity transition. Authentication failures remain
queued and are released on session change; other errors remain retryable rather
than silently dropping intent. Each acknowledgement checks client/account
identity. Diagnostics builds disable transmission of copied annotations. ID3
album and artist favorite writes use `albumId` and `artistId`; songs use `id`.

#### Sync execution ceilings and track-verification age

Coordinated runs own an async request scope shared with the Subsonic transport.
Endpoint admission, actual retry attempts, byte counts, concurrency and elapsed
limits belong to that scope; unrelated UI traffic is excluded. Automatic passes
have a 30-second, 96-request, 32-album-detail and 32-MiB ceiling (three concurrent
requests). Manual discovery has 60 seconds, 200 requests, 64 details and 64 MiB;
initial/repair snapshots have ten minutes and 512 MiB. Limits defer persisted work
without discarding committed hydration batches. Long Retry-After responses are
scheduled through durable retry state.
The engine obeys the admitted execution plan even when a safely promoted partial
catalog has no full-completion timestamp. Only a plan granting a broad snapshot
can start one; an incremental continuation cannot expand into first-time scanning.

Schema v75 adds `albums.songs_verified_at`. Eligible unmetered catalog passes
verify up to 16 oldest track snapshots aged seven days or unknown. Complete detail
or candidate-song snapshots advance the date; headers and carried-forward local
tracks do not. With a stable catalog and successful eligible checks, full coverage
is bounded by seven days plus `ceil(album_count / 16)` eligible intervals. Offline,
playback deferral, metered policy, failures or competing discovery work extend
wall-clock coverage. Deliberate typed repair verifies tracks omitted by the bulk
index rather than accepting matching album headers as evidence.

Explicit current external-source observations may reclassify previously polluted
canonical IDs through `repairExternalSourceEvidence`, which supports dry-run
counts and records aggregate apply counts. It changes membership flags, retaining
rows, references and files. Prefix inference alone does not authorize this repair.
Deletion confirmation requires a fresh second snapshot and the same exact removed
identities; interrupted candidates also revalidate saved page boundaries.

Schema v76 keys playlist membership by `(playlist_id, sort_order)`, preserving
repeated tracks and ordered occurrences. Migration retains all legacy membership
rows in a deterministic order; song identity remapping updates every occurrence
in place. A separate singleton annotation-dispatch lease serializes outbound
writers across app processes. The one-minute lease renews every ten seconds;
acknowledgement and failure bookkeeping recheck ownership under SQLite's writer
transaction. Process death leaves persisted intent for a later owner. This lease
is independent of catalog sync so local annotations remain responsive during it.

Incremental artist metadata and its traversal cursor commit together before
track hydration. A budget interruption retains completed artists and requeues
failed/unstarted IDs; automatic/manual artist passes additionally cap at 24/48.
Cancellation waits for auxiliary cleanup and prevents later auxiliary domains
from starting. A completed run ignores a late heartbeat result, so it cannot
cancel a newer operation. Diagnostics endpoint accounting comes from the
operation's immutable state, including while status is polled.

The Android network-cost MethodChannel is registered on both the activity and
headless worker messengers through `registerNetworkCostChannel`. Headless sync
therefore receives the same `ConnectivityManager.isActiveNetworkMetered` value
as foreground sync; a missing native bridge still fails conservatively. Worker
engine teardown removes its handler.

Catalog hydration counts and ID selectors exclude provisional and external
references. Explicit remote detail hydration remains available outside that
catalog backlog. Newest discoveries follow explicit user priorities and precede
older pending details; bounded DAO reads preserve caller order before limiting.
A due automatic discovery interval takes precedence over old targeted hydration,
while checks inside the interval can continue pending-only work.

Album/artist header timestamp comparisons use Drift's whole-second storage
precision. Newest-feed header discrepancies only invalidate track hydration when
the album is new/unhydrated or track-relevant fields change. Genre, rating,
play-count and creation-date updates alone preserve verified tracks; independent
age-based verification still covers song-only metadata changes.

### Sync cancellation drain

`LibrarySyncController.cancelAndWait` drains startup work, the engine, automatic
check completion (including its durable next-deadline write), and timer-arm tasks
before returning. Cancellation suppresses automatic rearming until the session's
existing restart path enables it again. Diagnostics shutdown and sign-out use
this barrier before database disposal; synchronous provider disposal alone
cannot await these owners.
