# Sync Improvement Plan — 1.4.0

**Audit date:** 2026-09-19. **Status:** core correctness changes implemented and validated; the first-setup policy in §19 is superseded by the automatic isolated-album recovery work in §20. The Linux sync-and-scroll frame gate now passes; broader platform, audible-playback and soak acceptance remains open. Bounded attempt observability is validated. Audit baseline retained below; latest evidence is in §§13–20.
**Baseline:** working tree based on `9d0ff34318b3c70ca5f1e552ebf7b8dd6146c7da`, including the user's existing uncommitted changes. Flutter 3.47.1 / Dart 3.13.1, Linux, database schema 73. This is a plan and evidence record, not a declaration that its proposed contracts are implemented.

## 1. Decision and priorities

Keep the candidate-generation architecture, durable scheduling, local database browsing, and source-aware song identity work. Fix the inconsistent paths around them before increasing concurrency or introducing another sync framework.

The largest demonstrated problem is **incremental sync undoing the separation between the server library and external results**. A live repair produced 5,644 albums. One subsequent manual check added **915 external-prefixed albums as canonical local entries**, scanned **69,323,555 reported bytes**, and left 6,059 albums without their previous newest-feed rank. The incorrect rows survived restart. This connects correctness, excessive work, and visible library instability in one reproducible sequence.

Other release-critical defects include nonempty partial album responses deleting tracks, a concurrent local like being overwritten, exhausted transient repairs becoming completed work, and malformed playlist responses being accepted as empty authoritative snapshots.

Use these priorities:

- **P0:** destructive or source/ownership corruption; fix before shipping sync changes.
- **P1:** broken discovery, retry, resumption, auxiliary synchronization, or uncontrolled work.
- **P2:** compatibility, bounded staleness, observability, and measured performance improvements.

Implementation checkboxes below close only after their full acceptance gate passes. A passing audit characterization test means the defect was reproduced; it does **not** mean the desired behavior passes.

## 2. Scope and evidence rules

Reviewed first-time setup, catalog repair and promotion, manual incremental discovery, automatic probes, compatibility audits, target hydration, starred state and its outbound queue, playlists, genres, foreground scheduling, Android worker admission, execution leases, candidate checkpoints, local mutation protection, source classification, identity reconciliation, database writes, and diagnostics. Scrobble delivery was reviewed as an adjacent outbox and its focused tests were run; download transfer and third-party recommendation systems were not independently audited end to end.

Evidence labels:

- **R:** reproduced through production Dart/Drift logic with a deterministic fixture.
- **L:** observed through the running Linux app's authenticated diagnostics API against the supplied server, or a read-only server probe.
- **S:** source-supported concern; its full failure sequence was not exercised.
- **Proposal:** a desired behavior or performance target, not a measurement.

During the audit, no application implementation was changed. Real-server work used the supplied account, temporary protected credentials, and disposable database/cache profiles. No server library, playlist, star, or scrobble mutation was intentionally submitted. The original desktop database and downloaded files were not modified. The first clone retained the source profile's cached user metadata; therefore removal of its 135 cached playlists when checking the supplied account is **not** evidence of wrongful live playlist deletion. That account returned no playlists or starred items. Playlist deletion safety is independently reproduced with a malformed fixture in F17.

### Source map

| Boundary | Main implementation |
|---|---|
| Setup and readiness | [initial_server_sync_provider.dart](lib/src/features/auth/presentation/initial_server_sync_provider.dart), [session_route_provider.dart](lib/src/features/auth/presentation/session_route_provider.dart) |
| UI scheduling/coalescing | [library_sync_provider.dart](lib/src/features/library/presentation/library_sync_provider.dart) |
| Planning and execution ownership | [library_sync_planner.dart](lib/src/features/library/data/library_sync_planner.dart), [adaptive_library_sync_coordinator.dart](lib/src/features/library/data/adaptive_library_sync_coordinator.dart), [sync_run_contract.dart](lib/src/features/library/domain/sync_run_contract.dart) |
| Catalog, targets, and auxiliary execution | [library_sync_engine.dart](lib/src/features/library/data/library_sync_engine.dart) |
| Candidate storage, diff and visibility | [library_sync_candidate_dao.dart](lib/src/database/daos/library_sync_candidate_dao.dart), [library_catalog_diff_analyzer.dart](lib/src/features/library/data/library_catalog_diff_analyzer.dart), [library_dao.dart](lib/src/database/daos/library_dao.dart) |
| Durable work, leases, history, mutations | [library_sync_dao.dart](lib/src/database/daos/library_sync_dao.dart) |
| Source and identity | [catalog_source.dart](lib/src/utils/catalog_source.dart), [song_identity_reconciler.dart](lib/src/features/library/data/song_identity_reconciler.dart), [song_identity_dao.dart](lib/src/database/daos/song_identity_dao.dart) |
| Protocol | [subsonic_api_client.dart](lib/src/api/subsonic_api_client.dart) |
| Playlists and likes | [playlist_dao.dart](lib/src/database/daos/playlist_dao.dart), [playlist_providers.dart](lib/src/features/playlists/presentation/playlist_providers.dart), [star_sync_dispatch_provider.dart](lib/src/features/library/presentation/star_sync_dispatch_provider.dart), [star_sync_dao.dart](lib/src/database/daos/star_sync_dao.dart) |
| Android background | [android_background_sync_entrypoint.dart](lib/src/features/library/data/android_background_sync_entrypoint.dart), [android_background_sync.dart](lib/src/features/library/data/android_background_sync.dart), [NavisBackgroundSyncWorker.kt](android/app/src/main/kotlin/com/navis/app/navis/NavisBackgroundSyncWorker.kt) |

Line numbers cited below refer to this working-tree audit; named symbols are the stable lookup points.

## 3. Established truths to preserve

1. **Server-local, external, provisional, and downloaded are different properties.** An external result can be played, liked, cached, or referenced by a playlist without becoming a member of the server-local catalog. Download availability must not change provenance.
2. **An unchanged artist cursor is not proof of unchanged tracks or albums.** OpenSubsonic defines `getIndexes.ifModifiedSince` around changes to the artist collection. The live server returned a 227-byte conditional response with an unchanged cursor and no artists. Do not interpret that as a complete empty catalog. [Protocol reference](https://opensubsonic.netlify.app/docs/endpoints/getindexes/)
3. **Bulk enumeration is a useful optimization.** Empty-query `search3` is explicitly supported for offline synchronization; the live server returned 1,000 songs at both offsets 0 and 1,000. Keep per-album fallback and count/identity checks. [Protocol reference](https://opensubsonic.netlify.app/docs/endpoints/search3/)
4. **The full-repair candidate boundary works in the measured happy path.** The live library stayed committed while a candidate was collected; a large-removal candidate required confirmation; promotion recorded aggregate removals. The isolated diagnostic script explicitly confirmed the clone's repair. Do not remove confirmation to make repair faster.
5. **Existing safeguards are valuable but not universal.** Incremental artist enumeration avoids deleting missing albums; target hydration preserves an entirely empty suspicious detail; pending outbound stars are protected; full promotion reads mutation journals inside its transaction; cache unlinking is deferred after full promotion. F01/F18 show why those protections need consistent coverage.
6. **Navigation should remain a local read.** Preserve catalog/target separation and the persisted one-shot automatic deadline. Do not repair the audit's freshness gaps by scanning on Home/Library/Liked builds.
7. **Symfonium is a behavior reference, not evidence about proprietary internals.** Its published guidance describes offline access, automatic detection where possible, and manual sync for changes it cannot detect. The goal here is predictable local browsing, bounded background work, and understandable results; this audit did not benchmark Symfonium or claim algorithmic parity. [Symfonium sync guidance](https://docs.symfonium.app/wiki/providers/sync-media-provider-data/)

## 4. Validation and live measurements

### Executed evidence

| Evidence | Result |
|---|---|
| Engine, coordinator, planner, sync DAO, initial-sync controller suites | **130 passed** |
| Library controller, Android policy/entrypoint, star DAO, identity reconciler, provisional DAO, scrobble service suites | **47 passed** |
| New audit characterizations F01–F18 and F24 | **19 passed**, confirming the documented current behaviors |
| Live isolated repair | Completed, including confirmation; 666 albums removed, zero songs removed |
| Live manual check immediately after repaired baseline | Reproduced 915 external-prefixed canonical albums and rank-tail loss; persisted after clean restart |
| Live first sync from empty catalog via app-owned reset/setup APIs | Completed in **105 seconds**; correct committed catalog retained after clean restart |
| Offline first-sync state | `initialSyncRequired / waitingForNetwork`, then resumed when Wi-Fi policy returned |
| Direct API observations | Navidrome identity `0.64.0 (1072e9f7)`; 1,777 artists; conditional cursor behavior; bulk pages; 671 genre records |

The server's API identifies as Navidrome. The user describes the deployment as Octo-Fiesta-backed; the audit verifies observed mixed-source behavior without claiming the proxy's build/version. The sum of artist-reported album counts was 7,891, whereas canonical album enumeration yielded 5,644. These are different response populations, not interchangeable completeness totals.

The first generic Python probe was rejected; repeating with the app-like request headers/client identity succeeded with token and legacy authentication. Rejected responses were not counted as empty libraries. Successful measurements are in the final probe artifact.

### Catalog and cost observations

| Scenario | Artists | Albums | Songs | Requests / reported payload bytes |
|---|---:|---:|---:|---|
| Starting copied catalog | 1,767 | 6,298 | 56,025 | Baseline only |
| Repair after confirmed promotion | 1,777 | 5,644 | 56,158 | Collection attempt: 138 / 77,828,854; confirmation attempt: 60 / 5,507,628 |
| Subsequent manual check | 1,777 | 6,559 | 56,158 | 115 / 69,323,555; terminal result `partial` |
| Fresh initial sync | 1,777 | 5,644 | 56,158 | 138 / 78,330,202 |

All 666 albums removed by repair had external-style ID prefixes, false external/provisional flags, and zero/null song counts. This is strong evidence of a polluted starting catalog, but does not establish which historical run inserted every row. F10 directly reproduces insertion through the current incremental path, both in fixtures and the subsequent live check.

The manual check called `getIndexes` once, newest-feed pages five times, `getArtist` 48 times, bulk song search 58 times, and genres/playlists once each. The song count was unchanged. This is not a cheap check; equal aggregate counts alone do not prove that every song row was unchanged.

### Smoothness measurements and their limits

| Scenario | Frame build+raster p95 / p99 / max | Database `countArtists()` canary | Promotion |
|---|---|---|---|
| Live repair/confirmation session | 4.62 / 8.63 / 26.37 ms | Collecting p99 10.23 ms; applying max 560.58 ms | Classification 6.434 s; atomic apply 0.894 s |
| Manual incremental session | 7.19 / 10.21 / 25.89 ms | Fetching songs p95 680.21 ms, max 697.15 ms | No new promotion; report's promotion field retained older values |
| Fresh initial sync session | 3.30 / 7.85 / 28.24 ms | Applying max 5.57 ms | Classification 5.702 s; atomic apply 13.242 s |

These are single Linux profile runs, without active audio or deliberate scrolling. The diagnostics frame metric adds build and raster durations; it is not an input-latency or dropped-frame distribution. The canary includes queueing/IPC/query latency, not just SQLite lock duration. A long first promotion did **not** produce comparably long read stalls in that run. Do not equate atomic-apply duration with UI freeze or claim a universal smoothness guarantee. The preparing app-owned screenshot was opened and inspected; it showed the Home surface, not a repair-settings acceptance screen.

### Evidence locations

Local artifacts (ignored `build/`, may be deleted by cleaning):

- `build/sync-audit-1-4-0/baseline-tests.log`
- `build/sync-audit-1-4-0/secondary-tests.log`
- `build/sync-audit-1-4-0/reproductions.log`
- `build/sync-audit-1-4-0/live-server-probes.json`
- `build/sync-audit-1-4-0/live-genre-shape.json`
- `build/sync-audit-1-4-0/live-repair-summary.json`
- `build/sync-diagnostics/20260919T120805Z-full-rescan/`
- `build/sync-audit-1-4-0/runtime/`: incremental, offline setup, first-sync, and clean-restart evidence.

The permanent [reproduction appendix](docs/audits/sync-1-4-0-reproductions.md) preserves the sanitized runnable fixture source. This plan preserves the important measurements so cleaning `build/` does not erase the conclusions. Credentials, database copies, raw app logs, bearer handshakes, and user media metadata are not part of that appendix.

## 5. Reproduced findings

### F01 — Nonempty partial album responses can delete tracks — P0, R

**Code:** engine `hydrateAlbum` around 991/1090; `_hydratePendingSongs.processAlbumBatch` around 4579; DAO `reconcileSongsForAlbumsChunk` around 895.

The targeted guard rejects an empty response, but accepts one song with `songCount: 2`. Reconciliation then removes the second committed song and returns success. The reproduction also verifies zero operation-ledger entries. Batch/candidate detail processing lacks even the same empty-response validation before marking an album hydrated. Ordinary removal can unlink rolling cache files inside a transaction, unlike the full-promotion deferred-unlink path.

**Method:** centralize detail validation before every destructive write: requested identity, unique song identities, parent membership, declared count, provenance, and explicit empty-list semantics. On insufficient evidence, merge safe additions/updates and retain missing tracks as unresolved; retry with bounded backoff. Validated complete changes can remove tracks with an atomic ledger entry. Defer filesystem unlink until commit.

**Acceptance:** seed two tracks; return one with declared count two, duplicate IDs, wrong parent/album ID, or omitted song list. No committed track/cache disappears, hydration remains unresolved, and the reason is visible. A complete one-track authoritative replacement must still be able to converge under the chosen deletion policy.

### F02 — Automatic checks can miss new albums behind an unchanged cursor — P1, R/L contract

**Code:** planner `plan`; coordinator `_enqueueProbeFollowUp` at 908; engine `probeCatalog` at 1732.

With a fresh audit deadline and unchanged indexes cursor, a due automatic request calls only `getIndexes`; a new newest-feed album is never queried or imported. Auxiliary freshness does not fix this: it selects a probe too. Compatibility audit is normally due weekly for a cursor considered reliable.

**Method:** add a separately scheduled, bounded newest-discovery lane on eligible unmetered automatic checks. Keep the cellular hard probe inexpensive. Persist discovery coverage independently from the artist cursor and distinguish “artist index unchanged” from “catalog checked.”

**Acceptance:** unchanged cursor plus new album under an existing artist is imported within a documented automatic freshness bound, without user repair. Repeated navigation still issues zero catalog requests.

### F03 — Typed initial/repair operations omit auxiliary initialization — P1, R/L

**Code:** engine `_runSync` at 2002; coordinator `auxiliaryUpdated` around 648 and `_refreshProviderProfile`; target callers in playlist providers.

Typed catalog runs disable `syncAuxiliary`; no replacement scheduler fan-out initializes starred state, playlists, and genres. The fixture proves a successful initial snapshot calls none of those endpoints. The live first sync did the same. The only production `playlistHeaders` caller found is the playlist refresh provider; no production starred-target caller was found. Separate starred/playlist target results also cannot jointly satisfy the coordinator's `starredSynchronized && playlistHeadersSynchronized` timestamp condition.

**Method:** create independent starred, playlist-header, and genre freshness/checkpoint records; enqueue them once after initial catalog commit and when independently due. Their terminal results must not replace catalog status. Initial readiness should explicitly distinguish browse-ready catalog from auxiliary completion.

**Acceptance:** populated fixture account gets liked/playlist/genre data on first setup without opening those screens; each domain refreshes on its own deadline; a failed auxiliary endpoint does not restart the catalog or erase other domains' freshness.

### F04 — Transient repair failure becomes completed durable work — P1, R

**Code:** engine `_runSync` transient catch around 2169; coordinator `_executePlanned` work transitions around 595 and circuit state around 656; Android `_categoryFor`.

A connection failure fetching artists produces `skipped`, not retryable failure. The coordinator marks `fullRepair` work `completed`, clears failure streak to zero, and can advance checked time. Android maps skipped to succeeded. The reproduction asserts all three persistence/result facts for repair; device scheduling was not tested.

**Method:** return typed retryable transport failure, preserve checkpoints and retry eligibility, and keep cancellation/no-op/authentication separate. Advance successful-check timestamps only on successful check evidence. Android should preserve the coordinator-owned retry outcome instead of treating it as completed work; retain WorkManager retry for bootstrap failures so two retry loops do not compete.

**Acceptance:** offline/timeout/429/5xx after transport retry produces pending work and a persisted retry deadline; auth errors do not loop; a fresh no-op does not clear an unresolved failure.

### F05 — Resumed pagination uses filtered count as network offset — P1, R

**Code:** engine `_discoverAlbumIdsFastPath` at 5156, checkpoint decode at 5295.

A live page advances by `page.length`, but its checkpoint stores `catalogPage.length` after external filtering. Resume advances by that filtered count. A fixture page `[local, external]` is checkpointed as one; after interruption, the next request uses offset one instead of two. An all-external completed page can retain `hasMore: true` with zero advancement until the page limit fails.

**Method:** persist separate raw returned count/next offset and accepted canonical row count, plus checkpoint format/version and scope. Validate forward progress on recovery. Restart incompatible old checkpoints conservatively.

**Acceptance:** interrupt at each mixed/all-external page boundary; resumed offsets match an uninterrupted scan; zero accepted local rows still advances transport position; count validation and candidate atomicity remain intact.

### F06 — A bounded newest refresh erases complete ordering — P1, R/L

**Code:** engine `_stageNewestAlbumsForHydration` at 4210; DAO `replaceRecentlyAddedRanksFromNewestFeed` at 747.

Every bounded discovery calls the same replacement helper as a complete snapshot, clearing all canonical ranks before writing the observed prefix. A fixture tail rank becomes null. Live: all 5,644 albums were ranked after repair; the manual check left 6,059 of its 6,559 albums unranked, including the older existing tail.

**Method:** distinguish complete replacement from partial-window reconciliation. Store observation scope/epoch and merge a bounded authoritative prefix without inventing unseen ordering. Retain a valid tail or explicitly model partial rank coverage; avoid rewriting the entire table on unchanged polls.

**Acceptance:** full repair → bounded check → restart preserves relative order of unobserved albums; prepend/delete/reorder cases converge; a no-change check does not rewrite every album.

### F07 — Typed endpoint and work budgets are descriptive, not enforced — P1, R/L

**Code:** coordinator `_typedPlanFor` around 770; engine `executeSyncExecutionPlan`, `_runIncrementalSync` around 4133, `_hydratePendingSongs`, `_runNewestAlbumHealthProbe`.

The execution plan carries allowed endpoints, page/hydration limits, bytes, and concurrency, but the engine mainly reads its kind/network grant. A changed manual fixture issues genres/playlists despite their exclusion from its allowed endpoints. Live manual discovery issued 58 bulk-search calls although the manual plan's allowlist excludes bulk songs. Hardcoded limits and captured `networkType` are not equivalent to enforcing the admitted plan.

**Method:** enforce a shared run-scoped budget at dispatch, including retries, observed bytes, page counts, concurrency, and live policy changes. Queue explicitly permitted continuation when exhausted. Reserve full-library bulk enumeration for a planned repair or a cost-justified large hydration batch, not merely a previously remembered bulk capability.

**Acceptance:** fail a test on any endpoint outside the plan; small incremental changes remain bounded; Wi-Fi-to-metered transition reduces/cancels future work; reported usage matches the enforced run budget.

### F08 — Later playlist changes cannot requeue completed hydration — P1, R

**Code:** engine `_syncPlaylistHeadersStrict` around 4377; sync DAO `enqueueWork` at 1086.

After playlist hydration has completed, changed headers enqueue the same `playlist:<id>` key without reactivating completed work. The fixture changes song count from one to two; the work stays completed and no runnable row exists. Equal-count reorder/track replacement is also not detected by `_playlistHeaderChanged`, which ignores server change/version evidence.

**Method:** key work by target plus observed content version, or explicitly reopen completed work only for newer evidence. Keep cancelled user work protected. Track playlist `changed`/content fingerprint independently of display metadata, with bounded detail refresh where no reliable version exists.

**Acceptance:** repeatedly change a playlist across completed runs, including equal-count reordering; each new version hydrates once, preserves order/duplicates, and survives restart without resurrecting cancelled operations.

### F09 — Recovery mutates another executor's running state before checking its lease — P1, R/S

**Code:** coordinator first-call recovery around 133; lease acquisition around 475; heartbeat around 508; sync DAO recovery/lease methods.

The second-coordinator fixture holds a valid worker lease and a running probe. Its request correctly returns `leaseHeld`, but first changes the other owner's work from running to queued. Typed running attempts are similarly recovered before lease admission. Heartbeat failure/false results are ignored; promotion does not verify an ownership fence.

**Method:** acquire the relevant lease before ownership-sensitive recovery/cleanup; recover only attempts whose owner is expired. Add a monotonically increasing fencing token checked inside commit transactions; stop on lost heartbeat. Define target-write interactions with a worker candidate explicitly.

**Acceptance:** foreground and headless coordinators sharing one database cannot recover each other's live attempts. Pause owner A beyond TTL, admit B, resume A: A must be unable to commit. The audit reproduced the premature recovery mutation, not simultaneous live-device commits.

### F10 — Incremental sync canonicalizes external albums and songs — P0, R/L

**Code:** engine `_runIncrementalSync` around 4029–4103 and batch song hydration; DAO `upsertAlbums` at 688 / song reconciliation around 907.

Incremental artist details filter external **artists** but do not split external **albums** out of `artist.albums`. The ordinary upsert forcibly sets `isExternal=false` and `isProvisional=false`. Batch song reconciliation does the same. The fixture starts with explicitly external album/song data and observes both stored as local. The live repaired→manual sequence added 915 external-prefixed canonical albums with unchanged song count.

**Method:** require source-aware write contracts, not just caller-side booleans. Route canonical catalog rows and provisional external references separately in every path, including bulk, newest, artist detail, playlist, starred, and identity promotion. Only positive server-local evidence may promote provenance. Repair existing misclassified rows using authoritative evidence, preserving referenced/downloaded/liked external items and aliases; never blanket-delete by prefix alone because an explicit API source flag has precedence.

**Acceptance:** mixed artist payload through initial/repair/incremental/target flows produces the same canonical catalog. External rows remain usable through their references. Repeat live repair → manual check twice: canonical count remains stable if the server library did not change, and no unneeded full-song scan occurs.

### F11 — New index evidence cannot reopen completed delta work — P1, R

**Code:** coordinator `_enqueueProbeFollowUp` at 908; sync DAO `enqueueWork` conflict clause at 1115.

After a previous delta completes, a probe detecting a newer index enqueues the same terminal key without reactivation. The fixture reports `probeIndexChanged=true`, but the delta remains completed and the runnable queue is empty. This is distinct from freshness gating: the change was detected and then lost at admission.

**Method:** version follow-up work by observed cursor/evidence generation; enqueue a new operation when evidence is newer. Do not generally reactivate terminal rows on every timer. Reuse the rule for F08 and unsupported-provider audits.

**Acceptance:** three successive server changes each create and drain one follow-up; identical repeated probe evidence coalesces; cancelled work stays cancelled unless genuinely new evidence or explicit consent justifies new work.

### F12 — Newest discovery stops early on server-capped pages — P2, R

**Code:** engine `_runNewestAlbumHealthProbe` around 2580–2599.

It treats `page.length < requestedSize` as EOF and calculates offsets with `pageIndex * pageSize`, while full enumeration correctly uses returned counts. A fixture serving one item per page hides a new album at offset one: manual discovery never requests it.

**Method:** use returned-count offsets and empty/repeat/progress guards consistently. Bound actual pages, records, bytes, and elapsed time; persist “coverage incomplete” when a budget ends rather than declaring no changes beyond the covered window.

**Acceptance:** caps of 1, 20, and 50 with requests for 100 discover the bounded next pages, never skip offsets, and stop at the configured budget. This cap was simulated; the live server returned the requested 100-album pages.

### F13 — Android executor permission is lost on resumed broad work — P1, R

**Code:** planner `_broadPlan` honors `isBackgroundExecutor`; coordinator `_planFromWork` around 1265 does not. Entrypoint passes `readIsForeground: () => false` and `isBackgroundExecution: true`.

A worker configured exactly this way and given queued automatic `deltaReconcile` returns deferred without any API call. Thus detecting a change and queuing its follow-up can lead to work that the headless worker cannot resume.

**Method:** centralize admission for fresh and resumed plans; carry bounded worker capability through both. Respect foreground playback/network constraints without equating a sanctioned headless worker with an unsanctioned hidden UI timer.

**Acceptance:** worker probe detects change; a subsequent worker drains its queued delta while the app is closed, with bounded deadlines and correct cancellation. Reproduction is Dart-level; actual WorkManager/device behavior remains a certification requirement.

### F14 — Compatibility audit does not verify song-only changes — P2, R

**Code:** engine `_albumRequiresSongHydration` at 5621 and compatibility rotation around 3860.

Change a track title while keeping album summary/count/duration unchanged. A compatibility audit fetches the artist, skips album hydration, retains the stale song title, and succeeds. A reliable-provider audit visits only 24 artists per weekly rotation: 1,777 artists would require 75 weekly batches (525 days) for one static rotation, and song-only changes still evade that check.

**Method:** distinguish artist discovery from track metadata verification. Maintain per-album verification age/version evidence and a bounded oldest-first verification budget independent of newest discovery. Define a maximum coverage age; allow a deliberate repair to force revalidation when bulk/carry-forward cannot prove content freshness.

**Acceptance:** a song-only correction is observed within the declared coverage bound without a full scan on navigation. Unchanged albums can be skipped only with sufficient version evidence, not just equal counts.

### F15 — Standard genre payload is discarded — P1, R/L

**Code:** API `getGenres` at 235; engine `_syncGenresStrict` at 4319.

The parser reads only `rawGenre['name']`. All 671 live records used `value`, `songCount`, and `albumCount`; none had `name`. A protocol fixture produces an empty successful result. `replaceGenres` then makes that empty result authoritative and records successful genre sync. Existing parser tests use `name`, so they miss the server shape.

**Method:** normalize standard `value`, optionally support compatible `name`, and distinguish an explicitly empty valid collection from records all rejected by parsing. Prevent destructive replacement when the payload is invalid.

**Acceptance:** the exact sanitized live shape imports 671 distinct valid genres (subject to intentional normalization); malformed records are reported; valid empty catalogs still work; sync tests use protocol-shaped responses.

### F16 — Album/artist stars use the wrong portable parameter — P2, R/protocol

**Code:** API `star`/`unstar` at 660; artist/album detail toggle callers; star dispatcher ignores `entry.itemType` when sending.

The wire fixture verifies `star('album-fixture')` sends `id`, with no `albumId`. Navis browses ID3 artists/albums, for which the protocol specifies `artistId`/`albumId`; `id` refers to file/folder identities. The live server may accept aliases, so this is a portability defect, not a demonstrated live failed like. No live stars were changed. [Star parameter contract](https://opensubsonic.netlify.app/docs/endpoints/star/)

**Method:** expose a typed annotation target and preserve its entity kind from UI/outbox to transport for both star and unstar.

**Acceptance:** request fixtures assert distinct song/album/artist parameters, including same textual ID across entity types; live mutation validation, if later performed, must use a deliberately reversible test item.

### F17 — Missing playlist payload is accepted as authority to delete — P0, R

**Code:** API `getPlaylists` around 485 / `_asMap`; engine `_syncPlaylistHeadersStrict`; playlist DAO `reconcileServerPlaylists` at 70.

`{"subsonic-response":{"status":"ok"}}` is accepted as an empty playlist list. Starting with one cached playlist, the integrated API→engine→DAO reproduction deletes it and reports success. This is malformed-response deletion, not a legitimate explicit empty account result.

**Method:** use endpoint-specific structural validation and completeness evidence before clearing collections. Treat unavailable/malformed/truncated as non-authoritative, retain cached data, record a safe reason, and apply validated playlist removal with an audit record. Extend validation to genres/starred/catalog collection decoders; two malformed empty starred snapshots must not substitute for two valid absence observations.

**Acceptance:** missing/wrong-type/truncated containers preserve cached rows; a valid explicitly empty authoritative response follows the chosen removal policy. Detail partial-count validation must also cover playlists, not only albums.

### F18 — In-flight hydration can overwrite a successful local like — P0, R

**Code:** target `hydrateAlbum`; DAO `_pendingStarOverrides` at 2028 and song reconciliation around 907; compare full-promotion journal protection at 3270.

The reproduction holds an album response, applies `updateSongStarred` locally (which records the mutation), and completes the older unstarred response. The song's like disappears. Pending outbound actions are protected, but a successfully acknowledged local edit need not remain in that queue; target/incremental writes do not consistently use the mutation journal.

**Method:** capture request/snapshot start and compare mutation versions inside the write transaction. Preserve edits newer than the snapshot regardless of whether their outbound action was acknowledged. Apply the same rule to artist/album stars and ratings, and avoid pruning journals while any older snapshot can still commit.

**Acceptance:** delay responses across local like→unlike and rating changes, with successful acknowledgement and with offline queueing. The latest user intent survives target, incremental, repair, and restart paths.

## 6. Additional findings, risks, and measured improvements

### F19 — Star outbox lacks serialization and durable transient retry — P1, S

`StarSyncDispatchController._flush` has no in-flight guard and can be launched by multiple listeners. Every exception other than `SubsonicConnectionException` deletes the action, including server/authentication errors that do not acknowledge it. Retrying only on reachability/session events can strand queued work if connectivity remains “online.” UI toggles submit directly while old queued operations can still exist.

Unify stars/ratings around versioned, per-entity desired state and a durable outbox: serialize dispatch, compare versions before send/ack, retain retryable failures with backoff, represent permanent/auth failures visibly, and resume on a due timer. The scrobble service already demonstrates serialization and retry scheduling; reuse its principles without conflating the two payloads. Required tests: two concurrent flushes, opposite toggles during an in-flight request, stale queued action after newer online success, 429/5xx/auth failures, restart, and account switch. These interleavings were inspected, not dynamically certified in this audit.

### F20 — Incremental latency and repair overhead need separate optimization — P1/P2, L/S

The measured incremental read canary reached 697 ms while bulk hydration rewrote live data. Candidate collection reads stayed much faster. `replaceRecentlyAddedRanksFromNewestFeed` also resets the entire canonical album table, and hydration repeatedly loads provisional songs. Fix F07/F10 before tuning concurrency: avoid work that should not exist.

The repair confirmation pass redownloaded all 58 newest-feed pages while reusing its candidate album/song pages. Full newest ordering has no durable page checkpoint of its own. Fresh initial promotion wrote 63,579 rows in a 13.242-second transaction; the stable repair mostly classified 62,578 rows unchanged. Preserve one atomic visibility change, but evaluate indexed SQL/set-based apply, no-op write elimination, staged ordering data, and generation-based reads if measurements justify the added migration complexity. Never expose a half-promoted catalog merely to shorten a transaction.

Acceptance requires three cold/warm paired runs at identical catalog size, stage timings, query queueing, frame percentiles, cancellation latency, and active-playback/scroll measurements. Use the same fixture and trace configuration for before/after comparisons.

### F21 — Terminal status and usage do not fully describe outstanding work — P2, R/L/S

The live manual check ended `partial` with `pendingWork: 0`; verification intent is also stored in JSON capabilities and album hydration flags, outside the work-row count. The session endpoint's `syncWork` is a row count (14 after initial sync), not a count of pending operations. A report's promotion statistics can describe a previous run, as observed during incremental testing. Network usage is measured by category/time window, which can include concurrent interactive requests rather than exact run ownership.

Unify scheduler inputs around versioned durable requests/continuations and expose distinct pending artists, albums, auxiliary work, retry/cancelled/confirmation states. Tag metrics with run/attempt IDs and stage timestamps. Do not label “skipped,” “no changes in covered window,” and “fully current” interchangeably. Keep safe aggregate telemetry, not credentials or media titles.

### F22 — Resumed repair has no clear evidence-expiry policy — P1, S

`_runFullSync` reuses collecting/ready/applying/awaiting-confirmation generations and completed pages without a candidate age/source-revision check. Its artist/newest observations can be fresh while album checkpoints and hydrated songs are old. The deletion fingerprint includes stale artist/album identities but only the **number** of stale songs, not their identities. Equal counts do not bind a confirmation to the same exact removal set.

Specify candidate expiry and consistent-snapshot evidence. Use provider revision/scan state where available; otherwise bound candidate age, revalidate collection boundaries, and abandon inconsistent candidates without touching the committed catalog. Bind confirmation to candidate generation plus exact destructive-set digest, and require a new confirmation when that set changes. Test a server changing between interrupted pages and between review and confirmation. No moving-server destructive experiment was performed against the live account.

### F23 — First-sync completion semantics need one authority — P2, S; decision and correction in §19

`InitialServerSyncController` accepts only `succeeded`, leaving its partial-warning branch unreachable, and an existing unit test intentionally blocks partial completion. `initialSyncRequiredProvider`, however, treats any `lastSynced` or promoted generation as ready. Engine completion timestamps can also be written when a candidate still awaits confirmation. Do not silently loosen onboarding: decide whether safe partial promotion is browse-ready with warnings or remains setup-blocked, then make controller, router, persisted state, and tests use that same predicate.

The live complete first sync passed; this is an inconsistent failure/partial-path contract requiring a focused provider+router test, not a claim that ordinary setup failed in the observed run.

### F24 — Starred synchronization does not import unseen remote items — P1, R

**Code:** engine `_syncStarredContentStrict` at 2261; DAO `batchReconcileSongStarred` at 1313 and its album/artist equivalents.

A valid starred snapshot containing one previously unseen external song returns success, but the song is absent from the database and Liked remains empty. The current reconciliation updates existing identities; it does not import the snapshot's missing metadata. Repair deliberately excludes external catalog rows, so merely fixing the auxiliary scheduler does not resolve remote favorites on a fresh device.

**Method:** materialize absent starred identities as source-aware referenced metadata, preserving external/provisional classification. Reconcile stars after those identities exist. Avoid recursively importing an external artist's entire catalog, and preserve aliases when the server later acquires a canonical copy.

**Acceptance:** first setup with remote-only liked songs/albums/artists shows those items in Liked after auxiliary refresh, survives restart, does not change canonical catalog counts, and does not duplicate items after later identity promotion. This was tested with a fixture; the supplied live account had no starred items.

## 7. Proposed execution contracts

| Operation | Allowed purpose | Completion evidence | Continuation |
|---|---|---|---|
| Initial catalog | Enumerate canonical entities into hidden candidate | Validated promotion; explicit readiness policy | Durable collection/hydration checkpoints; independent auxiliary initialization |
| Automatic check | Cheap index signal plus separately due bounded discovery | Record exact scope and observation time | Evidence-versioned follow-up, eligible worker execution |
| Manual check | Immediate bounded discovery and relevant detail refresh | Changes committed or no changes within stated coverage | Show remaining scope; persist continuation without silently running bulk repair |
| Repair | Comprehensive canonical verification and safe cleanup | Candidate validation, required confirmation, atomic promotion and ledger | Expiring resumable snapshot; exact confirmation binding |
| Target hydration | One requested artist/album/playlist | Validated detail with provenance/mutation protection | Per-target partial/retry state; no catalog status replacement |
| Auxiliary refresh | Starred, playlist headers, or genres | Structurally valid scoped snapshot | Independent deadline and retry policy per domain |
| Outbound annotation | Latest user intent per account/entity | Matching server acknowledgement | Versioned retryable outbox; never discard unacknowledged transient work |

Every plan must carry enforced endpoints, network grant, bytes/pages/entities/concurrency/time budgets, source scope, ownership fence, and a durable request ID. Progress and metrics must refer to that same ID. Use one admission function for new and resumed operations.

## 8. Implementation sequence

### Phase A — Prevent corruption and pin the contracts

- [x] Convert F01, F10, F17, and F18 characterizations into desired-behavior regression tests in the owning suites.
- [x] Add shared response-completeness validation and source-aware persistence boundaries.
- [x] Protect all local mutations inside commit transactions; defer file deletion until commit.
- [x] Fix genre decoding (F15) and add exact protocol-shaped fixtures.
- [x] Review existing remote-song plan overlap before changing identity/retention logic.
- [x] Add a safe, evidence-driven migration/repair for preexisting misclassified rows, with dry-run counts and retained references.

**Exit:** mixed-source library survives repair→manual→target→restart without source drift; partial/malformed responses cannot erase tracks, playlists, caches, or newer user edits. No public capability or download preservation regression.

### Phase B — Make discovery and recovery converge

- [x] Version work by fresh evidence (F08/F11); retain explicit cancellation semantics.
- [x] Fix transient terminal outcomes and persisted backoff (F04).
- [x] Unify worker/resumed admission and lease recovery/fencing (F09/F13).
- [x] Separate transport offsets from canonical counts (F05); fix capped discovery (F12).
- [x] Add automatic newest discovery and maximum verification age (F02/F14).
- [x] Define candidate expiry and exact deletion confirmation (F22).

**Exit:** repeated server changes converge without manual repair, even after offline periods, capped pages, worker restarts, and lease expiry. No foreground/background execution overlap can publish stale work.

### Phase C — Complete auxiliary and annotation synchronization

- [x] Give starred, playlist headers/content, and genres independent due/checked/success/retry state (F03).
- [x] Make playlist content change detection include server version/order evidence (F08).
- [x] Fix typed star wire parameters (F16); serialize/version the annotation outbox (F19).
- [x] Resolve first-sync partial readiness explicitly (F23). The existing strict
  contract is now enforced by both active and legacy controllers; the user
  selected full-screen, complete-catalog gating in §19.
- [x] Materialize unseen remote favorites (F24) and ensure liked/playlist references persist without polluting canonical library membership.

**Exit:** first setup initializes fixture user data; changes from another client converge within stated bounds; local edits survive reconnect/restart and older snapshots.

### Phase D — Reduce work and prove smoothness

- [x] Enforce execution budgets and disable unplanned bulk scans (F07).
- [x] Preserve partial newest ordering and eliminate no-op rank writes (F06).
- [x] Profile live-table hydration, provisional identity queries, classification/apply and newest replay (F20; measured corrections in §§14–18, with platform/soak limits retained).
- [x] Attribute metrics/pending state to durable operations (F21; bounded capture limits in §15).
- [x] Measure before/after under playback, scrolling, offline transitions, and large libraries (results and unmet targets below).

**Exit:** performance improvements meet the proposed gates below without weakened correctness checks. Update architecture, workflow/CI docs for new diagnostics, migration tests/generated outputs for schema changes, and both changelog/release-note sources for user-visible behavior.

## 9. Acceptance matrix and proposed performance gates

These are **proposed targets**, not numbers already achieved on every platform.

| Scenario | Required assertion |
|---|---|
| No-change manual check, small bounded window | No whole-library `search3` scan, no canonical source drift, no unchanged-row rewrite storm |
| New album with unchanged cursor | Manual and scheduled discovery both find it within their declared bounds |
| New changes after prior completed/cancelled work | New evidence is processed once; cancelled identical evidence does not resurrect |
| Mixed-source artist/album/song payloads | Canonical count reflects only server-local items; referenced external items remain available |
| Empty/malformed/partial responses | Preserve committed rows until evidence is authoritative; record partial/defer reason |
| Same-count playlist or track metadata change | Eventually detected within the declared verification-age SLA |
| Wi-Fi→metered/offline during a run | Stop new disallowed requests; budget retained; one resumable continuation |
| Concurrent annotations and older network responses | Latest local version wins in every ingestion path |
| Crash before/during/after promotion | Either old or new committed generation; no partial visibility or stale owner commit |
| Real Android worker resume | Queued delta drains with UI closed; foreground contention respects ownership |
| Large removal | Exact reviewed candidate/set is confirmed; mutation and ledger commit together |
| Detail removal with cached/queued song | Permanent download/active queue/alias ownership retained according to existing contracts |
| Database responsiveness under interaction | Target p95 under 20 ms / p99 under 50 ms for canary and representative library reads; explain outliers separately |
| Frames on a 60 Hz target | Target build+raster p99 below 16.7 ms during scripted interaction; also record dropped frames and input response |
| Cancellation | Target acknowledgment under 250 ms, active request cancellation under 2 s where transport supports it; never bypass a commit safety boundary |
| Performance comparison | At least three paired cold/warm runs with same account/catalog/device; report bytes, requests, peak RSS, phase duration and playback gaps |

Set a concrete freshness SLA before implementing Phase B; e.g. one configured eligible automatic interval for newest discovery, with a separately documented maximum metadata-verification age. Do not promise instant change detection that the server protocol cannot provide.

## 10. Validation still required for implementation

- Actual Android WorkManager lifecycle, process death, foreground/worker concurrency, and device metering; the audit ran Dart policy tests, not a device.
- Active audio, rapid queue changes, scrolling, input latency, and memory-pressure soak during sync.
- Populated remote starred/playlist account scenarios; the supplied account was empty for those domains. Deterministic fixtures must cover them first.
- Deliberate server edits during candidate collection, annotation acknowledgement races, and full candidate-expiry behavior.
- Cold/warm statistical comparison with Symfonium, if product wants a comparative performance claim.
- iOS/macOS/Windows runtime certification for affected platform contracts.

`./tool/check.sh`, code generation, and repository-wide analyzer were not run for this audit: the deliverable changes documentation only and the working tree already contains unrelated implementation work. The focused tests and Linux runtime evidence above were actually executed. Implementation phases must run the repository's required gate and runtime loop; this audit is not a waiver.

## 11. Completion rules for future work

For every finding, record the fixing commit, desired-behavior regression test, runtime evidence, migration/backward-compatibility handling, and any remaining limitation. Keep the original observation and append the resolution; do not turn a proposal into an established truth without evidence. Close P0 findings before performance tuning, and do not close a worker or playback item using only a mock test.

## 12. Implementation evidence and checkpoint history

2026-09-19: Phase A implementation started. Added authoritative-container parsing,
protocol `genre.value` support, shared album/playlist detail validation, canonical
persistence source guards, and transaction-local protection for edits made after
a snapshot started. Incremental artist discovery excludes external albums.
Ordinary album reconciliation collects cache paths until its transaction commits;
target hydration defers cleanup until the outer identity transaction commits.
Mutation journals retain the latest value-change marker per entity/field so a
newer snapshot cannot prune protection still needed by an older in-flight one.

Focused engine/API/library DAO validation: **117 tests passed** at the first
safety checkpoint (`build/sync-implementation-1-4-0/safety-tests.log`). Additional
auxiliary/reference coverage is being added. This is not release validation:
full gate, runtime/restart acceptance, remaining Phase A requirements, and
Phases B–D remain outstanding. No plan phase is declared complete.

### F25 — Newest staging can falsely complete an album with zero stored songs — P0, R/L (implementation validation)

The first implementation runtime gate found a previously uncovered defect.
`_stageNewestAlbumsForHydration` inserts a new pending album; the following
artist-detail metadata pass compares that row with the same server summary.
`_albumRequiresSongHydration` ignored the existing `songsHydrated=false` flag.
An unrelated metadata difference then placed the album in
`hydratedWithoutSongRefresh`, marking it hydrated without ever fetching tracks.
The isolated loopback run persisted declared count **1**, hydrated **true**, and
actual stored track count **0**. Its required `getAlbum` assertion failed.

Fix: pending hydration itself is a reason to fetch tracks. Regression coverage
asserts the request and stored tracks; the running-app album diagnostics now
optionally return `persistedSongCount` using `verifySongs=true`. The manual
reconnect/restart gate requires that count, not just the stored hydration flag.
Runtime acceptance is pending the rerun; this finding is part of Phase A.

First full gate ran formatting, generation, analysis and the full suite; one
old DAO test needed explicit local provenance for its intentionally remote-prefixed
canonical fixture. This preserves the test's same-ID/reference-promotion contract
under the stricter source boundary. The gate has not yet passed as a whole.

### Scheduling and favorites checkpoint

The F25 runtime rerun passed, including actual stored song-count verification and
clean restart (`build/manual-discovery-diagnostics/20260919T160843Z-clone`).
The app-owned restart screenshot was inspected. This replaces the pending-rerun
statement above, without claiming the later changes have runtime acceptance yet.

F03 now has independent durable success/retry checkpoints for starred content,
playlist headers, and genres. Catalog requests drain due domains after their
own operation; failures retain backoff and do not overwrite the catalog outcome.
The first-sync fixture imports user data and verifies fresh domains are not
refetched; another fixture fails starred, verifies other domains complete, then
retries only starred. The focused coordinator/regression/DAO checkpoint passed
**45 tests** (`build/sync-implementation-1-4-0/auxiliary-tests.log`).

F24 acceptance now covers the actual favorites query as well as persistence:
referenced remote favorites appear in Liked while canonical song enumeration
remains empty. A starred snapshot entry without its optional timestamp receives
a local observation timestamp so its membership is retained. Explicit liked
artist/album/song selectors admit these references; ordinary catalog selectors
retain source filtering.

F02 discovery policy: eligible due automatic catalog checks inspect at most two
newest pages, independent of the artist cursor; manual checks retain five pages.
The freshness guarantee is one configured **eligible** interval for additions
within that bounded head window. Offline, metered, playback and hidden-foreground
constraints defer broader discovery; no instantaneous or whole-catalog guarantee
is implied. Older metadata verification remains a separate F14 requirement.

F22/F23 checkpoint: repair candidates expire after 24 hours; deletion confirmation
binds generation, candidate start and sorted exact removed identities; completed
newest ranking is checkpointed for the confirmation pass. Partial syncs no longer
advance complete-catalog timestamps. Explicit hydration continuation uses its
stored work even when the last complete timestamp is stale. Setup readiness uses
a shared completion predicate. Focused engine/regression/setup tests passed
**97 tests** before the auxiliary changes; adversarial expiry/boundary tests and
final runtime/full-suite gates remain required.

F09 now has SQL-level ownership fencing for all coordinated catalog/target runs,
recovery and provider reset. A non-reused opaque token is checked under SQLite's
writer lock and again at commit; expiry rolls back nested writes. This replaces
the proposed numeric fence with equivalent unique-token ownership enforcement
under the database's single-writer serialization, without a schema migration.
Four on-disk database tests passed, including replacement from a second SQLite
connection and expiration before outer commit. The engine/coordinator regression
also blocks a delayed album response after replacement and preserves the newer
owner's song and lease (`fence-database-tests.log`, `fence-regression-tests.log`).
These results do not substitute for actual Android worker lifecycle validation.

The next full `./tool/check.sh` passed: **1,455 tests passed, one skipped**, with
formatting, generation and analysis passing (`check-third.log`). This checkpoint
precedes the following diagnostics fix and later work.

The subsequent runtime gate verified both new and existing album track counts,
but failed its endpoint-scope assertion: the catalog terminal event reported only
`getGenres`, inherited from the later auxiliary run. This is direct additional
F21 evidence. Endpoint counts now travel with the returned `LibrarySyncState`
instead of reading the engine's mutable last-operation counters at handoff.
The gate assertion is retained; its rerun is pending.

F21 endpoint attribution regression tests passed (**44 focused tests**), and the
running-app manual discovery/offline/reconnect/restart gate now passes with its
original endpoint assertions (`build/manual-discovery-diagnostics/20260919T163341Z-clone`).
The app-owned restart screenshot was inspected; the discovered track is present
and playable. Full per-request bytes/retries attribution remains open.

### Annotation checkpoint (schema v74)

F16 now sends the exact song/album/artist ID3 favorite parameters, verified for
both star and unstar. Production controls, context menus and audio favorite
actions now save through `StarSyncDao`; the shared dispatcher is their only
network writer. Ratings use the same outbox without superseding a pending star.
Local writes and queued intent commit together. New intent receives a new row ID,
so acknowledgement of an older operation cannot delete it. Failures preserve
intent with persisted backoff; authentication failures resume after session
change. Queue observation and a timer remove the old dependency on connectivity
transitions. Client/account identity is checked before acknowledging a response.
Diagnostic builds continue to suppress outbound annotations.

Schema v74 adds operation, attempts, retry time and safe failure fields to the
existing queue, preserving v73 pending actions. Generated Drift output is updated.
Focused dispatcher/protocol/migration tests passed **59 tests**, and subsequent
engine/ingestion/player tests passed **122 tests** (`annotation-tests.log`,
`annotation-ingestion-tests.log`). The full gate and runtime UI/annotation fixture
loop are pending for this checkpoint. Cross-process outbound ownership and
server Retry-After behavior still need explicit validation; F19 is not closed.

### Budget, verification and source-evidence checkpoint (schema v75)

F07 now uses a shared execution/transport scope. Endpoint allowlists, wire request
attempts (including immediate retries), album/page limits, concurrent requests,
response/total bytes, live network/playback admission and elapsed time are checked
within the operation. Ordinary concurrent UI requests have a separate async scope
and cannot enter its counters. Long Retry-After responses return to durable
scheduling instead of sleeping through a sync window. Current limits:

| Operation | Requests | Album details | Newest pages | Total bytes | Time | Concurrency |
|---|---:|---:|---:|---:|---:|---:|
| Eligible automatic discovery/continuation | 96 | 32 | 2 | 32 MiB | 30 s | 3 |
| Manual discovery | 200 | 64 | 5 | 64 MiB | 60 s | 6 |
| Bounded metered discovery | 200 | 3 | 1 | 32 MiB | 60 s | 1 |
| Initial catalog / repair | 10,000 | 10,000 | complete snapshot | 512 MiB | 10 min | 6 |
| Metered automatic probe | 1 | 0 | 0 | 32 MiB | 30 s | 1 |

Response limits are 16 MiB for bounded operations and 64 MiB for broad snapshots.
These are ceilings, not targets. Pending hydration commits small batches before
admitting another batch. A 35-album regression proves 32 details commit, three
remain queued, and the next run fetches only those three. It also exposed and
fixed completed work not reopening for a due automatic continuation, and an
unplanned index refresh at the end of hydration-only work.

F14 now persists `albums.songs_verified_at` (v74→v75). Only complete song snapshots
advance it; header changes, locally carried-forward tracks and migration do not.
Eligible non-metered catalog passes enqueue up to 16 oldest albums whose track
verification is unknown or at least seven days old. This detects song-only edits
without relying on a changed artist cursor or album header. Typed deliberate
repair does not use unchanged album headers to bypass missing bulk-index tracks.

The coverage bound, assuming a stable catalog, successful requests and enough
eligible capacity for each 16-album slice, is seven days plus
`ceil(canonical_album_count / 16) × eligible_check_interval`. At 5,644 albums and
hourly eligible checks that is about 21.7 days. Playback, offline/metered periods,
newly discovered backlog, transport failures and budget exhaustion extend wall
clock coverage; no unconditional 30-day or instant detection guarantee is made.
Newest discovery retains the one-eligible-interval SLA for its bounded head window.

F10 has an explicit-source repair primitive with dry-run counts. Current server
`isExternal: true` observations can demote already polluted IDs while retaining
rows, relationships, annotations and cached files. Prefix inference alone is not
repair evidence. Fresh explicit local observations can still promote the same ID.
The engine applies this evidence from canonical page, newest, artist and bulk-song
responses; the ledger records aggregate affected counts. This does not infer that
all children of an external parent are external.

Focused source/age/engine/migration suites passed **131 tests**. The full gate
then passed **1,471 tests, one skipped**, including formatting, generation and
analysis (`source-and-age-tests.log`, `check-budgets-age.log`). That full gate
precedes the evidence/confirmation and runtime-fixture changes below.

### Additional verified defect F26 — Deferred album starves later hydration — P1

Adding oldest-first verification reproduced a loop in which a failed album was
removed from the in-memory pass but remained the first pending database row. A
later chunk selected it again indefinitely, starving remaining albums. Chunk
selection now restricts itself to IDs still eligible in the current pass. The
existing multi-album engine test that timed out at 30 seconds completes within the
focused suite; failed work remains persisted for a later attempt.

### Confirmation and evidence work in progress

A second deletion observation now rebuilds the server snapshot instead of replaying
cached pages/tracks. It retains the candidate identity for exact-set comparison;
a changed removal set requires another observation. Interrupted snapshots recheck
the first and last saved transport-page boundaries; changed boundaries discard
saved pages. A server without a snapshot revision cannot provide a mathematically
atomic multi-request view; the 24-hour expiry and fresh deletion observation are
additional safeguards, not a claim that boundary checks detect every middle-page
change.

Durable work accepts an evidence version transactionally. Playlist header/version
evidence can reopen cancelled work only when it changes; repeated identical
observations preserve cancellation. Probe follow-ups carry cursor/index evidence.
A cancelled automatic catalog attempt is not immediately replayed; a later due
observation or explicit manual intent can start a new operation. The pending
acceptance tests and runtime checks must pass before these items are closed.


### Schema v76, duplicate playlists, and cancellation ownership

Implementation found **F27 (P1)**: `playlist_songs` keyed membership by
`(playlistId, songId)`, although Subsonic playlists can repeat a track. The key
is now `(playlistId, sortOrder)`. Migration 75→76 preserves existing memberships
and assigns deterministic dense positions. Identity remapping updates every
occurrence. Regression coverage verifies `[s1,s1,s2]` followed by `[s2,s1,s1]`;
the migration fixture verifies old membership retention and foreign keys.

The same migration adds an independent annotation-dispatch lease. Dispatchers
acquire a token, renew it, and acknowledge/fail queue versions inside a
transaction that checks ownership. Empty queues do not start heartbeat timers;
disposal cancels both transport and timers. This serializes active writers in
one database; it cannot provide server-side exactly-once delivery after an
ambiguous network timeout because Subsonic offers no idempotency token here.
Star/rating assignments are retried as desired state.

The full repository gate passed **1,479 tests, one skipped** at
`build/sync-implementation-1-4-0/check-v76-fourth.log` before the following live
checkpoint correction. The opt-in loopback fixture delivered song, album and
artist stars plus a rating through the production dispatcher, drained the
outbox, and survived restart. Evidence:
`build/manual-discovery-diagnostics/20260919T171518Z-clone/`.
Later code changes still require a new final gate and runtime validation.

### F28 — Budget exhaustion replays committed artist work — P1, R/L

The first interactive live run reached the manual time limit after committing
artist metadata but before persisting its traversal cursor. The next run
repeated that artist work. Metadata and its cursor now commit in the same
transaction before hydration. An interrupted artist batch retains successful
details while leaving failed/unstarted IDs pending. Typed passes cap artist
verification at 24 automatic / 48 manual details as well as the shared transport
budget. Deferred outcomes reload persisted hydration/verification counts.

The regression `F28 artist checkpoint survives a following hydration budget
stop` discovers 35 albums from an artist, commits the automatic allowance of 32,
and verifies that the next pass fetches only the remaining three albums without
another artist request. The 21-test sync regression suite passed after this fix.

Diagnostics reports now read endpoint counts from immutable operation state,
matching the terminal ledger. Polling status no longer overwrites them with the
last auxiliary operation's mutable engine counters. The first exploratory run
is retained as pre-correction evidence, not used as the final performance claim.

Phases A–C checklist items above describe implemented contracts with focused
regressions. They do not waive the outstanding live/platform acceptance matrix
or final review. Phase D and final runtime certification remain in progress.


### F29 — Android headless worker cannot read native metering — P1, L/S

An actual WorkManager catch-up on the isolated emulator sidecar returned
`deferredPolicy` on Android's unmetered `AndroidWifi` network. Source inspection
confirmed that `com.navis.app/network_cost` was registered only by MainActivity.
The headless engine uses a separate messenger; its missing-channel response
became `null`, and the worker deliberately treated unknown metering as metered.
Thus the default unmetered-only policy could prevent every headless sync.

Foreground and worker engines now register the same small Android network-cost
channel against `ConnectivityManager`. The worker unregisters it on close. The
conservative fallback remains intact. Live worker recertification is pending;
this is a platform implementation defect, not a reason to relax metering policy.


### F30/F31 — Discovery priority and remote backlog isolation — P1, R/L/S

Interactive live validation exposed two additional scheduling problems:

- **F30:** discovered newest albums entered the ordinary hydration backlog;
  the DAO applied SQL `LIMIT` before restoring caller priority, so ordered input
  alone did not guarantee the newest album was fetched. Due automatic checks
  could also be consumed by old hydration work before checking new arrivals.
- **F31:** canonical pending-ID/count queries included unhydrated provisional
  and external references. The detail validator correctly rejected external
  snapshots as canonical, but the scheduler repeatedly spent attempts on them.
  This selector defect was confirmed in a deterministic remote-reference
  regression. The live run's hundreds of canonical pending albums had a
  separate cause, established below as F32; those counts are not evidence that
  remote references caused the live backlog.

Canonical pending selectors now require both non-provisional and non-external
membership. Targeted external detail requests retain their separate path.
Newest discrepancies join explicit interaction priorities ahead of ordinary
backlog, and bounded DAO selection honors that input order before limiting.
A due automatic catalog interval inspects newest discovery ahead of old detail
work; within the interval, pending-only continuation remains available.
Regressions require the new arrival to be the first hydrated album despite 35
older pending albums, and require remote reference rows to consume zero catalog
hydration attempts while a starred reference remains stored.

The interrupted live series in
`build/sync-implementation-1-4-0/live-before-canonical-backlog-fix/` is retained
as defect evidence. It is not the final after-comparison. The final paired
series must be repeated after these corrections.


### F32 — Timestamp precision and header-only changes replay track hydration — P1, R/L

The next live pass still staged 500 newest-feed albums although their persisted
headers were unchanged. A direct read-only sample of 20 server albums showed
**20 exact timestamp mismatches and 20 matches at the stored whole second**.
Subsonic supplied subsecond `created` values while Drift persisted Unix seconds.
The exact DateTime comparison marked these headers dirty on every check.
Separately, `_stageNewestAlbumsForHydration` marked every header discrepancy as
needing tracks, including rating, play-count, genre, and creation-date changes.

Header comparisons now normalize creation/star timestamps to storage precision.
Newest staging uses the same track-refresh predicate as artist discovery:
new/unhydrated albums or track-relevant metadata changes require hydration;
header-only updates preserve verified membership. New albums still must fetch
actual songs (F25), and the maximum-age path still detects song-only changes
(F14). Regressions verify repeated subsecond observations cause no album-detail
requests and header-only changes preserve two existing tracks without fetching.
The focused engine/regression suite passed **110 tests** after this correction.

Evidence: `build/sync-implementation-1-4-0/timestamp-precision-evidence.json`,
`timestamp-header-tests.log`, and `live-before-timestamp-fix/`. A fresh final
benchmark replaces that exploratory series; no failed intermediate run is
presented as performance acceptance.


### Actual Android worker evidence

An isolated Android emulator sidecar used production WorkManager, secure storage,
Dart execution bootstrap and SQLite leases, with an HTTP loopback fixture account.
The worker initially reproduced F29 (`deferredPolicy` on unmetered Wi-Fi). After
registering the native cost channel it completed catch-up in 2,458 ms. Marking
Android's fixture Wi-Fi metered produced `deferredPolicy` again, as intended.

With an unmetered-constrained catch-up queued, the activity was backgrounded and
its process killed. Restoring unmetered Wi-Fi started a new process; persisted
worker history records completion, and a subsequent bounded hydration completed
in 831 ms. App API verification reported the existing album's actual stored
track count as one and `songsHydrated=true`. A simultaneously requested foreground
repair caused the worker to return **`leaseHeld` in 7 ms**, preserving foreground
ownership. That fixture's deliberately limited catalog then required deletion
confirmation; the two committed albums remained visible.

Evidence is under `build/sync-implementation-1-4-0/android/`, including
`native-metered-worker.json`, `recovered-worker.json`,
`worker-existing-album.json`, and `foreground-repair-final.json`. The app-owned
screenshot was inspected: both fixture albums were visible behind the normal
battery-optimization prompt. The original emulator Wi-Fi policy was restored.
Native scheduler unit tests also passed via `:app:testSideloadProfileUnitTest`
(`android-native-unit-second.log`). These are emulator/service results, not a
claim of physical-device, OEM battery-policy, or other-platform certification.


### F33 — Cancellation lets a waiting repair start afterward — P1, R/L

The final live transition test acknowledged cancellation immediately but did not
settle within 30 seconds. Durable history showed the active check was cancelled,
then the stronger repair that had been waiting behind it started and issued 78
requests before test shutdown cancelled it. The controller's priority queue
unconditionally invoked its continuation after the active future completed; the
coordinator had the same unchecked wait-before-replan pattern.

Both queues now capture a cancellation generation. Cancelling invalidates waiting
commands as well as active transport; queued coordinator work is atomically
marked cancelled only while still queued, never by overwriting another owner's
running work. A later explicit command captures the new generation and remains
allowed. Provider and production coordinator regressions cover both boundaries.
The first focused API/provider suite passed 50 tests; the coordinator/regression
suite passed 42. Live recertification follows below.

### Final-review compatibility correction

F17's strict snapshot parsing was initially applied too broadly to playlist
mutation acknowledgements. `updatePlaylist` legitimately returns an empty success
envelope ([OpenSubsonic contract](https://opensubsonic.netlify.app/docs/endpoints/updateplaylist/)).
Mutation parsing retains the existing compatibility behavior, while `getPlaylist`
and `getPlaylists` still reject omitted authoritative containers. A regression
asserts both behaviors against the same empty envelope. This was caught and
corrected in review; it is not represented as a pre-existing production defect.

### F34 — Complete mixed album responses were mistaken for truncation — P1, R/L

Read-only probes of the six unresolved albums distinguished four genuinely
incomplete responses from two complete mixed responses. The complete responses
advertised/returned 16/16 and 7/7 tracks; respectively 15 and two children were
explicitly external and referenced remote parent albums. Filtering those children
before checking the advertised total incorrectly rejected the local subset.

The shared validator now checks identity, uniqueness and total completeness on
the raw response, then projects local membership. Only explicit external
provenance permits a different parent. Targeted detail can retain those tracks
and provisional parents as references; broad catalog discovery excludes them.
The header's advertised count remains the server value, avoiding repeated false
header discrepancies. Local stored track count must be queried separately.
Tests cover target, incremental and repair paths, plus a truncated mixed response
that must retain old membership. The focused engine/regression suite passed
**116 tests** (`mixed-snapshot-focus.log`).

This is a compatibility correction to the newly strict validation, rather than
permission to accept genuinely truncated details. The four remaining raw
responses advertised/returned **334/221, 40/37, 30/14 and 2/1**, with unique local
tracks and matching album identities. Evidence:
`build/sync-implementation-1-4-0/live-incomplete-album-evidence.json`.

### F35 — A partial first-sync continuation widened its admitted plan — P1, R/L

After partial catalog promotion, a retry was admitted as incremental work, but
`_resolveMode` independently saw the missing completion timestamp and selected a
full scan. The request scope correctly denied `getArtists`; the user received a
failed retry without useful progress. The engine now respects the coordinator's
admitted plan. Broad initial/repair plans already request full mode explicitly;
legacy uncoordinated entry points retain their timestamp-based selection.
A regression seeds a promoted generation without `lastSynced` and requires the
incremental check to complete without artist-index or full album-list requests.
It passed in the 116-test suite above.

## 13. Live implementation measurements and remaining acceptance gaps

These results supersede earlier statements that live and Android validation had
not yet run. They do **not** close all smoothness or first-setup acceptance gates.
The benchmark used the same Linux machine, account and starting database clone
for each pair. Each cold leg started a fresh process; its warm leg reused that
process. The baseline includes the user's pre-existing work but none of these
sync fixes. Both builds included identical diagnostics scroll/reset/RSS probes.

### Playback and scrolling comparison

Medians across three baseline pairs and three playback-qualified implementation
pairs (2, 3 and 4):

| Metric | Before cold | After cold | Before warm | After warm |
|---|---:|---:|---:|---:|
| Reported network MiB | 66.514 | 2.529 | 66.328 | 2.425 |
| Requests | 114 | 118 | 112 | 118 |
| Process peak RSS MiB | 1,024.2 | 665.3 | 1,398.2 | 676.8 |
| Elapsed seconds | 65.764 | 61.315 | 64.568 | 60.802 |
| Frame build+raster p99 ms | 26.119 | 25.597 | 25.985 | 27.432 |
| DB canary p95 / p99 ms | 15.178 / 26.833 | 9.559 / 16.503 | 21.402 / 38.943 | 11.519 / 24.633 |
| Scroll command p95 ms | 298.825 | 295.102 | 294.507 | 293.922 |

Network bytes fell about **96%**, cold peak RSS about **35%**, and warm peak RSS
about **52%**. These are sample comparisons, not confidence bounds. Request
count did not fall: bounded detail verification replaced whole-library bulk
search. Elapsed time still approached the manual budget while old verification
work remained. Warm RSS is the process's cumulative high-water mark, not an
isolated per-operation allocation measurement.

The baseline issued 58 bulk song pages per incremental check and inflated local
album count to 6,331 cold / 6,936 warm. The implementation issued no bulk song
search and retained **1,777 artists / 5,645 albums / 56,166 songs** throughout
these pairs. The starting clone had 5,644 albums / 56,158 songs; the one added
album and eight songs were actual new local content. Starting catalogs matched;
ending catalogs necessarily differ because the baseline reproduced source drift.

All playback-qualified runs showed advancing position and playing state with
zero recorded load failures. An additional implementation pair (pair 1) paused
at approximately 63.47 seconds for an undetermined reason and remained paused
through its warm leg. Its raw evidence is retained and excluded only from the
playback-qualified medians; this is an unresolved playback observation, not a
successful uninterrupted-playback run. Muted diagnostics do not measure audible
gaps. Scroll command latency includes a deliberate 250 ms animation and must
not be called pure input latency.

**Smoothness target remains unmet.** After-run p99 frames exceeded 16.7 ms; a
30-second scrolling/playback control without sync also measured p99 **23.562 ms**.
Individual DB p95 outliers were 26.417 ms (pair 3 warm) and 24.158 ms (pair 4 cold),
above the proposed 20 ms target. There is no demonstrated consistent frame-time
improvement and no measured parity with Symfonium. Next profiling should separate
base library-grid rendering from sync-induced invalidations, then measure
representative library reads in addition to the canary.

Evidence: `build/sync-implementation-1-4-0/live-comparison.json`,
`live-comparison.txt`, `baseline-live/`, and `live/`. The app-owned pair-3 warm
screenshot was inspected: local album grid and active player rendered correctly.

### Repair, transitions and persistence

The live repair retained 1,777 / 5,645 / 56,166 rows and finished partial with six
unresolved albums before F34. It used 137 requests / 77,987,657 reported bytes.
Promotion analysis took **7.785 s**, reported apply **1.471 s**, with 334 changed
and 62,975 unchanged rows. Its 167 candidate pages had a maximum of 384 rows and
maximum page latency 164 ms. Collection canary p99 was 10.5 ms; during the phase labelled `applying`,
canary maximum/p99 reached **624.517 ms** (15 samples). The audited prior phase
maximum was 560.58 ms. F37 below establishes that this old phase included analysis
and cleanup, so the sample does not isolate atomic publication or prove database
lock contention. This work has **not** established that the F20 latency target is met. A future change should profile
identity queries and prepared writes before reducing the atomic visibility or
lease safety boundary. Follow-up source inspection confirmed that the file-backed
database already has WAL and a one-reader pool; adding the same mechanism again
is not a remedy. Further tracing must distinguish SQL/reader queueing from
Dart-isolate scheduling delays before attributing the canary stall to a lock.

Three post-repair warm checks still traversed inherited artist verification
(remaining 1,569 / 1,521 / 1,473) and discovered additional incomplete details;
they are not evidence of a fully-current no-op library. They used 101–109
requests and approximately 2.6–2.9 MiB. Restart retained committed catalog state.

After F33, live cancellation acknowledged in **3.846 ms** and settled in
**567.919 ms**, with no waiting repair restarting. An offline transition produced
`deferred` and retained the collecting candidate for recovery. Evidence:
`live/cancel-timing.json`, `offline-result.json`, `repair-report.json`,
`repair-restart-report.json`, and `post-repair-warm-*-report.json`.

### First-time setup and the then-outstanding product decision

The accelerated six-second diagnostics lease expired in the large first-sync
validation path. With the production-length 600-second lease, the same isolated
setup promoted 1,777 artists / 5,645 albums / 55,887 songs but correctly remained
partial before F34. Existing incomplete tracks could be retained during repair;
a fresh library cannot safely invent or fully validate them. Root-failure logging
previously hid the final failure behind earlier entity diagnostics, so the first
failed run alone does not prove which root exception occurred.

Diagnostics now permit a documented lease-duration override while production
retains its ten-minute contract, and always record terminal root failures.
The inspected first-setup screenshot displayed the existing failure/retry screen.
The current consistent readiness predicate blocks partial setup. At this checkpoint, the user had not yet chosen whether safely promoted partial
libraries should become browse-ready. That decision is recorded in §19; no
partial-readiness relaxation was implemented.

### Remaining work, with no implied certification

- F23 (at this checkpoint): decide and test first-setup policy across the
  controller, router, persisted state, retry behavior and cold restart. See §19.
- F20: investigate atomic repair read stalls and library-grid frame cost; rerun
  the relevant measured targets after any optimization.
- F21: current endpoint/request-budget metrics, active status, pending hydration
  and artist verification are reported; historical promotion counters are now
  explicitly labelled `lastCommittedCatalogPromotion` with generation. Bounded durable phase/request/retry evidence and exact attempt correlation are
  now validated in §15; truncated or interrupted captures remain explicitly
  labelled and do not establish full freshness or performance.
- Investigate the unexplained paused playback pair. Memory-pressure soak, rapid
  queue changes and audible continuity are not certified by position sampling.
- Real account favorites/playlists were empty; populated cases are fixture-tested.
  Android worker/metering/process-death evidence is emulator-based. iOS/macOS/
  Windows and physical OEM background behavior remain unverified.

### Latest correctness gate and live recertification

`./tool/check.sh` passed after F34/F35 and the final cancellation/diagnostics
changes: **1,497 passed, one skipped**, with formatting, generated code,
analysis, migration and critical reliability gates passing
(`build/sync-implementation-1-4-0/check-mixed-final.log`). The focused album suite
passed 116 tests. The implementation diff was reviewed against the preserved
pre-implementation working tree; unrelated player/radio work remains intact.

The fresh large-library runtime with the 600-second lease then promoted
**1,777 artists / 5,645 albums / 55,893 songs**, with exactly **four** pending
incomplete albums. F34 reduced the six pending cases to four and admitted the
six validated local tracks from the two mixed responses. No provisional or
external rows entered this fresh canonical catalog. An incremental retry issued
`getIndexes:1`, newest pages:5, `getArtist:48`, `getAlbum:56`, with no broad album
scan or bulk song search; it preserved the same four pending albums and catalog.
Cold restart retained those counts and continued bounded verification. The
router remained `initialSyncRequired`; this is strict partial behavior, not a
claim that onboarding completed. Session snapshots can catch the controller
between continuations (`running`), and should be interpreted with the terminal
catalog result. The app-owned partial-setup screenshot was inspected.

Evidence: `live/initial-mixed-result.json`, `initial-mixed-report.json`,
`initial-mixed-retry-report.json`, `initial-mixed-restart-session.json`, and
`initial-mixed-restart-report.json`. This rerun specifically certifies F34/F35;
it is not included in the earlier three-pair performance comparison.

The final `NAVIS_ANNOTATION_FIXTURE=true ./tool/manual_discovery_diagnostics.sh`
also passed against the latest code, covering offline discovery, unchanged-index
reconnect, annotation delivery assertions, actual stored tracks and clean restart.
Both app-owned screenshots were inspected: the discovered album and its track
remain present with no overflow. Evidence:
`build/manual-discovery-diagnostics/20260919T185935Z-clone/runtime-validation.json`
and `build/sync-implementation-1-4-0/manual-discovery-final.log`.
`git diff --check` passed; the changed/untracked deliverable scan found no supplied
credential literal or matching secret assignment across 116 files. The temporary
live credential, isolated Android sidecar/emulator, fixture service and baseline
worktree were removed/stopped. Ignored measurement artifacts and the baseline
patch remain for reproducibility; the normal user database was not modified.

## 14. Follow-up performance investigation

### F36 — Metadata upserts unnecessarily update primary keys — P1, R

The first independent F20 follow-up traced SQL through the production repair
engine and a disconnected API backed by the same large catalog clone. SQLite
foreign keys remained enabled and the executor used the production configuration
of a background writer plus one WAL reader. The trace showed **4,445 ms** spent
in 15 artist upsert batches while applying 710 changed artists. Each batch's
conflict clause assigned `id` to the same value as its conflict target.

An isolated SQLite experiment confirmed the mechanism. Updating 200 artist rows
with `SET id=id,name=name` took **1,280.549 / 1,278.772 / 1,278.503 ms**; updating
the same rows with `SET name=name` took **0.325 / 0.294 / 0.282 ms**. Each trial
ran in a rolled-back transaction. `EXPLAIN QUERY PLAN` showed two `SCAN songs`
foreign-key checks per primary-key self-update, absent from metadata-only updates.
This is unnecessary reference validation, not useful song synchronization.

All eight canonical/provisional artist, album and song metadata conflict-update
paths now omit the primary-key assignment, including album-detail reconciliation.
Insert IDs and real identity remapping are unchanged. A regression installs
`BEFORE UPDATE OF id` rejection triggers, exercises insert then update in each
path, verifies metadata and relationships, and checks foreign-key integrity.
This guards the performance-relevant SQL behavior without a flaky timing limit.
The focused DAO/provisional/sync-regression suite passed **54 tests**.

A same-clone disconnected repair comparison gave:

| Measurement | Before | After |
|---|---:|---:|
| Changed rows (artists / albums / songs) | 710 / 6 / 0 | 710 / 6 / 0 |
| Reported apply, changed repair | 4,774 ms | 328 ms |
| Artist upsert batches, summed | 4,445.483 ms | 4.716 ms |
| Full disconnected changed repair | 15.277 s | 10.928 s |
| Reported apply, following unchanged repair | 258 ms | 264 ms |
| Full disconnected unchanged repair | 10.629 s | 10.621 s |

Both versions classified the same 63,579 rows and removed none. Fixture API
headers were reconstructed from stored rows, with artist counts derived from
local albums; the 710 dirty artist headers are this controlled workload, not a
claim about the live server's current change distribution. This is one
before/after changed+unchanged pair in the Flutter test runtime, with no network
or visible UI; it is not a replacement for the three live playback/scrolling
pairs in §13. Canary maxima remained approximately 50–60 ms and periodic-timer
lag approximately 42–52 ms, so this fix does not establish that the live 624 ms
stall or frame target is solved. The trace also shows candidate collection,
classification and bounded cleanup commit costs worth separating in subsequent
profiling; weakening atomic publication is not justified by these results.

Evidence under `build/sync-implementation-1-4-0/`:
`primary-key-update-evidence.json`, `repair_profile_test.dart`,
`profile-before-{0,1}.json`, `profile-{0,1}.json`,
`primary-key-repair-comparison.json`, and `primary-key-upsert-tests.log`.
The profile fixture used only a disposable clone and in-memory API responses;
no real credentials or server mutations were needed.

### F37 — Promotion phase reporting conflates classification, commit and cleanup — P2, R/S

The F36 trace showed that `applyingCandidate/applying` covered candidate
classification, the publication transaction and bounded cleanup. The engine
emitted that state before calling `_promoteFullSyncCandidate` and did not change
it until the whole method returned. Consequently, a canary sample grouped as
`applying` could not identify a database-lock stall during atomic publication.
The §13 interpretation has been corrected rather than retaining that inference
as a measured fact.

Progress now reports `validatingCandidate/ready` during pre-publication analysis,
`applyingCandidate/applying` immediately before the publication transaction, and
`cleaningCandidate` only after commit, clearing the active candidate identity at
that boundary. Existing UI/notification labels support these stages. Two
regressions interrupt the engine exactly at its reported applying/cleaning
boundary: before publication the old album remains; after publication the new
album is already committed and the active candidate is cleared. The combined
engine/regression suite passed **118 tests** (`promotion-phase-tests.log`).

The persisted `applyDurationMs` is still sampled inside the transaction before
final ledger/commit overhead, so tables here label it **reported apply**. The
end-to-end trace also contains commit timings; a future durable attempt timeline
should expose both. F21 is not closed merely by correcting the phase labels.

### F36/F37 validation checkpoint

The final `./tool/check.sh` passed: **1,500 tests passed, one skipped**, including
formatting, generation, analysis, migration and reliability checks
(`check-primary-key-phases-final.log`). An earlier invocation stopped because
its formatter found the ignored profiling harness; the harness was formatted
before this successful gate. No failing assertions or validation gates were
removed.

The F36 running-app discovery/annotation/offline/restart fixture passed at
`build/manual-discovery-diagnostics/20260919T190806Z-clone/`; both screenshots
were inspected. A subsequent latest-build fixture exercised full repair as well
as those flows and cold restart, passing at
`build/manual-discovery-diagnostics/20260919T191524Z-clone/`. Its repair completed
with exactly **one artist, two albums and two songs**, no active candidate, and
both stored tracks present after restart. Both app-owned screenshots were
inspected. The initial full-repair attempt stopped at deletion confirmation
because the standard discovery fixture deliberately lists only the newest album;
the isolated phase fixture was corrected to return its complete two-album catalog
and consistent track IDs. The production deletion guard was retained.

Evidence: `promotion-phase-runtime-second.log`, the latest fixture's
`phase-repair-status.json`, `phase-repair-report.json` and
`runtime-validation.json`. The complete new code changes and documentation were
reviewed; `git diff --check` and the 116-file credential-pattern scan passed.
This checkpoint advances F20/F21 but does not close frame-time acceptance,
complete durable attempt observability, or the then-pending F23 product decision (resolved in §19).


## 15. Durable attempt attribution (F21)

Schema v77 adds nullable, versioned telemetry to each attempt. Existing history
migrates without invented observations. The coordinator captures local request
and attempt IDs, safe phase timestamps and elapsed times, retry-linked transport
attempts, observed bytes and endpoint totals, plus separate pending-work,
album-hydration and artist-verification axes. `workSummary` groups durable rows
by target kind, status, cooldown and next retry time without retaining target IDs.
Auxiliary runs have their own attempts. Reports now select the attempt belonging
to their displayed sync state; selecting simply the latest attempt was shown by
the coordinator regression to select a later auxiliary operation instead.

The recorder retains the latest 32 phases and 128 transport attempts with omission
counts; request, byte, retry and transport-outcome totals remain complete within
the admitted scope. Checkpoints coalesce, run in the owning execution zone rather
than an inherited nested transaction, and obey the existing SQL ownership fence.
They occur on phase changes, every five seconds and at completion. A failed
checkpoint does not turn a committed catalog into a failed sync. Terminal attempt
telemetry cannot be overwritten; recovery retains the last interrupted capture.
Detail is opportunistically pruned after seven days, while terminal aggregate
history keeps the existing 90-day policy.

Limits are explicit: `captureComplete` means recorder completion, not a terminal
transaction guarantee. Process death may occur between the final checkpoint and
terminal persistence; attempt status/outcome are authoritative. `envelopeAccepted`
means transport/protocol parsing succeeded, not that later snapshot validation
or publication succeeded. Bytes are observed response-body bytes, with serialized
response fallback where needed, not wire overhead. A truncated timeline is not a
complete trace, and these measurements do not prove frame-time or audible-playback
acceptance. No credentials, request parameters, response bodies, media IDs/titles,
URLs or exception messages enter this telemetry.

Focused tests passed **102 tests** (`telemetry-focus-final.log`). The full gate
passed **1,508 tests, one skipped** (`check-telemetry-second.log`), including
formatting, generation, analyzer, migrations and reliability checks. Tests cover
v76→v77 migration, owner-zone/coalescing behavior, interrupted capture and recovery,
retention, terminal immutability, retry linkage/accounting, server isolation and
redaction. The first full-gate attempt caught two strict-analysis issues in new
test fixtures; both were corrected before the successful gate. The Linux isolated
fixture also passed at `build/manual-discovery-diagnostics/20260919T194448Z-clone/`
(`telemetry-runtime.log`). Its full repair recorded **8 requests, 3,824 observed
bytes, zero checkpoint failures**, and distinct validation/publication/cleanup
phases. Report and status IDs/totals matched; the exact terminal attempt remained
identical after clean restart. Offline discovery and annotation delivery also
passed, both catalog songs remained stored, and both app-owned screenshots were
opened and inspected. This closes F21's bounded observability implementation;
it does not certify hard-kill checkpoint freshness, all-platform background
behavior, or F20 smoothness targets.


## 16. F38 — Recently Added reconciliation decodes unused album metadata — P2, R/S

`replaceRecentlyAddedRanksFromNewestFeed` loaded every canonical album's complete
row to use only its ID and existing rank. Both incremental newest-prefix merging
and full repair replay therefore transferred and decoded unrelated names,
artwork references and metadata on every pass, including unchanged passes.

On the disposable 5,644-album audit clone, an isolated SQLite comparison measured
**1,706,872 versus 190,786 serialized bytes** for full rows versus ID/rank columns
(88.8% less), with median query/fetch **6.959 versus 1.443 ms** over 12 iterations.
These are serialized query-result sizes, not network bytes or heap measurements.
A Flutter/Drift benchmark using the production DAO with a background writer and
one WAL reader then measured 20 unchanged iterations per path:

| Public DAO operation | Before median | After median |
|---|---:|---:|
| Complete newest-rank replacement | 52.598 ms | 17.671 ms |
| Bounded newest-prefix merge | 54.128 ms | 18.598 ms |

The implementation now selects only ID and rank, retaining the same source
filters, transactional ordering, unknown-ID behavior, partial-tail preservation
and no-op writes. The benchmark verifies identical final album order. This is
one controlled before/after benchmark pair, not a live UI frame or audible
continuity result. Timer-lag maxima fell from 32.423 to 11.208 ms in this harness,
but these are test-runtime event-loop samples, not compositor frame measurements.

Evidence: `rank-projection-sqlite-profile.json`, `rank_profile_test.dart`,
`rank-profile-{before,after}.json` and corresponding logs under
`build/sync-implementation-1-4-0/`. The focused DAO/provisional/sync-regression
suite passed **56 tests** (`rank-projection-tests.log`). The full gate also passed
**1,508 tests, one skipped** (`check-rank-projection.log`). The latest Linux
fixture passed repair, offline discovery, annotation delivery and clean restart
at `build/manual-discovery-diagnostics/20260919T194959Z-clone/`
(`rank-runtime.log`); exact durable attempt evidence and both stored songs
survived restart. Both app-owned screenshots were opened and inspected. The
119-file credential-pattern scan and `git diff --check` passed. F38 is closed;
the broader F20 live frame-time acceptance remains open.


## 17. Frame attribution and the remaining rendering boundary

Diagnostics now retain separate `frameBuild`, `frameRaster` and `frameSpan`
windows alongside the existing build-plus-raster `frames` metric. Each retains
at most 5,000 samples and resets together. Span is Flutter's vsync-start to
raster-finish interval; none measures compositor presentation, dropped hardware
frames or audible playback. The focused diagnostics suite passed **31 tests**;
the full gate passed **1,509 tests, one skipped** (`check-frame-attribution.log`).

The no-sync/no-playback control used the copied **1,777 artists, 5,644 albums,
56,158 songs**, an offline policy override and a loopback artwork fixture at
1200×760, device scale 1, on NVIDIA RTX 4080 / Flutter Impeller OpenGLESSDF.
Three 24-action scrolling runs produced build-plus-raster p99 **8.328 / 8.274 /
8.029 ms**, UI-build p99 **3.367 / 3.761 / 3.259 ms**, raster p99 **6.583 / 5.997 /
6.278 ms**, and frame-span p99 **15.478 / 16.204 / 16.103 ms**. Cold restart
retained all rows; its scrolling sum p99 was **12.304 ms**. The app-owned image
was inspected; the restart image is byte-identical. Artwork placeholders in this
control differ from the real account and cannot establish live-image performance.
Evidence is under `build/sync-implementation-1-4-0/frame-control/`.

The subsequent **three completed cold/warm live playback/scroll pairs** are under
`live-latest/`, with a machine-readable `summary.json`. Its compiled snapshot
includes F36–F38 and frame attribution. The preparing-state correlation correction
below is validated separately and was not part of that compiled benchmark.

| Median across three pairs | Cold | Warm |
|---|---:|---:|
| Attributed response MiB | 2.534 | 2.360 |
| Requests | 118 | 118 |
| Elapsed seconds | 59.438 | 56.278 |
| Peak process RSS MiB | 661.648 | 688.516 |
| Build-plus-raster p99 ms | 20.222 | 23.377 |
| UI build p99 ms | 7.623 | 7.364 |
| Raster p99 ms | 19.723 | 22.551 |
| Frame span p99 ms | 31.174 | 31.712 |
| Database canary p95 ms | 5.750 | 7.373 |
| Database canary p99 ms | 12.341 | 11.082 |

All six runs retained **1,777 artists / 5,645 albums / 56,166 songs**, with no
sampled playback pause across **673 samples** and advancing positions. Every
reported attempt matched its status IDs, requests and bytes, with zero checkpoint
failures. One cold run reached its time boundary at 105 requests; the other five
used 118. All six honestly ended `deferred` with verification still pending, not
fully current. The six elapsed times were 52.4–61.6 seconds; server timing and
covered work vary, so these are not an isolated causal estimate for F38.

The database percentile targets pass in these six traces. The proposed 16.7-ms
build-plus-raster target still fails. All build p99 values were below 8 ms, while
raster p99 was 18.2–23.0 ms: the tail is predominantly raster work, rather than
an observed UI-build or database percentile violation. The fixture-art control
cannot establish which image/rendering operation causes it. Playback was muted;
position continuity is not audible-gap certification. The earlier unexplained
paused pair was not reproduced here and remains unresolved, not disproved.

### Preparing-state correlation follow-up

Review found that the controller copied the prior terminal state into its new
`preparing` state, retaining the preceding request/attempt IDs and usage counters
until the first coordinator progress callback. Preparation now clears those
fields, and the existing delayed-planning regression first seeds an old completed
attempt before checking the new state. This prevents a new operation's early
report from being joined to old telemetry. The focused controller/coordinator/diagnostics suite passed **70 tests**
(`preparing-correlation-tests.log`). The final `./tool/check.sh` passed
**1,509 tests, one skipped** (`check-final-attribution.log`). The latest Linux
fixture passed at `build/manual-discovery-diagnostics/20260919T200631Z-clone/`
(`final-attribution-runtime.log`): starting a repair did not retain the preceding
attempt identity, terminal counters/phases matched their attempt, and exact
telemetry plus stored songs survived clean restart. Offline discovery and
annotation delivery also passed. Both final app-owned screenshots were opened
and inspected. No implementation changes followed this gate/runtime build.

### F39 — Artwork decode/cache paths need a controlled performance experiment — P2, S/proposal

The bounded designer-skill review inspected `AlbumCard`, `CoverArtImage`,
`HeroCoverArt`, the cover-art cache coordinator and the library grid. No visual
implementation changed. The grid already has repaint boundaries and viewport
loading admission; adding another generic boundary is not a demonstrated fix.
Hero artwork deliberately uses one 600-pixel decoded variant across source,
flight and destination to avoid flicker. A 600×600 RGBA image is approximately
1.37 MiB; about 72 such decoded images fill Flutter's default 100-MiB keep-alive
image cache, before other images. This is a size calculation and a verified SDK
default, not a measured eviction rate or total live-image memory bound.

The cached-file fallback calls `Image.file` without `cacheWidth/cacheHeight`,
while its network path supplies a decode limit. A cached file larger than its
requested thumbnail can therefore decode at source resolution in that path.
Source inspection establishes the asymmetry; this audit has not yet reproduced
an oversized live response or attributed a raster stall to it.

Next experiment: collect decoded-cache occupancy/evictions and raster events
while replaying the same populated artwork set; compare the existing decode
contract with bounded cached-file decoding and a source-provider-preserving hero
handoff. Keep network/cache identity, image quality, missing/error artwork,
provenance badges and forward/back hero continuity unchanged. Only adopt a change
that improves repeated live raster samples and passes existing hero/image tests
plus matched screenshots. Do not lower artwork quality or claim sync is the
cause merely to meet a frame target. This remains a measured-direction proposal,
not an implemented fix or proof that all remaining frame cost comes from artwork.


The read-only artwork audit report is
`build/sync-implementation-1-4-0/artwork-audit-report.json`, with source and
evidence hashes. Audited UI files remained unchanged. Its audit task is complete,
but its proposed performance gate fails; this is not overall UI readiness.
Some scroll captures omit static application chrome, so screenshot completeness
is not certified from those captures. The final repair fixture's complete
screenshots were separately inspected. `git diff --check` and a 119-file
credential-pattern scan passed; the temporary real-server credential was removed.
All implementation work remains uncommitted alongside the preserved pre-existing
changes. F23 still required a product decision at this checkpoint (resolved in §19); F20's live
raster target and the explicitly unverified platform/audible scenarios remain open.


## 18. Artwork decode experiment and F40 correction

### F40 — Displayed network artwork bypassed its decode limit — P2, reproduced

F39's initial source review understated the defect: the network wrapper supplied
memory bounds, but its custom `imageBuilder` rebuilt an `Image` from the original
unresized provider. In the installed `cached_network_image` implementation, that
builder receives the original provider rather than the resized decoded child.
Consequently the displayed image decoded at full source resolution too, with a
separate bounded decode in the wrapper. The cached-file path independently lacked
a bound. Neither finding proves that the live server returns oversized covers or
that this is the cause of the remaining raster tail.

A deterministic widget experiment supplies a 2400×2400 PNG through the real
`CoverArtImage` and a fixture cache manager. It inspects the actual displayed
`RawImage.image`, rather than merely asserting provider constructor arguments.
A 100×100 layout requests size 600; offstage visible priority exercises cached-file
fallback, and critical priority exercises the admitted network-provider path.

| Displayed decode, both paths | Before | After | RGBA bytes before → after |
|---|---:|---:|---:|
| Ordinary thumbnail | 2400×2400 | 200×200 | 23,040,000 → 160,000 |
| Shared hero budget | 2400×2400 | 600×600 | 23,040,000 → 1,440,000 |

These are decoded pixel-buffer sizes, not total process RSS, eviction counts or
GPU-memory measurements. The correction passes the bounded provider directly to
the already-installed `OctoImage` renderer and retains its decoded child. Both
paths use `ResizeImagePolicy.fit`, preserving non-square aspect ratio and avoiding
decode upscaling. Disk keys, source URLs, requested hero size, interpolation,
load admission, placeholders, clipping and provenance contracts are retained.
The existing transitive `octo_image` 2.1.0 dependency is now declared directly;
its version and package contents did not change.

Durable regression coverage in `cover_art_decode_test.dart` exercises square,
landscape and small portrait sources across both priorities and hero/thumbnail
budgets, plus once-only post-decode readiness for the admitted path. The focused
artwork and hero suite passed **16 tests**. Evidence under
`build/sync-implementation-1-4-0/`: `cached-art-decode-before.json`,
`cached-art-decode-after.json`, their test logs and `artwork-focused-tests.log`.
F39's original adoption criterion concerned a speculative raster optimization;
this experiment instead establishes a concrete broken decode-budget contract.
Its resource-use correction is evaluated independently from the still-open
live frame target. Runtime measurements and final gate results follow below.


### Repeated live measurement after the correction

The unchanged benchmark driver ran three cold/warm pairs on isolated clones,
with live server artwork, muted direct-stream playback and repeated library
scrolling. All six runs retained **1,777 artists / 5,645 albums / 56,166 songs**.
All reported attempts matched their run IDs and byte/request totals, with zero
checkpoint failures. All ended `deferred` with verification remaining; the frame
gate does not turn incomplete catalog verification into a completed sync.

| Median across three pairs | Cold before → after | Warm before → after |
|---|---:|---:|
| Build-plus-raster p99 ms | 20.222 → **13.891** | 23.377 → **15.925** |
| UI build p99 ms | 7.623 → 5.921 | 7.364 → 5.897 |
| Raster p99 ms | 19.723 → 12.448 | 22.551 → 14.746 |
| Frame span p99 ms | 31.174 → 22.380 | 31.712 → 22.117 |
| Database canary p95 ms | 5.750 → 5.472 | 7.373 → 7.252 |
| Database canary p99 ms | 12.341 → 15.794 | 11.082 → 9.257 |
| Peak process RSS MiB | 661.648 → 655.141 | 688.516 → 681.418 |
| Elapsed seconds | 59.438 → 58.965 | 56.278 → 59.483 |
| Attributed response MiB | 2.534 → 2.534 | 2.360 → 2.352 |

The six new frame p99 values are **11.578, 16.361, 14.601, 13.928, 13.891,
15.925 ms**, all below the proposed 16.7-ms gate. Database p95/p99 also pass in
every run (largest p99 41.180 ms, below 50 ms). There were **664 playback samples**,
zero sampled pauses and advancing positions. **16,496 frame samples** were
recorded in total; the largest build-plus-raster frame was still **50.716 ms**.
This is improvement against the specified percentile gate, not zero jank.

Four runs used 118 requests and two hit their time boundary at 117; elapsed
and network variation remain. The real server, OS scheduling and artwork cache
are not a frozen replay, so these repeated before/after observations are not a
controlled estimate of every individual rendering operation. The deterministic
decode experiment independently establishes the corrected resource contract.
Process RSS changed only modestly; do not extrapolate its fixture pixel-buffer
savings to total app memory. No eviction count, GPU-memory trace, hardware dropped
frame count, long soak or physical input-latency certification was collected.

Evidence: `live-artwork/summary.json` and its six report/sample sets, produced by
`live_validation.py` and `summarize_artwork.py` under the existing ignored artifact
root. The first cold and final warm app-owned screenshots were opened and
inspected. The first cold artwork region was compared with the preceding live
baseline: cards retain their crop, detail and text layout. Some captures still
omit static application chrome, as previously recorded; they are artwork-region
evidence, not a complete screenshot-readiness certification. Existing hero tests
and the new actual-image identity check preserve the shared decode across layout
changes. The live credential file was removed and the benchmark processes stopped.

### Final validation and then-pending decision

The final focused artwork/hero suite passed **16 tests**, including actual decoded
image reuse when a hero layout grows. `./tool/check.sh` passed **1,512 tests, one
skipped**, including formatting, generation, analysis, migration and critical
reliability checks (`check-artwork.log`). The isolated Linux fixture at
`build/manual-discovery-diagnostics/20260919T202837Z-clone/` passed offline
discovery/reconnect, annotation delivery, repair phase ordering and run attribution,
then exact attempt telemetry and both stored songs survived clean restart
(`artwork-runtime.log`). Both complete album-detail screenshots were opened and
inspected, with consistent controls and layout. The fixture uses a black test
image; real artwork detail was inspected separately in the live captures.

The bounded renderer review is recorded in `artwork-refine-report.json`, with
input/output source hashes and evidence hashes. Its pass applies to this Linux
artwork correction, not every platform or the overall sync release. Required
report fields and artifact hashes were checked; no full JSON Schema validator
was available. The complete current diff was reviewed in context of the preserved
pre-existing work; `git diff --check` passed. A **122-file** credential-pattern
scan found no supplied-password matches. The real credential was removed and
all test app/server processes stopped. No implementation changes followed the
final gate/runtime build; documentation and evidence records were finalized
subsequently. All implementation remains uncommitted.

**At this checkpoint, the next implementation decision was F23.** The existing strict first-setup
readiness contract was retained. The open choice was whether a safely imported
partial library might become browse-ready with a warning, or setup would remain
blocked until every required album response was complete. Partial browsing had
been recommended for resilience, but was not adopted; §19 records the user's
full-screen decision. Platform, audible-playback and long-soak limitations listed above remain
uncertified and are not closed by the passing Linux percentile benchmark.


## 19. F23 — Strict full-screen first-setup readiness (2026-09-20)

**Product decision:** The user chose the intended full-screen setup experience.
A safely promoted partial first catalog does **not** open browsing. The user
remains on the required build screen until the catalog completes, or may retry
or sign out. The decision and its trade-off are recorded in
`docs/decisions/2026-09-20-first-setup-readiness.md`.

**Verified implementation gap:** The route already required a durable completed
sync timestamp, while the active `RequiredLibraryRebuildController` could mark
first setup `complete` from `succeeded` plus a committed generation alone. A
promoted generation can exist without complete evidence, and a result can still
carry pending hydration, verification or candidate work. This could transiently
dismiss the full-screen view before the router redirected back. The legacy
`InitialServerSyncController` had stronger result checks, so the two controllers
could disagree.

**Correction:** Both controllers now use one first-run result predicate:
`succeeded`, zero pending hydration and verification, and no candidate. The
active rebuild controller additionally requires a committed generation and the
same durable complete-catalog evidence used by the router. It reads the
persisted server and sync state after the run; the route continues to re-evaluate
its narrow authenticated/first-sync phase. Partial, failed, deferred and
incomplete successful results remain on the full-screen screen with existing
retry, consent and sign-out controls. The rest of the required-rebuild reasons
retain their existing completion rules.

**Expected live limitation:** The four repeatedly incomplete album responses on
the supplied server can leave new-account setup on the full-screen retry state
until the server supplies authoritative album details. This is the selected
product behavior; the client must preserve imported safe data and surface the
failure rather than declare the catalog complete. Later incremental gaps after
a previously complete setup do not re-enter first setup.

**Acceptance:** A promoted generation without complete evidence does not leave
setup, including after a fresh provider/container start. A fabricated successful
result with pending hydration cannot complete setup; a subsequent complete run
with durable evidence can. The existing router/widget tests retain the
full-screen, retry, metered-consent and onboarding contracts. Run the focused
provider/router tests, the full gate and the isolated auth lifecycle with a
clean restart before marking this finding validated. Record final results here.

**Validation completed:** The focused provider/screen/router suite passed **26
tests** (`build/sync-implementation-1-4-0/f23-focused-final.log`). The new
regression uses a committed generation without a completed timestamp, disposes
and rebuilds its provider container, then confirms the setup route is still
required. It also rejects a success-shaped result with pending hydration and
admits a later complete result with durable evidence. `./tool/check.sh` passed
**1,513 tests, one skipped** (`check-f23.log`).

The isolated Linux auth lifecycle run passed at
`build/auth-lifecycle-diagnostics/20260919T204056Z-clone/`
(`f23-auth-runtime.log`). Its authenticated app API observed the full-screen
metered-consent and failed/retry states, then a successful complete setup reached
Home and remained ready after clean process restart. Cancellation returned to
Login. The failed, metered, complete-Home and cancelled-Login app-owned screenshots
were opened and inspected. The running capture omitted some static text, so it
is not used as proof of complete visual presentation. The fixture exercises a
failed endpoint followed by successful completion; the earlier real-server
partial-catalog evidence and the new provider regression cover the separate
partial-readiness boundary. No real-server catalog mutation was required for
this acceptance.

## 20. F41 — Full-screen recovery for incomplete server album details (2026-09-20)

**Product decision:** The user kept the full-screen initial build but rejected
an indefinite blocking retry screen for a server response the user cannot fix.
The same automatic safe-partial exit applies to first setup, cache upgrade,
manual cache reset, playback recovery, and Repair Library. The accepted decision
is `docs/decisions/2026-09-20-fullscreen-sync-partial-readiness.md`; §19 is
historical evidence of the stricter boundary and its original validation.

**Verified gap:** Four live `getAlbum` responses advertise more songs than they
return. The validated initial candidate can be committed with those albums
pending, but the §19 readiness rule leaves the user on the full-screen failure
view forever if the server continues to return those responses. The engine
already retains incomplete albums and automatic incremental work can hydrate
them when they recover. It did not distinguish incomplete album responses from
transport, 404, or other per-album failures in the result delivered to the
full-screen controller.

**Implementation:** The engine records album identities whose current detail
response failed complete-snapshot validation. Its terminal result flags the
server-detail-only condition only when that exact set equals the remaining
canonical pending-hydration set. A timeout, 404, hard failure, unattempted
album, or a newly pending album prevents the flag. The shared full-screen
predicate additionally requires a terminal partial result, metadata readiness,
no ongoing hydration, zero artist verification, and no candidate. The controller
checks the committed generation and persisted pending count before navigating.
Every full-screen reason requires evidence that its full candidate was
published during that run, so an older generation cannot satisfy a new setup
or repair that failed before publication.
First setup stores schema-v78 `initial_catalog_usable_at` after this check,
separate from `last_synced` and `last_catalog_synced_at`, so restart routing is
stable without claiming full freshness. The existing notice tells the user
that remaining items continue in the background; no new interaction is added.
Automatic incremental checks retain their existing network, interval, and
manual-only policy, and later complete detail reconciles the missing songs.

**Acceptance:** End-to-end engine/coordinator coverage must show incomplete
responses become a partial result and a later automatic incremental pass adds
the missing tracks. Focused controller coverage must show all five full-screen
reasons automatically leave on that result; first setup stays ready after a
fresh provider container while full-sync timestamps remain null. Negative
coverage must reject transient/404/candidate/artist-verification/deferred and
inconsistent persisted-pending cases. Schema 77-to-78 migration, full gate,
isolated authenticated runtime with app-owned screenshot, and clean restart are
required before this item is considered validated.

**Validation completed for this decision:** The focused engine, coordinator,
controller, migration, and diagnostics suites passed **192 tests**
(`build/sync-implementation-1-4-0/f41-focused-final.log`); the full
`./tool/check.sh` gate passed **1,524 tests, one skipped**, including formatting,
generation, analysis, migrations, and reliability checks (`check-f41-final.log`).
The engine/coordinator regression starts from an incomplete advertised album,
records a partial committed catalog without deleting known tracks, then
automatically hydrates the missing songs when the response becomes complete.
Controller regressions cover all five full-screen reasons, the durable first
setup marker across a fresh provider container, and rejection of unsafe result
shapes or an older committed repair generation.

The final isolated Linux run passed at
`build/auth-lifecycle-diagnostics/20260919T214339Z-partial/`
(`f41-runtime-publication-guard.log`). With one of two fixture albums incomplete, the app
stayed full-screen for the initial build, opened Home after safe promotion with
one song and one pending album, and remained route-ready after clean restart.
An earlier same-fixture Home screenshot from
`20260919T213709Z-partial/` was opened and showed the background-sync notice and
playable fixture track. The final headless capture was blank, so it was not used
as visual proof. A later automatic catalog target-hydration run completed
after the fixture response was corrected, and the missing album persisted both
tracks. Reintroducing the incomplete response, the authenticated presentation
route exercised manual cache reset, Repair Library, playback recovery, and
cache upgrade in sequence. Each new durable catalog run ended partial, reached
Home without a prompt, and kept the affected album pending. The repair
screenshot also captured a blank headless frame; the app-owned route, ledger,
database, and earlier rendered Home capture are the
runtime evidence for those transitions.

The run also exposed a diagnostics observation defect: after an API-started
automatic run, `GET /v1/sync/status` could keep reporting that older result
while a later UI-started rebuild appeared in the durable ledger and database.
The endpoint now selects the newer controller request and reports UI-triggered
running work as active. The fixture asserts repair completion from the durable
ledger and stored album state rather than treating an in-memory status snapshot
as authoritative history. No production scheduling or deletion guard was
relaxed. The supplied live server's four incomplete responses remain the
real-world motivating observation; this decision's runtime acceptance used a
deterministic isolated server and did not mutate the supplied account.
