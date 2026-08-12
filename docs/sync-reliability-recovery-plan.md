# Sync Reliability Recovery Plan

Status: active recovery plan. Phase 1 manual discovery and the first Phase 2
queue/scheduler checkpoint are implemented; runtime certification is in progress.
Date: 2026-08-12
Scope: library metadata sync, offline browsing, manual refresh and repair, and navigation-adjacent hydration. This is the source of truth for correcting the current sync model.

## Required behaviour

Navis must have one committed local catalog that remains browsable offline. Network activity may change it only through explicit, observable operations.

| Action | Required meaning |
| --- | --- |
| Startup, timer, resume, reconnect | Automatic low-data check only when the persisted schedule is due. |
| Check for updates or pull-to-refresh | Bounded user-requested remote check independent of automatic interval; detects a new album under an existing artist. |
| Repair Library | Explicit authoritative snapshot; atomically promote, give a concrete blocker, or leave old catalog unchanged. |
| Opening Home, Library, Liked, Artist, Album | Read local committed data; no broad catalog sync. At most one target-scoped hydration when content cannot render locally. |
| Offline | Read local data; queue eligible work without hiding or changing catalog rows. |

Every operation needs one owner, a durable cause, start and end time, result, and bounded endpoint/request counts. An HTTP response or a visible spinner is not success; a manual check is successful only after required observations have been evaluated and discovered changes committed, deferred, or failed explicitly.

## Audit evidence

Reviewed production controller, coordinator, planner, engine, state/work DAOs,
route entry points, diagnostics, and focused tests. The confirmed Phase 1 and
Phase 2 fixes below are implemented; the remaining phases stay active until
their runtime criteria pass.

Key paths:

- Controller, lifecycle and timers: lib/src/features/library/presentation/library_sync_provider.dart
- Planner and durable work: lib/src/features/library/data/adaptive_library_sync_coordinator.dart, library_sync_planner.dart, and lib/src/database/daos/library_sync_dao.dart
- Server reads and candidate promotion: lib/src/features/library/data/library_sync_engine.dart
- Navigation work: lib/src/features/library/presentation/library_screen.dart, album_detail_screen.dart, artist_detail_screen.dart
- Runtime controls: tool/sync_diagnostics.sh and docs/sync-stability-validation.md

External sources:

- [Subsonic getIndexes specification](https://www.subsonic.org/pages/api.jsp): ifModifiedSince applies to the artist collection, not album changes.
- [Navidrome Subsonic compatibility](https://www.navidrome.org/docs/developers/subsonic-api/): a client must not assume a richer server-side delta feed.
- [OpenSubsonic search3 specification](https://opensubsonic.netlify.app/docs/endpoints/search3/): an empty query is the portable all-library form; `query` is required and paging is defined by the returned category offsets.
- [Android offline-first data guidance](https://developer.android.com/topic/architecture/data-layer/offline-first): local data serves the UI; connectivity drains durable queued work with bounded retry/backoff.

## Confirmed faults

| Priority | Finding and evidence | Effect |
| --- | --- | --- |
| P0 | Manual Check for updates is time-gated like automatic work. The planner fresh-domain branch returns allDomainsFresh with shouldExecute false without distinguishing checkForUpdates. syncNow returns unless the first call was a successful probe. | The button can perform no request immediately after another check. |
| P0 | Manual discovery relies on getIndexes. syncNow queues follow-up only when probeIndexChanged; newest-album health probing is inside incremental sync and is not reached for an unchanged probe. | A new album under an existing artist can remain invisible. This is the main root cause for the reported missed album. |
| P0 | Pending verification schedules a continuation every two minutes regardless of configured interval. Resume, reconnect, Wi-Fi and startup paths schedule additional work. | The app appears to spam sync; cadence is hidden and does not honor the setting. |
| P0 | enqueueWork changes a completed conflicting work row back to queued. Partial catalog work then reaches markCancelled, which also means queued. | Work is resurrected and can run repeatedly, amplifying the continuation loop. |
| P1 | Server configuration, reachability notifications, engine availability, Wi-Fi, resume, periodic re-arm and a microtask all submit startup work. Partial result does not set startup-done fingerprint. | Event storms can schedule more planning after a preceding pass ends. |
| P1 | Entering the retained Liked tab watches an autoDispose provider that requests stale starred synchronization and writes global sync state. | Home to Library can look like catalog sync although it is a Liked refresh. |
| P1 | Starred reconciliation clears every local star not in getStarred before applying the returned set, excluding only queued/concurrent mutations. | This is a code-proven destructive path that can explain items disappearing from Liked. Exact user row still needs a diagnostics trace. |
| P1 | Large deletion repair returns awaitingDeletionConfirmation and requires a second repair request; UI shows only opaque status. | Repair can look like a no-op/failure. |
| P1 | Probe, repair, continuation, Liked sync and target hydration overwrite one global LibrarySyncState. | Navigation-adjacent work can replace broad-operation status and make causality unclear. |
| P1 | A legacy persisted `*` bulk-song query ran before the standard empty query. In the isolated clone it collected 5,464 albums then remained at zero hydrated/candidate songs for more than 20 minutes; cancellation did not reach a terminal state within the next 20 seconds. | Repair appeared stalled despite a valid candidate. The wildcard capability is now discarded; the verified empty-query path advanced 214→2,002 albums and 3,924→24,979 songs in 15 seconds. |
| P2 | Existing tests omit manual fresh-window checks, unchanged artist cursor plus new album, repeated Liked entry, and completed work remaining completed. | Current tests can pass while the user controls fail. |

## Boundaries and non-claims

There is no direct broad-catalog call on the Home to Library route change. The confirmed navigation trigger is Liked starred refresh; detail pages may request target hydration.

Candidate promotion correctly preserves the visible committed catalog until validated promotion and must remain. The exact vanished row has not yet been reproduced. The destructive starred path is credible and code-proven, but its conflict policy must change only after a trace confirms snapshot completeness and mutation state.

A full repair should discover all albums through its paginated candidate. If it misses the current server album, capture endpoint page/count evidence with the diagnostics API; do not hide the defect by making navigation or automatic checks perform full repair.

## Target architecture

### Single scheduler and durable ledger

Replace distributed timers and fire-and-forget triggers with one scheduler service above presentation:

    automaticDue | reconnect | resume | manualCheck | repair | targetHydration
        -> coalesce by durable semantic key and precedence
        -> persist requested, running, terminal transition
        -> one eligible executor drains work
        -> commit local catalog atomically
        -> publish scoped outcome

Store request ID, cause, target, created/started/completed time, attempt count, not-before, plan, endpoints, result, and safe reason code. Completed, deferred, cancelled and failed are terminal states. Only explicit new work or a defined retry transition may return a terminal row to queued.

Persist nextAutomaticCheckAt per server, calculated from configured interval and last successful automatic catalog observation. Screen construction, state changes, and an arbitrary continuation timer are not clocks.

### Discovery distinct from verification and repair

Keep getIndexes as advisory invalidation, never proof that albums did not change. Use bounded getAlbumList2 newest comparison as compatible discovery for recent new/changed albums under existing artists.

Manual Check must always run that bounded discovery on an allowed network even when automatic schedule is fresh and getIndexes is unchanged:

1. Read conditional indexes as advisory and newest window as direct discovery.
2. Diff IDs and metadata against committed catalog.
3. Upsert and hydrate discovered albums using existing identity-safe path.
4. Report checked, new, changed, deferred and failed counts.
5. Advance any cursor only after hydration and identity commit.

Automatic work may run the same bounded newest discovery only when due. Rotating artist verification remains separate low-priority work. Repair alone constructs a full candidate and deletes server-missing canonical rows.

### Navigation read-only by default

Home and Library read committed local data. Entering Liked cannot set global catalog state. A targeted refresh has target-local state and cannot preempt a manual check or repair.

Starred reconciliation must not clear values until it has a complete validated snapshot for the active server/user. Mutation journals remain authoritative until acknowledged. Label it Updating liked items, not Syncing library.

### Explain repair

Keep candidate tables and atomic promotion. Convert implicit second-click deletion confirmation into a durable explicit confirmation with safe counts. Repair reports candidate counts, promotion result, retained/protected rows, and safe failure reason.

## Phased plan

### Phase 0: reproduce and observe

1. Add clone fixture with a new album under existing artist and unchanged getIndexes lastModified. Drive API check and assert real Library provider shows album.
2. Add Home to Library to Liked to Home to Liked trace recording request IDs, cause, plan, target scope, endpoint counts and catalog counts. Capture and inspect screenshots.
3. Add opt-in redacted ledger endpoint retaining last 50 events; never return credentials, URLs, titles or paths.
4. Run isolated Linux clone against configured server: baseline counts, manual check, repair, post-run counts, clean restart, endpoint trace and logs.

Exit: deterministic manual-check reproduction and a trace separating catalog, Liked and target work.

### Phase 1: manual check correctness

1. Give automatic, manual check, repair and target requests explicit freshness policy; stop encoding semantics in force boolean.
2. Apply freshness gates only to automatic work. Manual no-change result is checkedNoChanges, never skipped. **Implemented:** manual requests select `manualCatalogDiscovery` instead of the automatic fresh-domain no-op.
3. Always run bounded newest discovery for manual check despite unchanged getIndexes. **Implemented:** the engine runs the newest window for every manual incremental pass.
4. Drain discovered follow-up in the same user operation or return explicit deferred reason.
5. Add unit, coordinator, widget and API tests for fresh window, unchanged cursor/new album, changed cursor/new album, offline, cellular and duplicate taps.

Exit: one manual check imports an album for existing artist in fixture and live clone; UI reports change counts.

### Phase 2: schedule and queue correctness

1. Add persisted automatic schedule and one scheduler entry point. Lifecycle/UI listeners submit typed cause only. **In progress:** the unpersisted two-minute continuation loop is removed; automatic pending work now waits for the configured interval.
2. Coalesce manually: manual check supersedes automatic probe; repair supersedes broad automatic work; target work is independent.
3. Correct work transitions: completed stays completed; cancelled has explicit backoff; a deletion-confirmation repair is terminal until the next explicit Repair Library action; partial broad parent names child work instead of requeueing itself. **Implemented:** ordinary conflict handling preserves terminal rows, while explicit user requests reactivate them.
4. Remove the two-minute loop. Pending durable work is resumed only by the configured automatic interval or an explicit user action, with visible next eligibility.
5. Make startup completion a terminal scheduler decision; listener emissions cannot reset a fresh schedule.
6. Keep only the standard empty-query `search3` bulk capability. Discard
   legacy wildcard capabilities, record request progress before the first page,
   and use the authoritative album-detail fallback if bulk enumeration fails.

Exit: a 60-minute no-action lifecycle stress test makes no catalog request before nextAutomaticCheckAt and shows no resurrected work.

### Phase 3: navigation and disappearance safety

1. Replace Liked autoDispose side effect with target-scoped work from explicit refresh or scheduler-due auxiliary event.
2. Split CatalogSyncState from per-target operation state.
3. Validate starred snapshot completeness before deletion; preserve values for uncertain response and pending journals.
4. Record before/after counts and reason code for every destructive catalog/starred transaction.
5. Add invariant: Home to Library changes neither catalog nor liked count without successful accounted server snapshot.

Exit: navigation causes no broad request, and no catalog/liked row disappears without a ledger event.

### Phase 4: repair UX and certification

1. Build explicit repair deletion confirmation, durable token and discard action.
2. Show operation type, remote check time, change counts, defer reason, retry time and safe endpoint failure type in Settings/Library.
3. Update AGENTS.md, docs/architecture.md, docs/development-workflow.md, release notes and migration tests with final architecture.
4. Complete runtime loop: Linux isolated clone, health API, unchanged-cursor album discovery, lifecycle stress, Liked route loop, repair confirmation, offline browse, clean restart, inspected screenshots and logs. Then run tool/check.sh.

## Regression matrix

| Scenario | Required assertion |
| --- | --- |
| Fresh automatic interval | No remote request and no global running state. |
| Fresh manual check | Bounded remote discovery gives checkedNoChanges or committed changes. |
| New album, existing artist, unchanged cursor | One manual check imports/hydrates album. |
| Repeated resume/Wi-Fi/reachability | One coalesced eligible operation; no work resurrection. |
| Pending hydration | Bounded persisted batches, visible eligibility, no two-minute busy loop. |
| Home to Albums | No sync request and no catalog mutation. |
| Home to Liked | No catalog request; validated auxiliary work only when due/requested. |
| Repair large deletion | Atomic promotion or explicit confirmation; old catalog visible until promotion. |
| Offline and restart | Local catalog stays browsable; deferred work drains once when eligible. |

## Decisions

- Do not fix missed albums by running full repair on navigation or every timer; that increases data use and destructive surface area.
- Do not remove candidate promotion; fix scheduling, discovery semantics and explanation around it.
- Do not treat successful HTTP as current catalog proof. Commit plus operation-specific evidence is the success boundary.
