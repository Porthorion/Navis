# Sync audit remediation — discovery cadence, observability, cover recovery, and server churn

Created: 2026-09-22
Status: **in progress** — stages B1-B7 implemented and committed; consolidated
runtime validation + live-server certification pending (deferred 2026-09-22,
server under heavy load); workstream A and the device checklist (C) are
operator-run and still open. Remaining work, prerequisites, and continuation
rules are consolidated in §8 (Handoff).
Companion runbook: [docs/server-library-hygiene.md](docs/server-library-hygiene.md)
Predecessor evidence: `Fix_Stale_Cache_Plan.md`, `Fix_Stale_Cache_Execution_Plan.md`
(schema 80 baseline), `docs/sync-reliability-recovery-plan.md`.

## 0. Verified during planning

Three audit sources were cross-examined on 2026-09-21/22: the Navis codebase
(sync engine, DAO queries, playback resolution, cover-art pipeline), the live
Subsonic API on `navidrome.example.test` (Navidrome v0.64.0, 1,777 artists /
7,892 albums / 56,166 tracks), and the device database
(`~/Documents/navis.sqlite.sqlite`, read-only, schema 78).

Reported symptoms and verdicts:

1. **"Fleeting Words by Animuz wasn't acknowledged until I played it"** —
   mostly Navis-side. The album existed server-side since 2026-09-01
   (newest-feed position 73), but the device ledger shows no full catalog
   promotion between 2026-08-28 and 2026-09-16, and the automatic
   newest-feed probe window is too shallow to reach it. Playback-triggered
   hydration inserted the row with `serverCreatedAt = 2026-09-01`, which then
   surfaced near the top of "Recently added" as if newly added.
2. **"Liked items took forever to load metadata even though sync was
   complete"** — Navis-side. The device's auxiliary (starred) timestamp had
   diverged from the sync-state record; Liked sat partially stale for up to
   two weeks while runs reported success, and a hydration backlog (104
   albums) drains at ~2 concurrent requests while status UI hides queued
   work. The Subsonic starred feed itself is complete and rich.
3. **"Hotel California / Hear the Wind Sing most-played weirdness"** —
   mostly metadata-side. SoulSync wrote trailing-space album/title tags
   (splitting Hotel California into three server albums) and a `•`-separated
   multi-artist blob as a single artist tag. The play-count pipeline works
   (verified by a single test scrobble on the disposable test account).
   Navis contributes a missing Most Played tiebreaker.
4. **Unreported findings**: 659 dead local albums (10.5% — server reissued
   IDs after SoulSync rewrote content; schema-78 build cannot mark them
   stale, schema 80's `catalogAvailability`/`serverDeletedAt` can, via Repair
   Library); server media throughput collapses ~25x during Navidrome scans,
   which recur roughly every 30 minutes because SoulSync keeps writing;
   Navidrome answers missing cover art with HTTP 200 + a Subsonic error
   document, which Navis's recovery path (HTTP 404/410 only) never treats as
   a missing cover.

Code verification during planning refined the audit:

- `registerAlbumInteraction` lives at
  `lib/src/features/library/presentation/library_sync_provider.dart:581`
  (the audit's queue_provider.dart:407 pointer is
  `_ensureSongsInDatabase`, which upserts provisional albums **without**
  `serverCreatedAt`/`recentlyAddedRank`).
- The automatic newest-feed probe is 1 page x 100 unconditional plus a
  second page only when the first page is entirely newer-or-unknown
  (`library_sync_engine.dart:2854-2900`); manual checks use 5 pages x 100.
  `libraryHealthCheckedAt` is stamped even when the page cap is hit without
  reaching known content, so a buried addition produces no signal at all.
- The auxiliary-timestamp divergence is structural, not a missed write:
  store A (`server_config.capabilities` JSON key `navis.auxiliarySyncLastSyncedAt`)
  is written only by `_markAuxiliarySynced` (engine 2754-2769) on the legacy
  combined-run path (`_activeExecutionPlan == null`), which the typed
  coordinator never takes; store B
  (`library_sync_state.last_auxiliary_synced_at`) is derived from
  starred/playlist-header work-row completion (coordinator 1097-1123). A
  one-time import (navis_database.dart:1185) copied A into B; they are never
  re-synced.
- The hydration backlog lives on `albums.songsHydrated = false`
  (`countPendingHydrationAlbums`), not in `library_sync_work`. The work
  table's `deltaReconcile`/`compatibilityAudit` rows appear perpetually
  queued because `_planFromWork` (coordinator 1834-1869) defers broad kinds
  unless the app is foreground and nothing is playing, and only
  catalog-target sync attempts claim work.
- The schema-80 scan guard (`_scanInvalidatedCollection`, engine
  3703-3717) resets the full-sync candidate to `collecting` whenever the
  scan token changed between collection and promotion, with **no cap on
  consecutive deferrals** — a livelock risk on a server that rescans every
  ~30 minutes.
- Cover transport already rejects HTTP 200 with a non-image content type
  (cover_art_cache_manager.dart:457-471) but never fires `onMissingCover`
  there, never sniffs body bytes when the content type is null/spoofed, and
  the missing-cover mark is session-memory only.

## 1. Objective and decisions

Restore trustworthy library freshness, honest sync status, and resilient
cover handling on a high-churn Navidrome server, and give the operator a
durable procedure for the server-side half (scan scheduling, SoulSync write
behavior, tag hygiene).

Decisions recorded 2026-09-22 (user-approved):

1. **Scope**: all three workstreams (Navis code, server ops, tag cleanup);
   the ops guidance becomes a permanent runbook at
   `docs/server-library-hygiene.md`.
2. **Discovery**: adaptive overlap paging plus a persisted discovery-debt
   ledger with escalation to broader reconciliation.
3. **Scan guard**: cap consecutive deferrals (3) and allow promotion once a
   completed scan token is observed stable across the collection window;
   record the streak in the ledger and surface it in sync status.
4. No database schema migration is anticipated in any B stage; debt and
   streak state ride existing stores (capabilities JSON, operation ledger).
   If implementation proves otherwise, the stepwise-migration rules apply
   (make gen + migration test update).

## 2. Workstream A — Server and library hygiene (runbook; operator-run)

Executed via [docs/server-library-hygiene.md](docs/server-library-hygiene.md).
The Navis test account (`navis` on `navidrome.example.test`) is disposable and
may be written freely; personal accounts are read-only.

- [ ] **A1 Tame the rescan storm.** Replace the default scan schedule with a
  fixed cadence (e.g. `@every 4h` or `0 */4 * * *`) via
  `Scanner.Schedule`/`ND_SCANNER_SCHEDULE`; either disable the filesystem
  watcher (`Scanner.WatcherEnabled=false`) or raise `Scanner.WatcherWait`
  above SoulSync's write-burst length so writes coalesce. Verify key names
  against the Navidrome v0.64.0 configuration reference before applying.
  *Acceptance: getScanStatus shows ≤ 1 scan per scheduled window; the ~25x
  mid-scan throughput collapse is confined to scheduled windows.*
- [ ] **A2 Batch SoulSync writes.** Quiesce writes into quiet windows aligned
  with the scan schedule; measure disk I/O during a scan (iostat/vmstat).
  *Acceptance: media and cover-art throughput stays near the 22 KB/s
  baseline outside scheduled scans.*
- [ ] **A3 Tag hygiene.** Audit with mutagen for trailing whitespace in
  album/title/artist tags and `•`-separated multi-artist blobs; back up;
  retag (strip trailing/leading whitespace; convert `•` blobs to
  Navidrome `;` multi-value artist fields); rescan. **Retagging changes
  album identity/IDs — expect another dead-album wave; run Repair Library
  (C3) after A3.** *Acceptance: Hotel California collapses 3 server albums
  → 1; the Hear the Wind Sing artist blob splits into its three artists.*
- [ ] **A4 Post-cleanup verification.** Server-side duplicate-album queries
  and count reconciliation; record before/after in this plan.

Blocker: A1-A3 require shell/config access to the server host and the
SoulSync/music-library filesystem, which this workstation does not have. The
runbook contains the exact commands for the operator. Navis-side
certification (B2/B6) is executed against the live server as-is.

## 3. Workstream B — Navis code fixes

Each stage is one commit on `dev`, `./tool/check.sh` green before the
commit, user-visible changes entered in both
`lib/src/features/changelog/changelog_data.dart` and
`tool/generate_release_notes.dart`. Runtime-affecting stages complete the
development-workflow runtime loop (diagnostics API, screenshots for visible
changes, clean restart).

### Stage B1 — Unify auxiliary-sync timestamps

`library_sync_state.lastAuxiliarySyncedAt` becomes the single source of
truth. Remove the dead capabilities-JSON store A read/write
(`navis.auxiliarySyncLastSyncedAt` reader/writer in the engine) and the
`_shouldSyncAuxiliary` dependence on it; the typed coordinator's
"advanced only when starred AND playlist-header work completed" semantics
stay. The one-time import remains harmless. The UI (sync settings) needs no
change — it already reads store B.

- [ ] Implementation: engine (`_readStoredAuxiliarySyncedAt`,
  `_markAuxiliarySynced`, `_shouldSyncAuxiliary`, capabilities key
  constant), coordinator due-ness path, tests updated.
- [x] Tests: engine auxiliary gating cases; coordinator auxiliary-drain
  case; no surviving reference to the retired key.
- [x] Evidence: check.sh green (1605 tests); commit `80653e5f` (2026-09-22).
  The new monotonic DAO writer (`markAuxiliarySyncedAt`) keeps the unified
  column regression-free against the coordinator's work-row derivation.

### Stage B4 — Cover-art recovery on 200 + error document

In `CoverArtHttpFileService.get`, the existing 200-non-image branch
(cover_art_cache_manager.dart:457-471) gains body inspection: if the drained
body parses as a Subsonic error envelope (or is any non-image payload), fire
`onMissingCover(coverId)` and classify as `missingCoverReference`. Add a
magic-byte sniff (JPEG `FF D8 FF`, PNG `89 50 4E 47`, WebP `RIFF....WEBP`,
GIF variants) so a null/spoofed `image/*` content type with garbage bytes is
rejected and evicted instead of cached.

- [x] Implementation in `cover_art_cache_manager.dart` (drain-then-classify
  rework; sniff before returning `_CoverArtHttpFileServiceResponse`).
- [x] Tests: loopback-server cases for (a) 200 + JSON error document →
  recovery fires, (b) 200 + spoofed image content type + non-image bytes →
  rejected, nothing cached, (c) HTML stays `invalidPayload` without
  recovery, (d) empty body rejected; existing 404/410 cases stay green.
- [x] Evidence: `cover_art_cache_manager_test.dart` 24/24 + check.sh green
  (1611 tests); commit `cfeb2bcf` (2026-09-22). JPEG detection uses the
  2-byte SOI marker; `BytesBuilder` moved to a direct `dart:typed_data`
  import after the gate flagged the deprecated indirect one.

### Stage B5 — Most Played tiebreaker

`watchMostPlayedSongs` (library_dao.dart:1728-1742) orders
`playCount DESC` only. Add deterministic tiebreakers: recency via a
`LEFT JOIN` on `MAX(play_history.playedAt)` per song, then `LOWER(title)`,
then id. Add the first DAO-level test for this query.

- [x] Implementation + DAO tests in `test/src/database/` (tiebreaker by
  recency-then-title, plus a history-less deterministic-order case; note
  `upsertSongs` intentionally clears `serverDeletedAt`, so the deleted-row
  filter is exercised via a direct row update).
- [x] Evidence: `library_dao_test.dart` 23/23 + check.sh green; commit
  `42c3e620` (2026-09-22).

### Stage B3 — Sync-status backlog observability

Add `watchPendingWorkCount` (Drift stream over `library_sync_work`
queued/running/failed) and `watchPendingHydrationAlbums` stream variants;
keep `LibrarySyncState.pendingWorkCount` live and populate
`pendingHydrationCount` from the stream; `_SyncStatusBanner` gains a backlog
pill ("catalog synced - N albums awaiting metadata"); completion
notification claims "complete" only when the backlog is 0. Sync Settings
already renders `pendingWork`; wire the live stream to it.

- [x] Implementation: DAO streams (`watchPendingWork`,
  `watchPendingHydrationAlbums`), live controller subscriptions (deferred
  to the engine while a run is in flight), idle backlog pill on the
  library screen (`library-sync-status-backlog`), l10n key
  `librarySyncBacklogBanner`.
- [x] Tests: DAO watch tests (bounded-wait settlement), banner widget
  tests (pill present at backlog 3, absent at 0); 43/43 screen tests.
- [x] Notable fix discovered by the new watch test: `enqueueWork` writes
  through `customStatement`, which bypasses drift's stream notifications —
  the DAO now reports the table explicitly after the enqueue transaction
  commits.
- [x] Evidence: check.sh green (1616 tests); commit `50af9c96` (2026-09-22).
  Screenshot evidence: consolidated runtime pass (pending, see §5 note).

### Stage B2 — Adaptive discovery paging + discovery-debt ledger

Generalize the probe's look-ahead: automatic checks page until they reach
known-and-unchanged content or a raised cap (5 pages x 100, matching the
manual window); on a capped-without-overlap outcome, persist a discovery
debt record in the server capabilities JSON (next to
`libraryHealthCheckedAt`, no schema change): depth reached, timestamp,
streak. The next probe starts at the debt depth; after 2 consecutive debts,
enqueue `deltaReconcile` (broad reconciliation). Metered runs keep the
shallow budget but record debt instead of silently dropping coverage.
`libraryHealthCheckedAt` is stamped only on overlap or a clean cap below
the budget.

- [x] Implementation: `_runNewestAlbumHealthProbe` (adaptive window:
  automatic 2 pages, widened to 5 while debt is outstanding; look-ahead
  overlap stop shared with the bounded metered check), `healthProbeDue`
  (debt keeps the probe on schedule), debt streak persisted in the
  capabilities JSON (`libraryDiscoveryDebtStreak`), escalation signal
  `probeDiscoveryDebtStreak` on the run state, coordinator
  `_enqueueDeltaReconcile` at streak ≥ 2 (`discoveryDebtEscalationStreak`
  in `sync_run_contract.dart`).
- [x] Tests: engine probe tests — capped metered window records debt,
  known-content overlap clears it, repeated caps reach the escalation
  streak; suite 238/238.
- [x] Design refinements recorded: (a) the window widens from offset 0, it
  does not resume at the debt depth — new additions shift `newest` offsets,
  so resume-at-depth could skip the very albums debt exists for; (b) debt is
  recorded only where overlap evidence exists (full manual windows scan
  everything by contract and never record debt; the bounded metered check
  does evaluate the look-ahead); (c) a partial final page proves the feed
  end and never counts as a cap.
- [x] Evidence: check.sh green (1623 tests); commit `5e941404` (2026-09-22).
  Live-server certification: pending (consolidated pass).

### Stage B6 — Scan-guard deferral cap + settle-wait

Derive the consecutive `scanChangedDuringCollection` streak from the
operation ledger (no schema change). After 3 consecutive deferrals, allow
promotion when a completed scan token is observed and remains stable across
the collection window (freshest completed snapshot wins). Record the
cap-release decision in the ledger and surface the deferral streak in sync
status. Depends on A1 in spirit (fewer scans make settle-wait trivially
fast) but must remain correct without it.

- [x] Implementation: deferral streak rides the capabilities JSON
  (`libraryScanDeferralStreak`, incremented on every
  `scanChangedDuringCollection` deferral; each deferral still records a
  ledger entry carrying its streak). At 3 consecutive deferrals
  (`_maxScanDeferralStreak`) the engine polls the server for a running scan
  (`_waitForScanSettle`, bounded 12 x 5s, constructor-injectable for
  tests); a quiet server releases the promotion (`scanChurnCapRelease`
  ledger entry, streak cleared). Successful promotions also clear any
  lingering streak.
- [x] Tests: scan-guard suite 8/8 — streak accrues across churn (ledger
  carries per-deferral streaks), settled server releases at the cap,
  still-scanning server stays deferred at the cap with the settle polls
  observed.
- [x] Design note: the streak lives in the capabilities JSON rather than
  being derived from ledger ordering — cheap atomic read/increment/clear;
  the ledger preserves the full event trail for diagnostics.
- [x] Evidence: check.sh green (1623 tests); commit `8e6f0ba8` (2026-09-22).
  Live-server certification: pending (consolidated pass).

### Stage B7 — Broad-work honesty (deltaReconcile / compatibilityAudit)

Investigate the steady state that leaves broad work rows perpetually queued
(deferred unless foreground + idle; only catalog-target runs claim work).
Decide policy: allow `deltaReconcile` at background priority when discovery
debt exists (pairs with B2), and either age out or document
`compatibilityAudit`'s steady state. Output: short decision note in this
plan, then implement or close with rationale.

- [x] Decision note (2026-09-22): the admission analysis showed broad work
  is NOT dead — a due automatic catalog sync claims runnable work and
  `_planFromWork` admits `deltaReconcile`/`compatibilityAudit` whenever the
  app is foreground, idle (no playback), and background sync is allowed;
  the audited device's perpetually-queued rows were that build's steady
  state between admissions, hidden by the old status UI. With B3 surfacing
  the live count and B2's escalation enqueueing `deltaReconcile` at
  priority 50, the loop now closes without widening the gating: widening
  admission to play-back-active or background sessions would reintroduce
  the contention the guard exists to prevent. A regression test pins the
  contract: an escalated `deltaReconcile` row is claimed by the next due
  automatic sync and marked completed (coordinator suite).
- [x] Implementation: test only (admission contract pinned); the policy
  itself is the existing guard, now observable. Evidence: coordinator
  suite green; commit with this plan update.

## 4. Workstream C — Device migration and repair (operator-run checklist)

The audited device runs schema 78; dev is schema 80.

- [ ] **C0** Install a current dev build (schema 80).
- [ ] **C1** Run Repair Library once (clears the 659 dead albums via
  `catalogAvailability`/`serverDeletedAt`; hydrates the backlog). Use
  `./tool/repair_confirmation_diagnostics.sh` for a bounded gate.
- [ ] **C2** Verify read-only against the device DB: dead-album count → 0,
  hydration backlog trending to 0, Liked fully populated, auxiliary
  timestamp advancing (post-B1 single store).
- [ ] **C3** After A3 retagging, run Repair Library again (album IDs change).
- [ ] **C4** Monitor cover recovery on the 200+error-document server
  behavior and Most Played ordering after B4/B5.

Blocker: C0/C1/C3 require the physical device; the operator performs these.
C2 verification queries are provided in the runbook appendix.

## 5. Validation and acceptance matrix

| Stage | Focused tests | Full gate | Runtime loop | Live-server cert |
|---|---|---|---|---|
| B1 | engine + coordinator aux tests | check.sh | clean restart + sync run | n/a |
| B4 | cover cache manager tests | check.sh | cover render + screenshot | missing-cover server behavior |
| B5 | new DAO test | check.sh | home screen render | n/a |
| B3 | DAO + provider + banner tests | check.sh | banner screenshot + clean restart | n/a |
| B2 | engine probe tests | check.sh | diagnostics app API | clone suite + probe run |
| B6 | scan-guard tests | check.sh | diagnostics app API | clone suite + promotion run |
| B7 | per decision | check.sh | per decision | n/a |

Runtime-affecting stages follow docs/development-workflow.md: acceptance
scenario written before editing, authenticated health gate, bounded polling,
inspected screenshots for visible changes, clean-restart repeat, completion
evidence recorded per line 635. Never describe unexecuted validation as
passing.

Runtime validation note (2026-09-22): the stages were validated with per-stage
focused suites plus the full `./tool/check.sh` gate at each commit (1605 →
1624 tests, all green). The consolidated runtime loop (live clone diagnostics
+ inspected screenshots + clean restart) runs once over the completed stack
instead of per stage; its evidence is recorded below in §5a.

### §5a Consolidated runtime certification (open)

First clone attempt (17:12Z) failed its first guardrail assertion for a
non-B-stage reason: the cloned primary device database is mid-repair
(resumable candidate, generation 32) and schema-migrates 78→80 at clone
startup, so the startup model repair resumed as a fullRepair and surfaced as
`deferred/meteredPolicy` inside the cellular scenario, whose plan-kind
expectation it does not satisfy. Host network verified ethernet/unmetered —
not a policy regression; deferral reason `meteredPolicy` with 2 requests
proves the guardrail itself worked.

Harness fix 1 (committed with this plan): clone mode now resets overrides and
drains startup work under real policy before the guardrail scenarios — a
bounded wait for startup work to appear (never an idle 4-hour wait when none
exists), then `wait_for_sync`. Documented in docs/development-workflow.md.

Second attempt (17:23Z): the drain worked exactly as designed — it caught the
startup model repair under Wi-Fi and let it run 10 minutes (86 requests,
23.4 MB, 37 write batches, starred target completed, hydration throughput
2.8 albums/s, candidate checkpointed) — but the operator's server was under
extended heavy load, so the repair ended `deferred / timeBudget`
(responseBudgetExceeded) and the cellular scenario again captured a deferred
`fullRepair`. This is now the expected condition for as long as the server
stays slow: every automatic catalog call legitimately resumes the repair
candidate, and the repair legitimately cannot finish inside its budget.

Harness fix 2 (this commit): (a) `wait_for_sync` polls on a backoff cadence
(2s doubling to 15s) instead of a fixed 2s spin, out of respect for the
loaded server; (b) the cellular guardrail scenario now asserts its actual
intent — no artist/catalog sweep attributable to automatic cellular work
(`getIndexes <= 1`) — and tolerates a deferred fullRepair remnant of the
startup model repair instead of failing on the leaked plan kind.

2026-09-24 certification attempt: `./tool/check.sh` passed (1,624 tests).
The single 20-second-bounded `getScanStatus` health probe returned promptly
with `status=ok` and no active scan, so two clone-suite attempts were made.
The first (`build/sync-diagnostics/20260924T075837Z-clone`) stopped at its
opening `POST /v1/playback/start` with HTTP 500 / `StateError`; no sync
scenario ran. The second (`build/sync-diagnostics/20260924T080547Z-clone`)
passed playback and drained the startup repair, but stopped at the cellular
automatic guardrail assertion. That repair ended `partial` with candidate
generation 32 `awaitingDeletionConfirmation`, rather than the previously
expected `deferred` outcome. The saved cellular result still reports repair
request 337 as the current status even though its `durableRuns` list includes
new auxiliary requests 338 and 339 (one completed, one deferred by metered
policy). The harness therefore cannot attribute its `planKind` and endpoint
counts to the cellular action from this snapshot. This is an observation gap,
not evidence that the cellular guardrail passed or failed. Both allowed suite
attempts for this session are exhausted. Before re-running, correlate each
posted action with new durable request/attempt IDs in the diagnostics harness;
then perform a fresh bounded server-health check. No certification checkbox
below is claimed from these partial attempts.

Harness fix 3 (pending live re-run): the clone now observes the terminal
diagnostics event for each metered guardrail action and checks only durable
requests and attempt endpoint counts created after that action's ledger
baseline. It forces the automatic deadline due for each automatic guardrail.
Focused action-correlation tests cover the stale-repair result from the
second attempt and reject a real catalog sweep; the complete live suite has
not yet been re-run. A separate local repair-confirmation fixture run on
2026-09-24 failed after restart with the candidate in `applying` and a
`failed` repair. It does not verify an automatic clone-only confirmation step,
so the suite leaves that boundary to its existing explicit repair scenarios.

2026-09-24 follow-up: the action-correlation fix passed the full repository
gate and was committed. The one fresh bounded `getScanStatus` probe responded
promptly but reported an active server scan. The live clone suite was not
started because the runbook documents severe throughput loss during scans;
no new runtime certification evidence is claimed from this follow-up.

2026-09-24 local confirmation follow-up: a fresh single bounded server probe
again reported an active scan, so no live clone suite was started. The isolated
loopback repair gate uncovered two independent blockers: an older source export
triggered an unrelated startup model repair after restart, and its diagnostic
six-second execution lease expired during large promotion. The fixture now
marks only its disposable clone model-current and uses the production ten-minute
lease. With those isolated fixture settings, promotion also exposed a real
batch review SQL error: an empty `ON CONFLICT DO UPDATE SET` statement. The
batch now uses `DO NOTHING` on its identity key, preserving earlier review
decisions. The focused DAO regression and full `./tool/check.sh` gate passed
(1,625 tests). The local gate then exited 0 at
`build/repair-confirmation-diagnostics/20260924T085630Z-clone`: generation 32
remained `awaitingDeletionConfirmation` with the original catalog across a
clean restart, then explicit repair succeeded, cleared the candidate, recorded
the before/after/removal promotion ledger and 297 new review entries. Both
app-owned Sync Settings screenshots were inspected, including the successful
`Last library change` summary. This is local confirmation-boundary evidence;
it does not satisfy the live clone-suite, B2/B3/B6, or operator device checks.

2026-09-25 live re-run: `./tool/check.sh` passed before the single bounded
`getScanStatus` probe, which returned promptly with `status=ok` and no active
scan. Both allowed clone-suite attempts were used. The first artifact,
`build/sync-diagnostics/20260925T182819Z-clone`, reached the cellular
automatic and manual guardrails. Its manual action incorrectly resumed a
queued automatic probe (`requestId` 344), so it never requested a newest page.
The coordinator now leaves that probe queued and preserves explicit bounded
manual discovery; its focused regression and the full gate passed (1,626
tests), committed as `8911dea1`. The second artifact,
`build/sync-diagnostics/20260925T183842Z-clone`, passed the cellular automatic,
manual, metered-Wi-Fi, and interactive-hydration checks. The manual action
made exactly one `getIndexes` and one `getNewestAlbumList2` request, with no
artist or bulk-song sweep. The suite then stopped at its no-override repair
assertion: production correctly returned `deferred` /
`waitingForMobileConsent` with zero requests and `updatesAvailable=false`,
but the harness expected every deferred repair to report updates available.
The harness now checks the explicit consent contract. No end-to-end suite
success or B2/B3/B6 certification is claimed from these partial attempts; a
new session with a fresh server-health check is needed for a complete run.

2026-09-25 later live window: the repository gate passed again (1,626 tests),
and the single bounded `getScanStatus` probe returned `status=ok`,
`scanning=false`, and count 56,220. Both allowed clone-suite attempts reached
the final performance assertion. The first artifact,
`build/sync-diagnostics/20260925T185046Z-clone`, failed only the
database-canary maximum (1,142,227 µs; limit 500,000 µs); the second,
`build/sync-diagnostics/20260925T191113Z-clone`, failed the same limit
(1,575,938 µs). Their canary p95, frame, promotion, and playback checks passed.
Moving the Library screenshot after the performance report in the second run
did not remove the slow reads. Its app-owned screenshot shows the backlog pill
"Library synced, 4 albums are still loading details"; the saved idle status
records four pending albums. The manual cellular action made one `getIndexes`
and one `getNewestAlbumList2` request without an artist or bulk-song sweep.
Neither run observed scan churn or discovery-debt escalation. These are partial
observations, not a green §5a certification. Both live attempts for this window
are exhausted. An offline SQLite copy deleted the 55,947-row candidate in 111
pages while a separate artist-count reader stayed below 1 ms, so cleanup-page
locking alone did not explain the app result. The isolated, authenticated
repair-confirmation fixture reproduced canary maxima of 757 ms and 751 ms
with Drift's single pooled reader. With two pooled readers, the same fixture's
134 samples reached 8.1 ms maximum and its 120 promotion-phase samples reached
3.2 ms maximum, while the large confirmation repair and clean restart still
passed. A final run without temporary timing probes also exited 0 at
`build/repair-confirmation-diagnostics/20260925T194248Z-clone`: 122 canary
samples, p95 7.4 ms, maximum 43.7 ms, and an inspected app-owned Sync Settings
screenshot showing the completed repair. The fixture now saves and asserts its
canary report. This is local
performance evidence only; the live clone suite must still pass in a new
responsive-server window.

2026-09-26 continuation: the previous full repository gate remained green on
the committed checkout, and one bounded server probe returned promptly with no
active scan. The first allowed live attempt,
`build/sync-diagnostics/20260925T194918Z-clone`, completed the sync scenarios
but again failed only the final database-canary maximum: 828,445 µs against
500,000 µs, with p95 7,077 µs and p99 16,090 µs. The frame, promotion, and
playback metrics met their limits. Slow reads were sampled during
`fetchingSongs` and `applying`; collection and candidate cleanup stayed below
38 ms maximum. The two-reader change improved most phases but did not
eliminate rare stalls. A bounded, redacted slow-canary trace now records
event-loop delay alongside phase and elapsed time for the remaining allowed
attempt. The full repository gate passed again (1,626 tests) before that
attempt. No green suite or B6 scan-churn evidence is claimed from this run.

The second and final attempt for this session,
`build/sync-diagnostics/20260925T200936Z-clone`, also completed the sync
scenarios and reached the final performance gate. Its database canary passed
(512 samples, p95 6,990 µs, maximum 96,731 µs) and recorded no slow-read
trace entries. The frame maximum failed at 175,285 µs against 100,000 µs;
the corresponding build maximum was 172,670 µs while raster stayed below
8,000 µs. Frame p99, promotion, and playback metrics met their limits. The
app-owned Library screenshot again showed the four-album backlog pill. Neither
run observed scan-churn promotion or discovery-debt escalation. A bounded
slow-frame trace now records build/raster detail and the approximate sync
phase for any future frame over the limit. No §5a checkbox is certified from
these performance-failing runs, and the two-attempt cap is exhausted. The
isolated confirmation fixture then exited 0 at
`build/repair-confirmation-diagnostics/20260925T202916Z-clone` with 124
canary samples, maximum 10.7 ms, a clean restart, and an inspected app-owned
Sync Settings screenshot. This local gate verifies the diagnostic build and
repair path; it does not substitute for the live suite.

- [ ] Clone suite green end to end: pending a live re-run after the
      intermittent canary and frame maxima are understood in a fresh
      responsive-server window
      (see §8 Handoff). Artifact
      dirs so far: `build/sync-diagnostics/20260922T171212Z-clone`,
      `20260922T171932Z-clone` (transient stream timeout, server-side),
      `20260922T172348Z-clone` (drain validated, timeBudget deferral),
      `20260924T075837Z-clone` (playback start error), and
      `20260924T080547Z-clone` (cellular result attribution gap),
      `20260925T182819Z-clone` (manual intent displaced by probe),
      `20260925T183842Z-clone` (repair-consent assertion gap),
      `20260925T185046Z-clone` and `20260925T191113Z-clone`
      (database-canary maximum exceeded), and
      `20260925T194918Z-clone` (database-canary maximum exceeded with two
      readers), and `20260925T200936Z-clone` (frame maximum exceeded).
- [ ] B2 evidence in the run: newest-feed probe behavior + escalation
      follow-up rows observed in the clone: newest-feed request observed;
      no escalation row, pending green re-run.
- [ ] B3 evidence: banner/backlog pill screenshot inspected in both Sep 25
      performance-failing artifacts; pending green re-run.
- [ ] B6 evidence: promotion completes despite scan churn: pending re-run.
- [ ] Clean restart: the suite's own restart/recovery cycle covers this on
      the green run.

## 6. Documentation, rollout, and remaining limits

- `docs/architecture.md`: sync section updates for B1 (single auxiliary
  store), B2 (debt ledger), B6 (settle-wait policy).
- Changelog: both `changelog_data.dart` and `tool/generate_release_notes.dart`
  for user-visible stages (B2, B3, B4, B5, B6).
- `docs/server-library-hygiene.md` is the owning doc for workstream A;
  `docs/README.md` maps it.
- This plan moves to `docs/completed-plans/` only after all B stages are
  implemented and validated and the C checklist is confirmed; A stages are
  operator work tracked here with explicit blockers.

## 7. Ordering and checkpoints

1. Checkpoint 1 (docs): this plan + runbook + README map — commit before any
   code.
2. A1/A2 first for the operator (unblocks stable certification), but B1,
   B4, B5 are safe against churn and go first in code.
3. B3, then B2, then B6 (behavioral; certified on the live server).
4. B7 last.
5. One commit per stage; `./tool/check.sh` before each commit; stage only
   the files the stage touched; no pushes without an explicit request.

## 8. Handoff — remaining work and completion requirements

Status as of 2026-09-22 (commit `abd284d3` on `dev`): every Navis code stage
(B1-B7) is implemented, committed, and passed the full `./tool/check.sh` gate
(1,624 tests) at its commit. Nothing remains to implement in workstream B.
What remains is one machine-runnable certification pass, two operator-run
workstreams, and closeout.

### 8.1 Machine-runnable: consolidated runtime certification (§5a)

Deferred 2026-09-22 because the live server (`navidrome.example.test`) was under
extended heavy load; the resumed startup repair on the clone deferred with
`timeBudget` after 10 minutes of real progress, which is correct behavior
under load, not a defect. The 2026-09-24 attempt found a diagnostics-harness
result-attribution gap (§5a); its focused fix is committed, but the complete
live clone-suite re-run is still required before certification. The later
2026-09-25 window reached the final performance check twice and exposed
database-canary maximum latency above its limit (§5a).

Prerequisites:

- Primary DB export at `~/Documents/navis.sqlite.sqlite` (refresh it from
  the device if it is much older than the current app state; the clone
  schema-migrates 78 → 80 at startup and resumes its mid-repair candidate,
  generation 32 — that resume is expected and exercised by the suite).
- Test-account credential file `~/.config/navis/clone-diagnostics.secret`
  containing only the password of the disposable `navis` account (mode 600;
  never commit it). The password is provided by the operator separately.
- `./tool/check.sh` green on the checkout before starting.

Procedure (documented in docs/development-workflow.md, "Linux Sync
Diagnostics"):

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB="$HOME/Documents/navis.sqlite.sqlite" \
NAVIS_DIAGNOSTICS_USERNAME=navis \
NAVIS_DIAGNOSTICS_CREDENTIAL_PATH="$HOME/.config/navis/clone-diagnostics.secret" \
  ./tool/sync_diagnostics.sh clone
```

Rules learned from the 2026-09-22 attempts:

- Probe server health first with one bounded `getScanStatus` call; if it
  times out, stop and reschedule — do not retry in the same session.
- Run in the background and check at most every 5 minutes; `wait_for_sync`
  already polls on a 2 s → 15 s backoff.
- At most two suite attempts per session.
- Expected-under-load outcomes: the startup model repair may end
  `deferred`/`timeBudget` or `meteredPolicy`; the cellular guardrail
  tolerates a deferred `fullRepair` remnant. Anything else failing is a new
  reason and needs diagnosis from the artifact directory under
  `build/sync-diagnostics/`.

Definition of done for this item: the suite exits 0 end to end; §5a's
checkboxes are filled with the artifact directory plus (a) B2 evidence
(newest-feed probe behavior and any discovery-debt/escalation follow-up rows
in the clone work table), (b) B3 evidence (backlog pill inspected via
`POST /v1/presentation/screenshot`), (c) B6 evidence (promotion completing
despite scan churn), and (d) the suite's restart/recovery cycle recorded as
the clean-restart evidence. Commit as
`docs: record sync audit certification evidence`.

### 8.2 Operator-run: workstream A (server)

Steps A1-A4 in [docs/server-library-hygiene.md](docs/server-library-hygiene.md):
cap the Navidrome scanner (`Scanner.Schedule`, watcher policy), batch
SoulSync writes, run the mutagen tag audit/retag, then verify. Needs shell
access to the server host and the music library filesystem — this
workstation does not have it. Acceptance criteria are per-step in the
runbook. Warning repeated here: retagging re-issues album IDs, so Repair
Library (C3) must run after A3.

### 8.3 Operator-run: workstream C (device)

Steps C0-C4 in §4: install a current dev build (schema 80), run Repair
Library once, verify with the runbook appendix's read-only SQL (dead-album
count → 0, hydration backlog trending to 0, auxiliary timestamp advancing),
run Repair Library again after A3's retag, and monitor cover recovery plus
Most Played ordering. Needs the physical device.

### 8.4 Closeout

Move this plan to `docs/completed-plans/` only when §5a is fully evidenced
AND the operator confirms C0-C4; list it in `docs/completed-plans/README.md`
and the `docs/README.md` map when moved. Workstream A acceptance is
server-side and tracked here, not blocking the plan's move (record it as an
operator handoff in this section if still open at move time).

### 8.5 Guardrails for any continuation session

- Read `AGENTS.md` and `docs/agentic-engineering.md` first; this plan is an
  evidence record, not implementation authority.
- `./tool/check.sh` before every commit; one commit per logical change.
- Never push to origin without an explicit request.
- Never commit credentials or real server values.
- Leave the operator's in-flight `docs/agentic-engineering.md` modification
  and the untracked `.agents/` and `.zcodeignore` out of all commits.
- Do not run the certification suite against a visibly overloaded server.
