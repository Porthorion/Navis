# Issue #43 Implementation Plan (Temporary)

Status: ready for implementation
Prepared: 2026-08-20
Target: Navis 1.2.6
Tracker: [Forgejo issue #43 — Issues to Solve for 1.2.6](https://git.porthorion.com/khalifa/Navis/issues/43)

## Purpose and deletion contract

This document is the temporary execution ledger for issue #43. It translates
the six tracker reports into reproducible scenarios, likely code ownership,
acceptance criteria, tests, and runtime evidence. It is intentionally more
specific than the permanent architecture documentation so a later agent can
start from verified repository facts instead of rediscovering the system.

Delete this file in the final issue #43 completion change, but only after all
of the following are true:

- every workstream checklist below is complete and issue #43 can be closed;
- implemented architecture and behavioral contracts have been transferred to
  `AGENTS.md` and `docs/architecture.md`;
- Android scheduler conclusions have been reconciled with
  `docs/android-background-sync-recovery-plan.md`;
- user-visible changes are recorded in
  `lib/src/features/changelog/changelog_data.dart` and
  `tool/generate_release_notes.dart`;
- `PROGRESS.md` contains dated implementation and validation evidence;
- the final runtime scenarios pass after a clean restart and
  `./tool/check.sh` passes.

The deletion commit must not discard unresolved findings. Any remaining work
must first move to the appropriate permanent document or a separate Forgejo
issue.

## Studied baseline

The baseline studied for this plan is branch `dev` at commit
`351f944d3d2f0b262001e5a754c042a6bb9ef7b0`, version `1.2.5+10205`.
Issue #43 was created on 2026-08-18 and updated on 2026-08-20, after that
commit. At study time it was the newest open issue, had no comments, and was
labelled confirmed, medium-priority enhancement.

The tracker contains six distinct outcomes:

1. restore a useful Desktop View size across launches;
2. make Android sync scheduling work and make its Settings status truthful;
3. make explicit refresh discover new server songs/albums consistently,
   including on Wi-Fi;
4. replace desktop Home song-row chevrons with useful responsive actions;
5. make a Home liked-track tap honor the liked-queue preference;
6. remove redundant Library and Settings page titles on portrait phones while
   preserving Library tab labels.

This is documentation-only planning. No runtime claim is made by this file.

## Existing facts and boundaries

| Area | Current repository fact | Consequence for implementation |
| --- | --- | --- |
| Desktop window | `DesktopWindowController` already stores `window_state.json` v3, defaults Desktop View to 1200×760, listens for move/resize, and restores normal bounds/maximized state. `onWindowClose()` starts an unawaited write. | Diagnose persistence timing, native bounds semantics, and profile/file selection before replacing the controller. |
| Android background sync | `AndroidBackgroundSyncScheduler`, `NavisBackgroundSyncWorker`, the retained Dart entrypoint, durable state, and Settings presentation exist. `NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC` defaults to `false`, so the reconciler leaves release users disabled. | Background scheduling is intentionally gated, not absent. Do not enable it until the P0 closure register in `docs/android-background-sync-recovery-plan.md` is satisfied. |
| Foreground/manual sync | `syncNow()` creates a `checkForUpdates` request. The planner chooses delta reconciliation for an eligible manual request. The engine scans up to five 100-album `newest` pages on unmetered networks; metered manual discovery is intentionally limited to one 50-album page and at most three album hydrations. | Reproduce the reported Wi-Fi discrepancy against current code. Do not assume cellular success proves the catalog is reconciled. |
| Manual discovery evidence | `tool/manual_discovery_diagnostics.sh` covers unchanged indexes, a new album, offline resume, and optional partial artist responses. Planner, coordinator, engine, and controller tests cover manual discovery. | Extend the existing fixture and app API rather than building a second sync harness. Real Android Wi-Fi classification and real provider responses remain unproven by the Linux fixture. |
| Home desktop rows | `_SongListSection` in `home_screen.dart` renders a `DesktopListRow` with a fixed `Icons.chevron_right` trailing widget. Like, download, and More actions already exist in shared helpers and other Home desktop rows. | This is a presentation/action-composition gap, not missing domain functionality. |
| Home liked tap | Home displays at most five rows from `homeLikedSongsProvider` and replaces the queue with only the tapped row. Library has a private `_likedPlaybackSongsProvider` that combines directly liked songs with songs from liked albums, deduplicates by ID, and starts the full queue at the selected song when both queue preferences are enabled. | Extract and reuse the Library policy; do not queue only the five-row Home preview. |
| Portrait titles | Phone Library uses an `AppBar` title plus `TabBar`; phone Settings uses an `AppBar` title. The selected bottom-navigation destination already identifies Library or Settings. | Suppress only the redundant portrait-phone toolbar title. Keep Library tabs and retain titles for landscape/tablet/desktop contexts. |

## Execution order

Use small vertical slices. Do not combine all six outcomes into one unreviewable
change.

1. Reproduce and strengthen observation surfaces.
2. Resolve manual discovery correctness and Android scheduling truthfulness.
3. Resolve Desktop View persistence.
4. Share and apply liked-queue semantics.
5. Add responsive desktop Home actions.
6. Remove redundant portrait titles.
7. Run the cross-feature regression matrix, update permanent documentation,
   close the tracker, and delete this file.

The sync work comes first because it can affect catalog integrity. The three
presentation slices can proceed only after their acceptance fixtures are
defined, but they do not need to wait for Android physical-device scheduling
certification if separate commits are used.

## Workstream 1 — Desktop launch size and restoration

### Reproduction questions

- Is the bad first launch the 1200×760 fallback, a clamped 800×600 value, a
  native outer-frame/content-size mismatch, or an old saved record?
- Is `window_state.json` written under the same support directory on the next
  launch and for stable/dev side-by-side builds?
- Does a normal close terminate before the unawaited `onWindowClose()` write?
- Does closing from maximized or Mini Player preserve the last valid Desktop
  bounds as intended?
- Do scale-factor, multi-monitor, display removal, or work-area clamping alter
  the saved size?

### Likely touch points

- `lib/src/routing/desktop_window_controller.dart`
- `lib/main.dart`
- `test/src/routing/desktop_window_controller_test.dart`
- `tool/desktop_layout_diagnostics.sh`
- authenticated `GET/POST /v1/presentation/window`

### Implementation plan

- [ ] Add diagnostic output for the state-record version, restoration source
      (`saved`, `fallback`, or `clamped`), and whether the last persistence
      operation completed. Keep paths and monitor identifiers redacted.
- [ ] Reproduce first launch, resized normal launch, maximized launch, and
      close-from-Mini restart with an isolated Linux profile. Inspect the
      persisted JSON and compare app-API bounds before shutdown and after
      restart.
- [ ] Add a controller test that simulates immediate shutdown after a resize.
      If close persistence is the defect, introduce an awaited close handshake
      through `window_manager` rather than relying on an unawaited callback.
- [ ] Select a useful fallback from the available work area instead of blindly
      increasing a fixed size. Preserve the 800×600 Desktop View minimum and
      leave room for system chrome on smaller displays. Record the approved
      rule in architecture docs.
- [ ] Preserve v1/v2/v3 state migration, Mini Player position-only persistence,
      maximized restoration, work-area clamping, and stable/dev profile
      isolation.

### Acceptance and regression evidence

- A fresh supported desktop profile opens at the approved useful size, within
  the visible work area, and in Desktop View.
- Resize to a non-default valid size, close normally, relaunch, and observe the
  same logical Desktop bounds (within the platform's documented frame
  tolerance).
- Repeat after maximization, after closing in Mini Player, and after a display
  topology change.
- Run focused controller tests, `tool/desktop_layout_diagnostics.sh`, app-owned
  Home screenshots before and after a clean restart, then `./tool/check.sh`.
- Linux is mandatory. Windows and macOS resize/DPI behavior remains required
  before claiming cross-platform window restoration complete.

## Workstream 2 — Android background sync and Settings schedule state

### Confirmed cause and existing blocker plan

The Android scheduler is disabled by default at compile time in
`library_sync_provider.dart`. The Settings card therefore can truthfully say
that Android background sync is disabled even when the general sync interval
picker is non-manual. That presentation is confusing because the foreground
timer and native process-independent scheduler are separate mechanisms.

`docs/android-background-sync-recovery-plan.md` already contains the detailed
closure register. Its P0 findings remain release blockers: native WorkManager
operations are not awaited, bootstrap/system-stop outcomes can remain
ambiguous, the headless worker snapshots network policy, and no instrumented
Worker plus physical-device matrix certifies the capability. Do not duplicate
or weaken that plan here.

### Likely touch points

- `lib/src/features/library/presentation/library_sync_provider.dart`
- `lib/src/features/library/data/android_background_sync.dart`
- `lib/src/features/library/data/android_background_sync_entrypoint.dart`
- `lib/src/features/settings/presentation/sync_settings_screen.dart`
- `android/app/src/main/kotlin/com/navis/app/navis/`
- Android unit and instrumented tests plus existing Dart/DAO/widget tests

### Implementation plan

- [ ] First make Settings distinguish foreground checks from Android
      process-independent scheduling. Show why native scheduling is unavailable
      or gated; never imply the interval itself has been disabled.
- [ ] Complete the P0 closure register in
      `docs/android-background-sync-recovery-plan.md`: await WorkManager
      operations, durably classify bootstrap/stop outcomes, make policy live,
      add WorkManager TestDriver coverage, and complete device certification.
- [ ] Preserve one opaque periodic `UPDATE` request and the separate `KEEP`
      catch-up contract, cross-engine lease, confirmation-aware repair
      boundary, secure profile validation, and redacted status fields.
- [ ] Add or extend authenticated diagnostics so `/v1/sync/status` reports the
      requested cadence, native capability/gate reason, work state, attempts,
      last terminal outcome, and foreground next-check time as separate fields.
- [ ] Enable the release capability only after the documented Android matrix
      passes. Retain a kill switch that cancels work and prevents an old profile
      from running after sign-out or server change.

### Acceptance and regression evidence

- On Android with the native capability gated, Settings says foreground checks
  remain available and states the bounded reason native background work is
  unavailable.
- When enabled, one correctly constrained schedule exists per active opaque
  profile and Settings/app API/native WorkManager state agree.
- Interval and unmetered-only changes reconcile the existing request rather
  than creating duplicates.
- Process death, app swipe-away, reboot, constraint wait/release, foreground
  overlap, worker cancellation, authentication loss, profile change, and
  metered Wi-Fi are exercised using the matrix in the existing recovery plan.
- Capture and inspect the app-owned Sync Settings screenshot after each
  meaningful state. Run Linux startup smoke, Android unit/instrumented tests,
  physical-device validation, and `./tool/check.sh`.

## Workstream 3 — Manual refresh and new server content discovery

### Reproduction matrix

Use a server fixture that starts with a committed catalog, then adds a new
album under an existing artist without changing the artist-index cursor. Give
that album at least one new song. Record endpoint calls, returned IDs/counts,
network classification, plan reason, durable work, final catalog counts, and
recent-album ordering.

Run all of these through the production controller boundary:

| Network/policy | Action | Required result |
| --- | --- | --- |
| Wi-Fi, native unmetered | Home pull refresh, Library pull refresh, Settings Check for updates | `manualCatalogDiscovery`; scan the bounded five-page newest window; stage and hydrate the new album/song. |
| Wi-Fi, native metered | Explicit check | Use the documented limited metered path unless the user grants the broad one-time override; never silently no-op. |
| Cellular | Explicit check | One 50-album page and at most three changed albums; expose remaining durable work. |
| Offline then Wi-Fi | Explicit check then reconnect | Preserve delta intent and resume it; do not downgrade to an indexes-only probe. |
| Unchanged indexes | Explicit check | Still inspect newest albums and discover an existing artist's new album. |
| Partial artist response | Explicit check | Retain existing sibling albums while staging the new one. |

### Likely touch points

- `lib/src/features/library/data/library_sync_planner.dart`
- `lib/src/features/library/data/library_sync_engine.dart`
- `lib/src/features/library/data/adaptive_library_sync_coordinator.dart`
- `lib/src/features/library/presentation/library_sync_provider.dart`
- `lib/src/providers/app_providers.dart` network policy providers
- `lib/src/utils/connectivity.dart` and Android `network_cost` bridge
- `tool/manual_discovery_diagnostics.sh`
- relevant planner/coordinator/engine/controller tests

### Implementation plan

- [ ] Run the existing manual-discovery suite unchanged to establish whether
      current `dev` already satisfies the deterministic case.
- [ ] Reproduce on Android Wi-Fi and cellular with the authenticated app API:
      `POST /v1/sync/check`, `GET /v1/sync/status`,
      `GET /v1/sync/ledger`, `GET /v1/library/album`, and
      `GET /v1/library/recent-albums`. Do not infer success from a spinner or
      local playback history.
- [ ] Verify `connectivity_plus` and `ConnectivityManager.isActiveNetworkMetered`
      classify the failing Wi-Fi correctly. Persist only the bounded network
      type/metering decision in diagnostics, never SSID or network identity.
- [ ] Compare failing live endpoint responses with the fixture. Pay particular
      attention to provider page caps, absent `created` values, unchanged
      indexes, album IDs returned by `newest`, `getArtist` singular `album`
      normalization, and whether the discovered album reaches authoritative
      `getAlbum` hydration.
- [ ] Fix the narrowest failing boundary. Preserve low-data automatic sync,
      durable resume, identity reconciliation, candidate-catalog isolation,
      and deletion-confirmation safeguards.
- [ ] If all current-dev scenarios pass, document the issue as fixed by the
      2026-08-12 discovery work only after current real-server Android Wi-Fi
      confirmation; otherwise keep the tracker open with the captured failing
      contract.

### Acceptance and regression evidence

- Every entry surface awaits the same terminal controller result and discovers
  the fixture album/song on unmetered Wi-Fi.
- The UI never reports current/success while the discovered work is still
  failed or silently abandoned; deferred work is explicit.
- The same album is not duplicated, existing albums are not removed, queue and
  cache identity remain valid, and a clean restart retains the new catalog.
- Extend `tool/manual_discovery_diagnostics.sh` for the reproduced edge, run
  focused tests, an isolated Linux clean-restart pass, the Android network
  matrix, log review, and `./tool/check.sh`.

## Workstream 4 — Responsive desktop Home song actions

### Confirmed gap

The arrow comes from the desktop branch of `_SongListSection`, which is shared
by liked, most-played, and recently-played Home song sections. Secondary click
already opens `showSongContextMenu`. Shared like/download behavior exists in
`toggle_song_star.dart`, `SongDownloadStatusIcon`, download-quality helpers,
and the song context menu. The random-album desktop row already demonstrates a
direct Like plus More pattern.

### Implementation plan

- [ ] Define one responsive trailing-action policy for Home song rows. At
      roomy desktop widths expose Like/Unlike, download/status, and More. At
      constrained desktop widths expose More while keeping download/cache
      state observable if it fits the approved design.
- [ ] Replace the chevron only for song rows; album/artist navigation chevrons
      may remain where they accurately signal navigation.
- [ ] Reuse the shared mutation, error notice, download state, quality picker,
      and anchored desktop menu. Do not create a Home-only star/download
      implementation.
- [ ] Keep row tap as playback, secondary click and More as the same anchored
      menu, 44 px interactive targets, stable Remote provenance, selected-song
      styling, and metadata truncation before actions.
- [ ] Add `LayoutBuilder`/policy tests at compact, standard, and ultra-wide
      Desktop View widths plus 130%/200% text scale. Add stable component
      goldens for the direct-action and collapsed-action states.

### Acceptance and regression evidence

- No desktop Home song row shows a navigation arrow.
- Direct actions are available when space permits; the More menu remains the
  complete action set and becomes the compact fallback without overflow.
- Like rollback/error feedback, download/queued/progress/downloaded states,
  right-click parity, keyboard focus, tooltips, and semantics all pass.
- Use authenticated Home navigation and screenshot capture on isolated Linux;
  inspect each affected section at wide and constrained bounds before and
  after a clean restart, then run `./tool/check.sh`.

## Workstream 5 — Home liked-track queue semantics

### Confirmed gap

`homeLikedSongsProvider` is a five-row preview. Its tap callback currently
calls `replaceWithTableData([song])`. Library already has the desired behavior
but keeps the combined/deduplicated playback provider private to
`library_screen.dart`.

### Implementation plan

- [ ] Move the combined liked playback list into a shared feature provider or
      domain helper. Preserve order, deduplicate by song ID, and include songs
      from liked albums exactly as Library does.
- [ ] Move the queue-decision rule into a shared helper/controller used by
      both Library and Home: when album queueing and liked queueing are enabled,
      replace with the full eligible list and select the tapped ID; otherwise
      play only the tapped song.
- [ ] Apply active Home filters deliberately. Downloaded-only mode must not
      queue unavailable songs; document whether the global liked-only action
      has any additional effect on this already-liked section.
- [ ] Keep the preview capped at five rows. Queue construction must read the
      full provider, not infer the queue from visible widgets.
- [ ] Add Home widget tests for both preference states, selected start index,
      directly liked plus liked-album deduplication, downloaded-only filtering,
      one-song fallback, and duplicate IDs.
- [ ] Add a narrow clone-only app-API control/observation if the existing
      presentation API cannot trigger and assert the production Home callback
      and resulting logical queue.

### Acceptance and regression evidence

- With both queue preferences enabled, tapping Home's third visible liked row
  queues the same ordered, deduplicated eligible list as Library and starts at
  that song.
- With either required preference disabled, only the tapped song is queued.
- Phase-1/phase-2 queue behavior, `loadingSongId`, immediate playback, queue
  persistence, duplicate handling, and Home visual selection do not regress.
- Run focused Home/Library/queue tests, authenticated runtime queue observation
  and screenshot, a clean restart, then `./tool/check.sh`.

## Workstream 6 — Portrait-phone Library and Settings titles

### Confirmed gap

Library's phone scaffold places `Library` in the AppBar and the section labels
in its `TabBar`. Settings places `Settings` in its AppBar. The selected bottom
navigation label already names the current top-level destination. Tablet,
landscape, and desktop layouts have different orientation/context needs and
must not be changed accidentally.

### Implementation plan

- [ ] Add an explicit portrait-phone page-title policy derived from adaptive
      context plus `MediaQuery.orientation`; do not infer orientation from one
      hard-coded width alone.
- [ ] For Library portrait phone, remove only the toolbar title/height while
      retaining the TabBar, safe-area inset, tab semantics, sync/filter banners,
      and scroll geometry.
- [ ] For Settings portrait phone, remove the AppBar and add the correct top
      safe-area/body inset so the first row never overlaps system UI.
- [ ] Retain titles for phone landscape where needed, tablet layouts, compact
      wide layouts, desktop icons-only workspaces, empty/disabled Library
      recovery, and nested settings pages.
- [ ] Add portrait-versus-landscape widget tests at 390×844 and 844×390,
      tablet tests at 700/840 widths, 200% text-scale coverage, semantics
      assertions, and component goldens for portrait Library and Settings.

### Acceptance and regression evidence

- Portrait phone shows the selected bottom-navigation label once, not a second
  `Library` or `Settings` page title.
- Library still shows its enabled tab labels (for example Albums, Liked,
  Artists, Playlists, or Radio), and Settings still shows group/entry labels
  such as Configuration and Cache & Storage.
- Back behavior, top safe area, pull-to-refresh, tab switching, large text, and
  nested-page titles remain correct.
- Validate on Android through production navigation plus
  `POST /v1/presentation/screenshot`; inspect Library and Settings screenshots
  in portrait and landscape before and after a clean restart. Run focused
  widget/golden tests and `./tool/check.sh`.

## Cross-workstream regression matrix

Before issue closure, run and record:

- focused tests for every touched controller/provider/widget;
- `./tool/manual_discovery_diagnostics.sh` including any new provider fixture;
- `./tool/desktop_layout_diagnostics.sh`;
- Android WorkManager unit/instrumented/device checks from the recovery plan;
- authenticated Linux and Android app-API scenarios, app-owned screenshots,
  persisted effects, and log review;
- clean-restart retests for Desktop bounds, catalog discovery, liked queue,
  Home actions, and portrait layouts;
- `./tool/check.sh` after focused iterations pass.

Do not record credentials, tokens, server URLs, SSIDs, private metadata, raw
WorkManager input, or unredacted screenshots. Existing analyzer informational
baseline is not permission to ignore new errors or warnings.

## Completion ledger

- [ ] Desktop launch/restoration accepted on Linux and required native desktop
      targets.
- [ ] Android scheduling status is truthful and the release rollout gate is
      resolved with the existing recovery plan.
- [ ] Manual refresh discovers new content on the required Wi-Fi/cellular/
      offline matrix.
- [ ] Desktop Home song actions are responsive and visually verified.
- [ ] Home liked-track taps share Library queue semantics.
- [ ] Portrait Library and Settings titles are deduplicated without losing tab
      context.
- [ ] Changelog, release notes, permanent architecture docs, and `PROGRESS.md`
      contain the final facts and evidence.
- [ ] Issue #43 is closed and this temporary document is deleted in the same
      completion change.
