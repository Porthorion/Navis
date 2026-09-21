# Fix Stale Cache — Execution Plan (completion phase)

Companion to [Fix_Stale_Cache_Plan.md](Fix_Stale_Cache_Plan.md). This file tracks the
remaining work needed to reach the plan's own release-acceptance bar. Status markers are
updated as stages complete. Created 2026-09-21.

Verified during planning:

- `https://navidrome.example.test` is live and reachable from this machine (Navidrome 0.64.0,
  OpenSubsonic, 1,777 artists / 7,892 albums / 56,166 tracks, idle, no scan in progress).
- The diagnostics API exposes `POST /v1/session/connect` and `POST /v1/sync/repair`, so live
  certification exercises production code paths.
- `coverArtRevision` columns are written and bumped but **no call site reads them** — the
  artwork stage includes wiring `CoverArtImage(revision:)` from the DB to widgets.

## Step 0 — Checkpoint

- [ ] Re-run `./tool/check.sh` (format first; log to file; echo exit code) to confirm the
      uncommitted stale-cache implementation is green.
- [ ] Commit the uncommitted implementation on `dev` as one checkpoint commit
      (`feat: implement stale-cache recovery plan (schema 79)`). No push.

## Stage 1 — Engine-level scan-guard tests

Matrix rows: "Failure during promotion", "Server scanning mid-collection", "Unsupported
scan-status endpoint".

- [ ] Upgrade `FakeLibrarySyncApi` (`test/helpers/library_sync_fakes.dart`): replace static
      `scanStatus` with a queue/callback so collection-time and promotion-time observations
      can differ.
- [ ] Engine tests: scanning at collection withholds promotion (candidate returns to
      `collecting`); token change at promotion → ledger `scanChangedDuringCollection` with
      both tokens, committed catalog untouched, second stable run promotes and marks the
      token reconciled; unsupported endpoint never blocks and does not re-probe endlessly;
      admission enqueues exactly one snapshot per pending token and coalesces repeats;
      failure inside the apply transaction rolls back fully (raw-sqlite `RAISE(ABORT)`
      trigger or engine seam) and stays retryable.
- [ ] API tests: `getScanStatus` parsing in `subsonic_api_client_test.dart`;
      `ScanStatus.fromJson` (incl. missing `lastScan`) in `models_serialization_test.dart`.

## Stage 2 — Two-sided complete-set uniqueness (plan D2)

- [ ] `song_identity_reconciler.dart`: add canonical-side indexing / two-pass selection so a
      candidate claimed by more than one canonical row becomes `SongIdentityAmbiguous`
      regardless of stream order (symmetric with candidate-side ambiguity).
- [ ] Wire ambiguity through the paged promotion loop so every involved row gets a
      `recordRecoveryReview` entry.
- [ ] Tests: two canonicals contending for one candidate → both ambiguous + review rows;
      permutation invariance in both directions; unique matches still auto-apply.

## Stage 3 — MBID population (plan D4 persistence, schema 80)

- [ ] `Album`/`Artist` API models gain `musicBrainzId` (OpenSubsonic AlbumID3/ArtistID3);
      parse it in `getArtists`/`getAlbumList2`/`getAlbum`/`getArtist`/hydration paths.
- [ ] Schema 79→80: `release_mbid`/`artist_mbid` on candidate album/artist tables. Stepwise
      migration, all `schemaVersion`/`user_version` assertions in
      `navis_migration_test.dart` updated, downgraded-v79 fixture test, `make gen`.
- [ ] Wire the four mapping families in `library_sync_engine.dart` (isolate JSON row
      parsers, `_to*Companions`, promotion write loop, candidate staging round-trip).
- [ ] Tests: parsing/serialization; candidate→promotion round-trip persists MBIDs; v80
      migration.

## Stage 4 — Album/artist automatic mapping (plan D4 matching)

- [x] At promotion, auto-map albums/artists only from a unique stable identifier
      (releaseMbid/artistMbid) or an unambiguous complete replacement set with compatible
      metadata; everything else → typed review rows.
- [x] Extend the remap transaction to merge album/artist user state (starred album/artist).
- [x] Review UI renders album/artist entries with typed reason labels; relink via the same
      transaction.
- [x] Tests: unique-MBID auto-map; ambiguous → review; user-state merge; UI listing.

## Stage 5 — suspectedMissing wiring + availability-aware selection (plan E2/E4)

- [x] Isolated media/detail 404s on an otherwise healthy connection set
      `CatalogAvailability.suspectedMissing`. Network/auth/rate-limit/decode failures never
      prove deletion; confirmed absence still only via validated catalog evidence.
- [x] Read-path exclusion: `confirmedMissing` without a local source excluded from Play All
      / shuffle / auto-download selection; `suspectedMissing` stays included; offline copies
      remain playable.
- [x] Review screen shows suspected entries with a distinct label; no auto-dismiss.
- [x] Tests: DAO transitions; engine 404 → suspected; selection exclusion; offline
      playability.

## Stage 6 — Relink preview dialog + review hardening (plan E7/E8)

- [x] Find match → preview dialog: old/new metadata side-by-side plus affected-references
      list, Apply through `remapSongIdentity` (same transaction as automatic recovery).
- [x] Render stored `candidateJson` as possible replacements; differentiate reason labels
      (`ambiguousMatch`/`conflictingMbid`/missing).
- [x] Generation revalidation at apply time; stale selection rejected and entry refreshed.
- [x] Tests: preview contents, apply, cancel; revalidation.

## Stage 7 — Partial-response-aware starred refresh (plan C7)

- [ ] Presence-aware upserts in `library_dao.dart`: update only supplied fields, preserve
      richer known fields, keep external/provisional provenance until catalog-authoritative
      evidence changes it.
- [ ] Schedule targeted hydration for incomplete starred entities via the existing work
      queue.
- [ ] Fake upgrade: partial `getStarredContent` responses with per-field presence.
- [ ] Tests: partial response preserves richer fields; hydration scheduled; provenance
      preserved; absence-clearing frozen during recovery (C9).

## Stage 8 — Artwork failure taxonomy, recovery, revision plumbing (F2/F3/F5–F9)

- [ ] Wire `coverArtRevision` from DB rows through providers to `CoverArtImage(revision:)`
      call sites so a bumped revision triggers exactly one targeted refetch.
- [ ] Typed failure categories: missing/stale cover reference; auth/proxy rejection; network
      timeout; invalid bytes / cached error payload; image decode failure.
      `CoverArtInvalidResponseException` now caught and classified.
- [ ] F6: on confirmed invalid cached image, evict only that entry from disk + decoded-image
      cache, one bounded refetch.
- [ ] F7: on missing cover reference, one coalesced entity-metadata refresh, retry the
      resulting cover ID; repeated builds must not loop (cooldown/pending set).
- [ ] F8: never cache HTTP-success error/HTML (content-type guard).
- [ ] F9: manager-level NieR test — two releases sharing "NieR:Automata Original Soundtrack"
      keep distinct artwork identities.
- [ ] Tests: classification; eviction + single refetch; coalesced refresh no-loop;
      shared-title distinctness.

## Stage 9 — Post-upgrade one-shot recovery reconciliation (plan §5)

- [ ] Persisted pending-recovery marker written by the upgrade migration; admission schedules
      exactly one eligible recovery reconciliation; marked complete only after successful
      promotion; survives restart until complete; never rescheduled afterward.
- [ ] Tests: upgrade schedules it; completes only post-promotion; no reschedule; restart
      mid-flow resumes; provider-level regression beside the existing "upgrading forces full
      repair" test.

## Stage 10 — 56k promotion measurement

- [ ] Synthetic ~56k-song in-memory engine fixture: assert `lastApplyDurationMs` /
      `lastPromotionDiagnosticsJson` recorded, generous duration bound, indexed matching via
      `api.calls` request counts.
- [ ] Runtime: `tool/sync_diagnostics.sh full-rescan` against a live-server clone; gate on
      promotion timings from `/v1/diagnostics/report`; numbers recorded in the plan doc.

## Stage 11 — Live-server runtime certification (Linux)

Credentials supplied at runtime via `POST /v1/session/connect`; clone launched with an
isolated `XDG_CACHE_HOME` so diagnostics do not share the production cover-art cache.

- [ ] Delta check: clone → connect → `/v1/sync/check` → counts vs server (1,777 / 7,892 /
      56,166), health, screenshots.
- [ ] Full repair: `/v1/sync/repair` → poll `/v1/sync/status` → promotion verified,
      `/v1/sync/ledger` clean, no user-state loss (spot-check likes/ratings/queue), review
      entries inspected.
- [ ] NieR artwork retest: both NieR:Automata releases keep distinct album identity (no
      merge), valid distinct artwork, revision-bump targeted refetch.
- [ ] `cache-alias` mode: live identity-remap certification (provisional→canonical ownership
      transfer).
- [ ] One-shot recovery reconciliation observed end-to-end (post Stage 9), including an app
      restart mid-flow.
- [ ] Bounded failure drills: mid-repair cancel + resume; simulated transport failure → no
      partial promotion.
- [ ] Evidence captured (handshake-dir artifacts, screenshots, sqlite3 dumps, timing report)
      and linked from the plan doc matrix.

## Stage 12 — Android written checklist (user runs)

- [ ] Checklist document produced (SAF download ownership, cellular/metered consent,
      cold-start gate `./tool/android_auto_cold_start_diagnostics.sh`, DHU projection if a
      phone is available). Plan acceptance records Android as user-pending.

## Stage 13 — Regression sweep, docs, changelog, acceptance

- [ ] `./tool/check.sh` fully green.
- [ ] Changelog + release notes for user-visible changes (Relink preview, review reasons,
      suspected-missing behavior, starred refresh, artwork recovery, post-upgrade
      reconciliation).
- [ ] Docs updated: `architecture.md` (identity/availability/artwork),
      `sync-reliability-recovery-plan.md` cross-link, `development-workflow.md` if tooling
      gained timing gates.
- [ ] Plan doc's 21-row matrix updated with per-row evidence (test name or runtime
      artifact); Phase A fixture note recorded (controls satisfied by the upgraded fake +
      coordinator tests).
- [ ] Acceptance per §4 checked; `Fix_Stale_Cache_Plan.md` moved to `docs/completed-plans/`
      when all rows have evidence.

## Ordering and checkpoints

Stages 1–2 lock in scan-guard and matching correctness; 3–4 are the identity core (schema 80
is the only migration); 5–9 are independent feature completions ordered by user-state risk;
10–11 certify; 12–13 close acceptance. Each stage ends with its targeted tests green;
`check.sh` runs before each commit. Working state stays on `dev`, one commit per stage, no
pushes.
