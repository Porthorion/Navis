# Radio Pool and Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Starting or refilling Personal Radio must not freeze the UI or keep the whole library in memory afterwards; then ship a dev build for the owner's phone test.

**Architecture:** Three small changes to existing code. The library DAO maps the full song list in yielding chunks, using the helper pattern commit `21c727b8` introduced. `RecommendationService` precomputes recording identities once per cached pool, chunked, instead of on every refill. It also drops the cached pool when its existing 2-minute window ends, instead of only checking that window on the next read. No new dependencies, no schema change, no new public API beyond test hooks.

**Tech Stack:** Flutter/Dart, Riverpod 3, Drift (SQLite), flutter_test, Android emulator + Dart VM service for verification.

**Spec:** this plan's Findings section. The measurements were taken 2026-10-12 on a 6 GB API 37 emulator, a profile clone build of dev `aaba9125`, and the real test server `navidrome.example.test` (57,863 songs).

## Findings (what was measured, and what is deliberately not changed)

| Stage | App PSS | Dart heap used | Image cache | Live dio `Response` objects |
|---|---|---|---|---|
| Home after initial sync | 226 MB | 37 MB | 8 MB / 8 | 43 |
| Playing, after 3 skips, idle 60 s | 277 MB | 66 MB | 25 MB / 40 | 152 |
| Personal Radio started | 318 MB | 89 MB | 30 MB / 45 | 152 |
| After 12 radio refills | 345 MB | 96 MB | 82 MB / 105 | 152 |
| Radio stopped | 333 MB | 96 MB | 82 MB / 105 | 152 |

**Radio sessions**
- *Refill responses:* the per-request token fix (`739f21c5`) works at runtime. Live responses stayed flat at 152 across 12 refills.
- *Start-up freeze:* starting Personal Radio blocks the UI isolate for **323 ms**. CPU samples point at `$SongsTableTable.map` (mapping all 57,863 rows from `LibraryDao.getAllSongs` at once) and at `RecommendationService._identity` → `normalizeMetadataKeepingEdition` via `_IdentityCache.ofRow` (a recording identity for every pool song). The identity work repeats on every refill, because `personalRadio` creates a fresh `_IdentityCache` per batch.
- *Retained pool:* from radio start onward, 57,863 `SongsTableData` objects and ~700,000 strings (~40 MB) stay live after the radio stops. The holder is `RecommendationService._eligibleLibraryCache`: its 2-minute age is only checked on the next read, so the list is referenced for the app's lifetime.

**Initial sync and memory**
- *Sync peak:* already fixed by `4b53ee20`, from 543 MB to 209 MB peak. Home after sync sits at 226 MB. Nothing left to do.
- *Image cache (no change):* it grows to 82 MB, within Flutter's default 100 MB budget. Flutter clears it on Android memory pressure (`PaintingBinding.handleMemoryPressure` → `imageCache.clear()`), so it is reclaimable and not a crash risk. Lowering the cap would trade memory for re-decoding and jank while scrolling.
- *Live responses (no change):* the 152 live dio responses from browsing plateau, so they are bounded and small. The Dart heap is 66 MB in total at that point.
- *Radio redesign (no change):* moving radio selection into SQL is a redesign with behaviour risk, and it isn't needed once the pool is released and built without blocking.

## Global Constraints

- **Dependencies and data:** no new packages, no Drift schema or migration change (schema stays 103).
- **Tests:** run only as `flutter test --concurrency=4 --timeout 60s <files>`. The coordinator runs `./tool/check.sh`, with one heavy job at a time on the host.
- **Picks unchanged:** radio picks, filters (liked-only, downloaded-only, offline) and exclusion rules must return the same songs for the same inputs and random seed as today.
- **Changelog (rule 24):** one entry in `lib/src/features/changelog/changelog_data.dart`, written from the user's side.
- **Commits:** plain subject (`fix: …`) with no scope, cause in the body, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Reuse:** reuse `kLocalTrackMatcherSnapshotYieldChunkSize` and the `await Future<void>.delayed(Duration.zero)` yield pattern. Do not add isolates or new constants for chunking.

## Review Focus

1. *Same results:* a library with soft-deleted and provisional songs must return exactly the same rows from `getAllSongs` as before (Task 1 test).
2. *Expiry during a read:* if the pool expires while a refill is reading it, the refill still completes from its own list, and the next read rebuilds (Task 3 test: release, then read again).
3. *Tracking catalog changes:* a catalog change between refills still invalidates the cached pool (the existing test `the eligible library follows catalog changes between refills` must keep passing in Tasks 2 and 3).
4. *Identity parity:* precomputed identities must equal what `_IdentityCache.ofRow` produced lazily, MBID rows included (Task 2 test compares both).
5. *Timer cleanup:* the release timer must not outlive the provider (Task 3: cancelled in `ref.onDispose`; the test disposes the container with no pending-timer failure).

---

### Task 1: Map the full song list in chunks

**Files:**
- Modify: `lib/src/database/daos/library_dao.dart:2221-2228` (`getAllSongs`), and around the chunk loop added by `21c727b8` in `getTrackMatchCandidates` (~line 3410)
- Test: `test/src/database/daos/library_dao_match_index_test.dart` (same file and helpers as the `21c727b8` chunk test)

**Interfaces:**
- Produces: `Future<List<SongsTableData>> getAllSongs()` (unchanged signature, now yields between chunks); private `Future<List<SongsTableData>> _mapSongRowsInChunks(List<QueryRow> rows)` reused by `getTrackMatchCandidates`.

- [ ] **Step 1: Write the failing-by-design parity test** (it pins today's results before the change)

```dart
    test(
      'getAllSongs keeps visible songs across chunks and skips hidden ones',
      () async {
        const count = kLocalTrackMatcherSnapshotYieldChunkSize * 2 + 1;
        await database.libraryDao.upsertSongs([
          for (var index = 0; index < count; index++)
            _song('all-${index.toString().padLeft(4, '0')}', 'Track $index'),
          _song('deleted', 'Gone').copyWith(
            serverDeletedAt: Value(DateTime.utc(2026)),
          ),
          _song('provisional', 'Remote').copyWith(
            isProvisional: const Value(true),
          ),
        ]);

        final songs = await database.libraryDao.getAllSongs();

        expect(songs, hasLength(count));
        expect(
          songs.map((song) => song.id).toSet(),
          {for (var i = 0; i < count; i++) 'all-${i.toString().padLeft(4, '0')}'},
        );
        expect(songs.first.title, isNotEmpty);
      },
    );
```

- [ ] **Step 2: Run it.** It passes on the current code; it is the parity guard.

Run: `flutter test --concurrency=4 --timeout 60s test/src/database/daos/library_dao_match_index_test.dart`
Expected: PASS (all tests in the file).

- [ ] **Step 3: Extract the helper and use it in both methods**

In `library_dao.dart`, add the helper next to `getTrackMatchCandidates`:

```dart
  /// Maps raw song rows in order, yielding between chunks so a large result
  /// set never blocks the UI isolate in one pass.
  Future<List<SongsTableData>> _mapSongRowsInChunks(
    List<QueryRow> rows,
  ) async {
    final songs = <SongsTableData>[];
    for (var index = 0; index < rows.length; index++) {
      songs.add(songsTable.map(rows[index].data));
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0 &&
          index + 1 < rows.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return songs;
  }
```

Replace the inline loop in `getTrackMatchCandidates` (the `final candidates = <SongsTableData>[]; for (...) {...} return candidates;` block from `21c727b8`) with:

```dart
    return _mapSongRowsInChunks(rows);
```

Replace `getAllSongs` with:

```dart
  Future<List<SongsTableData>> getAllSongs() async {
    final rows = await customSelect(
      'SELECT * FROM ${songsTable.actualTableName} '
      'WHERE ${songsTable.serverDeletedAt.name} IS NULL '
      'AND ${songsTable.isProvisional.name} = 0',
      readsFrom: {songsTable},
    ).get();
    return _mapSongRowsInChunks(rows);
  }
```

- [ ] **Step 4: Run the DAO and caller tests**

Run: `flutter test --concurrency=4 --timeout 60s test/src/database/daos/library_dao_match_index_test.dart test/src/features/library/data/library_sync_regression_test.dart test/src/features/home/presentation/home_new_releases_provider_test.dart test/src/features/player/data/recommendation_service_test.dart`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/src/database/daos/library_dao.dart test/src/database/daos/library_dao_match_index_test.dart
git commit -m "fix: map the full song list in chunks" -m "Starting Personal Radio blocked the UI isolate for 323 ms on a 57,863-song library; CPU samples showed getAllSongs mapping every row in one pass. Reuse the chunked mapper from getTrackMatchCandidates." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Compute radio recording identities once per pool

**Files:**
- Modify: `lib/src/features/player/data/recommendation_service.dart` (`_eligibleLibraryCache` record ~line 61, `eligibleLibrary` ~66-131, `personalRadio` ~249-260, `_IdentityCache` ~560)
- Test: `test/src/features/player/data/recommendation_service_test.dart`

**Interfaces:**
- Consumes: `getAllSongs()` from Task 1.
- Produces: `_eligibleLibraryCache` record gains `_IdentityCache identities`; `@visibleForTesting Future<String> debugRecordingIdentity(RadioFilters filters, String songId)` returning the cached identity for a pool song (used only by tests).

- [ ] **Step 1: Write the failing test**

```dart
  test(
    'the eligible pool precomputes recording identities once',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song (Live)',
          artistName: const Value('Artist'),
        ),
        SongsTableCompanion.insert(
          id: 'song-2',
          title: 'Other',
          recordingMbid: const Value('ABC-123'),
        ),
      ]);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          ],
        ),
      );
      addTearDown(container.dispose);
      final service = container.read(recommendationServiceProvider);

      expect(
        await service.debugRecordingIdentity(const RadioFilters(), 'song-1'),
        RecommendationService.debugIdentity('Artist', 'Song (Live)'),
      );
      expect(
        await service.debugRecordingIdentity(const RadioFilters(), 'song-2'),
        'mbid:abc-123',
      );
    },
    skip: !sqliteAvailable,
  );
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test --concurrency=4 --timeout 60s test/src/features/player/data/recommendation_service_test.dart`
Expected: FAIL to compile, because `debugRecordingIdentity` and `debugIdentity` are not defined.

- [ ] **Step 3: Implement**

In `RecommendationService`:

```dart
  ({
    Object key,
    int revision,
    DateTime at,
    List<SongsTableData> songs,
    _IdentityCache identities,
  })?
  _eligibleLibraryCache;
```

Replace the tail of `eligibleLibrary` (from `_eligibleLibraryCache = (` to `return eligible;`) with:

```dart
    // Identities are normalised once per pool, in chunks, so refills reuse
    // them and building them never blocks the UI isolate in one pass.
    final identities = _IdentityCache();
    for (var index = 0; index < eligible.length; index++) {
      _recordingRow(eligible[index], identities);
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _eligibleLibraryCache = (
      key: key,
      revision: revision,
      at: DateTime.now(),
      songs: List<SongsTableData>.unmodifiable(eligible),
      identities: identities,
    );
    return eligible;
  }

  /// The identity cache built with the current pool for [filters].
  Future<_IdentityCache> _poolIdentities(RadioFilters filters) async {
    await eligibleLibrary(filters);
    return _eligibleLibraryCache?.identities ?? _IdentityCache();
  }

  @visibleForTesting
  Future<String> debugRecordingIdentity(
    RadioFilters filters,
    String songId,
  ) async {
    final pool = await eligibleLibrary(filters);
    final identities = await _poolIdentities(filters);
    return _recordingRow(
      pool.firstWhere((song) => song.id == songId),
      identities,
    );
  }

  @visibleForTesting
  static String debugIdentity(String artist, String title) =>
      _identity(artist, title);
```

In `personalRadio`, replace:

```dart
    final eligible = await eligibleLibrary(filters);
    // Identities are computed once per song for the whole batch.
    final identities = _IdentityCache();
```

with:

```dart
    final eligible = await eligibleLibrary(filters);
    // Identities were computed once with the cached pool.
    final identities = await _poolIdentities(filters);
```

Add the import at the top of the file: `import 'package:flutter/foundation.dart' show visibleForTesting;` (skip it if `meta` is already imported for this), and `import 'package:navis/src/features/library/data/local_track_matcher.dart' show kLocalTrackMatcherSnapshotYieldChunkSize;`.

- [ ] **Step 4: Run the tests**

Run: `flutter test --concurrency=4 --timeout 60s test/src/features/player/data/recommendation_service_test.dart test/src/features/player/presentation/personal_radio_notifier_test.dart test/src/features/player/presentation/recommendation_session_coordinator_test.dart`
Expected: PASS, including `radio interleaves related and familiar tracks without duplicates`, `small library fills from shuffle and avoids duplicate recordings` and `the eligible library follows catalog changes between refills`.

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/player/data/recommendation_service.dart test/src/features/player/data/recommendation_service_test.dart
git commit -m "fix: compute radio recording identities once per pool" -m "Every Personal Radio refill normalised the identity of all eligible songs on the UI isolate (RecommendationService._identity via _IdentityCache.ofRow in the 323 ms start-up sample). Build them once with the cached pool, in yielding chunks, and reuse them across refills." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Release the radio pool when its window ends

**Files:**
- Modify: `lib/src/features/player/data/recommendation_service.dart` (constructor, `_eligibleLibraryMaxAge` ~line 60, cache assignment from Task 2, provider ~line 569)
- Modify: `lib/src/features/changelog/changelog_data.dart` (top `ChangelogVersion` entries list)
- Test: `test/src/features/player/data/recommendation_service_test.dart`

**Interfaces:**
- Consumes: the Task 2 cache record.
- Produces: `RecommendationService.new(this._ref, {Duration eligibleLibraryMaxAge = const Duration(minutes: 2)})`; `@visibleForTesting bool get debugHasEligibleLibrary`.

- [ ] **Step 1: Write the failing test**

```dart
  test(
    'the eligible pool is released when its window ends',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-1', title: 'One'),
      ]);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            recommendationServiceProvider.overrideWith(
              (ref) => RecommendationService(
                ref,
                eligibleLibraryMaxAge: const Duration(milliseconds: 50),
              ),
            ),
          ],
        ),
      );
      addTearDown(container.dispose);
      final service = container.read(recommendationServiceProvider);

      await service.eligibleLibrary(const RadioFilters());
      expect(service.debugHasEligibleLibrary, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(service.debugHasEligibleLibrary, isFalse);

      // A later read rebuilds the pool.
      expect(
        (await service.eligibleLibrary(const RadioFilters())).single.id,
        'song-1',
      );
      expect(service.debugHasEligibleLibrary, isTrue);
    },
    skip: !sqliteAvailable,
  );
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test --concurrency=4 --timeout 60s test/src/features/player/data/recommendation_service_test.dart`
Expected: FAIL to compile, because the `eligibleLibraryMaxAge` parameter and `debugHasEligibleLibrary` are not defined.

- [ ] **Step 3: Implement**

Change the constructor and the max-age constant (keep everything else in the class header):

```dart
  RecommendationService(
    this._ref, {
    Duration eligibleLibraryMaxAge = const Duration(minutes: 2),
  }) : _eligibleLibraryMaxAge = eligibleLibraryMaxAge {
    _ref.onDispose(() => _eligibleLibraryRelease?.cancel());
  }

  final Duration _eligibleLibraryMaxAge;
  Timer? _eligibleLibraryRelease;

  @visibleForTesting
  bool get debugHasEligibleLibrary => _eligibleLibraryCache != null;
```

Remove the old `static const Duration _eligibleLibraryMaxAge = Duration(minutes: 2);` line, and replace its uses (the age check in `eligibleLibrary`) with the instance field. Check the actual constructor form first: if the class uses the `new(this._ref)` primary-constructor syntax, write the equivalent in that syntax.

Right after the `_eligibleLibraryCache = (...)` assignment from Task 2, add:

```dart
    // The pool holds every eligible song; drop it once it can no longer be
    // reused instead of keeping it for the app's lifetime.
    _eligibleLibraryRelease?.cancel();
    _eligibleLibraryRelease = Timer(_eligibleLibraryMaxAge, () {
      _eligibleLibraryCache = null;
    });
```

Add `import 'dart:async';` if it is not imported. The provider stays `Provider<RecommendationService>(RecommendationService.new)`; a constructor tear-off with an optional named parameter still matches `(Ref ref) => …`.

Add the changelog entry at the top of the current version's `entries` in `changelog_data.dart`:

```dart
      ChangelogEntry(
        'Fixed a brief freeze when starting Personal Radio and high memory use after listening to it',
        type: ChangelogEntryType.fix,
      ),
```

- [ ] **Step 4: Run the tests**

Run: `flutter test --concurrency=4 --timeout 60s test/src/features/player/data/recommendation_service_test.dart test/src/features/player/presentation/personal_radio_notifier_test.dart test/src/features/player/presentation/instant_mix_notifier_test.dart test/src/features/changelog`
Expected: PASS, 0 failures. Container disposal must not report a pending timer.

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/player/data/recommendation_service.dart lib/src/features/changelog/changelog_data.dart test/src/features/player/data/recommendation_service_test.dart
git commit -m "fix: release the Personal Radio pool when it expires" -m "RecommendationService kept the eligible pool (57,863 SongsTableData rows, ~40 MB on the test library) referenced for the app's lifetime because its 2-minute age was only checked on the next read. Release it with a timer when the window ends; later reads rebuild it." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Verify on the emulator, gate, merge and ship the dev build

**Files:** none in the repo, apart from docs if a measurement changes a documented number (`docs/architecture.md`, radio section).

**Interfaces:**
- Consumes: Tasks 1-3 on branch `fix/radio-pool-memory` (worktree `../Navis-memprobe`).

- [ ] **Step 1: Build the profile clone APK.** Run `~/.cache/claude-navis-logs/ponytail/rt/build-apk-mem.sh` under `~/.cache/claude-navis-tools/capped.sh 8G`, then stop the Gradle daemons (`pgrep -x java` + kill).
- [ ] **Step 2: Measure.** Boot the 6 GB disposable AVD (copy of `Navis_Dependency_Upgrade`, `-memory 6144 -gpu host`). Run `NAVIS_PW=… ~/.cache/claude-navis-logs/ponytail/rt/memattr.sh <apk> after`. Then measure the radio-start stall with the heartbeat plus runtime profiler, the same way as the 323 ms baseline.
  Expected:
  - radio start: event-loop lag under 50 ms.
  - stage H (radio stopped), re-read after 2+ minutes: `SongsTableData` instances back near zero, and the Dart heap within ~10 MB of stage D.
  - dio responses still flat across refills.
- [ ] **Step 3: Quality gate.** Run `./tool/check.sh` (capped at 8 GB). Expected: `All checks passed.`
- [ ] **Step 4: Merge and push.** In the main checkout (clean `dev`), run `git merge --no-ff fix/radio-pool-memory`, then `git push origin dev`.
- [ ] **Step 5: Publish the dev build.**
  1. Make a worktree at the merged `dev` and copy in `tool/release.env`, `android/key.properties` and `android/app/navis-release.jks` from the main checkout.
  2. Run `JAVA_HOME=/home/khalifa/android-studio/jbr PATH=$JAVA_HOME/bin:$PATH ./tool/dev_release.sh` there. It builds the Navis Dev **sidecar** (`com.navis.app.navis.dev`, arm64).
  3. Confirm `signature OK` and the APK URL in its output, stop the Gradle daemons, and remove the worktree.
- [ ] **Step 6: Owner's phone checklist** (sent with the build):
  1. Start Personal Radio. It should start without a visible hitch.
  2. Let it refill a few times. Playback should continue, with no pause in the UI when the next batch loads.
  3. Stop the radio and keep using the app for a few minutes. It should feel the same as before radio.
  4. Repeat the earlier checks: the first minute after opening, skipping tracks, and scrolling Home.
