# Navis library migration, artwork recovery, and reliable repair

## 1. Objective, decisions, and investigated baseline

Make Navis recover safely when server scans change file locations, metadata, or media IDs. Existing favorites and local references must follow proven replacements, uncertain matches must remain recoverable, and library repair must work predictably on Wi-Fi and explicitly approved mobile data.

The user selected these behaviors:

- Automatically relink proven matches; provide manual review for ambiguous or missing items.
- Restore recovered likes to the server so other clients receive them.
- Preserve mobile-data consent through retries and brief disconnects within the current repair session. Clear consent on completion, cancellation, sign-out, account change, or app restart.
- Keep the last committed library browsable and playable during ordinary Repair Library.
- Validate Linux and Android.
- Investigate both immediate rebuild failures and failures after partial progress.

### Evidence collected on 2026-09-19

| Area | Finding |
|---|---|
| Repository | Investigation began at commit `9d0ff343`; database schema is 73. Concurrent playback work subsequently changed the workspace. Preserve and integrate with that work. |
| Server | Navidrome reports `0.64.0 (1072e9f7)`. Soul Sync and Octo-Fiesta are also deployed. |
| Server catalog | Navidrome contained 56,438 media rows: 56,073 available and 365 marked missing. Its latest observed scan completed without a recorded scan error. |
| Linux catalog | The inspected profile contained 56,025 songs. All existed in Navidrome and none were marked missing there. |
| Favorites | Linux and the configured server agreed on 224 liked songs, 15 liked albums, and 8 liked artists. The historical stale-favorite problem was not reproduced in this current profile. |
| Artwork | Four likely NieR soundtrack entries returned valid JPEGs through both the configured public address and direct Navidrome. Their current cover IDs matched Linux metadata. Two distinct releases share the title “NieR:Automata Original Soundtrack.” |
| Server errors | A bounded log sample contained missing-cover, download, stream, and now-playing failures. Examined missing cover/song IDs were absent from both the current Linux catalog and Navidrome. Their originating client was not established. |
| Request fidelity | Initial Python-default requests received HTTP 403; requests using application-like headers succeeded. Those initial failures are not evidence that Navis itself is blocked. |
| Tests | 132 existing tests passed across identity reconciliation, identity persistence, planning, synchronization, coordination, and artwork caching. |
| Limitations | No Android device was connected. No end-to-end repair or visual reproduction was performed during this investigation. No implementation or production-data changes were made. |

### Confirmed implementation gaps

1. `SongIdentityReconciler` obtains candidates through `getProvisionalSongs()`. Previously authoritative server songs changing IDs are excluded.
2. Album-song reconciliation can remove old rows before identity reconciliation runs, losing the metadata and references needed to recover them.
3. Identity remapping transfers several references but does not explicitly merge the old song’s liked/rating state into its replacement.
4. Matching consumes old candidates while streaming new songs; uniqueness is not established across the complete replacement set.
5. Starred synchronization reconciles timestamps/flags without refreshing the returned media metadata.
6. Navis has no `getScanStatus` integration. Artist-index/newest checks cannot reliably detect every change to an older album or existing song.
7. Repair retry/reconnect paths start without the earlier mobile override. Request coalescing can also return existing work without accounting for stronger network consent.
8. The rebuild controller converts most non-success results into a generic failure, including states needing waiting, continuation, or confirmation.
9. Artwork keys contain cover ID and size, without a profile namespace or explicit targeted recovery revision.
10. Identity/cache validation uses filesystem checks that do not correctly cover Android SAF document URIs.

These are verified code gaps, not proof that every reported failure has the same cause. Navidrome itself documents that moving and retagging files in the same scan can prevent automatic identity preservation, making client recovery relevant to this migration. [Navidrome persistent IDs](https://www.navidrome.org/docs/usage/configuration/persistent-ids/)

## 2. Implementation sequence

### Phase A — Establish reproducible failures and useful diagnostics

1. Re-read the repository guide, current architecture, and runtime workflow. Record the current commit, dirty files, dependency versions, and deployed image revisions.
2. Coordinate with the concurrent playback work before changing audio-handler contracts, queue behavior, diagnostics, or release notes. Do not overwrite its changes.
3. Create an isolated database/cache profile using SQLite’s backup mechanism. Preserve production metadata, downloads, and server configuration.
4. Build a deterministic Subsonic fixture with two catalog versions:
   - **Before migration:** liked songs/albums/artists, playlists, queue/history, downloads, and cached artwork.
   - **After migration:** changed IDs, moved albums, altered metadata, changed artwork, unchanged-ID metadata updates, missing songs, and ambiguous replacement releases.
5. Add fixture controls for scan-in-progress, completed scans, unchanged artist cursors, interrupted pagination, capped pages, transient failures, and mobile-network transitions.
6. Extend existing redacted diagnostics with:
   - Operation/session ID, origin, phase, network classification, grant, and effective budgets.
   - Endpoint category, attempt, duration, HTTP/Subsonic error category, bytes, and checkpoint.
   - Committed/candidate generations, scan observation, repaired/ambiguous/unavailable counts.
   - Explicit terminal reason and next eligible action.
7. Persist useful failure categories per attempt. A later successful request must not erase the evidence needed to explain a previous failed repair.
8. Reproduce failures through the production controller and authenticated app API, not only fake engine methods.

**Exit condition:** controlled fixtures reproduce identity loss and consent/rebuild-state defects; any live failure is attributed to a specific client phase or upstream response. If a live failure cannot be reproduced, report that limitation and retain deterministic coverage rather than inventing its cause.

### Phase B — Make repair resumable and preserve session consent

1. Represent an ordinary repair as a controller-owned session with stable identity, candidate generation, progress, terminal reason, and an in-memory network grant.
2. Apply consent before starting or joining work. Eliminate the race between automatic controller startup and the screen’s post-frame mobile-consent action.
3. Retain the grant across retry and reconnect within that session. Persist collection checkpoints, but do not restore mobile consent after process restart.
4. Coalesce requests by operation, target, session, and effective grant—not priority alone. A consented request must not be satisfied by a weaker deferred request.
5. Use the admitted execution plan as the authority for endpoint access, concurrency, and byte limits:
   - Broad consent permits the complete repair pipeline, including fallback hydration.
   - Ordinary automatic cellular checks retain their existing restrictions.
   - Offline state always pauses network work, even when a mobile grant exists.
   - Keep bounded response-memory limits. Reduce pageable response sizes after budget overflow; report an oversized indivisible response distinctly.
6. Preserve successfully collected candidate pages through transient failures. Resume missing work instead of clearing the candidate or restarting the entire scan.
7. Keep transport retries bounded and honor existing backoff/`Retry-After` behavior. Do not fix intermittent failure by removing limits or adding indefinite retries.
8. Map outcomes explicitly:

| Outcome | Required behavior |
|---|---|
| Offline | Waiting for connection; retain checkpoint and session grant. |
| Mobile consent absent | Waiting for permission; explain the required action. |
| Another executor owns the lease | Waiting for current work; avoid duplicate execution. |
| Transient transport failure | Retain checkpoint; show retry timing and Retry. |
| Candidate still needs hydration | Continue pending work or show a precise deferred reason. |
| Large removal requires confirmation | Show affected counts and Apply/Discard controls. |
| Authentication failure | Explain that connection credentials/session need attention. |
| Completed | Require committed promotion; then show actual change counts. |
| Cancelled | Stop work, retain the committed library, clear session consent, and prevent automatic resurrection. |

9. Start ordinary Repair Library from Sync Settings without forcing the user out of the library. Provide a persistent progress/status entry with details, Retry, Cancel, and confirmation actions.
10. Keep initial login and destructive cache-reset flows blocking when no usable catalog exists. Preserve the router’s narrow refresh contract.

**Exit condition:** one mobile approval survives disconnect/retry; repair can complete on the fixture without repeated manual restarts; browsing and playback continue from the committed catalog.

### Phase C — Refresh metadata after server scans

1. Add a typed, read-only `getScanStatus` API to the Subsonic client and sync abstraction. Support the standard `scanning` and `count` fields and optional provider fields such as Navidrome’s `lastScan`. Do not require optional fields from other servers. [OpenSubsonic scan status](https://opensubsonic.netlify.app/docs/endpoints/getscanstatus/)
2. Persist the last observed and last successfully reconciled scan tokens per server/profile.
3. Check scan status within existing scheduled, resume, and manual sync admission:
   - Do not create a separate aggressive polling loop.
   - On a newly completed scan token, enqueue one resumable catalog snapshot.
   - Coalesce repeated observations of the same token.
   - Apply existing network, foreground/background, and playback scheduling restrictions.
4. A scan-aware snapshot must inspect songs as well as album summaries. Otherwise, changed song tags or IDs with unchanged album counts can remain undetected.
5. Observe scan state again before promotion. If the server scanned during collection, invalidate that candidate’s completeness evidence and recollect safely; keep the committed catalog visible.
6. Treat providers lacking scan tokens through existing discovery/audit mechanisms. Unsupported scan status must not block synchronization or cause repeated unsupported requests.
7. Refresh positive starred payload metadata using partial-response-aware mapping:
   - Update fields actually supplied.
   - Preserve richer known fields that a response omits.
   - Schedule targeted hydration for incomplete entities.
   - Preserve external/provisional provenance until catalog-authoritative evidence changes it.
8. Separate favorite reconciliation from catalog membership. A song absent from `getStarred2` is not necessarily deleted; a missing catalog ID is not necessarily intentionally unliked.
9. Keep the existing independent-absence protection for ordinary unlikes. Freeze absence-based clearing for identities awaiting recovery.
10. Run the recovery process below before destructive catalog cleanup or large-deletion assessment.

**Automatic behavior contract:** updates happen on the next permitted Navis check after a server scan. Immediate push notification from the server is not assumed. On restricted mobile data, record pending work and expose the consent action.

### Phase D — Reconcile changed identities without losing user state

Use the existing reconciliation and persistence architecture, centered on `lib/src/features/library/data/song_identity_reconciler.dart`, `lib/src/database/daos/song_identity_dao.dart`, and `lib/src/features/library/data/library_sync_engine.dart`.

1. Build the recovery candidate set before removing anything. Include:
   - Previously authoritative rows absent from a validated replacement snapshot.
   - Retained unavailable rows awaiting recovery.
   - Existing provisional candidates, retaining their separate provenance rules.
2. Build indexed candidate sets on both sides before selecting matches. Do not let page order or “first match wins” determine identity.
3. Apply these automatic matching rules:
   - Same server ID: refresh metadata directly.
   - Different song IDs: require a unique recording MBID on both sides, with no contradictory known duration/release evidence.
   - Without a usable MBID: require normalized exact title, artist, and album; duration within the existing three-second tolerance; compatible known disc/track positions; and uniqueness on both sides.
   - Conflicting nonempty MBIDs prohibit metadata-only automatic matching.
   - Multiple editions, many-to-one, one-to-many, and otherwise conflicting candidates enter review.
   - Do not use fuzzy titles or artwork as automatic identity proof.
4. Persist optional album release MBIDs and artist MBIDs when supplied. Automatically map albums/artists only from unique stable identifiers or an unambiguous, complete relationship mapping with compatible metadata. Otherwise require review.
5. Make a recovery plan before applying it: mappings, retained items, conflicts, user-state changes, reference changes, and deferred side effects.
6. In one database transaction:
   - Upsert authoritative replacements.
   - Merge user state with precedence: latest pending/concurrent local action; explicit current canonical state; preserved old state when the replacement lacks it.
   - Preserve the original local liked timestamp when carrying a like forward.
   - Remap queue items, history, playlist memberships, downloads, match-flow references, lyrics/scrobble/feedback references, local mutation journals, absence candidates, and aliases.
   - Preserve ordering and existing duplicate-entry semantics.
   - Enqueue required server-like changes.
   - Retain unresolved rows and record review entries.
   - Promote the generation and write aggregate recovery/removal evidence.
7. Separate irreversible side effects from the transaction:
   - Do not delete files, send server mutations, or leave irreversible playback changes before commit.
   - Protect active source files throughout promotion.
   - Publish committed aliases and refreshed display metadata to playback.
   - Perform ownership-aware cleanup afterward, with retryable reconciliation for sidecars/manifests.
8. Resolve aliases at playback, download, queue restoration, playlist ingestion, and late cache-completion boundaries. Stale incoming references must not resurrect deleted identities.
9. Preserve playback priority: permanent download → rolling cache → stream.
10. Validate local storage through an injected filesystem/SAF-aware service. Never test Android document URIs with `File.exists()`.
11. Preserve valid permanent downloads and user-owned files. Cache collisions must not delete a user-owned duplicate merely because another cache entry wins.
12. Transfer recovered likes through the existing durable dispatcher, extending it to:
    - Wake when recovery queues work while already online.
    - Resolve aliases and respect entity type.
    - Coalesce competing actions so the latest unlike wins.
    - Retain transient/authentication failures with an actionable status.
    - Send album/artist stars using their ID3 parameters. [OpenSubsonic star parameters](https://opensubsonic.netlify.app/docs/endpoints/star/)
13. Do not automatically rewrite server playlists or replay historical scrobbles. Preserve their local references; server-side playlist/history migration is outside this implementation.
14. Preserve existing mass-removal confirmation. Compute removals after proven replacements and retained unresolved items are accounted for; do not weaken the guard.

**Exit condition:** a changed-ID liked song appears once under its current metadata, remains liked locally and eventually on the server, retains its references/downloads, and survives restart without interrupting an active valid source.

### Phase E — Retain unavailable items and provide review

1. Persist unavailable state separately from `isExternal` and `isProvisional`. Neither field means “previously on this server but now missing.”
2. Use three availability states: present, suspected missing, and confirmed missing.
   - An isolated media/detail failure may create suspicion.
   - Confirmed absence requires validated catalog evidence.
   - Network, authentication, rate-limit, and decoding failures must never prove media deletion.
3. Preserve unresolved items that have favorites, ratings, history, playlist/queue references, download ownership, or pending mutations.
4. Exclude confirmed unavailable items without a usable local source from normal Play All, shuffle, and automatic download selection.
5. Keep valid local copies playable and distinguish “Available offline” from “Unavailable on server.”
6. Add an **Unavailable items** entry with a count in Liked and Sync Settings. Reuse established list, picker, dialog, typography, and spacing patterns.
7. Each review item shows its saved title/artist/album, reason, local availability, and possible replacements. Provide:
   - **Find match:** search current same-profile catalog and choose a replacement.
   - **Relink:** preview old/new metadata and affected references, then apply through the same transaction as automatic recovery.
   - **Keep for later:** retain it across restarts and reconsider after subsequent scans.
   - **Remove from Liked:** remove that preference explicitly without deleting downloaded files.
8. Manual selections must be revalidated against the current generation before application. Never silently apply a stale selection.
9. Do not auto-dismiss unresolved records or offer bulk approval of uncertain matches.
10. Add localized copy, accessible labels, keyboard navigation, Android touch targets, and large-text layouts.

### Phase F — Recover artwork without clearing all caches

1. Introduce one shared artwork identity containing profile namespace, cover ID, requested size, and a targeted refresh revision.
2. Use that identity consistently across widgets, prefetch, downloads, full-screen covers, playback artwork, and request coordination.
3. When refreshed metadata changes a cover ID, notify consumers and load the new identity. Retain old artwork needed by unavailable/offline items.
4. For unchanged cover IDs whose content changed, use conditional revalidation and a targeted refresh revision on explicit repair or artwork recovery. Do not invalidate every cover after every sync.
5. Distinguish:
   - Missing/stale cover reference.
   - Authentication or proxy rejection.
   - Network timeout.
   - Invalid image bytes or cached error payload.
   - Image decode failure.
6. On a confirmed invalid cached image, evict only that entry from disk and Flutter’s decoded-image cache, then permit one bounded refetch.
7. On a missing cover reference, request one coalesced entity metadata refresh and retry the resulting cover ID. Repeated builds must not create retry loops.
8. Never cache an HTTP-success Subsonic error/HTML response as valid artwork. Validate response type and decoding.
9. Retest both NieR:Automata releases separately; shared titles must not cause artwork or album identity merging.
10. Preserve offline artwork during normal repair and cache-key migration. Explicit cache reset remains the separate destructive action.

## 3. Persistence and interface changes

Use the next schema version after the current schema 73, rebasing the migration number if concurrent work advances it.

Add or extend:

- **Scan observation:** supported/unsupported status, optional provider scan token, observed token, reconciled token, and pending reconciliation state.
- **Availability:** typed catalog availability on songs/albums/artists; migrate existing `serverDeletedAt` rows to confirmed-missing availability without losing their local-download semantics.
- **Recovery review:** profile, entity type/old ID, evidence generation, reason, candidate references, disposition, and timestamps. Retain original metadata rows while review/reference ownership requires them.
- **Typed aliases:** profile-scoped entity type, old/new IDs, match reason, and timestamp. Migrate existing song aliases and preserve the current song-resolution API as a compatibility adapter.
- **Identity metadata:** nullable stable album/artist identifiers where available.
- **Repair state:** session identity and typed outcome/reason; persist resumable work but keep session mobile consent in memory.
- **Artwork identity/revision:** shared across every artwork producer and consumer.
- **Diagnostics:** backward-compatible additions to the existing authenticated control plane; review/mutation controls remain clone-only for automated certification.

Implement all services through Riverpod DI. Extend the production interfaces, adapters, fakes, migration tests, and generated source together. Do not change standard Subsonic wire behavior or introduce a required Navidrome-specific API.

## 4. Validation and acceptance criteria

### Automated regression matrix

| Scenario | Required result |
|---|---|
| Same ID, changed metadata | Liked, album detail, queue, and now-playing metadata refresh. |
| Changed song ID, unique MBID | One replacement; likes/references retained. |
| Exact metadata fallback | Only unique compatible matches relink. |
| Duplicate MBID or release editions | No automatic merge, regardless of page order. |
| Conflicting MBIDs | No metadata-only automatic merge. |
| Album hydration replaces IDs | Old metadata survives until matching completes. |
| Concurrent like/unlike/rating | Latest local action survives promotion and server dispatch. |
| Repeated snapshots/restart | No duplicate aliases, likes, history, or recovery actions. |
| Missing favorite with no match | Persistent review item; no repeated broken playback/download attempts. |
| Missing favorite with local copy | Offline playback remains available. |
| Filesystem and Android SAF downloads | Ownership survives remap and restart. |
| Failure during promotion | Transaction rolls back; files and active playback remain intact. |
| Server scanning or changing mid-collection | No destructive promotion of inconsistent evidence. |
| Unchanged artist cursor, older retagged album | Scan-aware snapshot refreshes its songs. |
| Unsupported scan-status endpoint | Existing compatibility workflow continues. |
| Mobile consent plus retry/reconnect | Grant survives within the session and reaches all repair phases. |
| App restart/cancel/sign-out | Grant is cleared; no unauthorized cellular continuation. |
| Lease contention/partial/confirmation | Correct waiting or action state, never generic failure. |
| Timeout, 429, 5xx, capped/repeated pages | Bounded retry, correct checkpoints, no false completion. |
| Changed/stable cover IDs and corrupt cache | Targeted refresh succeeds without global cache clearing. |
| Account change | No cross-profile aliases, review entries, or artwork collisions. |

Add a large fixture comparable to the observed 56,000-song library. Matching must use indexed candidate lookup rather than all-pairs comparisons; record request counts, memory, and promotion duration.

### Runtime certification

1. Run the repository bootstrap and regenerate required Freezed/JSON/Drift output.
2. Run focused API, DAO, migration, reconciliation, planner, controller, artwork, playback, download, and widget tests.
3. Use an isolated Linux profile and authenticated diagnostics API for the complete before/after migration.
4. During repair, navigate Liked/Albums/Settings, play an existing local source, interrupt collection, retry, and restart.
5. Verify committed data, aliases, pending server actions, review persistence, artwork, and download ownership after restart.
6. Capture and inspect app-owned screenshots of Liked, unavailable review, repair progress/failure/confirmation, and the NieR album pages.
7. Repeat on Android with Wi-Fi, mobile data, disconnect/reconnect, app restart, and a SAF download. An emulator with injected network policy supplements but does not replace actual cellular validation.
8. Compare live configured-route and direct-server requests using equivalent headers, parameters, and IDs. Correlate failures before assigning responsibility to Navis, Octo-Fiesta, the proxy, or Navidrome.
9. Validate recovered server stars against a disposable fixture account/library. Do not use production favorites as destructive test fixtures.
10. Run analysis and the required `./tool/check.sh`, then review the complete diff.

**Release acceptance:** deterministic cases pass; Linux runtime evidence is complete; Android results are explicitly recorded; no favorite, valid download, or active source is lost; no uncertain match is silently applied; ordinary repair remains usable and resumable.

## 5. Documentation, rollout, and remaining limits

- Update architecture for scan detection, availability, identity recovery, reference ownership, artwork identity, and repair behavior.
- Update development/CI documentation for the migration fixture and runtime certification.
- Update troubleshooting with separate explanations for server scan, Navis synchronization, Repair Library, unavailable review, and cache reset.
- Update both in-app changelog data and the release-notes generator.
- Record replacement of the blocking ordinary-repair behavior in the removal/deprecation history.
- Introduce the migration without requiring a cache reset. On upgrade, schedule one eligible recovery reconciliation and mark it complete only after successful promotion.
- Keep unresolved items and old committed data through failed/interrupted rollout. Do not erase user state to make migration appear successful.
- Server PID/configuration changes, production missing-file deletion, and library-manager changes are not part of this implementation. Document evidence-backed upstream findings separately.
- Previously erased metadata cannot be reconstructed reliably from nothing. Recover from surviving local rows, server metadata, aliases, or explicitly available backups; report unrecoverable history honestly.
- The implementing agent’s final handoff must distinguish verified root causes, preventive fixes, unresolved live symptoms, executed tests, and missing device evidence.

## Evidence addendum (2026-09-22)

Per-row test and runtime evidence is tracked in
[Fix_Stale_Cache_Execution_Plan.md](Fix_Stale_Cache_Execution_Plan.md).
Headline results: engine scan-guard suite covers failure-during-promotion,
mid-collection scan change, unsupported endpoints, admission coalescing, and
transaction rollback; two-sided complete-set uniqueness is enforced in
`SongIdentityReconciliationSession`; schema 80 promotes album/artist
MusicBrainz identifiers and `EntityIdentityReconciler` relinks albums and
artists inside promotion; `suspectedMissing` is wired with absence-aware bulk
selection; the Relink preview gates manual recovery; starred refresh is
partial-response-aware; artwork failures carry a typed taxonomy with
targeted eviction/coalesced refresh and revision plumbing; the post-upgrade
one-shot reconciliation rides the sync-model version bump; a scalable
promotion fixture measured 56k songs at ~2 s apply. Live-server
certification on Navidrome 0.64.0 promoted the 56k clone to the exact
server count (56,166 tracks, 4.8 s apply), kept all user state, passed the
NieR shared-title artwork retest, and survived cancel and lease-contention
drills. Remaining before moving this plan to `docs/completed-plans/`:
the recorded Android checklist (`docs/android-certification-checklist.md`)
and the fresh-profile initial-sync lease-race follow-up.
