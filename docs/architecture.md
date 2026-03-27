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

- **Cache Management**
  - `rollingCacheManagerProvider` - Rolling cache manager
  - `rollingCacheBudgetBytesProvider` - Cache size budget
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
   - `app_providers.dart` should NOT import from feature providers
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

### Shell Routes

The app uses `StatefulShellRoute.indexedStack` for persistent navigation. The shell composition
mode (bottom nav vs. navigation rail) is determined at runtime by `resolveAdaptiveShellMode`
based on the current `AdaptiveContext`. On desktop, a persistent side rail and now-playing bar
are shown instead of a bottom navigation bar. The expandable player sheet is embedded directly
in the shell on all platforms — there is no separate `/now-playing` route.

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
  channel, parses semver, and returns `UpdateInfo` when a newer version is available
- `data/update_service.dart` — downloads the APK asset into the app cache directory and
  invokes the Android package installer via a `MethodChannel`
- `domain/update_info.dart` — immutable value object describing the available release

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

### Sync Flow

1. App launch or pull-to-refresh → `LibrarySyncController.syncIfStale()`
2. Sync controller checks staleness threshold
3. Sync engine fetches from API (full or incremental)
4. Sync engine writes to database in transactions
5. Database streams notify providers
6. UI updates reactively

### Cache Flow

1. Playback starts → `LockCachingAudioSource` downloads to temp
2. On completion → `RollingCacheManager.registerTrack()`
3. Cache manager enforces budget via LRU eviction
4. User pins content → Download to permanent cache
5. Playback prefers permanent → rolling → stream

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
