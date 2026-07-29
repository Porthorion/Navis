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
  - `subsonicApiProvider` - Configured Subsonic API client

- **Audio System**
  - `audioBootstrapControllerProvider` - Audio handler initialization state
  - `audioHandlerProvider` - Active audio handler instance
  - `audioHandlerStateProvider` - Audio handler state controller
  - `playbackSnapshotProvider` - Current playback state stream
  - `playerStateProvider` - Simplified playback state
  - Linux uses the app-owned `LinuxMprisBridge` over `dbus`; Windows uses the
    app-owned SMTC bridge; Android, iOS, and macOS use `audio_service`

- **Cache Management**
  - `rollingCacheManagerProvider` - Rolling cache manager
  - `rollingCacheBudgetBytesProvider` - Live cache size budget read for every
    cache write
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
- `requiredLibrarySyncModelVersionProvider` - Optional one-time repair gate
  for sync storage contract changes; app build updates do not force full sync

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
5. Audio handler updates `playbackSnapshotProvider`
6. UI reacts to snapshot changes

Remote stream recovery is layered. If a lock-cached remote source stalls or
fails at runtime, the audio handler marks that song as bypassed for the session
and rebuilds playback with direct streams at the current index/position. If a
direct stream fails, the song is marked as failed and playback advances to the
next playable queue item when available. Background phase-2 queue fill failures
must not clear the active start item.

Album-style queue replacement is lazy: the active transport queue prepares the
tapped song first, then fills the remaining sources in phase 2. While phase 2
is loading, `PlaybackSnapshot.queueSongIds` can represent the pending logical
queue rather than the prepared transport queue, with
`hasPendingLogicalQueue == true`. Queue UIs should display those IDs but avoid
remove, reorder, or play-index actions until the transport queue catches up.

Now Playing commits a full directional artwork transition only for an actual
queue-index change. Previous actions that restart the current track and Next
actions at the end of the queue use a short directional snapback with
replay/end-of-queue feedback instead.

### Sync Flow

1. App launch or periodic timer → `LibrarySyncController.syncIfStale()`
2. Sync controller checks staleness threshold and skips cellular auto-sync
   Failed automatic passes remain failed until the next configured interval,
   reconnect, or explicit manual retry; they do not start short forced retry
   loops
3. Sync engine sends the persisted server `Indexes.lastModified` cursor to
   `getIndexes(ifModifiedSince)`; local completion time is used only for
   scheduling and status
4. A returned index is treated as a gated artist snapshot. Missing artists,
   album-count changes, and newest-album discrepancies are prioritized, then
   the remaining artists drain through persisted batches of 48 artists
   (24 for manual cellular checks). Pending work bypasses the normal staleness
   gate and continues quietly in the foreground on non-cellular networks
5. A newest-album health probe runs every 12 hours. Unsupported or unreliable
   index servers use bounded artist/newest-album verification and retry the
   index endpoint daily
6. Non-fatal artist and album endpoint failures are isolated to their entity.
   Successful metadata is committed, unfinished IDs remain queued for bounded
   foreground continuation, and safe diagnostics record only the stage,
   endpoint, entity ID, exception type, and attempt count. Authentication,
   authorization, database, and invariant errors still fail the pass
7. The server cursor advances only after every candidate from the response and
   its album hydration succeeds. Partial batches show verification pending
   rather than silently claiming current metadata. If a newer cursor arrives
   mid-audit, newly reported artists lead, the untouched tail keeps priority,
   and previously checked artists move behind it
8. Search and discovery metadata is written provisionally. Canonical hydration
   reconciles song identities conservatively and transactionally remaps cache,
   downloads, queues, history, playlists, lyrics, Match Flow, scrobbles,
   feedback, and star actions. Playback receives the alias before the
   provisional row is removed; late cache completion resolves the canonical ID
   and an active losing cache file is retained until orphan cleanup can safely
   reclaim it
9. Starred, genre, and playlist metadata refresh on manual sync, real metadata
   changes, or the longer auxiliary sync window
10. Initial sync, a one-time sync-model repair, and explicit Force Full Sync are
   the only authoritative full-library modes

### Cache Flow

1. Playback starts → `LockCachingAudioSource` downloads to temp
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
