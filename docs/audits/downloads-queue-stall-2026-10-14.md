# Large downloaded queue investigation — 2026-10-14

## Scenario and controls

Profile Android diagnostics sidecar on branch `fix/downloads-queue-stall`, using
a new disposable `Navis_Stall_Test` AVD: API 37.0 Google APIs Play Store 16 KB
x86_64 image, 6 GB RAM, host GPU, no snapshots saved. The work used memory-capped
systemd jobs, stopping the emulator for builds and test suites.

Fresh setup produced 57,841 local songs. The fixture contains 171 real permanent
downloads, about 64 MB, mostly 30–33-second tracks, with one 57-second replacement.
Downloads used 96 kbps transcodes; successful Opus files were retained and the
remainder used MP3 after server transfer failures. Failed/stalled transfers were
cancelled/replaced before measurement. All files were verified present, with no
rolling entries or pending downloads.

Each run restored the same downloaded SQLite snapshot, enabled Album Queue,
disabled optional integrations, and started a fresh app process. The mounted
Downloaded row's production tap callback ran `playSongIdInCollection`, then
Now Playing and Queue were opened immediately and the queue was scrolled.
Offsets reached 180, 360 and 540 logical pixels and returned upward; app-owned
screenshots were inspected before and after. All 171 sources materialized, with
no skipped/deferred items.

Heartbeat metrics were reset immediately before playback. Main-isolate CPU
samples used a 1 ms period during each approximately 2.6–2.7-second window.
Early trial runs were discarded: a battery-optimization sheet obscured the
queue, and diagnostic `jumpTo` was undone by initial queue centring. Only the
disposable sidecar was exempted from battery optimization. Existing diagnostics
controls were extended to tap a mounted shared row and send Flutter
pointer-scroll signals for relative scrolling. These control changes were
identical in the accepted baseline and fixed builds.

## Confirmed defect and fix

Each accepted baseline run emitted **171 `cached_tracks` change notifications**.
Permanent-file resolution called `RollingCacheManager.touchTrack`, including
canonical-identity lookup and a `lastAccessedAt` update per queued song. Those
updates invalidated the permanent-list query and
`LibraryDao.watchDownloadRelatedSongs`, although downloads are excluded from
rolling-cache LRU eviction.

The regression reproduced this without native playback: 171 resolutions caused
171 cache notifications, **172 permanent-list snapshots and 172 related-song
snapshots**, including the initial snapshots. After the fix it observes zero
cache notifications and exactly one initial snapshot per watcher, with all
permanent cache rows unchanged.

`PlaybackSourceResolver` now touches only accepted rolling sources. Permanent
download priority and missing-file repair remain intact. Another regression
resolves an older rolling entry, verifies its timestamp increases, enforces a
three-byte rolling budget, and verifies the untouched rolling entry is evicted
while the played rolling entry and permanent download remain on disk.

## Accepted Android measurements

Times are milliseconds. Heartbeat columns are worst values in the full
play/open/scroll window, rather than raster FrameTiming.

| Run | Before frameGap | Before eventLoopLag | After frameGap | After eventLoopLag | Before / after cache updates |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 38.384 | 28.204 | 47.389 | 17.224 | 171 / 0 |
| 2 | 33.850 | 16.454 | 46.515 | 28.780 | 171 / 0 |
| 3 | 46.639 | 20.983 | 36.355 | 24.285 | 171 / 0 |

| Run | Before / after source resolution | Before / after frame-build p99 | Before / after native batch total |
| --- | ---: | ---: | ---: |
| 1 | 166 / 101 | 14.122 / 8.246 | 15 / 20 |
| 2 | 162 / 70 | 12.444 / 6.006 | 14 / 17 |
| 3 | 160 / 100 | 12.690 / 6.767 | 30 / 15 |

Average source-resolution time fell about 44%; median frame-build p99 fell about
47%. Four native append batches and three queue-table notifications remained
in each run. The fix removes unnecessary database/watch work; worst heartbeat
maxima **did not consistently improve**, so these results do not establish
elimination of every opening hitch or the owner's phone symptom.

## Samples and remaining gaps

Counts below are samples, not invocations or exact CPU times. Qualified owners
were reconstructed from VM metadata; recursive frames were counted once per
sample.

| Frame | Before runs 1 / 2 / 3 | After runs 1 / 2 / 3 |
| --- | ---: | ---: |
| `RenderViewportBase.layoutChildSequence` (inclusive) | 62 / 38 / 39 | 22 / 11 / 15 |
| `_NativeParagraph._layout` (exclusive) | 35 / 12 / 16 | 16 / 7 / 11 |
| `$CachedTracksTableTable.map` (inclusive) | 3 / 1 / 0 | 0 / 0 / 0 |
| `LibraryDao.watchDownloadRelatedSongs` closure (inclusive) | 1 / 0 / 1 | 0 / 0 / 0 |
| `PlaybackSourceResolver.resolveForSong` (inclusive) | 5 / 6 / 3 | 7 / 8 / 8 |

Top exclusive frames overall included `_EventHandler._sendData`,
`_SendPort._sendInternal`, `_reportTaskEvent`, and native paragraph layout.
Baseline samples also included `RollingCacheManager.touchTrack`,
`CacheDao.touchTrack`, and `$SongsTableTable.map`. Palette quantization was not
a main-isolate hotspot. Queue preparation/native sequence publication and
persistence appeared but did not dominate the app-specific stacks.

An additional fixed-build timeline run measured frameGap 39.801 ms and
eventLoopLag 22.562 ms. The longest UI-thread `Animator::BeginFrame` span was
11.430 ms (`VsyncProcessCallback`: 11.439 ms); longest UI GC span was 5.415 ms.
Raster `GPURasterizer::Draw` reached 28.521 ms, including GLES surface work.
This supports graphics/presentation variability contributing to the remaining
emulator gaps. It does not identify a remaining 30 ms synchronous Navis
function or establish phone GPU performance.

## Validation and limits

- Focused playback, cache, DAO and diagnostics suites: **137 passed**.
- The permanent-resolution regression failed before the production change,
  then passed after it.
- `./tool/check.sh`: **passed**, including generation, analysis, dead-code,
  migrations, critical reliability and the full suite (**7,887 passed, one
  existing skip**). An initial full-suite run timed out in the unrelated
  annotation test "two isolate connections serialize annotation network
  writers". Its eight-test file passed immediately in isolation. The complete
  gate passed with a temporary `dart_test.yaml` setting concurrency to four;
  no assertion, timeout or coverage was changed, and the file was removed.
- Final Linux and Android profile builds passed clean-start runtime checks
  after the gate: 171 materialized local sources, advancing native playback,
  and zero cache-table notifications. Final diagnostics also verify covered
  and nested scroll owners. Queue offsets were 360 on Linux and 540 on Android;
  both app-owned screenshots were inspected. Android retained all 171 files,
  with no missing entries. Advancement uses `playerPositionMs` on Android:
  `positionMs` belongs to the structural snapshot and need not tick between
  structural updates.
- The sidecar was uninstalled, the emulator stopped, the owned AVD and its
  files deleted, and task-owned profiles, scripts, traces and temporary files
  removed. No commits or stashes were made.
- Real-phone measurements and subjective confirmation of the original stutter
  remain unverified. Emulator heartbeat maxima do not show a reliable reduction;
  demonstrated improvements are removal of write/watch amplification, reduced
  layout sampling, shorter resolution, and lower frame-build p99.

## Changed files

- `lib/src/features/player/data/playback_source_resolver.dart`: skip permanent
  LRU touches while preserving rolling refresh.
- `lib/src/utils/diagnostics_presentation_controller.dart`: mounted-row Play
  control and scrolling that yields queue centring and selects an uncovered
  owner without moving a nested list.
- `test/src/features/player/data/playback_source_resolver_test.dart`: write/watch
  regression, permanent timestamp stability, rolling LRU and download retention;
  use the existing database factory.
- `test/src/utils/diagnostics_presentation_controller_test.dart`: production tap,
  pointer notification, nested-list and covered-overlay coverage.
- `lib/src/features/changelog/changelog_data.dart`: 1.5.0 fix entry.
- `docs/architecture.md`: permanent/rolling access-timestamp contract.
- `docs/development/development-workflow.md`: diagnostics controls.
- `docs/project/progress.md`: completion evidence and measurement limits.
- `docs/README.md`: investigation index.
- This report: reproduction, samples, measurements and validation evidence.
