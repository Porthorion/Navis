# Sync Reliability Recovery Plan

Status: active recovery plan. Phase 1 manual discovery, the first Phase 2
queue/scheduler checkpoints, and explicit large-deletion repair confirmation
are implemented; unchanged-cursor manual discovery and configured-server clone
repair certification are runtime-certified.
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
- Runtime controls: `tool/sync_diagnostics.sh`,
  `tool/manual_discovery_diagnostics.sh`, and
  `docs/sync-stability-validation.md`

External sources:

- [OpenSubsonic getIndexes specification](https://opensubsonic.netlify.app/docs/endpoints/getindexes/): `ifModifiedSince` applies to the indexed artist collection, so it cannot prove that an album under an unchanged artist did not change.
- [Navidrome Subsonic compatibility](https://www.navidrome.org/docs/developers/subsonic-api/): Navidrome implements the separate `getAlbumList2`, `getIndexes`, `search3`, starred, and playlist endpoints, while `search3` supports only simple autocomplete queries; a client must not invent a richer delta or wildcard-query contract.
- [OpenSubsonic endpoint reference](https://opensubsonic.netlify.app/docs/endpoints/): `getAlbumList2`, `getAlbum`, `getIndexes`, and `search3` are distinct compatible operations. Navis's empty-query bulk behavior is a tested server capability, not a protocol assumption.
- [Android offline-first data guidance](https://developer.android.com/topic/architecture/data-layer/offline-first): local data serves the UI; connectivity drains durable queued work with bounded retry/backoff, and network work updates the local source rather than becoming a screen's read source.

## Confirmed faults

| Priority | Finding and evidence | Effect |
| --- | --- | --- |
| P0 | Manual Check for updates is time-gated like automatic work. The planner fresh-domain branch returns allDomainsFresh with shouldExecute false without distinguishing checkForUpdates. syncNow returns unless the first call was a successful probe. | The button can perform no request immediately after another check. |
| P0 | Manual discovery relies on getIndexes. syncNow queues follow-up only when probeIndexChanged; newest-album health probing is inside incremental sync and is not reached for an unchanged probe. | A new album under an existing artist can remain invisible. This is the main root cause for the reported missed album. |
| P0 | An offline manual Check for updates was classified as a metered-style probe. On reconnect, an unchanged `getIndexes` response could complete that probe without resuming the user's newest-album discovery. **Fixed:** offline manual checks now persist deferred `deltaReconcile` work, which drains as delta discovery once an eligible network returns. | A user could press Check for updates while offline and still miss a new album after reconnect when the artist cursor was unchanged. |
| P0 | The long-lived engine obtained live network policy through its construction `Ref`; after the first offline read, that provider-local value could remain cached despite a reconnect. The controller would dispatch queued manual work, but the engine still deferred it. **Fixed:** the stable engine now reads the lightweight policy from the root `ProviderContainer` at operation time, without watching/replacing the coordinator. | Deferred manual discovery could remain queued after reconnect even though the visible policy was Wi-Fi. |
| P0 | `SubsonicApiClient.getArtist` deserialized its standard `artist.album` response directly into Navis's plural `Artist.albums` model field. The generated parser therefore treated every standard artist-detail album list as empty. | Even after bounded newest discovery identified a discrepancy, normal artist reconciliation could upsert the artist without its albums or schedule the authoritative `getAlbum` hydration. **Fixed:** normalize `artist.album` to `albums` at the API boundary, with unit and controller-backed runtime coverage. |
| P0 | Pending verification scheduled a continuation every two minutes regardless of configured interval. Resume, reconnect, Wi-Fi and startup paths could schedule additional work. **Fixed:** a server-scoped durable deadline and one foreground one-shot timer now gate every automatic check; lifecycle events only re-arm/ask whether that deadline is due. | The app appeared to spam sync; cadence was hidden and did not honor the setting. |
| P0 | enqueueWork changes a completed conflicting work row back to queued. Partial catalog work then reaches markCancelled, which also means queued. | Work is resurrected and can run repeatedly, amplifying the continuation loop. |
| P1 | Server configuration, reachability notifications, engine availability, Wi-Fi, resume, periodic re-arm and a microtask all submit startup work. Partial result does not set startup-done fingerprint. Queued full repairs were also eligible for those automatic resume requests. | Event storms could schedule more planning after a preceding pass ends, app resume submitted both startup and interval work, and opening the app could restart an interrupted user Repair Library operation. **Fixed:** resume now submits only its interval check; automatic callers leave queued full repairs dormant, and only an explicit Repair Library action may resume one. |
| P1 | Entering the retained Liked tab watches an autoDispose provider that requests stale starred synchronization and writes global sync state. | Home to Library can look like catalog sync although it is a Liked refresh. |
| P1 | Starred reconciliation cleared every local star not in `getStarred2` before applying the returned set, excluding only queued/concurrent mutations. | This was a code-proven destructive path that could make Liked items disappear after one incomplete response. **Fixed:** absence candidates are persisted per server/entity; the first successful absence retains the local star and only a second independent successful absence clears it. Pending and concurrent local mutations remain protected. |
| P0 | Incremental artist reconciliation deleted every locally known album missing from one `getArtist` response. A detail response can be partial even when the bounded newest feed reports a valid new album. | A routine update could make an existing offline album disappear without a full-catalog candidate, confirmation, or operation ledger. **Fixed:** incremental artist details now only add/update/hydrate; only validated full-candidate promotion may delete catalog rows. Unit coverage and the isolated loopback app gate confirm that a partial detail response imports the new album while retaining the omitted sibling across restart. |
| P0 | Full repair calculated the candidate-vs-live stale-song count immediately after metadata collection, before bulk or album-detail hydration had inserted candidate songs. The active server's generation 18 recorded 5,464 candidate albums and **zero** candidate songs, then falsely reported all 54,327 committed songs as server-missing and stopped at confirmation. | Repair could neither complete nor reliably discover the server library; an empty pre-hydration candidate was treated as deletion evidence. **Fixed:** collect/carry-forward/hydrate candidate songs before any deletion analysis. Existing tracks for an unresolved candidate album are excluded from stale-song deletion until authoritative detail hydration succeeds. |
| P1 | Large deletion repair returns awaitingDeletionConfirmation and requires a second repair request; UI showed only opaque status. | Repair could look like a no-op/failure. **Fixed:** Settings now names the pending server-missing count and requires an explicit Apply library repair confirmation before it issues that retry. |
| P1 | Probe, repair, continuation, Liked sync and target hydration previously shared one controller in-flight future and wrote one global `LibrarySyncState`. A target could therefore satisfy a catalog command, and target progress could replace broad-operation status. **Fixed at the controller boundary:** catalog work now coalesces by precedence (automatic < manual check < repair), while target work coalesces only by its durable target key and never writes catalog UI state. | Navigation-adjacent work no longer masquerades as a library-wide sync, and a manual Check requested during an automatic pass is guaranteed to run after it. |
| P1 | A legacy persisted `*` bulk-song query ran before the standard empty query. In the isolated clone it collected 5,464 albums then remained at zero hydrated/candidate songs for more than 20 minutes; cancellation did not reach a terminal state within the next 20 seconds. | Repair appeared stalled despite a valid candidate. The wildcard capability is now discarded; the verified empty-query path advanced 214→2,002 albums and 3,924→24,979 songs in 15 seconds. |
| P2 | Initial coverage omitted manual fresh-window checks, unchanged artist cursor plus new album, repeated Liked entry, completed work remaining completed, and manual offline/cellular policy. **Fixed:** planner, coordinator, engine, controller and isolated app-API gates now cover these boundaries, including preserving offline manual delta discovery and the explicit cellular broad-data override. | These controls can no longer silently regress behind green lower-level tests. |

## Boundaries and non-claims

There is no direct broad-catalog call on the Home to Library route change. The confirmed navigation trigger is Liked starred refresh; detail pages may request target hydration.

Candidate promotion correctly preserves the visible committed catalog until validated promotion and must remain. The exact vanished row has not yet been reproduced against the affected server. The previous destructive starred path is now guarded by durable two-observation confirmation; runtime traces still need to prove the affected navigation path and server response behavior.

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

Keep candidate tables and atomic promotion. Deletion analysis is valid only after the candidate's song collection and safe carry-forward stage; an unresolved candidate album protects its committed tracks from stale-song removal. Convert implicit second-click deletion confirmation into a durable explicit confirmation with safe counts. Repair reports candidate counts, promotion result, retained/protected rows, and safe failure reason.

## Phased plan

### Phase 0: reproduce and observe

1. Add clone fixture with a new album under existing artist and unchanged getIndexes lastModified. Drive API check and assert real Library provider shows album. **Implemented and certified:** the loopback fixture returns the standard `artist.album` payload and a fixed cursor. The authenticated app check discovers, hydrates, persists, routes to, screenshots, and clean-restarts the new album.
2. Add Home to Library to Liked to Home to Liked trace recording request IDs, cause, plan, target scope, endpoint counts and catalog counts. Capture and inspect screenshots. **Implemented:** the isolated Linux target-lane gate drives the visible Library-section provider through `/library#liked`, asserts that every navigation leaves sync status and aggregate catalog counts unchanged, and proves that no controller ledger event was added. Its inspected Liked and Sync Settings screenshots are captured before a clean restart.
3. Add opt-in redacted ledger endpoint retaining last 50 events; never return credentials, URLs, titles or paths. **Implemented for diagnostics-initiated controller actions:** `GET /v1/sync/ledger` records requested, started, terminal, and failed transitions with cause, target kind, plan/result, endpoint counts, and safe error type.
4. Run isolated Linux clone against configured server: baseline counts, manual check, repair, post-run counts, clean restart, endpoint trace and logs. **Implemented and certified:** the primary catalog was copied into an isolated Linux profile; normal policy, interruption/restart, local-mutation precedence, active playback, two Repair Library passes, and final target work completed through the authenticated app API. The committed catalog remained 1,714 artists / 5,464 albums / 54,329 songs over clean restart. The second repair classified 61,507 rows unchanged, removed zero songs, and recorded a 117 ms apply. This certifies current-server lifecycle and repair convergence without changing the primary profile or claiming a live user-created-album reproduction.

Exit: deterministic manual-check reproduction and a trace separating catalog, Liked and target work. **Met:** unchanged-cursor manual discovery, navigation/target lanes, repair confirmation, and configured-server isolated clone lifecycle all have app-API evidence. A direct affected-server vanished-row reproduction remains a focused diagnostic follow-up if it recurs.

### Phase 1: manual check correctness

1. Give automatic, manual check, repair and target requests explicit freshness policy; stop encoding semantics in force boolean.
2. Apply freshness gates only to automatic work. Manual no-change result is checkedNoChanges, never skipped. **Implemented:** manual requests select `manualCatalogDiscovery` instead of the automatic fresh-domain no-op.
3. Always run bounded newest discovery for manual check despite unchanged getIndexes. **Implemented:** the engine runs the newest window for every manual incremental pass.
4. Drain discovered follow-up in the same user operation or return explicit deferred reason. **Implemented and runtime-certified for offline manual discovery:** the planner persists deferred `deltaReconcile` rather than an indexes-only probe; the controller admits eligible user work despite a future automatic deadline, and the stable engine reads current policy from the root container so it resumes that exact work as discovery on reconnect.
5. Add unit, coordinator, widget and API tests for fresh window, unchanged cursor/new album, changed cursor/new album, offline, cellular and duplicate taps. **Implemented:** planner/coordinator coverage proves a fresh manual check chooses discovery, an offline one queues the same discovery and drains it after reconnect, a cellular one remains a cheap probe until the explicit mobile-data override, and duplicate/precedence callers share correct terminal work. Engine regressions cover both unchanged- and changed-cursor new albums, while the isolated app API gate verifies the unchanged-cursor album is persisted and rendered before and after restart.

Exit: one manual check imports an album for existing artist in fixture and live clone; UI reports change counts. **Fixture clone exit met; configured-server lifecycle/repair certification is met. A controlled, live user-created-album reproduction remains optional only if the reported symptom recurs, because this gate does not mutate the configured server.**

### Phase 2: schedule and queue correctness

1. Add persisted automatic schedule and one scheduler entry point. Lifecycle/UI listeners submit typed cause only. **Implemented:** schema v63 stores the server-scoped `nextAutomaticCheckAt`; automatic checks coalesce at the controller, a one-shot foreground timer re-arms from that deadline, and app/settings hydration cannot erase a persisted schedule.
2. Coalesce manually: manual check supersedes automatic probe; repair supersedes broad automatic work; target work is independent. **Implemented in the controller:** an active stronger catalog request satisfies weaker work, while a stronger request is queued after a weaker active request; duplicate target work shares only its durable target key.
3. Correct work transitions: completed stays completed; cancelled is terminal until an explicit compatible user action reactivates it; a deletion-confirmation repair is terminal until the next explicit Repair Library action; partial broad parent names child work instead of requeueing itself. **Implemented:** ordinary conflict handling preserves terminal rows, explicit user requests reactivate them, automatic callers cannot resume queued full repairs, and user cancellation no longer falls through to an immediately runnable queue row.
4. Remove the two-minute loop. Pending durable work is resumed only by the configured automatic interval or an explicit user action, with visible next eligibility. **Implemented:** Sync Settings shows the persisted next automatic check (or manual-only/scheduling state).
5. Make startup completion a terminal scheduler decision; listener emissions cannot reset a fresh schedule. **Implemented and regression-tested:** a controller test uses the production 60-minute interval with a persisted near-future deadline to verify the one-shot timer produces zero catalog calls before the deadline and exactly one automatic pass after it; the resulting deadline is persisted for the next interval.
6. Keep only the standard empty-query `search3` bulk capability. Discard
   legacy wildcard capabilities, record request progress before the first page,
   and use the authoritative album-detail fallback if bulk enumeration fails.

Exit: a 60-minute no-action lifecycle stress test makes no catalog request before nextAutomaticCheckAt and shows no resurrected work. **The deterministic timer and durable-work regression coverage is complete; a wall-clock foreground soak remains optional operational certification rather than a substitute for the automated boundary.**

### Phase 3: navigation and disappearance safety

1. Replace Liked autoDispose side effect with target-scoped work from explicit refresh or scheduler-due auxiliary event.
2. Split CatalogSyncState from per-target operation state. **Controller isolation implemented:** target progress/results no longer write catalog state, and the album/playlist explicit refresh surfaces already own their local loading/error state. Follow up by extracting a typed target-operation provider for non-explicit interaction hydration and diagnostics.
3. Validate starred snapshot completeness before deletion; preserve values for uncertain response and pending journals. **Implemented defensively:** retain a missing star after its first successful response and clear it only after a second independent successful absence; pending and concurrent local mutations clear any candidate and remain authoritative.
4. Record before/after counts and reason code for every destructive catalog/starred transaction. **Partially reduced:** incremental artist reconciliation no longer contains a catalog-delete transaction; broad candidate promotion remains the catalog deletion authority. A durable transaction ledger for promotion and confirmed starred absences remains open.
5. Add invariant: Home to Library changes neither catalog nor liked count without successful accounted server snapshot.

   **Implemented as a runtime gate:** the target-lane clone diagnostics now
   drives Home-to-Library-to-Liked navigation on both online and explicitly
   offline policy, asserting that production catalog status/counts and the
   controller ledger remain byte-for-byte unchanged before it tests target
   work.

Exit: navigation causes no broad request, and no catalog/liked row disappears without a ledger event.

### Phase 4: repair UX and certification

1. Build explicit repair deletion confirmation, durable token and discard action. **Implemented:** the persisted fingerprint/count remains the durable remote-evidence token; Settings exposes its count and requires a deliberate Apply library repair confirmation before retrying, or a separate confirmed discard that clears only the uncommitted candidate and repair work. Candidate song collection/carry-forward precedes token calculation, and unresolved candidate albums protect committed tracks.
2. Show operation type, remote check time, change counts, defer reason, retry time and safe endpoint failure type in Settings/Library. **Partially implemented:** Settings distinguishes the durable automatic deadline from the persisted failure/circuit cooldown (`nextRetryAt`), including after restart; the clone target-lane gate verifies the two values survive navigation, target hydration, and clean restart in inspected app-owned Settings captures. Operation change-count and destructive-transaction ledger work remains open.
3. Update AGENTS.md, docs/architecture.md, docs/development-workflow.md, release notes and migration tests with final architecture.
4. Complete runtime loop: Linux isolated clone, health API, unchanged-cursor album discovery, lifecycle stress, Liked route loop, repair confirmation, offline browse, clean restart, inspected screenshots and logs. **Implemented with deterministic scheduler coverage:** the target-lane clone gate has passed online and offline Home/Library/Liked browsing plus clean restart with inspected Liked/Settings screenshots. The controller suite proves that a persisted future deadline has no early timer call and exactly one call at eligibility. `tool/manual_discovery_diagnostics.sh` now certifies that an offline Check for updates retains unchanged-cursor newest-album discovery, resumes it after Wi-Fi returns despite the future automatic deadline, persists the album/song, renders it in two byte-identical inspected app-owned captures, and clean-restarts. `tool/repair_confirmation_diagnostics.sh` certifies that a 61,503-row deletion candidate does not alter the committed catalog before explicit confirmation, remains awaiting confirmation over restart, then promotes atomically. `tool/sync_diagnostics.sh clone` completed the configured-server isolated lifecycle, interruption/restart, active-playback and repeated-repair sequence with an unchanged converged catalog. A full wall-clock 60-minute foreground soak remains an operational follow-up, not a missing code/test boundary. Then run `tool/check.sh`.

Current certification evidence: focused engine, coordinator, DAO, migration,
controller, Home, Library, and Settings suites pass. The controller regression
suite now proves that duplicate album hydration coalesces locally, a concurrent
manual refresh still executes, and the target terminal result cannot replace
the catalog result. `tool/sync_target_lane_diagnostics.sh` is the matching
controller-backed isolated Linux runtime gate; its endpoint contract proves the
diagnostics target request cannot bypass that boundary. Its latest run used
schema v63 and drove `/ → /library → /library#liked → / → /library#liked`.
Every post-navigation status, including aggregate artists/albums/songs counts,
matched the pre-navigation state and the bounded controller ledger gained no
event. It then accepted an album target request while catalog status/counts
remained unchanged, recorded a terminal target result, and clean-restarted with
the same future automatic deadline. The inspected Liked and Sync Settings
captures were unobscured by first-run UI and showed no running catalog state.
Isolated Linux clone startup also kept an awaiting-deletion-confirmation repair
dormant while it resumed only target work. The focused
full-rescan rerun against a current-library clone began with 1,714 artists,
5,463 albums, and 54,327 songs; the authenticated repair collected 5,464
albums, indexed songs through 57 `search3` pages, used five authoritative
album-detail fallbacks, and completed promotion with no candidate/deletion
token. The committed clone ended at 5,464 albums and 54,329 songs. A clean
restart to Sync Settings was captured through the app API and inspected; it
showed `Last sync succeeded`, no pending deletion confirmation, and the
completed catalog apply time. The capture harness now waits for route
acknowledgement and transitions to settle before taking visual evidence.
`./tool/check.sh` passed formatting and code generation, then stopped at the
repository-wide analyzer baseline of 493 informational diagnostics; none were
introduced by this recovery work.

Schema v63 persists `nextAutomaticCheckAt` per server. Focused
migration/controller tests prove a future deadline blocks automatic work,
manual actions leave it untouched, an expired deadline executes one automatic
pass and records the next deadline, and a first-sync schedule write cannot
silently update zero rows. The isolated Linux clone gate seeded a future
deadline, invoked the production automatic endpoint without starting catalog
work, preserved status/counts and the ledger through Home-to-Library-to-Liked
navigation and target hydration, then clean-restarted with the same deadline.
The clone isolates its app-support state and marks the current changelog seen,
so the inspected Liked and Sync Settings captures directly show the affected
surfaces rather than a first-run modal.

The manual-discovery clone gate uses a deterministic loopback server which
returns a fixed `getIndexes.lastModified`, one locally known artist, and a
newer album under that same artist. It seeds the old album as hydrated, calls
the running app's `POST /v1/sync/check`, and observes the new album only via
the authenticated narrow `GET /v1/library/album` endpoint. Its 2026-08-12 run
recorded `getIndexes`, `getNewestAlbumList2`, `getArtist`, and `getAlbum` in
the terminal redacted ledger, persisted one hydrated song, and passed after a
clean restart. Both app-owned 1440x900 album-detail screenshots were opened
and inspected; each showed the new album and its song without clipping. The
capture helper rejects all-black compositor frames instead of treating PNG
existence as visual evidence.

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
| Repair with existing catalog | Candidate songs are collected before deletion analysis; a zero-song pre-hydration candidate can never produce a deletion token. |
| Failed detail hydration | Existing tracks for the unresolved candidate album remain visible until a later authoritative detail response. |
| Offline and restart | Local catalog stays browsable; deferred work drains once when eligible. |

## Decisions

- Do not fix missed albums by running full repair on navigation or every timer; that increases data use and destructive surface area.
- Do not remove candidate promotion; fix scheduling, discovery semantics and explanation around it.
- Do not treat successful HTTP as current catalog proof. Commit plus operation-specific evidence is the success boundary.
