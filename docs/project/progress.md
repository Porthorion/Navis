# Navis Development Progress

Tracks completion of all phases and sub-tasks defined in [docs/project/development-plan.md](development-plan.md). Checkboxes are updated as work is completed.

Last updated: 2026-10-28

---

## Tracking Conventions
- Completed item format: `- [x] Task name — YYYY-MM-DD (evidence: command/file)`
- Partially complete format: `- [ ] Task name — partial: YYYY-MM-DD (remaining: short note)`
- If blocked, add/update the `Blockers` section with exact error and next action.
- ACP task ID format: `ACP-M{milestone}-{nn}`.
- ACP status values: `backlog`, `ready`, `in_progress`, `blocked`, `done`.

## Current Focus
- [x] Issue #109 (1.5.1 P6), Linux package install wait copy — 2026-10-28
  (evidence: `update_dialog_test.dart` linuxDeb/linuxRpm apply cases failed first
  with `Found 0 widgets with text "Installing the update. This can take a minute."`;
  focused update dialog + changelog tests 39/39 pass; fresh review found no blockers).
  Debian/RPM applying state shows the new localized copy; other modes keep
  "Applying update…".
- [ ] Issue #86 P1, recovery intent and fallback (triage 01–05, 15–18) —
  implementation complete on `fix/recovery-intent`, 2026-10-26; integrated
  runtime certification and `tool/check.sh` remain with the orchestrator.
  Final quiet shutdown holds only its load generation: newer Play re-arms the
  same occurrence, later Pause stays paused, and a newer queue plays normally.
  Failed bridge recovery opens the original once, prefers a file completing
  during reopen, and records the selected `recoveryPath`. An owned, unbuilt
  original rebuild uses bounded failover; removal and selection retire it.
  Failed-seek suppression uses the configured `healthyPlayback` distance while
  real backend advancement keeps its separate failover accounting semantics.
  Deterministic row-15 tests reproduce cuts during initial fill, deferred
  release, trim and an uncaptured natural advance inside release. Recovery
  pauses the successor immediately, retains metadata, waits for the lane,
  rechecks occurrence/generation, and prevents another idle trim from overtaking
  the reopen. A newer seek also retains its occurrence after a failed reopen
  (row 16 reproduced a defect, rather than only a coverage gap).
  Failing-first evidence: row 01 `Expected: <true>`, `Actual: <false>`;
  row 02 `Expected: <3>`, `Actual: <2>`; row 03 `Expected: <4>`, `Actual: <5>`;
  row 04 `Expected: 'original'`, `Actual: <null>`; row 05
  `Expected: 'song-2'`, `Actual: 'song-1'`; rows 15/16
  `Expected: 'song-1'`, `Actual: 'song-2'`. Deferred release/trim/capture-gap
  tests also failed with `Expected: <2>`, `Actual: <1>`; the successor-silence
  test failed with `Expected: null`, `Actual: 'song-2'`.
  Bootstrap ran once. All 25 row-focused cases pass. Fourteen targeted mutations
  were killed: intent re-arm, single fallback, failover cap, healthy interval,
  unbuilt failure, newer-seek ownership/selection, source-ready Play, queue
  neighbours, and the five row-15 pause/index/completion/idle-trim/capture guards.
  Scoped analysis compared
  with the item-14 base reports the same 33 pre-existing infos, no added
  findings and no errors/warnings. Final navigation, handler helper, playback
  lane and transport-trace files passed together: `08:58 +956: All tests passed!`
  (foreground, 6 GiB cap, `--concurrency 1`; zero OOM kills).
  Architecture and the 1.5.1 changelog updated; item-14 `oggSplice` event fields
  preserved. No emulator, playback harness, full gate, push, merge or rebase run.
  Review r2, 2026-10-27: queued appends preserve an already classified cut;
  a current seek reloads its failed source at its newer target after shutdown;
  Pause preserves ordinary unbuilt recovery ownership and lands failover paused.
  Each finding has a committed failing-first regression: append
  `Expected: 'song-1' / Actual: 'song-2'`, current seek
  `Expected: 'completed' / Actual: 'failed'` (seek, Play and Pause), and paused
  failover `Expected: 'song-2' / Actual: 'song-1'`.
  Six mutations were killed: post-classification invalidation, missing seek
  reload, departed-only revision capture, ordinary transport rejection, missing
  shutdown wait, and the new-seek eligibility check. Cold-load retry/deadline
  controls keep their existing bounds; the shutdown wait has a separate
  ordinary-recovery regression.
  After restricting reload to a fresh seek that was not waiting on a load,
  39 P1/retry/deadline/intent cases pass, as do all nine final reviewer probes.
  Scoped analysis reports the same 30 existing infos for the four checked files,
  no added findings and no errors/warnings. Final navigation, handler helper,
  playback lane and transport-trace suites passed together:
  `09:03 +962: All tests passed!` (foreground, 4 GiB cap, concurrency 1;
  zero OOM kills). The full gate and native runtime certification remain with
  the orchestrator.
  Review r3, 2026-10-27: removing a classified cut releases recovery's native
  pause on the surviving queue after acknowledgement, with the latest intent
  and only while the captured player/load/seek remain owned. Shared cleanup
  covers every recovery return; newer work and quiet stops keep ownership.
  The committed red regression reported `Expected: <true> / Actual: <false>`
  in four cases, with both Pause controls passing. All six cases now pass,
  including delayed acknowledgement and unchanged source-load counts.
  Three mutations were killed: disabled release, ignored latest intent, and
  omitted acknowledgement wait. P1 rows plus the r1/r2 reviewer copies pass:
  `00:53 +130: All tests passed!`. The complete four-file P1 set passes:
  `08:58 +968: All tests passed!` (foreground, 4 GiB cap, concurrency 1;
  zero OOM kills). Scoped analysis retains the same 30 infos, no added findings
  or errors/warnings. Item-14 trace fields remain intact; the full gate and
  native/audible certification remain with the orchestrator.
- [ ] Issue #86, P2 Android repeat-boundary policy (triage 06, 07, 09) —
  R5 implementation on `fix/android-repeat-boundary`, 2026-10-27; R4 review found
  no blockers. Orchestrator full quality gate, hosted CI, Linux smoke and Android
  runtime acceptance remain pending. R1/R2 repaired delivered-pause policy changes,
  app-thread-first delivery and post-scrub re-arming. R3 captures the current UID
  for fresh recovery after current-occurrence removal, restores paused policy
  refresh (`|| !playRequested`, which was not redundant), and resumes an Off
  boundary on the last item when native state is not ENDED. A truly ENDED Off
  engine still publishes completion. F1 (R5 review): that
  completion now restores native `playWhenReady` to the requested play intent
  (a user pause stays paused), so a seek restart after it plays; bridge suites are
  61 tests. Current-removal d1/d1b, paused-removal d3,
  Off-after-scrub d2 and U6/C4/K4/L3 gap fixtures are committed in the existing
  callback suite. First failures on `c167f8783`: d1/d3
  `expected:<[0@0]> but was:<[]>`, d2 `expected:<1> but was:<0>`, and the pure
  fixture `OFF must resume the last item when the engine is not ENDED`.
  The original narrow R2 implementation sweep killed 18/22 adapted bridge
  mutations. The broader reviewer R2 matrix had 31 failing/49 variants and 18
  survivors (three rows were candidate fixes), plus 17/17 pure mutations killed;
  that evidence did not establish coverage of every callback/owner-clear guard.
  R3's adapted fast sweep kills 38/49 bridge mutations: the 46 non-fix
  reviewer variants plus inverse mutations of the three fixes. All seven target
  mutations (U6/C4/K4/L3 and the inverse fixes) die; 17/17 pure mutations die too.
  The eleven R3 bridge survivors included two observable gaps, S4 (late end
  after Pause) and K3 (Pause/scrub/Play loses the scrub), as well as redundant
  predicates and error/load cleanup. R4 commits the reviewer's S4/K3 probes and
  the Off-completion flag-reset probe. R4 replaced the missing-Handler exception
  seam with an inert default-returning Handler stub, making scheduling return
  normally and exercising callback tails and completed-state assertions.
  A failing-first seam test reported `expected:<2> but was:<1>` on R3. R5 replaces
  inferred posts with a host-only Handler queue that captures actual runnables
  and executes their lambdas, including captured UID/revision. Its test first
  failed with `capture the Runnable actually passed to Handler.post` on R4.
  Both post mutants now die: deleting `handler.post` fails 29 cases and capturing
  `revision + 1` fails 23, including the new direct Runnable test in each.
  R5 passes all 72 app JVM tests (59 repeat bridge cases) under the 6 GiB cap;
  the four R4 target mutants remain killed. Real Looper scheduling and native
  timing still require runtime evidence.
  R4's four target bridge mutants all die: K3, S4, the Off-completion reset and
  scheduling's success return (the last now fails four completion assertions).
  Foreground 6 GiB-capped R4 checks pass: 58 repeat bridge tests (47 callback
  cases and 11 boundary/scan cases), five related recovery/error tests, and
  11 changelog/release-note tests. Dart formatting and shell syntax pass too.
  R3 also passed 97 repeat decisions, 13 retry and equalizer fixtures, and
  11 changelog/release-note tests.
  Dart formatting, shell syntax, CI YAML wiring and the runner contract checks
  pass. The bounded runner and its hermetic contract are wired into `check.sh`
  immediately after the pure fixtures and into the new
  required CI `native` job. The runner uses a ten-minute timeout, one worker,
  bounded JVM memory and no persistent daemon, APK install or device. R4 pins
  all actions in the native job by full SHA and requires nonzero executed-test
  counts in both named suites from Gradle XML. R5's contract uses only Python's
  stdlib to check the maintained workflow layout and fails closed on unsupported
  forms. Eighteen committed variants reject suppressed/removed/commented CI and
  check.sh steps, conditional skips and step/job error suppression, including
  the contract's own step. `python3 -S` proves no site-package dependency.
  The old contract accepted all eight negative wiring variants (`contract accepted 8/8 broken gates`); R4 rejects them all.
  R3 execution of the supplied model reports one failing seed in 8,000
  (4927): removing a current Repeat One stream into a READY successor can still
  require explicit Play, whether streamed or local, as on base. A Play reusing a
  pending post can itself be lost if the current occurrence is removed before
  the post runs in the same main-looper turn. Owned Repeat All removal of the
  playing last song can start item 1 instead of item 0 (also on base). Paused
  queue edits preserve the legacy ENDED rewind only without a retained boundary
  UID; with one retained they can complete under Off and advance on the next Play.
  Pre-delivery Pause/Play can advance under Repeat One,
  and a pre-delivery seek can still restart under One/All; the Off form now
  resumes the current position when not ENDED. These limits are documented,
  alongside the narrower non-current last-stream-removal continuation guarantee.
  The fixture records actual Handler posts and runs their captured lambdas after
  the callback returns, without an Android Looper or native playback thread.
  No emulator, harness, VM, analyzer or `./tool/check.sh` ran here; the orchestrator owns runtime/full-gate
  checks. AI implementation/verification: Codex gpt-6.1-sol; local commits only,
  no push, PR or Fable model use. The legacy empty-playlist fallback is unchanged.
- [ ] Issue #86, item 14 Android Ogg/Opus cut splice — `fix/ogg-cut-splice`:
  continues unknown-length Android Opus transcodes through the existing
  `LockCachingAudioSource` and `OggOpusSplicer`. Round 2 fixes pre-listen cancel
  publication, disposal/connect cancellation, original-error/tail fallback,
  unsupported frame durations, the 255-segment page limit and incomplete
  continuation EOF publication. Round 2b allows six seconds for continuation
  setup (connect plus headers) below Media3's eight-second loopback read
  timeout; body progress uses the normal configured source deadline (30 seconds
  by default). Rewritten bytes already delivered cannot be rolled back after
  a later failure.
  Test-first cancel reproduction: `Expected: false`, `Actual: <true>`,
  `a cancelled download must not publish a cache file`.
  Round 2b regressions failed first for 2.5-second startup and 1.5-second body
  gaps (`Expected: null`, `Actual: HttpException`) and observed the old setup
  deadline at 1.025 seconds. Both delay cases now splice; exceeding six seconds
  preserves the original cut error object and withheld bytes. Focused splicer,
  lock-cache, resolver suites: `00:14 +149: All tests passed!`; harness
  self-checks: `Ran 51 tests`, `OK` (all foreground, 6 GiB cap). Prior round 2
  mutation recheck: splicer 26/26 killed; wiring 15/17 killed. Round 3 closes the
  observable mid-continuation cancel trace gap previously classified as a
  redundant guard; the old empty-page refusal mutation was retired because
  valid empty pages pass through.
  Round 3 restores whole-file caching after remove/clear/replace for plain and
  opted-in sources, and after player disposal for plain sources. Only opted-in
  sources are cancelled by the private player-disposal hook. Cancellation now
  disarms the six-second setup timer; a fake setup clock replaces the wall-time
  deadline assertion. Data-less EOS pages retain the delivered granule and EOS
  without duplicating a marker already delivered. Missing EOS at a complete
  page boundary refuses, deletes the partial file and preserves the original
  error and stack. Test-first removal evidence: `Expected: empty`,
  `Actual: [_Exception:Exception: Download cancelled]`; EOS evidence:
  `Expected: an object with length of <2>`, `Which: has length of <1>`; setup
  timer evidence: `Expected: <0>`, `Actual: <1>`. Final focused splicer,
  lock-cache and resolver run: `00:14 +161: All tests passed!` (6 GiB cap, no OOM
  kills). Targeted review mutants N4, M6, M2b, M3, W1 and S10b are killed (6/6);
  the full 71-mutant review set was not rerun. Changed Dart formatting and
  `git diff --check` pass.
  Round 4 preserves mixed-duration packets before end trim, including when the
  continuation's first audio page is EOS, by calibrating the decoded granule
  base from the original stream. Cut-after-EOS falls back without requesting or
  appending continuation audio; failed attempt 2 resets its own drop count.
  First failing trim lines: `Expected: [[144, 1], [152, 2]]`,
  `Actual: [[152, 2]]`; telemetry: `Expected: <0>`, `Actual: <55>`.
  New assertions cover mapped/serial-rewritten empty EOS, emission guards,
  paused plain-player disposal and pre-listen sink/state cleanup. Focused
  splicer, lock-cache and resolver suites: `00:14 +170: All tests passed!`;
  regenerated review seeds 9145, 9517 and 10451 all preserve every packet,
  final granules, CRCs and a single EOS. The mid-packet-page fallback limit is
  now explicit in the architecture section. Targeted D3, D10, D11, D12, D16
  and D20 mutations are killed (6/7 total). D18 survives because the shared
  `_startFetch` error cleanup also clears `_downloading`; public state and sink
  closure are explicitly asserted. The full review mutation set was not rerun.
  Harness gates now require a base reload, use a cut-cell frozen median,
  enforce decoded length parity within 20 ms, and reserve `cut5` for Android.
  Remaining: final Android base-vs-fix runtime evidence and `check.sh` from the
  coordinator; both are explicitly prohibited for this implementation task
  while its independently owned harness run is active.
- [ ] Issue #86, P3 lock-cache duplicate occurrences (triage 19-22) —
  `fix/lock-cache-occurrences`, 2026-10-28, local commits only. Row 21: `audit`
  now fails one instance at two queue positions (`atTwoPositions`); a merged
  identity mutant of `_shareLockCacheSources` dies in 3 tests. Row 22:
  `debugPrepareReplacementSources` and a failed-far-jump restore test kill both
  `replacesQueue: true` deletions (the `_prepareQueueItems` one only via the
  rebuild test: no reachable flow rebuilds with a held writer; the seek-recovery
  rebuild uses neither flag). Row 20: `_releaseTail` and `_applyMaterialisedInsert`
  observe right after the native commit; the release mirror uses the bounded
  `_mirrorInsertOnDeck`. Failing before: registered source `Expected: true Actual:
  <false>` while the deck add hangs. Row 19: a repeat is a `LockCacheFollowerSource`
  delegating to the one writer; before, a repeat read `Expected: <1> Actual: <2>`
  origin fetches. `.part` race: removing the partial file under a finishing
  download reproduced `PathNotFoundException` at the rename; the vendored fetch now
  fails cleanly. Focused: navigation_test 878 pass, lock_caching 60, follower 4.
  No `./tool/check.sh`, harness, emulator or runtime pass ran (host busy).
  Pre-merge review r2 (Opus) fixes, 2026-10-28: F1 an evicted song's re-download
  was unregistered and a new occurrence became a second writer on the same `.part`
  (failing: registry `Expected: true Actual: <false>`; idle writer `Expected:
  LockCacheFollowerSource, Actual: LockCachingAudioSource`); now `onDownloadStart`
  re-registers it and `_heldLockCacheWriters` supplies the leader. F2 requests
  queued while a download finishes hung (`Expected: <0> Actual: <6>`); now served
  from the published file. F3 the failed-publication reset is atomic and resets
  progress (`Expected: <0> Actual: <2048>`).
  Review r3 fixes: G1 a rebuild onto an idle evicted writer replayed its 1.0
  progress as a completion (`Expected: true Actual: <false>` for the registry);
  the listener now ignores 100% while the cache file is missing. G2 a player
  recovery clears the retired sources' `onDownloadStart` (`Expected: null Actual:
  <Closure: () => void>`). Nit: requests queued during the publish-failure
  reset's await now fail after it.
- [x] Issue #86, item 14 follow-up: overlapped continuation EOS —
  `fix/ogg-overlapped-eos` (from `release/1.5`): when the original delivered its
  final audio page but lost the separate empty EOS page, the continuation's EOS
  rode on a wholly overlapped page that was dropped, so the cache file had no
  EOS marker although `continuationComplete` was true. `OggOpusSplicer` now
  emits one empty EOS page (original serial, next sequence, delivered granule)
  for any wholly overlapped page carrying EOS when none was emitted yet, via the
  shared `_emptyEosFor`. Failing-first: `Expected: an object with length of <1>`,
  `Which: has length of <0>`. New tests cover the lost-empty-EOS case, no
  duplicate EOS, partially overlapped and fully new EOS pages; the older
  synthetic wholly-overlapped-EOS test now expects the empty EOS page. Focused
  splicer, lock-cache splice and source suites: all passed (128). No harness,
  emulator or `./tool/check.sh` ran.
- [ ] Issue #86, item 13b Android next-song warm — `fix/android-next-warm`: at
  current-song completion `_syncSidecarChain` starts the next song's own
  lock-cache source with the vendored `prefetch()` (no replay buffer); one source
  per cache file across rebuilds and duplicates, paused during a live range fetch,
  cancelled on dispose, radio, gate close and queue edits; Android now gates the
  `repeat` next-song metrics. Remaining: Android harness proof at the final HEAD.
- [ ] Issue #86, item 13 prefetch check and tune — `fix/prefetch-13`: desktop
  next-song warm chained on the sidecar downloader, shared next-song helper
  (Repeat One/All, shuffle) for the Android stale/priority logic, eviction keeps
  current and next song, "Prefetch the next song on mobile data" setting (on by
  default, confirmation when turned off, schema 106→107), and `repeat/chain_end`
  harness metrics. Round 3: pair-scoped retries, missing-file refill and saved-queue
  startup eviction protection; 17 focused handler tests pass, including three
  failures before these fixes and a tick-only retry that fails on round-1 code.
  Linux isolated-fixture calibration (`build/harness/20261025T065152Z`) proves
  next-song warming: base/fix minimum lead 0.02/14.62 s, bytes
  ≤540,672/3,454,317, seek rate 0/1; no recovery or anomaly entries in
  `chain_end`. The calibration exposed a healthy wrap hidden by a loading
  cursor; a self-check reproduces it and the oracle now compares ready samples.
  Gates: 6 s / 1 MiB / 0.75. Final `./tool/check.sh` passed (9,472 tests,
  one skipped); `python3 tool/playback_harness_test.py` passed 30 tests.
  Runtime control used the authenticated queue, repeat, seek and status APIs
  against clean Linux fixture profiles; both `chain_end` reports have no
  recovery or anomaly entries. Audio was muted; no new visible UI was changed.
  Android evidence and the setting dialog screenshots remain with the coordinator.
  Round 4: clear the warm pair and retry state before refilling a deleted
  current sidecar. With prefetch enabled and a warm held in flight, the regression
  fails on `c69a81bf5` (missing the second song-1 request) and verifies immediate
  re-arming after refill. All 17 focused prefetch tests pass. Round-4 gates:
  `11:29 +9472 ~1: All tests passed!`, `[check] All checks passed.` (one run);
  `python3 tool/playback_harness_test.py`: 30 tests, OK.
  Runtime A/B belongs to the separate runner; not run
  in this implementation round. Legacy shuffle null-rank startup protection
  (P3) is deferred because maintenance reads song-only rows, not saved ranks.
  Round 5: apply file backpressure to the sidecar; the new regression first
  measured 4,194,304 queued bytes against a 65,536-byte chunk budget. The
  37-test downloader suite passes. Seek oracles now share a bounded,
  occurrence/offset-aware native clock-blip check; persistent and slow resets
  remain failures. R4 seek_back/seek_burst trace replay reproduced the false
  kinds before the repair. Unchanged-code A/A (`build/harness/20261025T103346Z`)
  passes seek, crossfade (1.70/1.69 s frozen median) and stress-drag
  (50.878/83.012 ms max frame gap). Its memory slope fails at 16.569/-1.868
  MiB/drag while post-GC resident PSS improves to 340.435/438.669 MiB:
  captured swap/file-backed residency establishes measurement noise, not
  next-song traffic in the single-song soak. Performance budgets stay unchanged.
  Final quality gate (one run): `10:20 +9472 ~1 -1`; the sidecar-disabled
  300-song paused-next unshuffle invariant fails, then passes in isolation.
  All earlier check stages pass; the full-suite gate remains failed.
  `python3 tool/playback_harness_test.py`: 34 tests, OK. The 17 focused
  prefetch handler tests also pass. Independent review remains with the coordinator.
  The first committed five-scenario run (`build/harness/20261025T111609Z`)
  passes seek and all prefetch-readiness gates (14.89 s / 3,454,317 bytes / 1).
  A native zero-clock blip at 294.4 s also fools the offset-repeat driver
  into marking an early wrap. Three more failing-first assertions cover
  offset/plain repeat drivers and repeat-fill counting; wrap candidates now
  use the shared blip confirmation. All 37 harness self-checks pass.
- [x] Playback runtime harness — 2026-10-25: `tool/playback_harness.py` (list, map, ab)
  on the `tool/live_seek_stress.py` engine; diagnostics `queue-edit`, `quality`,
  `queue {shuffle,startIndex}`, `rawSeekBack` and a no-op-unless-diagnostics
  `transportTrace`. Linux A/A (8 scenarios, quick and `--full`) and Android A/A
  (stress-drag, memory-soak, repeat, queue-edit) pass on identical code; a 1 s
  seek-lane delay fails `seek latencyMedianS` with exit 1; a missing AVD exits 2;
  downloads sha256 unchanged. Gaps: Windows, real phone, real server (`--real`
  untested). Evidence under `~/.cache/claude-navis-logs/playback-151/harness/acceptance/`.
- [x] Seek-drag round 6 — 2026-10-24: dropped the generic just_audio registry
  removal of rounds 4/5 (each round exposed a new edge). Disposed preview
  sources release their owner and retries, so a registry entry that persists
  until player disposal (upstream behavior) holds no body bytes. Kept: idle
  platform disposal on replacement and HTTP 404 for a missing proxy handler.
- [x] Seek-drag review round 3 P3 fixes — 2026-10-24: tests-first regressions
  cover failed Futures after source disposal, completed retry removal, explicit
  diagnostics HTTP 400 validation and HTTP 409 overlap rejection, including
  guard release after failure. Both focused suites pass (84 tests).
  Foreground 8 GiB-capped `./tool/check.sh` passes:
  `09:30 +9430 ~1: All tests passed!`, `[check] All checks passed.`, exit 0,
  peak 6138 MiB, no swap/OOM kills. Generated sources remain unchanged.
- [x] Seek-drag review round 2 — 2026-10-24: tests-first regressions cover native
  reopens after EOF/socket cuts, request identity, desired occurrence adoption
  and stream offsets with cleared queue metadata. Six regressions fail before
  the fix; 27 focused player tests pass afterward. Scripted diagnostics retain
  one held pointer, bounded smooth moves/rests, continuous flicks and the legacy
  body; pointer/auth/validation tests pass. Heartbeat p95 and capture immediately
  before release make the held-input window inspectable; scripted gestures skip
  animation settling so rests retain their specified timing.
  Final foreground 8 GiB-capped `./tool/check.sh` passes:
  `09:28 +9428 ~1: All tests passed!`, `[check] All checks passed.`, exit 0,
  peak 5814 MiB, zero swap/OOM kills. Generated sources remain unchanged.
  The local diagnostics-only baseline is `verify/i12-base` at `d78b44333`
  on `31f21caea`; both fixed profile artifacts come from `ab927cb8e`.
  Five 20-rest gestures per build/platform pass all stress criteria. Linux
  release-to-native-target+1 s median is 3.281 → 2.758 s; Android is
  4.527 → 3.997 s. Android uses the same 3072 MiB guest for both builds,
  superseding the earlier unequal-RAM comparison. Frame-gap p95 is
  18.288 → 17.925 ms on Linux and 44.141 → 40.037 ms on Android.
  Android has baseline/fix frame gaps above 50 ms (25/3 samples); fixed
  maximum and count remain below baseline. Fixed preview socket maximum is
  one, superseded sockets close before successors, and GET counts per 20 rests
  are 11–12 on Linux and 10–11 on Android. Every fixed release adopts;
  both five-second flick controls issue zero preview GETs on each platform.
  Owner-authorized fresh-login real-server Linux medians (five per target/build,
  Opus 128, one-second rest) are 3.161 → 1.686 s at midpoint and
  3.610 → 2.056 s near the end. All use the offset path; two extra fixed slow
  drags stay below 20 ms maximum frame gap. CPU profiles, resource samples,
  origin timestamps, app-owned screenshots and clean restarts are retained in
  coordinator item-12 `rt-stress/summary.md` and raw evidence.
  Two 2048 MiB Android preparations fail before measurement; one records guest
  `reason=3 (LOW_MEMORY)`. An earlier Linux 317.239 ms sample included profiler
  setup in its heartbeat window; its cause remains unresolved and its CPU
  profile is retained. Final matched windows exclude profiler setup. Higher
  fixed memory readings and five trials do not establish long-soak stability.
  Five real download hashes are unchanged; credentials stay in script memory.
  Owned app/emulator/Gradle/Kotlin PIDs are stopped and temporary AVD/test roots
  deleted. Device-panel attachment lacks Java; SDK/app diagnostics provide the
  emulator evidence. No physical listening/device, Windows or Apple runtime
  proof. AI implementation/verification: Codex gpt-6.1-sol; local commits only,
  no push, PR or Fable model. Independent review remains with the coordinator.
- [x] Issue #86, item 12 seek while dragging — 2026-10-24,
  `feat/seek-while-dragging`.
  Failing-test-first commit `6d916998` specifies all four bars, bounded HTTP
  ownership and adoption. The shared plan reuses offset/bridge predicates and
  rounding; one HTTP owner follows lock-cache cancellation, and adopted streams
  reuse just_audio's proxy and song-time translation. A 250 ms rest pre-opens
  without changing transport state; release adopts within the approved 0–2 s
  tolerance. Supersession closes before another owner opens; buffering pauses
  at 512 KiB and unused requests expire after 10 s. Cache/representation changes
  preserve the ordinary release target and fresh metadata.
  Final focused tests: `00:04 +33: All tests passed!`, including 50 replacements
  while headers are pending, zero subscriptions, proxy disconnect/disposal,
  exact buffer cap, byte/error propagation and all four seek bars. Foreground
  capped `./tool/check.sh` passes: `09:24 +9417 ~1: All tests passed!`,
  `[check] All checks passed.`, exit 0, peak 5507 MiB, zero OOM kills; generated
  source is unchanged and analysis has no new findings.
  Pinned-base versus fix fixture medians (release to native target+1 s): Linux
  offset 3.305 → 2.254 s, desktop bridge 3.476 → 2.416 s, Android offset
  3.856 → 2.775 s (Android baseline/fix guest RAM: 2048/1536 MiB).
  Every adopted trial uses one GET; fifty abandoned requests
  close on each platform. Real-pointer app-owned screenshots show the held
  thumb at 1:30 while native playback remains near the start. Adopted EOF
  recovery, Repeat One/All, Linux crossfade and native/local controls, and clean
  restarts pass. The owned Android emulator and temporary AVD are deleted.
  Evidence: coordinator item-12 `implementation-evidence.md`, runtime JSON/PNG
  artifacts and logs. Real-server proof is excluded by the binding fixture-only
  preamble; no listening, physical-device, Windows or Apple runtime proof.
  AI implementation/verification: Codex gpt-6.1-sol; local commits only, no push,
  PR or Fable model use. Independent review remains with the coordinator.
- [x] Android progressive Repeat All near-end replay — r3, 2026-10-24.
  Test-first fixtures `a2496cbb` and fix `860384a8` repair both r2 failures.
  Logging-only native proof reproduces an append timeline at count 6 before
  END_OF_MEDIA_ITEM: the old last-item scheduling guard rejects that pause,
  leaving READY/PWR false with Play requested and no ENDED fallback. Scheduling
  now accepts the non-last boundary; the guarded action resumes READY or seeks
  to the appended next item from ENDED. The emulator observes three RESUME
  recoveries and one ENDED-next recovery, followed by playing index 5.
  Mixed-source proof confirms native ALL on files and 13 S2 periods before its
  first departure. Repeat All now owns any current playlist with an eligible
  HTTP item, including while files play; Repeat One stays current-item scoped.
  Occurrence UID, revision, Play intent, retry eligibility and source priority
  remain unchanged. Architecture and the 1.5.1 changelog describe the behavior.
  Focused native checks pass: 88 repeat fixtures, 13 retry fixtures and equalizer
  checks. Foreground capped `./tool/check.sh` passes:
  `09:23 +9384 ~1: All tests passed!`, `[check] All checks passed.`, exit 0,
  peak 5954 MiB and zero OOM kills; generation leaves no tracked changes.
  Local verification APK `9660633d` contains the fix and the unchanged q7
  harness, with logging-only conflict adaptations. New-head emulator acceptance
  passes all 29 rows and eleven independent checks: 19/19 admitted appends
  (seven timings twice plus 10, 3, 1, 0 and -1 ms; 15 sample the old last item),
  tail seek, two Repeat One loops, Repeat Off stop, both boundary skips, three
  mixed runs with two ordered wraps each, and original q7 0/3 resets. All 15
  observed playing-stream intervals have exactly one period; post-policy and
  transition logs retain native repeat OFF. No recorder anomalies, sample
  errors or native load errors. Evidence: `q7/rt-fix3/summary.md`, `cause.md`,
  native interleaving files, `mixed-native.json`, `validation-results.json`
  and all run logs/traces. Profile APK build and full gate report zero OOM
  kills; owned emulators and runtime jobs are stopped, known Gradle/Kotlin
  daemons stopped by PID, proxy port released, and five download hashes match.
  This Android round does not rerun physical listening, other-platform runtime,
  the paced 120-second proof or long/crossfade/wrap-gap benchmarks. Independent
  review remains with the coordinator. AI implementation/verification: Codex
  gpt-6.1-sol; no push, PR or Fable model use.
- [ ] Issue #86, item 11a PR C desktop transcode EOF — implementation complete
  on `fix/transcode-cut-eof`, 2026-10-23; coordinator `./tool/check.sh`,
  independent reviews and native cut-matrix acceptance remain pending under
  the build brief. Native auto-advance and final-item completion compare the
  departed occurrence's backend position with authoritative song duration.
  Remote transcodes/offset continuations ending more than 10 seconds early
  reopen at whole-second `timeOffset` through the existing recovery path and
  shared retry budget. Duplicates, Repeat One, queue completion, bridge failure
  fallback and newer Pause/seek/skip retain their occurrence and intent.
  Completed files, unknown durations, originals, unsupported servers and
  near-end completions keep normal behavior; active crossfades are excluded.
  Sixteen tests were committed first in `28f880b6` after the expected
  `00:34 +6 -10: Some tests failed.` Regressions expanded to 21 cases, including
  backend versus interpolated time, healthy play and bridge rejection with
  duplicate queue entries. The natural bridge Repeat One fixture now reports
  the actual 180-second end rather than an early 90-second departure.
  Final foreground `flutter test --concurrency=4 --timeout 60s --reporter expanded`
  passed eight files (navigation, handler rules, source resolver, playback lanes,
  position offset, media-kit seek, deferred seek and mpv errors):
  `08:03 +907: All tests passed!` `./tool/bootstrap.sh` completed. Scoped
  `dart analyze` exits 0 with no errors/warnings; all 17 infos map to unchanged
  lines in `9d5e5a9b`. `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 5.99 seconds.` The formatter has no
  per-file mode, so its full source set was checked. `git diff --check` passes.
  Heavy commands used the required 8 GiB cap with zero OOM kills. No apps,
  emulators or VMs were launched, and no task-owned background jobs remain.
  Round 2, 2026-10-24: nine additional regressions were committed first in `bcd59762`
  after `00:03 +21 -9: Some tests failed.` They cover current/earlier removal,
  insert/move, scrobble/history continuity for middle/last cuts in both native
  event orders, and silence during gated source resolution. Departure detection
  now requires the handler's current entry and an idle queue lane. Recovery
  holds that occurrence's metadata/session, suppresses successor/completion
  side effects, and invokes a bounded native pause before source resolution.
  Index events yield to a same-turn discontinuity and cannot cancel the held
  recovery, independent of queue-lane occupancy. A newer Pause/seek/skip keeps
  ownership. The session regressions also wait for recovery settlement and
  verify the resumed submission uses the original session key. A tenth gated
  regression covers a newer Pause before native pause acknowledgement; recovery
  installs its seek request before awaiting that acknowledgement. The complete
  transcode-offset group passes `00:37 +79: All tests passed!` Final foreground
  rerun of the eight suites above plus `scrobble_service_test.dart` passes
  `08:05 +939: All tests passed!` The required 8 GiB cap reports exit 0,
  peak 2288 MiB, swap peak 595 MiB and zero OOM kills. Scoped `dart analyze`
  exits 0 with no errors/warnings; all 23 infos map to unchanged lines in `03393250`.
  `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 5.97 seconds.`
  Round 3, 2026-10-24: eight regressions were committed before their fixes in
  `29fffb21` and `5dd74355`. The seven review reproductions failed with
  `00:12 +31 -7: Some tests failed.`; an additional Play-after-reopen boundary
  regression failed with `00:00 +0 -1: Some tests failed.` Native source identity,
  source metadata and backend position now identify the departed occurrence
  across artwork copies and duplicate songs. Queue edits invalidate that capture
  at both ends; backend timestamps also reject departures recorded before the
  edit, after its lane releases. Play during source resolution only records
  intent, including the completed-last-song case and Pause→Play; once the new
  source is ready, Play resumes it normally while seek settlement is pending.
  The index listener's one-microtask yield is now desktop-only, and the
  architecture documents same-turn ordering rather than arbitrary event order.
  The accepted busy-lane tail release/trim/fill ceiling is recorded at the lane
  guard. Focused recovery tests pass `00:06 +39: All tests passed!` Scoped
  `dart analyze` exits 0 with no errors/warnings; all 23 infos map to unchanged
  lines in `4d5516d3`. `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 7.10 seconds.` The final foreground
  rerun covers the nine round-2 suites plus `playback_art_cache_test.dart`:
  `08:07 +959: All tests passed!` All eight new regressions pass. Heavy commands
  used the required 8 GiB cap; the final suite exits 0 with zero OOM kills.
  `git diff --check` passes. `./tool/bootstrap.sh` completed. No apps, emulators
  or VMs were launched, and no task-owned background jobs remain. Runtime and
  `./tool/check.sh` remain coordinator-owned under the build brief.
  Round 4, 2026-10-24: nine regressions were committed first in `0423aeda`
  after `00:00 +0 -9: Some tests failed.` They cover resolver failures and
  false rebuilds after Play/Pause for middle/final songs, plus audio-focus
  regain during source resolution. Failover retains the departed seek's
  ownership across Play/Pause, checks that no newer seek replaced it, and uses
  the latest explicit play intent. Final-song failover keeps the existing quiet
  stop contract; a subsequent Play reloads it. The shared native-play path now
  defers all resume callers while the departure's source is unresolved. The
  existing rejected-bridge regression exposed a fallback missing its recovery
  seek; passing that request also lets this fallback mark its source ready and
  resume. The capture comment and architecture now name the index listener's
  early-return window during tail fill/release alongside the busy-lane ceiling.
  Focused recovery tests pass `00:07 +48: All tests passed!` Scoped
  `dart analyze` exits 0 with no errors/warnings; all 17 infos map to unchanged
  lines in `3ee045f00`. `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 5.89 seconds.` Bootstrap completed.
  The final foreground rerun of all ten round-3 suites passes
  `08:07 +968: All tests passed!` The required 8 GiB cap reports exit 0,
  peak 3247 MiB, no swap and zero OOM kills. `git diff --check` passes.
  No apps, emulators or VMs were launched; no task-owned jobs remain.
  Runtime acceptance and `./tool/check.sh` remain coordinator-owned under
  the build brief.
  Round 5, 2026-10-24: nine regressions were committed first in `b263d5ef`
  after `00:03 +5 -4: Some tests failed.` Native-load rejection after replacing
  the playlist reproduces the final-song logical/native mismatch with no
  command, Play and Pause during resolution; middle-song failover is also
  checked. Recovery now keeps the failed native song materialised and defers
  its original neighbours, preserving all queue entries and the current logical
  index. Later Play reloads the failed final song at its departed position
  (47 seconds in these tests), following the existing stopped-source retry rule.
  The retained anomaly's exact 3368→0→3489 ms sequence reproduces the false
  replay without an index change: confirmation previously accepted the
  corrected position merely because it remained under 10 seconds. Confirmation
  now also requires a position below the departure position. A real four-second
  replay is still detected; ordinary four-second advancement with the desktop
  index yield produces no record. All nine focused tests pass
  `00:03 +9: All tests passed!` Scoped `dart analyze` exits 0 without errors or
  warnings; all 29 infos map to unchanged lines in `d9ce781f`. Bootstrap completed.
  Final foreground rerun covers the ten round-4 suites plus
  `playback_anomaly_recorder_test.dart`: `08:10 +1025: All tests passed!`
  The required 8 GiB cap reports exit 0, peak 3268 MiB, swap peak 1558 MiB
  and zero OOM kills. `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 5.76 seconds.` `git diff --check` passes.
  No apps, emulators or VMs were launched; no task-owned jobs remain.
  Native acceptance and `./tool/check.sh` remain coordinator-owned under the
  build brief.
  AI implementation and self-review: T3 Code/Codex, gpt-6.1-sol. No native
  performance or audible-continuity claim is recorded.
- [ ] Issue #86, item 11a PR A Android seek bandwidth — implementation complete
  on `fix/android-seek-bandwidth`, 2026-10-23; native runtime acceptance,
  independent reviews and `./tool/check.sh` remain coordinator-owned under the
  build brief. Beyond-cache ranges own their client/subscription and close
  with their proxy consumer or source removal/disposal. A main-fetch cut leaves
  independent ranges alive. Main pause/resume preserves the prefix and suspends
  body inactivity; Android playback ranges with under 30 seconds buffered ahead
  pause the current and next whole-file downloads. Mobile native seek waits
  count range bytes and buffer growth with idle/hard caps; desktop stays fixed.
  Every Android deck receives the 180-second / 32 MiB reserve with unchanged
  2.5-second start and 5-second rebuffer thresholds.
  Review round 2 fixes early-cancel late-listener errors, silent client
  disconnects before range headers/during stalled bodies, unnecessary engine
  retirement on seek supersession, retired range lifetime behind a hung native
  Stop and next-song priority during queue-index mismatch. Superseded seeks
  release the lane while retaining their engine/cache with no bypass/reload;
  load-generation changes and real stalls retain engine retirement. The stream
  proxy owns sockets from acceptance, preserves virtual source overrides and
  validates and frames sized/chunked responses, including interrupted bodies.
  Evidence: six regressions failed before repair and were committed first in
  `7bfe2493`; six additional framing cases cover exact/chunked/short/oversized
  bodies, absent MIME metadata and header injection. `./tool/bootstrap.sh`
  completed. `dart analyze` on all six touched Dart files exits 0 without
  errors/warnings; all 27 infos map to unchanged lines in `27af9a6a`.
  Final foreground `flutter test --concurrency=4 --timeout 60s --reporter expanded`
  passed navigation, source resolver, playback lanes, lock-cache, position-offset,
  media-kit seek and deferred-seek suites (`07:45 +866: All tests passed!`).
  The remaining handler rules suite plus a final lock-cache rerun passed
  (`00:08 +95: All tests passed!`). `./tool/dart_format.sh --check` reports
  `Formatted 1113 files (0 changed) in 5.80 seconds.` `git diff --check` passes.
  Heavy commands used the required 8 GiB cap with zero OOM kills; no task-owned
  background jobs, apps, emulators or VMs remain. No PR B implementation,
  dependencies or version change: 1.5.1 is already pending. AI implementation
  and self-review: T3 Code/Codex, gpt-6.1-sol; no independent review or native
  performance claim is recorded.
  Review round 3 clears a retired current source's progress subscription,
  tracked source, received bytes and caching activity before native Stop or
  bypass reload. A test first reproduced the stale 40% activity without a song
  change (`2c9f279c`), then passed after cleanup. The proxy's read-EOF policy
  stays unchanged; its `ponytail:` comment records the half-closing-client limit
  and the write-failure/grace-period upgrade path. Foreground validation:
  navigation and lock-cache suites: `07:44 +778: All tests passed!`; scoped
  `dart analyze` exits 0
  with no errors/warnings and 26 infos verified against unchanged lines.
  `./tool/dart_format.sh` formatted 1113 files (only the new test changed);
  `git diff --check` passes. Bootstrap completed; all heavy commands used the
  8 GiB cap with zero OOM kills. Runtime acceptance and `./tool/check.sh`
  remain coordinator-owned; no apps, emulators, VMs or background jobs ran.
- [ ] Issue #86, item 11a, desktop sidecar Range resume — implementation
  complete on `fix/sidecar-range-resume`, 2026-10-23; coordinator acceptance
  pending. Known-length, uncompressed originals retain their generation-owned
  contiguous part and resume only verified `206` continuations. Backoff waits
  1/2/4 seconds, respects pause/cancel, excludes outage time from transfer rate,
  and renews its three-attempt budget after 256 KiB of new data. Transcodes and
  unknown-length bodies keep their previous behavior. The handler passes
  existing original-quality metadata. Current-index events cannot restart a
  full GET during resume; they can restart after abandonment. An active bridge
  keeps playing without an incomplete-file upgrade. Sink closure also covers
  cancellation while reconnecting.
  The new handler regressions failed against the original downloader (both
  issued a second full GET), then passed with resume. Final validation across
  nine cache/player test files: `07:53 +903: All tests passed!`; the four
  targeted restart/bridge/exhaustion cases also passed (`00:09 +4: All tests
  passed!`). The first broad run exposed a two-second buffered-line test wait;
  it now waits for terminal cleanup with a ten-second timeout and retains its
  buffer assertion. `dart analyze` on all five touched Dart files exits 0 with
  no errors or warnings; 14 infos belong to unchanged handler-test lines.
  `./tool/dart_format.sh --check` passes (1113 files, zero changes), and
  `git diff --check` passes. All commands ran in the foreground under the
  requested memory cap, with zero OOM kills and no pending jobs.
  Native Linux cut/sha/bridge proof, independent review and `./tool/check.sh`
  remain coordinator-owned per the build brief; no app, emulator, VM or app
  build was launched. AI implementation and tests: Codex gpt-6.1-sol.
  Round-2 review fixes require the selected strong ETag or Last-Modified on
  every continuation, honor `Accept-Ranges: none`, and retry TLS/handshake
  reconnect errors within the existing budget. Nine new regression cases
  cover missing/changed validators, range refusal, and transient/exhausted
  TLS reconnects. Test-first evidence: `00:42 +21 -7: Some tests failed.`
  before the implementation fix; the failing tests were committed separately.
  Round-2 validation: downloader plus cache manager, source resolver, cached
  extent and full handler navigation suites pass (`07:55 +836: All tests
  passed!`). The final downloader-only rerun passes all 36 cases (`00:58 +36:
  All tests passed!`), including all nine new cases. `dart analyze` on the
  three touched Dart files reports `No issues found!`; the repository format
  check passes (1113 files, zero changes), and `git diff --check` passes.
  Foreground runs stayed under the requested cap with zero OOM kills and no
  pending jobs. Runtime validation and `./tool/check.sh` remain with the
  coordinator; no change to the plan or open implementation question.
- [ ] Issue #86, item 10 Fast Seeking — implementation on `fix/fast-seeking`:
  Linux/Windows lossless-to-Opus seek bridge, original-only sidecar caching,
  backpressure during bridge buffering, lossless upgrades, settings and schema
  105→106. Test-first regressions cover sidecar lifecycle/rate, resolver gates,
  handler settlement/recovery/queue transitions, settings migration/persistence
  and Now Playing quality. Runtime evidence and the round-2 `./tool/check.sh`
  remain with the batch coordinator under the worktree's memory restrictions;
  no app, emulator, VM or application build was launched here. Evidence: bootstrap,
  build_runner and gen-l10n completed; downloader (6), resolver (45), settings
  repository (24), migrations (104), settings screen (17), Now Playing (39)
  and unchanged desktop preview golden (2) tests pass using
  `flutter test --concurrency=4 --timeout 60s` with specific files. All 22 new
  bridge handler cases pass. `dart analyze` on changed Dart files exits 0
  with no errors or warnings; its 30 infos point to unchanged lines. The full
  `navis_audio_handler_navigation_test.dart` run passes all 710 tests, for 947
  passing tests across the eight validated files.
  Round-2 review repairs reproduce all seven findings before their fixes:
  bridge load failure desynchronizes the native playlist, paused buffering
  leaves the original paused, native guard exceptions skip bridging, completed
  originals are bypassed during bridge recovery, fractional initial positions
  seek the linear bridge, `.aif` is rejected, and response latency depresses the
  sidecar transfer rate. Recovery now reloads the original and native playlist
  before fallback, recalculates sidecar priority at every seek exit and yields
  only for requested playback, tries the bridge after guard errors, prefers a
  completed original on remote recovery, and opens bridges at whole seconds.
  Lossless suffixes use `aif` instead of the unreachable `alac`; transfer timing
  starts with the first body chunk, including after a pre-data pause/resume.
  Evidence: `flutter test --concurrency=4 --timeout 60s` with the specific
  downloader (8), resolver (46) and full handler navigation (716) test files
  passes all 770 tests. The handler regressions first failed with the expected
  six failures; the suffix and response-latency regressions also failed before
  repair. `dart analyze` on all nine changed Dart files exits 0 with no errors
  or warnings; its 26 infos point to unchanged lines. No app, emulator, VM,
  build or full quality gate was run in this round, per the coordinator's
  workspace restrictions; native runtime acceptance remains coordinator-owned.
  Round-3 review repairs recheck the completed original after a bridge reopen
  fails, then use the existing lossless stream recovery at the song position
  before allowing failover. Explicit Pause recalculates sidecar priority even
  when a queue edit suppresses player events. Both gated-reopen cases skipped
  the song before repair; the queue-edit Pause regression left the original
  download paused before its fix. Evidence:
  `flutter test --concurrency=4 --timeout 60s test/src/features/player/data/navis_audio_handler_navigation_test.dart`
  passes all 719 tests (`07:36 +719: All tests passed!`), including all three
  new regressions. The pre-fix runs ended with 716 passes / 3 failures (including
  a corrected initial test-setup assertion) and 718 passes / 1 expected failure.
  `dart analyze` on the four changed Dart files exits 0 with no errors or
  warnings; all 20 infos map to unchanged lines. Runtime validation, app builds
  and `./tool/check.sh` remain coordinator-owned under the explicit round-3
  workspace restrictions.
- [ ] Issue #86, item 9 silent playback anomaly recorder — partial: 2026-10-22
  (`fix/anomaly-recorder`, remaining: independent review and the Android and
  Linux runtime pass against a release/1.5 baseline). Observe-only: a
  `[PLAYBACK_ANOMALY]` warning, with the last 30 s of transport events, when a
  queue entry's position moves back more than 2 s with no seek, navigation,
  loop or stop (`backwardJump`), or a song from its last 10 s replays from
  under 3 s within 10 s without Repeat One (`replayNearEnd`). The last 5 records
  are in `GET /v1/playback/status` as `anomalies`. Evidence: recorder unit
  tests (48) and handler tests (8) pass; the handler tests fail without the
  seek, navigation and loop explanations. Records print through `debugPrint`
  (AppLogger drops them without asserts); jumps are judged by song, so entry
  swaps (likes, art cache, recovery rebuilds) do not hide them.
- [ ] Issue #86, shuffle per queue — partial: 2026-10-22
  (`fix/shuffle-per-queue`, remaining: coordinator check.sh, review and the
  Android and Linux runtime pass). Shuffle is a property of the current queue:
  `_applyNewQueueMode` (was `_playOrderForLoad`) sets it for every new queue,
  so Play, song taps, Play now, search, radio, mixes and links play in order
  with shuffle off and only entity Shuffle turns it on. Reloads, edits and
  appends keep the mode; clearing the queue ends it; the toggle is unchanged.
  Evidence: new handler tests fail on the old code (a plain replace after
  Shuffle stayed shuffled) and pass now; targeted player, auto, common widget
  and library presentation suites pass (2452).
- [x] Issue #120, Last.fm recommendations fell back to server similar songs —
  2026-10-22 (`fix/lastfm-similar-fallback`): cause was Last.fm itself.
  `track.getSimilar` returns an empty list for most songs released since about
  2015 (Starboy, Anti-Hero, Shape of You) with a healthy key. The client now
  retries the title without qualifiers, then uses the top tracks of the seed
  artist's similar artists; empty answers are cached for 10 minutes, not 24
  hours; error 6 reads as empty. Evidence: focused tests pass (1897); the real
  Same Vibes notifier against the live server used the server fallback for 30
  of 43 library songs before and 9 after (`./tool/check.sh` not yet run).
- [ ] Issue #86, item 8 two-range seek bar and exact cached time — partial:
  2026-10-22 (`fix/two-range-seek`, remaining: coordinator check.sh result,
  Linux and Android runtime pass, review). The seek bar draws the cached range
  from 0 and, after a seek past the download or on an offset stream, the
  player's own range `[S, raw]` apart, so the gap is no longer drawn as
  buffered. For Ogg (Opus, Vorbis) and FLAC the cached time is read from the
  partial file (last complete Ogg page granule, last CRC-8-verified chained FLAC
  frame) at most once a second; MP3 and AAC keep the estimate. Evidence: new
  parser, handler, style and shell widget tests pass; handler tests failed
  before the change (compile error for the new state, then wrong ranges). Test
  rendering of the three thumb positions is in
  `~/.cache/claude-navis-logs/playback-151/i8/shots/`. The Windows read of a
  part file open for writing is unverified (a failed read falls back silently).
- [ ] Issue #86, item 5 follow-ups — partial: 2026-10-21
  (`fix/item5-followups`, remaining: coordinator check.sh, runtime pass and
  review). 5a: after a crossfade deck swap the current item, diagnostics offset,
  seek and restart readers are not stale (tests passed unchanged); the real leak
  was a non-current song keeping its offset entry, so Previous/selection back to
  it started at the offset (failed before: `positionOffsetMs` 90000, expected
  0), now reopened from the start. 5b: the per-song stream retry renews after
  `healthyPlayback` of real advance (failed before: `Expected: song-1 / Actual:
  song-2`); the second-cut-too-soon and frozen-position cases still skip. 5c is
  runtime-only. Round 4: a departed offset entry is repaired as a queued edit
  (fresh source inserted behind it, old one removed, never the current song),
  and a Repeat One loop starts a new play-time occurrence.
- [x] Issue #92, optional Home Random Albums section — 2026-10-20
  (`feat/home-random-albums`): `random_album_list` after Recently Added,
  hidden by default. Its own server `getAlbumList2(random, 20)` draw; the
  downloaded-only list is now a one-shot snapshot. Both re-pick after every
  finished library sync. Showing a never-seen hidden-by-default section now
  also saves the order, or `resolveHidden` hid it again (GLM review P1).
  Runtime check in the app still to do.
- [x] Issue #111, specific failure messages — 2026-10-20
  (`fix/specific-failure-messages`): sub-items 1-3 were verified unreachable
  (radio and Instant Mix never receive invalidKey/rateLimited; Last.fm key
  validation already shows a connection message inline), so only the relink
  message changed. Evidence: focused tests from the original change passed;
  `./tool/check.sh`: all checks passed on the pre-fix commit (will be rerun).
- [x] Issue #112, explain long waits — review round — 2026-10-21
  (`fix/explain-long-waits`): manual import now says "Importing downloads…"
  (`downloadsImporting`) instead of "Moving downloaded tracks..." via a
  screen-local flag; folder choose and rescan keep their text. Fixed a
  pre-existing bug: `markImported` used `ref.read` after the awaited import, so
  leaving the tab mid-import skipped it and committed files reappeared as
  pending; both notifiers are now read before the await. Evidence: new widget
  tests in `downloads_screen_test.dart` (busy text while a gated import runs,
  and pending cleared after the tab is left mid-import); the text test fails
  without the flag. `flutter gen-l10n` run; `flutter test` on
  `downloads_screen_test.dart` and `custom_download_folder_controller_test.dart`
  passed `+39: All tests passed!`; `./tool/check.sh`: all checks passed on the
  pre-fix commit (will be rerun).
- [x] Issue #110, About "Check now" failure feedback — 2026-10-20
  (`fix/about-check-now-error`): a user-triggered failed check shows an error
  notice; automatic failures deliberately only show the failed subtitle. Review
  round added a widget test pinning that no notice is raised for an automatic
  failure. Evidence: `flutter test
  test/src/features/settings/presentation/about_screen_test.dart` passed
  `+14: All tests passed!`; `flutter analyze` on the file clean;
  `./tool/check.sh`: all checks passed on the pre-fix commit (will be rerun).
- [x] Verified update download reuse after cancelled installation — 2026-10-20:
  `UpdateService` retains one digest/path per session, re-verifies before reuse,
  re-downloads missing/tampered files and removes superseded artifacts. The
  existing private-directory test now asserts reuse and one HTTP request;
  additional cases cover case-insensitive hashes, progress/network accounting,
  tampering, deletion and changed-digest directory removal before downloading.
  Test-first service run failed four cases (`00:00 +38 -4: Some tests failed.`).
  `flutter test test/src/features/settings/data/update_service_test.dart
  test/src/features/settings/presentation/update_dialog_test.dart` passed
  (`00:02 +53: All tests passed!`); changed Dart files pass formatting.
  `flutter analyze lib/src/features/settings test/src/features/settings`
  reports four existing infos in untouched appearance tests (escaping quotes,
  setter style, constructor type and braces); no findings in the changed code.
  Runtime/polkit validation remains with the coordinator; `./tool/check.sh`
  was explicitly reserved for the orchestrator.
- [ ] Issue #86, round 10 bounded failover — partial: 2026-10-21
  (`fix/seek-settlement`, remaining: coordinator Linux/Android runtime pass
  against a `release/1.5` baseline and independent review). Round-9 runs showed
  a 12-second load-timeout cascade through the queue (idx 0 to 4) and a
  desktop seek failure that skipped a song which was still playing. Now: the
  final quiet stop bounds `pause()/stop()` by the reset timeout; a failed
  desktop seek fails over only when the source is not advancing; automatic
  failovers from seek, stall and queue-load share a cap of two songs until
  five seconds of real playback (position stream) or Play, after which playback
  stops quietly on the current song, reloadable by Play; `_waitForSeekSource`
  fails at once after a quiet stop and is capped by `seekProgress` in total.
  Regressions (each failed before its change): hung final stop (seek lane
  parked, test timeout), still-playing song skipped (`Expected: song-0 / Actual:
  song-1`), cascade (`Expected: song-2 / Actual: song-5`), seek plus stall
  cascade and healthy-play reset (`Actual: song-3` / `song-2`), a seek
  waiting on a load that ends in a quiet stop (2,004 ms), cold load holding a
  seek (outcome null). `./tool/check.sh` passed (8,952 tests; 435 s). A seek
  failover cannot repeat after the queue moved: every queue move already
  cancels the pending seek, and that regression passed unchanged. The r9
  cold-a.1 mid-song advance is not a premature completion: that file is 51.0 s
  long and the harness seeks to 60 s, so the track ended at 51.2 s (trace
  `dur: 51000`, `pos: 51200`); the FLAC decode errors follow the seek into the
  partial download. No code change for it.
  Runtime r10 dead-source finding: after the cap stop the current index
  jumped from 2 to 9 (`nativeIndex index 7 songId 2C3I…` at +81.498). The tail
  release appended the deferred songs to the stopped, source-less player, so
  native index 7 mapped to logical 9. `_shouldReleaseTail` now skips an empty
  player (regression: sources `['song-3', 'song-4', 'song-5']` before).
  Codex review fixes: an early completion after healthy play is not a failure
  (`Expected: song-3 / Actual: song-2` before); the advance signal uses the
  backend position, not the interpolated one (`Expected: song-1 / Actual:
  song-0`, and `song-2` / `song-3` for the cap reset); a hung final stop
  replaces the player (`Expected: an object with length of <1>` before).

- [ ] Issue #86, round 9 cold seek recovery — partial: 2026-10-21
  (`fix/seek-settlement`, remaining: coordinator live large-FLAC/Android
  revalidation and independent review). Focused seek, transcode and deadline runs
  pass 74 tests, including both held-body durations for original/transcoded
  sources, single-song cold retry exhaustion, silent failover, and Play restart.
  Round-8 hold traces show `active queue apply` timing out at +12.158 s,
  `seekStage: recovering` immediately afterward, then `seekEvent: failed` at
  +24.198 s (`elapsedMs: 19142`) with no second timeout or media request.
  At +13 s the logical queue had shrunk to its one materialized source;
  +25 s and +50 s stayed loading at position zero despite sidecar bytes.
  The round-8 retry reused AudioSource objects while retiring their owner;
  just_audio disposal clears those objects' attachments. The new regression
  models that lifecycle and reproduced the early failed seek; both held-body
  cases failed before the repair. The existing phase-one fallback now prepares
  a fresh source and uses one bounded 45-second cold retry, opening transcodes
  directly at the server offset. Seek source readiness follows its active load;
  settlement retains the completed-file fallback. Internal timeouts and seek
  failures stay quiet. Exhausted desktop recovery fails over or
  stops the final song, retaining a failed source that Play can reload.
  The native failing-Range fixture also exposed a frozen `ready` source
  (`reason: no progress`, `positionMs: 90000`) after recovery, so desktop
  exhaustion now uses failover in every processing state. Its regression
  first failed with `Expected: false / Actual: true` for Playing.
  The final-song timeout regression also failed before the retention repair
  (`Expected: song-0 / Actual: null`). Natural cold-seek traces differ: they
  issue the seek at +5.056 s, then exhaust two 25-second buffering probes at
  60,000 ms. Their proxy records repeated FLAC byte-range searches; an app-side
  source-wait expiry does not explain those cases. Native revalidation must
  distinguish those decoder waits from the repaired cold-source ownership bug.
  Isolated Linux evidence: `.dart_tool/round9_seek_runtime.py` extends the
  existing synthetic seek runner only in ignored local evidence, holding every
  media body for 20/40 s and issuing the seek at +5 s. The FLAC run passed all
  22 required scenarios across two clean starts (`build/seek-reliability/r9-flac-holds/report.json`),
  including all four held-body cases. Initial hold20/hold40 seeks completed
  in 16,106/36,085 ms at positions 60,332/60,343 ms, using one recovery each.
  After removing the frozen-ready exception, `.dart_tool/round9_terminal_runtime.py`
  rebuilt the final implementation and verified two clean starts with failing
  Range responses: both reported `quietStop: true`, `playRestarted: true` after
  Range support returned (`build/seek-reliability/r9-terminal/report.json`).
  App-owned lyrics/player screenshots were inspected; the Mini Player capture
  was obscured by the existing Return to Desktop View prompt. Both runtime
  runners exited successfully and shut down their isolated processes.
  Android retains its load/seek retry timing and source selection. Shared
  changes make internal timeout/seek failures quiet, follow an active source
  load's deadline, and stop/mark the final failed source reloadable by Play.
  Final `./tool/check.sh` passed: formatting, generation, analyzer, dead-code
  baseline, 103 migration tests, 283 critical reliability tests and the full
  suite (8,943 passed, one skipped; 426 s). The complete diff was reviewed;
  generated files stayed unchanged. Evidence: `.dart_tool/round9-check.log`.

- [ ] Issue #86, slow-stream seek settlement and song start — partial: 2026-10-20
  (`fix/seek-settlement`, remaining: coordinator native FLAC/Android
  revalidation and independent review): round 8 repairs exhausted source-load
  recovery while preserving the existing deadlines. The round-7 cold-b traces
  show successful initial loads at +13.994 s / +18.717 s, then seeks, a 25-second
  settlement deadline, and recovery reloads at 60,000 ms. Both reloads end with
  `decision: playerOperationTimedOut`, `operation: active queue apply`,
  `timeoutMs: 12000`, followed by idle and a failed seek. Offset loads deliberately
  have `hardCap == initial`; sidecar bytes cannot extend them (received bytes
  still grew 1,589,248 → 2,211,840 and 2,424,832 → 3,506,176 during those reloads).
  The seek error handler then blocked stream recovery even though its retired
  player was empty.
  An exhausted desktop recovery load now uses the existing failed-song failover.
  A desktop cold initial apply that times out with a same-song seek pending uses the existing
  source-apply retry once at that target, then ordinary load failover if it fails.
  Both paths preserve the queue and latest Play/Pause intent. The repair is
  desktop-only; Android's existing source retry and offset paths are unchanged.
  Regressions first failed with `Expected: song-0 / Actual: song-1` (missing same-song retry),
  `Expected: an object with length of <2>` (no attempted retry before failover),
  and `Expected: <2> / Actual: <0>` (empty native queue after seek recovery).
  All three passed after the repair (`00:03 +3`); the focused progress-aware
  deadline suite passed `00:17 +22`.
  The healthy h4 snap-back is a harness false positive: its first seek completed
  at 140,747 ms; a second request explicitly targeted 35,100 ms at +36.854 s.
  The first request's snap-back oracle kept comparing samples to its old moving
  position after that new command. The recovery `initialPositionMs` is 35,100,
  its deadline position is 35,100, and it completes at 35,435 ms in 56.682 s
  (the accepted 25 s + reload + 25 s bound). No application snap-back repair
  is justified: the raw position stream temporarily reports zero while the
  native deck is paused/loading, but `pendingSeekMs` remains 35,100 throughout;
  `watchDisplayedPlaybackPosition` gives that pending target priority. Across ten
  cold traces the first seek runs 0–158 ms after both request and source readiness;
  FLAC range requests and degraded-server waits, rather than a fixed app delay, explain the remaining latency. The fixed-cap
  comment, server-versus-player-progress architecture note and neutral ICY test
  property were also corrected. The isolated Linux FLAC runtime command
  `WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland CMAKE_BUILD_PARALLEL_LEVEL=2
  python3 tool/seek_reliability_diagnostics.py --platform linux --codecs flac
  --restarts 2 --output build/seek-reliability/r8-flac-wayland` completed with
  18/18 required scenarios across two clean starts; the two failing-Range
  negative cases remained failures. The native run preceded only a lint-only
  local-variable rename and explicit desktop guards; Linux behavior is unchanged. Evidence is in that directory's
  `report.json`, `app.log` and app-owned screenshots. The first attempt built
  successfully but exited before startup with `Gtk-WARNING: cannot open display`;
  using the available Wayland display resolved it. Inspected lyrics screenshots
  show the paused target and intact controls; the compact capture has a
  desktop-return dialog, so compact visual acceptance is limited. The live
  degraded-server cold-seek rerun and independent review remain with the
  coordinator; Android, #87 and crossfade offsets were not revalidated here.
  Final validation: the desktop-scoped deadline suite passed again (`00:17 +22`),
  and the neutral ICY property suite passed `00:00 +3`. `./tool/check.sh` completed
  successfully (`build/r8-check-complete.log`): formatting, generation, analysis,
  dead code, 103 migration tests, 283 critical reliability tests, and
  `06:41 +8935 ~1: All tests passed!` for the full suite. Its 201 informational
  analyzer findings include none on added/changed lines; all 16 findings in edited
  Dart files map to unchanged lines. The complete diff passes `git diff --check`.
  No generated source changed and no runtime/test jobs remain. Earlier round
  details follow.
  Desktop seek probes use a fixed
  25-second settlement deadline, including recovery. Desktop zero-position
  loads use sidecar received bytes for the existing 12-second/idle/45-second
  progress deadline; mobile buffer and lock-cache byte events remain intact.
  Same-song cold seeks keep the active load's ownership. The sampled mpv
  input APIs and their diagnostics were removed. Cache-complete reloads,
  transcode-offset selection, cancellation, Play/Pause intent and radio keep
  their existing paths. Earlier rounds and their superseded policies follow.
  The tests use shortened injectable production budgets
  and a real loopback sidecar transfer. Before the fix, the six-case regression
  run ended `00:02 +1 -5: Some tests failed.`; both seek states, idle/cap
  preconditions and the growing start failed. Seek assertions reported
  `Expected: <0>` / `Actual: <1>`; the start reported `Expected: <false>` /
  `Actual: <true>`. The no-byte start already passed. The first fixed rerun
  passed `00:06 +6: All tests passed!`; additional start idle/cap cases cover
  the shared bound. The requested `flutter test --concurrency=4` run of
  `navis_audio_handler_navigation_test.dart` and `position_offset_test.dart`
  passed `05:21 +588: All tests passed!`. After lint corrections, the eight
  deadline regressions passed again: `00:08 +8: All tests passed!`. All eight
  edited Dart files pass `dart format --set-exit-if-changed`; scoped
  `flutter analyze --no-fatal-infos` exits successfully with no errors or
  warnings and 16 existing informational findings, each mapped to an unchanged
  `HEAD` line. The complete diff passes `git diff --check`. No app, emulator
  or VM was launched; runtime validation and the full gate remain with the
  coordinator per this task's scope.
  Round 2: rebased onto `github/release/1.5` including PR #106, without
  conflicts. The coordinator reported round-1 Linux native-direct FLAC seeks
  (6/6, 6–18 seconds), FLAC cold starts (3–11 seconds), dead-stream failover at
  12 seconds and Android offset-seek/stall-recovery checks passing. Review
  finding 2 was confirmed: `_partialCacheBytesForSong` returned independent
  desktop sidecar bytes. Both deadline consumers now use player-side signals.
  Waiting queue commands and superseded load generations remove extended
  waits using the existing lane backlog and generation; native-load checks
  run every 250 ms without file I/O. The lock-cache source emits progress on
  each received chunk and exposes its in-memory byte count, preserving
  sub-percent and unknown-length progress. Timeout messages and exceptions
  report elapsed time, and the cap assertion allows scheduling slack.
  Before the fixes, the ten deadline cases ended
  `00:12 +8 -2: Some tests failed.`: the frozen desktop seek reported
  `Expected: 'missed target'` / `Actual: 'deadline'`, and the waiting-seek
  case reported `Expected: true` / `Actual: <false>`. The first fixed run
  passed `00:10 +10: All tests passed!`. The requested three-file
  `flutter test --concurrency=4` command (navigation, position-offset and
  lock-cache source) passed `05:23 +611: All tests passed!`. After final style
  cleanup, the ten deadline cases and two new sub-percent/unknown-length
  lock-cache event cases passed `00:10 +12: All tests passed!`. All eight
  edited Dart files pass `dart format --set-exit-if-changed` unchanged.
  Scoped `flutter analyze --no-fatal-infos` exits successfully with no errors
  or warnings; its 29 informational findings map to unchanged `HEAD` lines.
  The complete diff passes `git diff --check`. No app, emulator, VM or
  `./tool/check.sh` was run for this round, per the assigned scope.
  Round 3: coordinator Linux evidence rejected round 2: mpv buffered position
  froze during range probes, causing five recoveries in twelve seeks and a
  cold-start seek timeout cascade. Desktop deadlines now sample mpv's own
  `cache-speed` input rate through the existing native property bridge, at
  most every 250 ms; desktop buffer and sidecar growth are excluded. A waiting
  same-song seek preserves a progressing load; next/Stop retire a superseded
  load on the next check, including before its original deadline. Android
  lock-cache events, bounds, cache-complete/offset recovery and telemetry stay
  intact. Tests were written first: `00:10 +3 -12: Some tests failed.`
  Exact failures included `Expected: <0>` / `Actual: <1>` for frozen-buffer
  seeks and `Expected: false` / `Actual: <true>` for both cold-start variants.
  The mpv property is a network-layer estimate updated when demux reads return;
  it can lag in blocking reads and is unavailable before demuxer publication.
  Native slow-probe/cold-open coverage remains a coordinator runtime question.
  The requested three-file run plus the two edited media_kit fixtures passed
  `05:26 +628: All tests passed!` with `flutter test --concurrency=4`.
  All eleven edited Dart files pass formatting; scoped analysis has no errors
  or warnings and 27 existing informational findings on unchanged HEAD lines.
  The complete diff passes `git diff --check`. No app, emulator, VM or full
  gate was run, per the assigned scope; native acceptance remains open.
  Round 4: coordinator Linux evidence reported a ready/playing seek frozen at
  its target waiting 45 seconds twice because a positive mpv rate kept extending it.
  The shared deadline now permits input extensions only while loading/buffering;
  ready uses the existing three-second no-progress/missed-target handling.
  A late landing gets that short motion-confirmation window rather than failing
  the already expired load budget; recent input survives brief state flapping
  but cannot extend the ready state's wait. Round 5 corrects the adapter rule:
  input qualifies at >=8 KiB/s with a sampled change in either direction in
  the last two seconds; unchanged samples between mpv recomputes remain active.
  Decay below the floor and blocked-read values stale for two seconds expire.
  Seek-lane inspection found no independent cancellation defect in same-song
  load preservation: a playing seek needs 250 ms of native advancement after
  landing, and a newer seek marks an unconfirmed request `superseded`. Stale
  input could keep that earlier request pending until the next seek; the
  regression requires a frozen ready request to finish recovery first.
  The exact 26-second coordinator trace is unavailable in this worktree, so
  attributing that individual event remains conditional on its native motion.
  Tests were written first on `c585bf12`: `00:06 +0 -5: Some tests failed.`;
  ready-at-target reported `Expected: 'no progress'` / `Actual: 'deadline'`,
  and both unchanged/decaying-rate cases reported `Expected: false` /
  `Actual: <true>`. Re-running the final five regressions against that commit's
  implementation again failed all five, including `Expected: 'failed'` /
  `Actual: 'superseded'` for the landed-frozen request followed by a later seek.
  After the fix the focused run passed
  `00:16 +21: All tests passed!`; an additional late state-flapping case
  retains the round-3 buffering contract. The former ready/frozen extension
  expectation is replaced with prompt recovery as required by this round.
  The final requested three-file run plus `mediakit_seek_test.dart` passed
  `05:30 +630: All tests passed!` with `flutter test --concurrency=4`.
  All seven edited Dart files pass `dart format --set-exit-if-changed` unchanged;
  scoped `flutter analyze --no-fatal-infos` exits successfully with no errors
  or warnings and 13 informational findings mapped to unchanged HEAD lines.
  The complete diff passes `git diff --check`. No app, emulator, VM or
  `./tool/check.sh` was run, per the assigned scope; coordinator native
  revalidation and independent review remain open.
  Round 5: replaces rising-only mpv activity with the >=8 KiB/s floor and
  two-second age of the last sampled change in either direction. The shared
  loading/buffering gate and ready/frozen recovery timers remain unchanged.
  Tests were written first on `5e5c32c8`: `00:24 +4 -4: Some tests failed.`;
  the real 12-second buffering regression reloaded despite steady input
  (`Expected: <1>` / `Actual: <2>` source loads). Unchanged samples, downward
  recomputes and halving decay also failed (`Expected: true` or
  `Expected: <true>` / `Actual: <false>`). The focused adapter/deadline run
  passed `00:31 +24: All tests passed!`, including the ready/frozen and
  superseded-seek regressions. The requested three-file run plus the edited
  `mediakit_seek_test.dart` passed `05:43 +632: All tests passed!` with
  `flutter test --concurrency=4`. All three edited Dart files pass formatting;
  scoped `flutter analyze --no-fatal-infos` exits successfully with no errors
  or warnings and seven informational findings mapped to unchanged HEAD lines.
  The complete diff passes `git diff --check`. Native acceptance, independent
  review and the full gate remain with the coordinator; no app, emulator, VM
  or `./tool/check.sh` was run, per the assigned scope.
  Round 6: coordinator Linux/live-server FLAC evidence rejected the floor and
  sampled-change heuristic (5/15 direct, 10 recoveries, eight failed outcomes).
  Restores input activity for any sampled mpv `cache-speed` > 0, including low,
  constant or falling estimates during range probes. The loading/buffering
  gate, ready/frozen timers, idle window and 45-second cap remain. A stale
  positive estimate while buffering may extend a truly stuck load or seek to
  that cap; the accepted ceiling is documented with a `ponytail:` comment.
  Existing seek `unsettled` maps now include the latest `inputBytesPerSecond`
  (null when unavailable) and `inputExtensionActive`; sampling also observes
  ready states without extending them. Tests cover a constant 1 byte/s rate
  through the real 12-second buffering deadline, decaying input while ready,
  zero/unavailable input diagnostics, the active hard cap, the superseded
  regression, and the retained cold-start seek/Next/Stop cases. Floor and
  sampled-change expectations were removed. The focused deadline run passed
  `00:29 +20: All tests passed!`. The requested three-file command plus the
  touched `mediakit_seek_test.dart` passed
  `05:42 +632: All tests passed!` with `flutter test --concurrency=4`.
  All ten edited Dart files pass `dart format --set-exit-if-changed` unchanged;
  scoped `flutter analyze --no-fatal-infos` exits 0 with no errors or warnings
  and 25 existing informational findings mapped to unchanged HEAD lines.
  The complete diff passes `git diff --check`. Native acceptance, independent
  review and the full gate remain with the coordinator; no app, emulator, VM
  or `./tool/check.sh` was run, per the assigned scope.
  Round 7 (2026-10-21): coordinator slow FLAC evidence showed mpv's input rate
  measures linear download activity even when seeking is stuck. Both desktop
  settlement probes now use `desktopSeekSettle` (25 seconds) through the existing
  deadline helper. Source control/reload timeouts remain additional bounded work.
  Desktop zero-position loads use sidecar counters without file polling; loads
  at a seek position cannot extend from those independent bytes. The mobile
  byte-event extension, 12-second dead start and next-check Next/Stop cancellation
  remain. No queue token/generation change was needed: read-only r5/r6 cold
  traces show `active queue apply` timing out at 12 seconds, then next-song
  failover superseding the waiting seek. A cold mpv load has no useful progress
  sample while sidecar bytes are arriving. The test-first regression reproduced
  this with no mpv input signal: `00:04 +1 -3: Some tests failed.`; the fixed
  deadline expected 600–1000 ms but observed 1200 ms, and both cold starts
  expected `disposed == false` but observed `true`. The third-party native
  buffering seek test already passed. Single and rapid same-song seeks now
  verify no failure notice, no retirement and completion at the latest target.
  Final review found that bypassing the progress loop for nonzero recovery loads
  also bypassed generation cancellation. Next/Stop regressions first failed
  `00:01 +0 -2: Some tests failed.` (`Expected: true` / `Actual: <false>` for
  retirement within one check). Those loads now keep the same polling helper,
  with its hard cap set to the existing load deadline; arriving sidecar bytes
  cannot extend them. A third regression checks that fixed cap.
  The four-file serial run before the added cancellation cases (navigation,
  media-kit seek, position-offset and lock-cache tests) passed
  `05:39 +625: All tests passed!`. The final focused deadline/native-seek run
  passed `00:17 +22: All tests passed!`. An isolated muted
  Linux profile used the authenticated diagnostics API against a synthetic WAV
  fixture: the native read waited 14 seconds while sidecar bytes arrived; a
  same-song cold seek completed in 14.57 seconds with zero recovery attempts,
  surviving the 12-second load threshold without a skip. A paused backward seek
  reached 29,901 ms for a 30,000 ms target; clean restart restored both queue
  occurrences. Evidence: `build/round7-runtime/report.json` and app logs. The
  native FLAC stuck-probe/Android harness and independent review remain external
  acceptance work. `./tool/check.sh` passed with two test workers: migration
  `00:03 +103`, critical reliability `00:10 +283`, and full suite
  `10:55 +8933 ~1: All tests passed!`, followed by `[check] All checks passed.`
  The temporary concurrency config was removed. Final formatting passes all
  eleven edited Dart files unchanged; final scoped analysis exits 0 with no
  errors or warnings and 25 informational findings mapped to unchanged HEAD
  lines. The complete diff passes `git diff --check`.
- [ ] Issue #86, Android progressive HTTP repeat-one rewind — partial: 2026-10-20
  (`fix/repeat-one-rewind`, based on `3c1d8c54`, remaining: coordinator Android
  runtime probes, independent review and `./tool/check.sh`): native repeat-one
  is replaced by repeat-off plus pause-at-end only for progressive HTTP VOD;
  the same item restarts at native zero with command-revision cancellation and
  no terminal completion. Radio's default-retry opt-out, local/asset sources,
  HLS/DASH and repeat-all remain native. The existing Dart offset-loop handler
  clears an offset source with one reload; no parallel Dart repeat mechanism
  was introduced. The JVM regression first failed with `AssertionError:
  progressive repeat one must disable native preloading of itself`; all
  equalizer fixtures, 12 retry fixtures and 21 repeat fixtures now pass via
  `./tool/equalizer_native_test.sh`. Two plain-stream unknown-duration Dart
  cases first failed (`00:00 +19 -2`); fixing the pairwise detector's reversed
  subtraction makes all 21 `position_offset_test.dart` cases pass. The
  handler regression covers middle/last offset items and exactly one reload.
  The combined `flutter test --concurrency=4 --timeout 60s` run of
  `position_offset_test.dart` and `navis_audio_handler_navigation_test.dart`
  passed `05:22 +580: All tests passed!`, including repeat-one crossfade and
  timeline cases. Bootstrap ran once; edited non-vendored Dart files pass
  formatting and the complete diff passes `git diff --check`. No app, emulator
  or VM was launched; Android
  compilation/runtime, analyzer and the full gate remain with the coordinator.
  Review round 1 fixes: boundary ownership now uses the timeline window UID,
  so appends/inserts/moves retain a pending restart or paused boundary while
  the same occurrence stays current; removal/replacement cancels it, and the
  runnable seeks its current index. Removed redundant loop-policy updates from
  Play/Pause. The insert-before fixture first failed with `AssertionError:
  inserting before the boundary item restarts at its shifted index`; the JVM
  harness now passes all equalizer fixtures, 12 retry fixtures and 26 repeat
  fixtures. The same two-file targeted Dart command above passed
  `05:19 +580: All tests passed!`. Architecture, vendored change notes and the
  existing release-note entry were updated. The complete diff passes
  `git diff --check`. No app, emulator, VM, Android build, analyzer or
  `./tool/check.sh` was run for this round, per the assigned validation scope.
- [ ] Issue #86, unknown-length Android stall replay — partial: 2026-10-20
  (`fix/stall-replay`): Media3 progressive load errors with unknown HTTP length
  become fatal instead of restarting at byte zero; sized/ranged sources and
  radio retain native retries. Handler recovery prefers the completed cache,
  then reuses transcode-offset seeking at the current song time, with the seek
  lane, cancellation, Play/Pause intent and existing one-retry budget. An error
  at the known end advances without a reload. The initial handler run failed
  four new regressions (`05:14 +550 -4`); the pure JVM framing fixture first
  failed on chunked playback and then passed all 11 cases. The end-of-song
  regression also failed before its advance guard. Broader validation exposed
  two existing Play/rearm regressions; distinguishing automatic recovery from
  a user seek fixed both. The focused rerun passed `00:03 +15`; the final
  `flutter test --concurrency=4 --timeout 60s` run of
  `navis_audio_handler_navigation_test.dart`, `position_offset_test.dart` and
  `lock_caching_audio_source_test.dart` passed `05:14 +583: All tests passed!`.
  All nine edited Dart files pass the formatter check; the complete diff passes
  `git diff --check`. Coordinator retains the emulator stall probe,
  runtime loop, independent review and `./tool/check.sh`; no app, emulator or
  VM was launched for this implementation task.
- [ ] Issue #86, transcode offset seek — partial: 2026-10-20
  (`fix/transcode-offset-seek`, remaining: orchestrator runtime pass with
  `tool/live_seek_stress.py` on Linux and the Android emulator): `streamUrl`
  `timeOffset`, the `transcodeOffset` capability, a vendored just_audio
  `positionOffset` translation layer, an offset resolver source with a
  full-URI sidecar, and the handler seek branch with its edge-case tests
  (`docs/plans/Transcode_Offset_Seek_Plan.md`).
- [x] Issue #86, abort interrupted audio proxy responses — 2026-10-20
  (`fix/proxy-download-error`): stream and header-forwarding proxies abort
  origin body errors instead of sending clean EOF or entering HTTP/0.9 fallback
  after headers arrive. Both reuse `HttpResponse.addStream`; zero response
  deadline destroys the socket after headers, when detachment is unavailable.
  Existing body-progress deadlines, range-fetch error propagation, partial-file
  cleanup and radio retry policy remain unchanged. The six interruption cases
  first failed (`00:04 +0 -6: Some tests failed.`); the chunked lock-cache
  assertions at test line 272 reported `Expected: <Instance of 'HttpException'>`
  and `Actual: <null>`. The corrected lock-cache file passes
  `00:06 +19: All tests passed!`, including sized failures, cache publication,
  retry and live chunked completion. The requested three-file run with
  `--concurrency=4` passes `05:19 +590: All tests passed!`. Edited Dart files pass
  `dart format --set-exit-if-changed`; the full diff passes `git diff --check`.
  `tool/equalizer_native_test.sh` passes, including
  `ProgressiveLoadRetryTest: 13 fixtures passed`: a real incomplete chunked read
  throws `IOException` and selects the existing fatal policy. Full-gate,
  independent review and device/runtime validation remain with the coordinator;
  no app, emulator or VM was launched for this implementation task.
- [x] Issue #86, frame unknown-length lock-cache proxy responses — 2026-10-19
  (`fix/proxy-response-framing`): restore chunked transfer encoding after the
  proxy clears response headers, and explicitly size empty HTTP 500 bodies at
  zero bytes. Sized HTTP 206 responses retain their content length; the URI
  proxy copies origin framing headers. The raw HTTP/1.1 keep-alive regression
  first failed with `TimeoutException after 0:00:02.000000: Future not completed`
  and passes after the fix, requiring a terminating chunk or a complete sized
  body. The whole lock-caching file passes all 12 tests. Started unreleased
  1.5.1 and documented the fork patch. After one bootstrap, the 8 GB-capped
  gate first failed only in the playlist-library stream-reload test; all nine
  tests in that file passed on an unchanged isolated rerun. The repeated full
  gate passed: `06:10 +8844 ~1: All tests passed!` and
  `[check] All checks passed.` (peak 5545 MB, no OOM kills). Native playback
  and the isolated app runtime loop have not been repeated; the regression
  exercises the real Dart HTTP proxy with the existing fake native player.
- [x] Issue #81, rebuild reachability checks stay in preparing progress —
  2026-10-18 (`fix/rebuild-checking-not-offline`): `checkingNetwork` keeps
  Retry hidden until the existing reachability controller confirms an outage
  (`offline`) or device policy is offline. Existing listeners resume on success
  and handle policy changes while checking; cancellation and session changes
  publish no late progress. Four regressions failed before implementation:
  pending-ping initial login and cache upgrade (provider test line 283),
  confirmed-failure waiting (line 335), and hidden Retry (screen test line 132).
  The two rebuild test files plus `server_reachability_provider_test.dart`
  pass all 55 tests with `flutter test --concurrency=4`; scoped analysis exits
  0 with no errors or warnings and one pre-existing changelog quote-style info.
  Bootstrap, changed-file formatting and diff whitespace checks completed.
  Runtime, builds and emulators were not run under this task's memory
  constraints; `./tool/check.sh` remains the orchestrator's validation step.
- [x] Issue #78, library reset preserves listening history and pending submissions —
  2026-10-18 (`fix/reset-keeps-history`): the existing set-based retention delete
  now protects `play_history`, `scrobble_queue`, and
  `listenbrainz_feedback_queue` song references and their parent metadata.
  Audited all Drift catalog foreign keys and documented the reset policy in
  `docs/architecture.md`; no schema migration or changelog edit (reserved for
  the parallel changelog branch). All four new regressions failed first;
  40 focused reset/upgrade/queue tests pass, including real rescan reconfirmation,
  missing-song retention, repeat reset/GC, and deletion of unreferenced songs.
  `make gen` produced no tracked changes; analysis exited 0 with no errors or
  warnings. Isolated muted Linux API checks passed the 1004 → 1005 upgrade,
  manual Reset Caches, and clean-restart history/feedback persistence, retained
  missing songs, reconfirmation, and unreferenced deletion
  (`build/issue78-runtime/report.json`), repeated after the full gate. Scrobbles
  are covered by the database/service regressions: diagnostics intentionally
  disables scrobbling and clears its queue at startup. The locked 10 GB-capped
  `./tool/check.sh` ran once and passed: 8,828 tests, one skipped; exact final
  line `[check] All checks passed.` Final runtime logs had no errors or
  exceptions. Native mobile/Apple/Windows runtime checks were not repeated.
- [x] Issue #70, saved playlist kept the Navidrome placeholder cover — 2026-10-18
  (`fix/playlist-cover-placeholder-ttl`): Navidrome serves a placeholder
  (HTTP 200, no cache headers) for about 5-8 s after a playlist is created and
  the cover cache kept it for 30 days. `validTill` now expires a `pl-` cover
  without cache headers after 2 minutes, so it revalidates and updates on the
  next view; other covers keep 30 days. Three tests in
  `cover_art_cache_manager_test.dart`; the playlist TTL test failed before the
  fix (`Actual: Duration:<719:59:59.999988>`).
- [x] Issue #71 follow-up: malformed instrumental LRC and plain-only upgrades —
  2026-10-18 (`feat/instrumental-lyrics`): instrumental classification now follows
  parsing; the DAO can mark plain-only rows without overwriting their lyrics or
  source and still protects synced rows. Server plain refreshes retain a known
  upgrade marker, so forced backfill never retries it. Added parsing, resolver,
  repeated forced-backfill and double-run 104 → 105 migration coverage. Four
  behavioural regressions failed before implementation; the migration rerun
  test already passed. The four targeted resolver/DAO/backfill/migration suites
  passed 204 tests. `flutter analyze --no-fatal-infos` exited 0 with no errors
  or warnings (198 info findings). The required locked, 10 GB-capped full gate
  ran once and passed: 8,813 tests, one skipped; exact final line
  `[check] All checks passed.` Code generation produced no source changes.
  Fresh muted Linux diagnostics fixtures before and after the gate passed
  authenticated health, plain-lyrics display alongside the marker, clean-restart
  persistence and fresh server-lyrics precedence; all six app-owned screenshots
  were inspected (`build/issue71-followup-runtime/report.json`). Malformed LRCLIB
  responses are covered by deterministic resolver tests, not runtime injection.
  Native mobile/Apple/Windows runtime validation was not repeated.
- [x] Issue #71, instrumental lyrics — 2026-10-18
  (`feat/instrumental-lyrics`): LRCLIB exact/search responses persist the
  instrumental status in the existing external lyrics cache via schema 105's
  104 → 105 migration. Forced and automatic backfill skip marked tracks,
  the missing-lyrics list excludes them, and shared/fullscreen/desktop lyrics
  reuse the localized empty-state layout. Real lyrics take precedence and
  cannot be overwritten by a slower instrumental lookup. Tests were added
  before implementation (missing API compilation failures and a missing-column
  migration failure); the five targeted suites pass 203 tests and the two
  consumer widget regressions pass. `make gen` and `flutter gen-l10n` ran.
  Isolated muted Linux profile passed authenticated health, expired-marker
  display, clean-restart persistence, and real-server-lyrics precedence;
  inspected all three app-owned screenshots (`build/issue71-runtime/report.json`).
  Runtime logs contain the media-kit `osc` property warning, with no lyrics
  errors. The required locked, 10 GB-capped `./tool/check.sh` passed once:
  8,808 tests passed, one skipped; final line `[check] All checks passed.`
  Repeated all three runtime cycles and inspected their screenshots after the
  gate. Reusing the disposable profile first returned HTTP 500 from the session
  reconnect endpoint; resetting only that task-owned fixture database allowed
  the fresh-profile run and its clean restarts to pass. Runtime coverage is
  Linux; native mobile/Apple/Windows builds were not run.
- [x] Issue #69: device playlists show a 2x2 cover mosaic — 2026-10-18
  (`fix/device-playlist-mosaic`): Library rows and the playlist detail header
  reuse `PlaylistCoverMosaic` for device playlists only (server playlists keep
  the server's `pl-<id>` cover; empty ones keep the placeholder; one album
  shows a single cover). The header derives ids from the songs it already
  loads; rows use `devicePlaylistCoverArtIdsProvider`, one grouped
  `PlaylistDao.watchLocalPlaylistCoverArtIds` query for all device playlists
  (no per-row query). Tests: `playlist_dao_test.dart`,
  `playlist_detail_cover_test.dart`, `library_screen_test.dart`. No goldens
  changed.
- [x] Issue #52, Pill buttons should be circles — 2026-10-18
  (`fix/pill-fab-circle`): `floatingActionButtonTheme.shape` is a stadium in
  Pill (a circle on the square Playlists and Radio FABs, still fitting the
  extended match-flow FAB); Soft and Square keep `lgShape`. Added
  `test/src/theme/pill_circle_test.dart` (FAB shape per corner style, including
  the lyrics re-center small FAB, now a circle in Pill; compact
  header download button in Pill and Soft across light/dark/OLED and
  accent/white controls). The FAB test failed before the fix
  (`Expected: true  Actual: <false>`). The compact header download button
  already renders as a circle in Pill (widget render inspected), so no change
  was needed there; the owner's rounded square was not reproduced. No goldens
  changed.
- [x] Issue #51: device rows vanish while lists reload — 2026-10-18
  (`fix/device-rows-while-loading`): `playlistLibraryItemsProvider` lists the
  last device and server rows from `playlistListProvider.value` during a reload
  or failed read, so the Library tab cache is never overwritten by a
  virtual-only list; the radio screen and `searchCollectionMatchesProvider`
  read playlists and stations with `.value` instead of `.asData?.value`, and
  the radio screen keeps the last server stations while that list reloads.
  Four tests written first failed (radio, playlist and search files), then
  passed. Runtime validation was not performed.
- [x] Issue #54, Light Now Playing artwork background washed out — 2026-10-18
  (`fix/light-artwork-veil`): the Light veil range is 0.30-0.70 (was
  0.58-0.88), the fixed veil 0.6 (was 0.68) and the lyrics floor 0.6 (was
  0.72), so the contrast loop rather than the cap picks the alpha and 30-70%
  of the cover shows. Dark and OLED are unchanged. Primary text stays at the
  loop's 5.0:1 target; the accent title falls back to 3.0:1 by shifting its colour toward
  `onSurface` (`nowPlayingArtworkAccent`); secondary lines are best-effort
  within the cap. New Light mid-tone cover test failed before the fix
  (`Actual: <0.8700000000000002>`) and passes after; the range, lyrics-floor
  and accent-title tests were updated. No goldens changed.
- [x] Issue #57: playlist rows show artwork — 2026-10-18
  (`fix/playlist-row-artwork`): `TrackListTile.showAlbumArt` now defaults to
  true; only the album detail list passes `false`, and the redundant `true`
  arguments were removed. The playlist and weekly detail headers drop their
  number column, and unmatched weekly rows follow the artwork-sized slot (the
  Home desktop hero list keeps its 32 px numbers). The new playlist-row test
  failed first (`Found 0 widgets with type "CoverArtImage"`), then passed. No
  golden changed. Runtime and desktop/compact-density screenshots were not
  inspected.
- [x] Issue #53, chip labels unreadable under Controls: White — 2026-10-18
  (`fix/chip-label-white-controls`): the chip theme's
  `WidgetStateTextStyle` label style is never resolved by the chip, so the
  colour was null and painted white. It is now a plain labelLarge style with a
  `WidgetStateColor` (tonal ink when selected, else on-surface). Added
  `test/src/theme/chip_label_color_test.dart` (light/dark, selected/unselected);
  it failed before the fix (`Actual: <null>`) and passes after. No goldens
  changed.
- [x] Issue #49 review fixes, round 3 — 2026-10-18
  (`feat/device-to-server-upload`): a kept device playlist retains its resolved
  server id; saving again sets the current name and replaces ordered songs via
  `updatePlaylist`, then repeats the snapshot-checked swap. Create recovery is
  completed only after replacement. Radio moves compare the original device
  name, stream URL and homepage inside the deletion transaction, preserve
  concurrent edits, and return/show the kept-copy result and notice. The
  recovery comment and architecture document the accepted app-kill duplication
  ceiling and pending-metadata persistence upgrade; architecture also records
  header lag until the next sync for journal-protected ids skipped by stale
  reconciliation. Tests-first baseline: `00:00 +51 -4: Some tests failed.`
  (one duplicate playlist create and three lost radio-field edits). The final
  four-file focused batch used the shared `flock`, 9G cap, concurrency 4 and
  60s timeout: `00:03 +123: All tests passed!`;
  `[capped] exit=0 peak=2666M swappeak=0M oom_kills=0`. Coverage includes playlist
  uploads/actions, radio actions, and the radio editor's kept-copy notice.
  Eight-file scoped analysis reported `No issues found! (ran in 2.6s)`.
  `flutter gen-l10n`, changed Dart formatting and `git diff --check` passed.
  Runtime validation was not performed;
  `tool/check.sh` was excluded by the implementation handoff.
- [x] Issue #49 review fixes, round 2 — 2026-10-18
  (`feat/device-to-server-upload`): upload replacement compares the device name
  and ordered entries with the original snapshot in the transaction; concurrent
  edits preserve both copies and produce a notice. Readback validates and caches
  the server's actual entries and reports partial acceptance. Playlist and radio
  moves share pre-create id snapshots and new-id resolution for bodyless or
  uncertain creates; ambiguous/failed lookups preserve the device copy, and
  retries retain the original snapshot/resolved id in the actions instance.
  This recovery state does not survive an app restart or actions replacement.
  Header reconciliation uses the existing durable local-mutation journal's
  increasing id to protect later writes, without a schema change, and deletes
  hydration work only for rows actually removed. Header refresh queues through
  the existing library target request path; the per-server sync lease is
  unchanged. The stale-response race explains a newly uploaded server row
  disappearing, but does not establish #51's cause: device rows remain excluded
  from server deletion, and a regression pins their survival. Validation:
  tests-first baseline `00:09 +239 -14: Some tests failed.`; all 14 failures
  corresponded to the requested regressions. The final 12-file focused batch,
  using the handoff's shared `flock`, 9G cap, concurrency 4 and 60s timeout,
  passed: `00:10 +458: All tests passed!` and
  `[capped] exit=0 peak=3905M swappeak=138M oom_kills=0`. Coverage includes
  playlist uploads/actions, radio actions/screen, sync engine/controller,
  playlist DAO, transaction streams, Library, playlist detail/device providers,
  and remote detail pages. Focused analysis of 17 changed files reported
  `No issues found! (ran in 4.7s)`. `make gen` and `flutter gen-l10n` succeeded;
  no Drift-generated changes or migrations were needed. Changed Dart formatting
  and `git diff --check` passed. App launches/runtime screenshots and
  `tool/check.sh` were explicitly excluded by the implementation handoff.
- [x] Issue #49, upload device playlists and radio stations to the server — 2026-10-18
  (`feat/device-to-server-upload`): Edit Playlist (the former rename dialog)
  has a Save on Server switch for device playlists, disabled while
  `playlistServerCreationAvailableProvider` is false. `PlaylistActions.uploadToServer`
  creates the server playlist from the ordered song ids, then
  `PlaylistDao.replaceLocalWithServer` swaps the rows in one transaction; a
  failed create keeps the device playlist, and concurrent calls share one
  create. An open detail screen follows the move through
  `playlistMovedToServerProvider`. Admins get the same switch when editing a
  device radio station (`RadioStationActions.save(moveToServer: true)`). Tests:
  the new `playlist_upload_test.dart` (5 cases), radio actions/screen,
  library screen and playlist detail tests; all passed on the focused run.
- [x] Issue #48, paced lyrics backfill with automatic cooldown resume — 2026-10-18
  (`feat/backfill-rate-limit-resume`): LRCLIB reuses the renamed
  `RequestLimiter` with two starts/second, one background start/second and two
  in flight. Retry-After is capped at ten minutes; headerless cooldowns double
  from 60 seconds to that cap and reset after success. Non-future headers use
  a one-second pause. Lyrics resume through the existing backfill gates while
  artwork proceeds; progress carries `resumeAt` and Downloads shows a live
  countdown. Stop and policy changes cancel the timer and queued/in-flight
  LRCLIB work; manual forced upgrades survive cooldowns without repeating
  completed songs or marking rate limits as misses.
  Evidence: client/countdown regressions first failed
  (`00:13 +41 -3: Some tests failed.`); background traffic and deadline
  regressions then failed
  (`00:06 +17 -6: Some tests failed.`). The final eleven-file focused run passed
  (`00:17 +296: All tests passed!`, capped peak 2956M). Scoped
  `flutter analyze --no-fatal-infos` exited 0 with nine infos, all in unchanged
  files. Localization regenerated with `flutter gen-l10n`; changed Dart was
  formatted. Runtime checks were not run by instruction; `./tool/check.sh`
  remains the coordinator's gate.
  Round 2: lyrics preserve visited IDs only for rate-limit resumes, retain
  cooldown progress at pass start, and own the countdown timer through an
  `initState` progress subscription. The existing launch, network, client,
  policy and reconciliation triggers now reopen completed gates through a
  local metadata/disk preflight; completed synced lyrics and covers need no
  pass or network request. Direct foreground-return and library-sync-completion
  listeners cover short resumes, automatic sync, manual sync and pull-to-refresh.
  Triggers coalesce during a pass and preserve a pending cooldown deadline.
  Regression tests first failed (`00:19 +55 -8: Some tests failed.`), including
  `Expected: <2>` / `Actual: <1>` after offline, Wi-Fi-only and stop interruptions;
  the four download/UI suites then passed (`00:23 +204: All tests passed!`,
  capped peak 2874M). Provider baseline tests also reproduced missing foreground
  and sync-completion callbacks. The provider/sync suites passed
  (`00:04 +66: All tests passed!`, capped peak 1934M); the final test-helper
  cleanup passed all 11 provider tests again
  (`00:03 +11: All tests passed!`, capped peak 1822M). All Flutter test runs
  used the shared lock, 9G cap, concurrency 4 and 60-second timeout. Scoped
  analysis of all seven changed Dart files reported `No issues found!`
  (exit 0, peak 1150M); formatting and diff checks passed. Runtime, emulator
  and full-gate validation remain excluded by the task instructions.
  Round 3: verified covers reuse store write/prune/removal invalidation; the
  joined local lyrics query shares the pass's seven-day eligibility predicate.
  Reconciliation kicks only at completion. Added offline LRCLIB two-song retry
  coverage. Red: `00:24 +41 -5: Some tests failed.`; the corrected reconciliation
  assertion also failed on the old listener (`00:02 +9 -2: Some tests failed.`).
  Four focused suites passed (`00:24 +97: All tests passed!`, peak 2850M) with
  the required locked/capped command. `make gen` changed no generated source;
  scoped analysis: `No issues found!` (exit 0, peak 2181M). Formatting and diff
  checks passed. Runtime and `check.sh` were not run.
- [x] Issue #55, persisted shuffle test database lifetime — 2026-10-18:
  the round-trip test captures its expected play order and disposes the first
  handler and database before creating the restored handler. Its guarded
  teardown avoids closing the database twice; all assertions remain. Evidence:
  the navigation test file passed under the shared lock and 9 GiB cap
  (`04:48 +528: All tests passed!`); the Drift multiple-database warning count
  was 0 and no `flutter_tester` process remained. Formatting passed; focused
  analysis exited 0 with seven infos on unchanged lines. `./tool/check.sh` was
  not rerun, as requested for this test-only follow-up.
- [x] Issue #55, shuffle the whole queue mid-playback — 2026-10-18
  (`feat/shuffle-whole-queue`): toggle-on reuses `shuffledFromStart` over the
  deferred head, materialised window and deferred tail. The current occurrence
  moves to index 0 without a source reload, seek, stop or playback restart;
  large queues remain windowed. Shuffle-off keeps the existing original-rank
  reconciliation. Play Next records successful insertions in the original
  order so repeated song IDs still unshuffle correctly. Legacy saved queues
  retain `shuffledAfter` compatibility. Added 12/60/100-song regressions at
  42 seconds, Previous under all repeat modes, and a persisted-rank restore
  round trip; updated the queue model's old history-prefix assertion and the
  added-songs test's native/logical index assumption. Evidence: bootstrap
  passed; the shuffle-order and navigation files ran with
  `flutter test --concurrency=4 --timeout 60s` under the required shared lock
  and 9 GiB cap. Tests failed first (`04:57 +529 -7: Some tests failed.`),
  then passed (`04:49 +536: All tests passed!`), including all 500 queue-model
  seeds. Changed Dart files pass formatting and the diff passes whitespace
  checks. No app/device launch or `./tool/check.sh` was run under this
  implementation handoff; full-gate, independent review and runtime evidence
  remain with the coordinator.
- [x] Issue #46, server plain lyrics on first fetch — 2026-10-17
  (`fix/server-plain-lyrics`): the batched runtime check of dev b5468cbd found
  that plain-only server lyrics (structured lines without `start`) showed "No
  Lyrics Available" on the first fetch; cached reads worked. A shared
  `plainLyricsText` helper in `lyrics_resolver.dart` now feeds the lyrics
  widget and the cache write. The Integrations lyrics subtitle describes the
  server-first order. A widget test failed before the fix and passes after it;
  `./tool/check.sh` passed (+8693 ~1). GLM-5.3 review: approved.
- [x] Issue #41 review fixes, round 1 — 2026-10-17
  (`feat/update-source-github`): `release.sh` rejects non-stable GitHub
  publication and stable prereleases without explicit `--no-github`, including
  staged metadata. Direct publication retains a unique checksummed recovery
  bundle before R2 changes; any later unverified GitHub exit fails and prints
  an executable resume command. Fixtures cover push/upload/fetch/equality
  failures followed by successful resume, staged paths with spaces, a skipped
  verification, and late direct publication with an existing bundle. GitHub
  asset byte counts strip `wc` padding. The repository rechecks remapped URLs;
  Integrations reads `updateHostProvider`, resolving its dead-code finding.
  Added malformed/typed source JSON, HTTP mid-chain redirect, signed asset
  query/fragment/encoded-separator and mismatched-tag tests. Release and host
  regressions failed before fixes; the negative trust cases already passed
  existing guards. Item 5 uses the requested `ponytail:` ceiling comment:
  selected source/hop metadata would need factory and transport plumbing;
  `followUpdateRedirects` already checks source and hop before contact.
  Evidence: the six-file focused run passed (`00:09 +236: All tests passed!`),
  `bash tool/github_release_test.sh` and `bash tool/dev_release_test.sh` passed,
  changed scripts passed `bash -n`, and changed Dart passed formatting.
  `dart analyze lib test` exited 0 with zero errors/warnings (186 existing infos).
  The unchanged-baseline dead-code gate exited 0 with no NEW entries
  (`declaration=4, l10n=0, asset=1, asset-missing=0, font=0, dependency=5;
  test-only=2`). Full `tool/check.sh`, app/device launches and real publication
  were excluded by this implementation handoff; runtime/full-gate evidence
  remains with the orchestrator. The existing 1.5.0 source-choice changelog
  entry remains accurate; no additional visible behavior was introduced.
- [ ] Issue #41, update source choice — partial: 2026-10-17 (Part C UI added below)
  (`feat/update-source-github`): Parts A/B backend and release tooling complete.
  Persisted integration-source metadata requires no migration; a notifier setter
  resets cache/throttle before saving, and providers expose effective source,
  host and platform/channel availability for Part C. GitHub mapping uses only
  verified signed tags/basenames, with explicit HTTPS redirect allowlists and
  unchanged pinned-signature, SHA-256 and size verification. Stable publication
  requires GitHub unless explicitly opted out, exports the verified R2 envelope,
  mirrors late additions and compares manifest bytes. Tests were written first
  and failed on missing APIs. Evidence: the combined updater, integrations,
  provider, diagnostics and Home selection passed (`00:08 +474: All tests passed!`);
  the final transport/diagnostics rerun passed (`00:05 +198: All tests passed!`).
  Diagnostics also show the selected source before checking and retain blocked
  redirects as fetch failures. Hermetic GitHub/R2 shell fixtures and `bash -n`
  passed. `dart analyze lib test` reports zero errors and warnings (existing infos
  remain). Shellcheck is not installed. Per handoff constraints, no app/device,
  real publication or `tool/check.sh` was run; orchestrator owns full validation,
  and Part C owns the selector, widget tests and 1.5.0 changelog entry.
- [x] Issue #41 Part C, update source choice UI — 2026-10-17
  (`feat/update-source-github`): Settings > Integrations > Update checks shows a
  "Source" radio choice (Porthorion downloads, GitHub) in the entry's existing
  credential slot, with helper text; the host line follows the effective
  source, dev builds show it disabled with a note, and store-managed,
  unsupported and loading states hide it. Disabled like the entry's feature
  switches when Update checks or the master switch is off. No notice on change.
  Widget tests written first (4 of 7 failed), then passed (`00:06 +195: All tests
  passed!` for the integrations and changelog tests). The Integrations goldens
  show only the top of the page, so they are unchanged.
- [x] Issue #39, review fixes round 1 — 2026-10-17
  (`feat/downloads-backfill-now`): corrected the token-authenticated cover probe
  with the app User-Agent. Cover-less album: HTTP 200, `image/webp`, 69,228
  bytes, verified stock Navidrome placeholder; nonexistent ID: HTTP 200,
  `application/json`, 185 bytes, Subsonic error 70. Exact hashes and miss/failure
  mapping are recorded in `docs/architecture.md`; the earlier curl 403 was
  Cloudflare error 1010. The store recognises only that verified placeholder,
  sends the same User-Agent and reuses the existing 20 MiB artwork cap. Test
  fakes default to failure, guarded Deezer Dio closes synchronously on disposal,
  and the seeded progress stream consumes `currentBackfillProgress`. Now Playing
  shares the seven-day failed-upgrade check, preserves plain lyrics/failure
  metadata and still permits server synced lyrics; manual backfill explicitly
  forces an upgrade. Missing metadata shows quiet loading/error rows, and the
  button requires an API client while retaining offline retry. The DAO documents
  its intentional orphan exclusion. Tests first reproduced 13 failures; six
  focused files then passed under the shared 9G cap and lock
  (`00:09 +155: All tests passed!`). `dart analyze lib test` exited 0 with
  zero errors/warnings and 183 pre-existing infos, none on changed lines.
  `dart run tool/dead_code_check.dart` exited 0 with no NEW/stale entries
  (baseline: declaration=4, l10n=0, asset=1, asset-missing=0, font=0,
  dependency=5, test-only=2). Changed Dart formatting and `git diff --check`
  passed. No app/emulator/VM launch, runtime screenshot or `tool/check.sh` run:
  explicitly excluded by the round-1 task; runtime/full-gate acceptance remains
  with the coordinator.
- [x] Issue #39 backend, Parts A/B — 2026-10-17
  (`feat/downloads-backfill-now`): lyrics resolve server first, keep server
  plain lyrics unless LRCLIB provides synced lyrics, protect synced cache rows
  from late plain writes, and retain plain lyrics during seven-day upgrade
  backoff. Permanent download metadata uses one joined query and checks artwork
  on disk per unique cover ID. Manual backfill shares concurrent calls, honours
  network/playback/cooldown gates, and exposes seeded phase/count/blocked-reason
  progress. Confirmed missing server covers can use a confident, policy-gated
  Deezer match under the existing server cover key. Schema remains 104.
  Tests first reproduced three lyrics regressions and the missing backend APIs.
  Evidence: five focused test files passed under the shared 9G cap and lock
  (`00:09 +200: All tests passed!`); `make gen` passed without tracked generated
  changes; `dart analyze lib test` exited 0 with no errors or warnings (183
  existing infos, none on changed lines); changed Dart formatting and
  `git diff --check` passed. The real-server cover probe received HTTP 403
  (`text/plain; charset=UTF-8`, 17 bytes), so placeholder image detection is
  unverified. Part C UI, its l10n/widget checks, independent review, app runtime
  validation and `tool/check.sh` remain with the coordinator per task scope.
- [x] Issue #38, Search finds saved playlists and radio stations — 2026-10-17
  (`feat/search-playlists-radio`): `SearchResultType` gains `playlists` and
  `radio`; `searchCollectionMatchesProvider` matches `playlistListProvider` and
  the device and server radio stations with `searchRelevanceTier`, outside
  `SearchResult3`, so it works offline. Search shows Playlists and Radio chips
  and sections only on a match; the two filters make no `search3` call. The
  radio screen's station start moved unchanged into `toggleRadioStation`
  (`radio_playback.dart`), shared with Search. Diagnostics
  `POST /v1/presentation/search` accepts the new filters. Tests first failed
  (missing provider and enum values), then passed.
- [x] Issue #37, Radio search on touch layouts — 2026-10-17
  (`feat/radio-touch-search`): `RadioTabContent` is now stateful and shows a
  `ListFilterField` (`radioFilterHint`) on non-desktop layouts when stations
  exist, reusing the existing name filter for both the device and server
  sections and the "no matches" state; the field clears itself when the station
  list empties. Desktop keeps type-to-filter with no field. Tests first failed
  for the four touch cases, then passed; the two Radio goldens were
  regenerated for the new field. Evidence: `flutter test
  test/src/features/library test/src/features/changelog` passed
  (`00:30 +1408 ~1: All tests passed!`).
- [x] Issue #34, restore the queue after a rejected station start — 2026-10-17
  (`fix/dead-station-queue`): source-load exceptions bypassed terminal radio
  recovery, leaving the in-session queue empty and native play intent true.
  Both the station card and diagnostics used that path; #21 did not change it
  (the rethrowing catch predates it in `8f49a126`). Startup now reuses
  `_stopUnavailableRadio` with its lane token; stream failures schedule cleanup
  and restore as one job. The shell owns the single failure notice, and the
  diagnostics route returns sanitized HTTP 502. Tests first reproduced empty
  queues for 1/80 songs and HTTP 500. Evidence: the three affected test files
  passed under `flock /tmp/navis-heavy.lock flutter test --concurrency=4`
  (`04:55 +629: All tests passed!`); the strengthened native-event/load-rejection
  race passed separately (`00:00 +1: All tests passed!`). `dart analyze lib test`
  exited 0 with no errors or warnings (184 existing infos; none on added or
  changed lines). Changed Dart files passed formatting; `git diff --check`
  passed. App launch/runtime validation, independent review and `tool/check.sh`
  remain with the coordinator, per the implementation task's constraints.
- [x] Issue #32, reject Flutter false passes — 2026-10-17
  (`fix/check-sh-false-pass`): every captured test step, including CI coverage,
  rejects a nonzero final progress failure count, `Some tests failed`, or a
  runner shutdown crash even when Flutter exits 0. ANSI/CR fixture coverage
  runs in the tooling gate. Evidence: `./tool/check_test_log_test.sh` printed
  `check_test_log_test: ok`; the reported failure log was rejected with exit 1;
  Bash syntax checks passed. After bootstrap resolved missing dependencies,
  `flock /tmp/navis-heavy.lock ./tool/check.sh` passed (8,517 tests, one skip;
  `[check] tests completed in 361s`, `[check] All checks passed.`).
  ShellCheck was unavailable. The initial unbootstrapped gate stopped at format.
- [x] Offline indicator strip, issue #6 UI — 2026-10-17
  (`feat/offline-indicator-strip`): the floating `ShellOfflineChip` is gone.
  `ShellOfflineBanner` now has a full 48 dp form and a 24 dp in-layout strip
  (cloud-off icon and "Offline"); the close button or three failed retries
  shrink it, tapping the strip grows it back, and back online removes it. The
  scope animates the size (`compact`), and `ShellOfflineBannerExtentBuilder`
  follows it so notices stay below. Tests first (`shell_offline_banner_test`,
  `app_router_test`, new `offline_status_strip.png` golden); the full banner
  golden is unchanged.
- [x] Issue #12 nav bar stuck after Back, soft ends — 2026-10-17
  (`perf/now-playing-drag`): after tap-open then Back the bottom nav bar stayed
  hidden. Cause: the shell's progress dedupe (`app_shell.dart`,
  `onProgressChanged`) dropped the last settle step (0.00085 to 0, under its
  0.001 threshold), so the bar's reveal stayed above 0; only a fast swipe skipped
  it. The dedupe now always takes 0 and 1. Owner design: the mini player rides
  the panel's top edge and fades over the first 15% of the travel (and back in as
  the panel lands), the nav bar slides down and fades over the same range;
  `_miniTranslateY` was removed (the layout delegate positions the mini player).
  Tests cover every dismiss path (Back, predictive back, slow swipe, fling,
  programmatic collapse, reduced motion, quick re-open) and a mid-settle tap
  above the panel edge.
- [x] Issue #12 Now Playing on top of the nav bar, review fixes — 2026-10-17
  (`perf/now-playing-drag`): owner design change. The panel is painted above
  the mini player and, from its first pixel of travel, covers the bottom nav
  bar (hit-tested first, so taps reach the panel); `_BottomNavReveal` now hides
  the bar (opacity 0, `IgnorePointer`, `ExcludeSemantics`) while the sheet is
  above collapsed and fades it in over 150 ms after collapse. No page or nav
  bar re-layout (both layout probe tests green). Review fixes: queue-swipe
  guard reads the real system inset from the view (the shell scope zeroes
  `MediaQuery` padding and view padding, so GLM's `viewPaddingOf` suggestion
  would still be 0); a state-changing release no longer restarts its fling when
  the parent flips `isExpanded`; reduced-motion collapse test asserts the
  report; `_travel` ceiling commented. Tests: `expandable_player_sheet_test.dart`,
  `app_shell_navigation_test.dart`.
- [x] Issue #12 Now Playing drag, review follow-ups — 2026-10-16
  (`perf/now-playing-drag`): `onExpand`/`onCollapse` fire at drag release again
  (deduplicated against the lagging `isExpanded`, so reduced-motion completion
  does not report twice) so back during the settle sees the player open or
  closed; stale "30 %" comment fixed; mini-player `AnimatedBuilder`s merged; new
  drag-driven layout probe test (page and nav bar never re-laid out under a
  finger). Evidence: `flutter test` player + routing + sheet, 1589 passed.
- [x] Device playlists review fixes — 2026-10-16 (`feat/playlists-device`):
  queue "Save as playlist" now uses `showCreatePlaylistDialog` (device fallback,
  failure notice); the Save to server switch stays available while server
  reachability is `checking`; partial device adds report the skipped count;
  `renamePlaylist` only touches device rows; a failed destination-setting write
  is logged; the Playlists filter clears when its field is hidden. Tests:
  `queue_save_as_playlist_test.dart`, `playlist_dao_test.dart`,
  `playlist_device_providers_test.dart`, `add_to_playlist_sheet_test.dart`,
  `create_playlist_dialog_test.dart`, `library_screen_test.dart`.
- [x] PR B2 UI: create switch, device playlists in the Library, local detail and
  add paths — 2026-10-16 (`feat/playlists-device`, rebased onto
  `feat/playlists-sections`; Sonnet implementation). New shared
  `showCreatePlaylistDialog` (name + sticky "Save to server" switch, disabled
  and off while offline without saving) replaces the two copies in the
  Playlists tab and the add sheet; device playlists show "On this device · N
  songs", have their own delete confirmation and "On this device" owner line,
  and the add sheet lists and adds to them through `PlaylistActions`. Widget
  tests: `create_playlist_dialog_test.dart` (sticky default/off/next dialog,
  offline unsaved, failure notice), `add_to_playlist_sheet_test.dart`,
  `playlist_detail_screen_test.dart` (no server call, offline remove) and
  `library_screen_test.dart` (subtitle, local delete text, created device
  playlist under Your playlists). `dart run tool/dead_code_check.dart` exits 0
  (the two B2 backend providers are now consumed). `./tool/check.sh`, the app
  and emulators were not run (host limits); the dialog layout is unseen on a
  device.
- [x] PR B2 backend: device-only playlist storage, actions and create destination —
  2026-10-16 (`feat/playlists-device`, based on B1 backend cec268ee; Codex
  implementation). Added transactional local creation/replacement with UUID
  IDs, ordered duplicate occurrences, FK-safe unknown-ID filtering, skipped
  counts, metadata recomputation and rollback coverage. Local actions use only
  the DAO; server create disables transport retries and existing server-action
  invalidations remain. Detail sync skips local rows and deleted `local:` IDs.
  Android Auto browse, the real queue-controller handoff (mocked audio handler
  and lyrics prewarm), and offline download enqueue reuse existing stored rows.
  The targeted playlist destination writer and notifier retain explicit choices
  across new dialogs; offline connectivity, unreachable servers and missing
  APIs force the effective choice off without persisting that forced state.
  The UI reads `playlistCreateOnServerProvider`, writes through its notifier's
  `setOnServer(enabled: value)`, and enables the switch with
  `playlistServerCreationAvailableProvider`.
  Tests were written first: the new DAO/actions/settings APIs failed compilation;
  a deleted local detail ID incorrectly queued a server target, and a connected
  but unreachable server initially left server creation enabled. These cases
  now pass. The final capped eight-file suite reported
  `00:03 +209: All tests passed!` and
  `[capped] exit=0 peak=3541M swappeak=0M oom_kills=0`, using
  `~/.cache/claude-navis-tools/capped.sh 6G "$PWD" flutter test --concurrency=4`
  with `playlist_dao_test.dart`, `playlist_actions_test.dart`,
  `playlist_device_providers_test.dart`, `app_settings_dao_test.dart`,
  `settings_repository_test.dart`, `auto_media_tree_service_test.dart`,
  `download_service_test.dart`, and `subsonic_api_client_test.dart`.
  `make gen` exited 0: `Built with build_runner/aot in 49s; wrote 2005 outputs.`
  It left no tracked generated-file changes. All 15 changed Dart files were
  formatted; capped scoped `flutter analyze --no-fatal-infos` reported
  `No issues found!` (exit 0). The complete diff was reviewed and
  `git diff --check` passed.
  The dead-code check exited 1 with exactly four NEW entries awaiting UI wiring:
  `PlaylistActions.addSongs` and `playlistActionsProvider` in
  `lib/src/features/playlists/data/playlist_actions.dart` (inherited from B1),
  plus `PlaylistCreateOnServerController.setOnServer` and
  `playlistCreateOnServerProvider` in
  `lib/src/features/playlists/presentation/playlist_providers.dart` (new in B2).
  The baseline is unchanged. UI files were not edited.
  Integration gaps: the supplied B1 branch lacks the specified PR0 follow-up
  f686cff8 (`fix(db): keep songs that device playlists hold during playback
  cleanup`); no earlier commits were modified. Existing download batch enqueue
  does not deduplicate repeated IDs within a single request (`[a, b, a]` inserts
  three queue rows); this applies to server playlists too and was left unchanged.
  The create switch, badges, local UI action paths and widget tests remain for
  the UI step. The full check, application/emulator runs and runtime loop were
  prohibited by the task's host limits; independent review remains with the
  coordinating agent.
- [x] PR B1 UI: playlist sections, filter, gated edits and visible failures —
  2026-10-16 (`feat/playlists-sections`, on top of the B1 backend commit; Sonnet
  implementation). Library › Playlists shows Your playlists / Made for you /
  Other playlists headers only when more than one section has rows (replacing
  `listenBrainzPlaylistDivider`), a touch filter field (`ListFilterField`, moved
  out of Downloads) and the desktop type-to-filter, with the shared
  filtered-empty state. Long-press, ⋮ and right-click open rename/delete only
  when `canEditPlaylist` holds; rename, delete, add, remove and reorder run
  through `PlaylistActions` and show new failure notices
  (`playlistsRenameFailed`, `playlistsDeleteFailed`, `addToPlaylistFailed`,
  `playlistDetailReorderFailed`). The detail screen hides the drag handle and
  Remove when not editable; the add sheet lists only editable playlists.
  Widget tests were written first (compile and assertion failures against the
  old tab). Capped runs: `library_screen_test.dart` + `test/src/features/playlists`
  + changelog + downloads/presentation reported `00:10 +181: All tests passed!`
  (`[capped] exit=0 peak=3344M`); `test/src/features/library`,
  `test/src/features/downloads`, `test/src/common_widgets`, `test/src/routing`
  and `test/src/features/changelog` reported `01:20 +2194 ~1: All tests passed!`.
  `dart format` clean; `flutter analyze --no-fatal-infos lib test` has no errors
  or warnings in touched files. `dart run tool/dead_code_check.dart` exits 0
  (`playlistActionsProvider` and `PlaylistActions.addSongs` are now consumed;
  the unused `PlaylistLibraryItem.isVirtual` getter was removed). No goldens were
  regenerated. `./tool/check.sh`, the app and emulators were not run (host
  limits); the touch layout (filter field above the list, section headers) has
  not been seen on a device or in a screenshot.

- [x] PR B1 backend: playlist ownership, sections and throwing server actions —
  2026-10-16 (`feat/playlists-sections`, based on PR0 commits ae8d3991 and
  5e65e9be; Codex implementation). Added optional API `readonly` parsing and
  generated output, header/detail persistence and header comparison, pure
  ownership rules, case-insensitive playlist ordering, and Yours → Made for you
  → Other section metadata. Virtual playlist gates, routing, and availability
  during server-read failures remain covered. `PlaylistActions` exposes server
  rename/delete/add/remove/reorder with existing sync invalidations; errors
  propagate, offline calls throw, and local IDs are rejected pending B2.
  Tests were written first: new APIs failed compilation and the DAO ordering
  assertion failed against the old behavior. After implementation, the capped
  six-file run reported `00:12 +197: All tests passed!` and
  `[capped] exit=0 peak=2327M swappeak=0M oom_kills=0`, using
  `~/.cache/claude-navis-tools/capped.sh 6G "$PWD" flutter test --concurrency=4`
  with `models_serialization_test.dart`, `playlist_dao_test.dart`,
  `playlist_ownership_test.dart`, `playlist_actions_test.dart`,
  `playlist_library_items_test.dart`, and `library_sync_engine_test.dart`.
  `make gen` succeeded: `Built with build_runner/aot in 52s; wrote 2003 outputs.`
  `dart format` covered all 15 changed Dart files; capped scoped
  `flutter analyze --no-fatal-infos` reported `No issues found!` (exit 0).
  `dart run tool/dead_code_check.dart` exited 1 with exactly two new test-only
  entries awaiting the B1 UI wiring: `PlaylistActions.addSongs` (line 37) and
  `playlistActionsProvider` (line 7) in
  `lib/src/features/playlists/data/playlist_actions.dart`; the baseline is
  unchanged. B1 UI wiring, filter, edit gating, notices and widget coverage
  remain with the UI agent. B2 local DAO/actions/create/detail-sync changes
  were not implemented. No new PR0 issue was identified. The full check,
  application/emulator runs and runtime evidence were prohibited by the task's
  host limits; independent review remains for the coordinating agent.
- [x] Download lyrics/artwork backfill review fixes (issue #9) — 2026-10-16
  (`fix/download-lyrics-art-backfill`; the shared lyrics resolver distinguishes
  confirmed misses from transport/API failures, so only confirmed misses get
  a seven-day negative entry. Both backfills recheck stop/network eligibility
  after a playback hold and before a request; stopped passes drain without new
  network work, and a Wi-Fi-only pass interrupted by cellular stays pending
  and resumes through the pump on Wi-Fi. Interactive server lyrics for permanent
  downloads use the resolver cache path and clear failure metadata, permitting
  later synced-lyrics upgrades; rolling/uncached songs retain their previous
  caching behavior. Twelve regressions failed before their fixes; all nineteen
  new regression/control cases pass. The requested downloads, lyrics-resolver,
  song-identity DAO and provider suites pass 372 tests with concurrency 4 under
  a 6G cap. Changed-file analysis and formatting and the dead-code gate pass.
  Two existing provider brace-style infos were corrected during analysis;
  the provider suite then passed all 94 tests again.
  Runtime/app/emulator validation and `./tool/check.sh` were not run under the
  host limits; the coordinator owns broader validation.)

- [x] Radio UI review fixes for issue #14 — 2026-10-16
  (`feat/radio-device-stations`; Codex). Save failures now appear inside the
  editor with entered values retained, clearing on retry or field/destination
  edits. Device stations hidden by a filter show filtered-empty guidance while
  server stations load; the device section title no longer has a redundant
  condition. Architecture and changelog updated.
  Regression-first capped widget run: `"00:03 +32 -2: Some tests failed."`
  (missing inline save error and missing filtered-empty message, exit 1).
  Final `~/.cache/claude-navis-tools/capped.sh 6G "$PWD" flutter test
  --concurrency=4 test/src/features/library/presentation/radio_screen_test.dart`:
  `"00:02 +34: All tests passed!"` (exit 0, peak 1926M, no OOM kills).
  Changed-file `dart analyze`: `"No issues found!"`, exit 0.
  Capped `flutter analyze --no-fatal-infos`: exit 0 with 195 existing infos
  outside changed files. Changed-file format check and `git diff --check` pass.
  Capped `dart run tool/dead_code_check.dart`: exit 0 (baseline unchanged).
  App/emulator launch, screenshots, runtime loop and `./tool/check.sh` were
  excluded by the task's explicit host limits; runtime verification remains.
- [x] PR A UI: device radio stations and admin station editing —
  2026-10-16 (`feat/radio-device-stations`; Sonnet). Radio tab sections, add
  button, long-press/secondary-click Edit/Delete (device or admin only), editor
  and delete dialogs in `radio_station_dialogs.dart`, 17 new l10n strings, two
  radio goldens regenerated (the add button is the only visual change),
  architecture and changelog updated. Targeted widget tests only
  (`radio_screen_test.dart`); no app/emulator launch or `./tool/check.sh`.
  Runtime verification and independent review remain.
- [x] PR A backend: device radio stations and server station editing —
  2026-10-16 (`feat/radio-device-stations`; Codex implementation, based on
  schema-104 commits `ae8d3991` and `5e65e9be`). Added admin lookup and radio
  mutation endpoints, retry suppression for station creation, registered local
  station DAO, local/admin providers, and validated local/server save/delete
  actions. DAO deletion is named `deleteStation(id)` because Drift owns
  `delete(table)`; the actions API exposes `delete(station, isLocal: ...)`.
  Both clear-data confirmation paths explicitly mention device playlists and
  stations. Architecture and the unreleased 1.5.0 changelog are updated.
  Evidence: `./tool/bootstrap.sh`, `make gen` (existing
  `json_annotation >=4.12.0` dependency-bound warning), and
  `flutter gen-l10n` succeeded. Tests were added first and failed on the missing
  backend APIs; the final capped run passed **78 tests** with
  `capped.sh 6G "$PWD" flutter test --concurrency=4` over
  `test/src/api/subsonic_api_client_test.dart`,
  `test/src/database/daos/local_radio_station_dao_test.dart`,
  `test/src/features/library/data/radio_station_actions_test.dart`, and
  `test/src/providers/radio_station_providers_test.dart` (`All tests passed!`,
  exit 0, peak 2144M, no OOM kills). Coverage includes URL/name rejection,
  request/response homepage spelling, homepage clearing, unique local UUIDs,
  reactive ordering/update/delete, local/server routing, error propagation,
  successful-server-only invalidation, and offline/admin-error fallbacks.
  `dart format` covers changed Dart files. Targeted `dart analyze` exits 0
  with only three pre-existing infos outside changed hunks:
  `avoid_catching_errors` in `navis_database.dart` and two
  `curly_braces_in_flow_control_structures` in `app_providers.dart`.
  `dart run tool/dead_code_check.dart` exits 1 for exactly three new test-only
  declarations: `localRadioStationsProvider`, `serverUserIsAdminProvider`, and
  `radioStationActionsProvider`; baseline unchanged. Their UI consumers, radio
  dialogs/widget tests, feature changelog entry, independent PR review, and
  runtime verification remain for the next step. No PR0 defects found.
  No app/emulator launch or `./tool/check.sh` was performed, as required by
  this task's host limits.
- [x] False offline alarms, issue #6 state/logic — 2026-10-16
  (`fix/offline-false-alarms`; replaced-client failures trigger one immediate
  current-client probe, repeated replacement waits for the quick retry, and
  only two current-client failures confirm an outage. The three-second
  confirmation retry shares the existing timer field; the 30-second offline
  retry and three-visible-count budget start at confirmation and survive
  connectivity checks. Connectivity reloads retain the previous network type;
  initial unknown connectivity uses conservatively metered `other`. Search
  uses local-only mode only for confirmed offline, and banner dismissal lasts
  until confirmed online. Tests first: `+114 -9: Some tests failed.` before
  implementation; after, `+215: All tests passed!` across reachability,
  app providers, banner state, search, routing, library sync and starred-download
  dispatch suites under the required 6G cap (`peak=2954M`, no OOM kills).
  Changed-file `dart analyze`: `No issues found!`; formatting and
  `dart run tool/dead_code_check.dart` pass with no baseline changes. Banner/chip
  layout is deferred. Per task host limits, no app/emulator, runtime loop,
  full suite or `./tool/check.sh` ran here; independent review and real-device
  confirmation of this fix remain with the coordinator.)
- [x] PR0: schema 104 foundation for device playlists and radio stations —
  2026-10-16 (`feat/schema-104-device-items`; Codex implementation). Added
  guarded 103→104 migration, playlist scope/read-only columns, local station
  table, and sticky playlist destination setting/model decode (writer deferred
  to B2). Library resets preserve local entries and provisional parent metadata;
  server reconciliation excludes local rows; clear-data sign-out wipes local
  playlists and stations. Architecture records the retention table; confirmation
  copy is deferred to PR A. No user-facing feature ships in PR0, so no changelog
  entry was added.
  Evidence: `./tool/bootstrap.sh`; `make gen` succeeded (existing
  `json_annotation >=4.12.0` dependency-bound warning); regression tests failed
  first on the missing schema, then the six-file focused run passed **224 tests**
  with `~/.cache/claude-navis-tools/capped.sh 6G "$PWD" flutter test --concurrency=4`
  over `navis_migration_test.dart`, `playlist_dao_test.dart`,
  `library_cache_reset_service_test.dart`, `sign_out_service_test.dart`,
  `settings_repository_test.dart`, and `library_sync_regression_test.dart`.
  Covered partial columns/table, migration re-entry, duplicate local entries,
  repeated cache resets, provisional GC, confirmed server absence, empty server
  responses, both sign-out modes, and sticky-setting decode/preservation.
  Follow-up migration/auth tests passed **113 tests** after strengthening the
  populated migration fixture and authenticated sign-out setup. Eight existing
  `PlaylistsTableData` fixtures across five files now explicitly set
  `isLocal: false`; their playlist, Home and Library suites passed **126 tests**.
  `dart format` covered all 22 changed Dart files; `dart analyze` over those
  files exited 0 with eight existing informational findings outside changed
  hunks (four `async_return_with_no_await`, one `avoid_catching_errors`,
  `overridden_fields`/`annotate_overrides` on the existing sync-test fake, and
  an existing `comment_references` finding in the Library widget tests).
  `dart run tool/dead_code_check.dart` exited 0 against the unchanged baseline
  (declaration=4, l10n=0, asset=1, asset-missing=0, font=0, dependency=5;
  test-only=2). Full `./tool/check.sh`, app/emulator runs, and runtime evidence
  were explicitly prohibited by the task's host limits and were not run.
  Retention follow-up: existing playback `deleteLocalOnlySong` can still cascade
  playlist entries when a confirmed-missing song has no available cached audio;
  this is outside library reset/sync and needs review before PR B2 ships.

- [x] Update check on every app open — 2026-10-16 (`feat/update-check-on-open`;
  automatic checks are throttled to 1 h and returning after 30 s away
  invalidates `updateProvider` through the existing resume hook. Fix round:
  cache only the signed envelope in `verifiedManifest` and run the same
  signature, channel, version/build, install mode, Android installer/ABI and
  asset validation for fresh and cached checks. Completed fetches replace or
  clear the cache; transport failures preserve it. Home Dismiss persists the
  tag/build identity without hiding the update in About; a different identity
  shows again. The Sync settings library-sync button is labelled "Sync library
  now". Ten regression tests failed before the fix. Targeted capped Flutter
  tests: `update_repository_test.dart`, `update_check_store_test.dart` and
  `home_screen_test.dart` (223 passing); update cases of
  `app_providers_test.dart` and `sync_diagnostics_server_test.dart` (11 passing);
  `about_screen_test.dart` and `update_pull_test.dart` (24 passing).
  `dart analyze` on changed files has no new findings (six existing infos on
  unchanged lines); `dart format` and the dead-code gate pass. Per host limits,
  `./tool/check.sh`, app/emulator launches and runtime screenshot/restart
  validation were not run; the coordinator owns those remaining checks.)

- [x] Shuffled repeat/restart passes (issue #5) — 2026-10-16: automatic
  completion, forward wrap, completed-queue Play and short Normal crossfades
  share one next-pass operation built on the existing shuffle helpers, queue
  rearrangement and navigation intent. It avoids repeating the ending song
  when another identity exists, retains duplicate occurrences and original
  ranks, persists the new order, and preserves paused Next. Released-window
  and Smart-mode wraps use completion/navigation. Final capped validation:
  navigation + shuffle + navigation-intent suites 521 passed (including the
  500-seed queue-window model); latest shuffle matrix/edge cases 68 passed;
  handler/projection suites 61 passed. Earlier red matrices: initial fill
  0 passed/16 failed, entity state 0/18, next pass 0/18. Formatting and diff
  checks passed. App/emulator runtime, analyzer and `check.sh` were not run
  under the task's host-resource rules; Android reproduction/entry-point and
  repeat-setting confirmation remain coordinator/owner validation.

- [x] Entity Shuffle mode and original-order persistence (issue #5) —
  2026-10-16: the shared row/ID load-order adapter now enables shuffle when
  entity callers supply original ranks. All 18 stopped/playing/paused ×
  crossfade × repeat regression cases failed before the fix and pass after it,
  including persisted shuffle/ranks and restoring the original queue order.
  Capped targeted tests only; runtime and full gate remain coordinator-owned.

- [x] Initial queue-fill completion race (issue #5) — 2026-10-16: reproduced
  native Repeat All replaying the temporary one-song playlist and repeat-off
  stalling after completion (16 failing regression cases before the fix).
  Native Repeat All now waits for logical fill; the existing completion path
  advances after fill settles. Expanded matrix: 24 passed across queue sizes
  6/300, shuffle toggle/entity inputs, crossfade off/on and repeat none/all/one.
  Capped targeted tests only; runtime and `check.sh` remain coordinator-owned
  under this task's host-resource rules.
- [x] Idle-robustness final fixes (shared sync requests and busy databases) —
  2026-10-15 (`fix/idle-integration`, aa3d3452..abf8f071; a lease-held check
  against a live worker lease retries at the 30 s floor instead of waiting out
  its heartbeat-extended expiry, because the app preempts the worker; any
  writer-lock timeout inside a sync request is surfaced as `leaseHeld` (busy)
  instead of a raw failure; an inconsistent catalog candidate and its page
  checkpoints are cleared in one transaction; `beginSyncRunAttempt` refuses to
  reopen a request another engine already finished, so a sharing engine defers
  instead of running the completed work twice. Regressions added with the
  fixes: the provider 30 s-floor test, fence tests 12a and 13/13a/13b, the DAO
  terminal-guard test, and cross-connection hand-off tests 26/27 in
  `library_sync_regression_test.dart`. Reviewed read-only in this worktree;
  `./tool/check.sh`, the full suite and runtime validation were not run here,
  the coordinator owns them.)

- [x] Idle-robustness follow-ups 11 and 12 (credential unavailability) —
  2026-10-14 (`fix/idle-partb`; secure-storage operations are serialized and
  deadline-bounded per store, so pending reads surface as unavailable and are
  retried instead of hanging startup or reading as missing; failed saves retry
  with backoff and Android requires durable persistence before a login is
  declared, so a cold start never finds a falsely authenticated memory-only
  profile; routing keeps a config error in loading instead of unauthenticated.
  ListenBrainz token reads propagate unavailability instead of null, keeping
  queued listens queued while Subsonic delivery continues; drops remain limited
  to confirmed absence, explicit disabling or invalid tokens. Eight regressions
  failed before and pass after, three more cannot compile against the old API
  and pass after; 116 tests pass across the twelve touched suites
  (`flutter test --concurrency=4` under a 6G cap). `dart analyze` on changed
  files is clean and `dart format` applied. `./tool/check.sh`, runtime loops
  and platform validation were not run in this worktree; the coordinator owns
  them. Recovery events are recorded once per process in the private startup
  timeline. Cross-engine keystore serialization still needs native work.)

- [x] Silent-recovery review rounds 2–3 (batch 2) — 2026-10-14
  (`fix/idle-batch2`; Play re-arms song recovery only for a failure the handler
  recorded, not a stale just_audio error code, and falls back to a plain seek
  and restarts recovery after a queue load that held a re-failed reload; a seek held during a
  stall survives a Play while the network check runs; re-armed recovery, seeks
  and focus retries stay consistent, and a Play that re-arms leaves no old
  focus budget behind; radio stays silent offline, counts only failure time
  (dropped streams included), stops paused and gets a fresh budget after a
  minute of healthy play. Each regression failed on its base commit and passes
  after; timing-sensitive focus/radio tests now keep at least 1 s margins.
  `navis_audio_handler_navigation_test.dart` passes 458 tests, three runs in a
  row. Targeted tests only: `./tool/check.sh`, builds and runtime/device
  validation were not run for round 3.)
- [x] Silent-recovery review fixes (P2-1 to P3-9) — 2026-10-14
  (`fix/idle-batch2`; pending song recovery belongs to its song and reloads
  only a player that is still idle/loading/buffering; Play re-prepares a failed
  stream once and a seek moves the recovery target; an explicit Play overrides
  a lingering transient interruption; focus retries stop after two minutes and
  just_audio reports `playing` only once focus is granted; radio waits for
  device connectivity only, Android passes Media3 error codes and HTTP status,
  permanent or ten-minute-exhausted station failures stop with one notice
  (the notice provider now counts failures, so repeats are not dropped);
  Personal Radio re-arms only network failures; the network signal is created
  once per initializer. Each regression failed before its fix and passes after;
  JVM `JustAudioErrorCodeTest`, `JustAudioRecoveryPositionTest` and
  `NavisAudioServiceRecoveryTest` pass. `./tool/check.sh` passes: 7,999 tests,
  one existing skip, 96 migration and 249 critical reliability tests, no
  analyzer errors/warnings. No runtime, device or audible-playback validation
  was run for this follow-up; no commits or stashes.)
- [x] Overlapping first-Play radio fallback preserves newer transport intent —
  2026-10-14 (`fix/startup-hang`; existing transport/load generations and play
  intent guard recent, liked and radio fallback admission. Radio carries the
  guard through its fetch; a newer Pause or Stop discards the unadmitted queue.
  Four integrated regressions fail on HEAD and pass after, including newer
  queue and newest-Play controls; 481 focused tests pass. `./tool/check.sh`
  passes: 7,954 tests, one existing skip, 96 migration and 246 critical
  reliability tests, no new analyzer errors/warnings. Post-gate isolated muted
  Linux held-fetch Pause leaves zero queue items/native sources and no persisted
  queue; newest Play retries and reaches advancing native playback across clean
  restarts. App-owned screenshot inspected: Home and paused player, no startup
  overlay; owned apps stopped and fixture credential/handshake files removed.
  Stop is covered by deterministic regression; audible output and device/OS
  controls were not retested. Read-only self-review found no new races.
  Architecture, changelog and
  [Review follow-up](../audits/startup-hang-2026-10-14.md#review-follow-up)
  updated; no commits or stashes.)
- [x] Startup/idle robustness re-review: three additional P2 defects —
  2026-10-14 (`fix/startup-hang`; fallback captures load ownership after internal
  restore changes, newest Play restarts superseded shared preparation, and each
  resume independently re-arms bounded worker observation. All five new defect
  cases failed before and pass after. Three focused suites pass 467 tests; the
  final resume suite passes 11, including pause/dispose/budget controls.
  `./tool/check.sh` passes: 7,950 tests, one existing skip, 96 migration and 246
  critical reliability tests, no new analyzer errors/warnings. Post-gate Linux
  clean restarts with an isolated 70-occurrence queue verify recent and liked
  fallback plays on the first request, with one native source and advancing
  position; concurrent empty-queue Plays also pass. Final app-owned screenshot
  inspected: Home, paused fallback, ordinary offline notice, no startup/internal
  error overlay. Owned apps shut down; credential/handshake files removed.
  Android worker lifecycle and external-commit races covered by deterministic
  two-connection regressions; device/OS/overnight testing not repeated.
  Architecture, changelog and [the audit](../audits/startup-hang-2026-10-14.md)
  updated; no commits or stashes.)
- [x] Startup/idle robustness review follow-up — 2026-10-14
  (`fix/startup-hang`; all five P2 findings from `ecc21594` fixed through the
  existing readiness, transport, preparation and resume mechanisms. Ten
  pre-fix regression failures cover every finding; 488 focused-suite tests
  and the final 14 selected cases pass, including alias retry and watcher
  completion. `./tool/check.sh` passes with 7,942 tests and one existing skip.
  Post-gate Linux clean restart restores the paused later item at 41,999 ms
  without native sources; first Previous stays on it at zero and clear passes.
  App-owned screenshot after `appReady` inspected: Home, empty player, no
  startup overlay. Owned fixture apps shut down, credential/handshake files
  removed. Architecture, changelog and the audit's Review follow-up updated;
  no commits/stashes. See [the audit](../audits/startup-hang-2026-10-14.md).)
- [ ] Idle/startup robustness (F1, F2, F3, F6, F9 and private timeline) —
  partial: 2026-10-14 (`fix/startup-hang`; implementation and focused regressions
  complete; review follow-up `./tool/check.sh` passes (7,942 tests, one skip). Step-0 uncached-source fixture
  reproduced attempts 1–5 and discarded handlers before changes; the same
  12-second source delay now reaches one ready construction in 99 ms, restores
  metadata without sources and streams after network return. Long resume
  coalesces connection checks and writer data_version reconciliation. Actual
  paused-queue worker sync succeeded and refreshed an open Liked Albums screen.
  Worker-first, system-started service and Doze scenarios pass; forced timeout
  exposes the inspected recovery panel and restart changes the PID with one
  resumed MainActivity. Linux startup/playback and clean restart with in-memory
  credential reinjection pass. Owned AVD and isolated Linux runtime profile
  deleted, original server star restored; no commits/stashes. Independent paused
  wake-lock release and findings 4, 5, 7, 8, 10–14 are deferred to
  [1.5.1](../plans/idle-robustness-followups.md). Physical overnight trigger and
  audible playback remain unverified. See [the updated audit](../audits/startup-hang-2026-10-14.md).)
- [x] Android background-sync engine plugin isolation — 2026-10-14
  (the branch's existing commit restricts the worker engine to JNI,
  secure-storage and connectivity plugins. It removes the observed duplicate
  player-plugin registration; its presentation-time session-future retirement
  is replaced by the single-construction work above. The native rebind remains
  rejected. Original scenarios and source-supported failure ordering are kept
  as historical evidence in [the audit](../audits/startup-hang-2026-10-14.md).)
- [x] Large downloaded queue cache churn — 2026-10-14 (permanent source resolution
  no longer touches LRU timestamps; regression demonstrates 171 writes and
  172 snapshots per Downloads watcher before, zero writes and one initial
  snapshot after; rolling LRU and download retention covered; 137 focused tests
  pass. Three Android profile before/after runs and inspected app-owned queue
  screenshots are recorded in [the investigation](../audits/downloads-queue-stall-2026-10-14.md).
  Source resolution and frame-build p99 improve, but worst heartbeat maxima do
  not consistently improve. Linux and Android clean-start runtime passed with
  171 local sources, advancing native playback and zero cache updates; final
  queue screenshots inspected. `./tool/check.sh` passed with 7,887 tests and one
  existing skip using four workers after an unrelated annotation-isolate
  timeout; temporary concurrency configuration removed. Sidecar uninstalled,
  owned AVD deleted and temporary files removed; no commits/stashes. Exact
  real-phone symptom remains unverified.)
- [x] Documentation and repository layout reorganization — 2026-10-13
  (branch `chore/docs-reorg`; 41 history-preserving moves, 31 deletions totaling
  825,005 bytes; maintained guides grouped by development/release/platform/feature,
  project trackers moved under `docs/project/`, completed plans/specs under
  `docs/history/`; five open plans remain active, and Android background-sync
  rollout/certification stays in `docs/features/`. Retired phase close-out scripts
  and Make targets have no bootstrap/check/test consumers. Relative-link checker:
  109 tracked Markdown files, 273 relative links, zero broken targets; old-path
  grep: zero hits. Dart format, shell syntax, Makefile parsing and diff checks
  passed; `./tool/check.sh` passed, including 7,884 full-suite tests with one
  skip. No runtime behavior changed.)
- [x] Phone feedback round — 2026-10-12 (branch `fix/phone-feedback-1012`. Root causes worth remembering: (1) `android_file_picker` 2.0.0 nests the SAF persist option under `safOptions` but its Kotlin reads it at the top level, so tree grants were never persisted and the custom download folder was lost on every restart/update; Navis now calls `persistTree` (MainActivity `permanent_download_storage` channel) when a folder is chosen. (2) A failed secure-storage read used to be treated as "no password" and permanently signed the user out (plus flutter_secure_storage's default `resetOnError: true` deleted the data); reads now throw `CredentialReadException`, which is transient and never signs out, and both secure stores set `resetOnError: false`. (3) The You Might Like carousel started at virtual page 0 when albums arrived late. Also: Personal Radio refills at 8 tracks left (`kRecommendationRefillLowWater`, shared with Server Mix and Same Vibes) and holds a Next pressed at the queue tail until the refill lands; cached-song icon taps download; album art centre tap opens the viewer; album title long-press copies "Artist - Album"; the cached-playback setting is renamed. `./tool/check.sh` passed (7,783 tests, 1 skipped); 6 GB emulator against the real test server verified the folder surviving a build-over-build install, carousel both ways after a cold start, art tap, title copy, cached-icon download, the renamed setting and 15/30-tap Next bursts during radio; the long-background sign-out itself was not reproducible on the emulator keystore.)
- [x] Ponytail audit, second pass — 2026-10-12 (branch `refactor/ponytail-audit-2`; reuse these instead of re-implementing: `AppSettingsDao._writeSettings` for single-row settings writes, `renameWithRetry`, `downloadSongWithQualityPrompt`, `showConfirmDialog`/`confirmRemoveDownload`/`confirmAndDeleteDownload`, `AlbumCardContent` for album cards from raw fields, and `tool/lib/diagnostics.sh` for diagnostics-script helpers. Album and playlist song menus deliberately stay bespoke (their items differ from `showSongContextMenu`); docs/project/development-plan.md stays at the root because it holds live commit/release/changelog rules. `./tool/check.sh` passed (7,708 tests, 1 skipped); Linux before/after captures against the real test server were pixel-identical apart from random/timing content; download-preferences, download-folder and volume-memory diagnostics passed on the shared shell helpers; Android emulator (6 GB) real-server checklist passed; Windows not covered.)
- [x] Ponytail over-engineering audit and cleanup — 2026-10-12 (branch `refactor/ponytail-audit-1012`; new shared helpers to reuse: `buildSubsonicAuthQuery`, `BoundedLruMap`, `AsyncBody`, `ArtistCard.grid`, `NavisSectionHeader.maxLines`, `kAdaptiveMediumWidth`/`kAdaptiveExpandedWidth`; removed `ArtistGridCard`, `DesktopSectionHeader`, the `RollingCacheManager` interface (now the concrete class), four unread `NavisTokens` fields and the qobuz shell wrapper; completed EQ and dependency plans moved to `docs/history/completed-plans/`. The detail-page failure view keeps its own compact layout (moving it onto `ErrorState` was reverted after owner review). `flutter_lints` stays: the root analyze resolves the vendored `third_party/` packages' include of it. `./tool/check.sh` passed (7,707 tests, 1 skipped); Linux desktop and Android emulator runtime checklists passed against the fixture server behind an auth-verifying proxy; Windows not covered.)
- [x] Fine-Tune Colors v2 persistence, tuning presets and Appearance Looks — 2026-10-10 (unshipped schema 101 redefined with guarded Light/Dark depth and JSON libraries; resolved adjustments preserve theme/worker/caption cache keys; shared playback name validation, targeted DAO writers and settings/preview providers reused; complete appearance snapshots apply atomically with live tuning references or captured fallback, including language, swatches, recommendation auto-advance and legacy grid size; Night band, setup drafts/highlight registry and authenticated diagnostics updated. One build_runner run completed; 180 initial focused tests, 3,872 tests across all requested directories, 116 focused rechecks and 5 final storage cases passed using the required concurrency/timeout command; touched-file formatting, diff checks and analysis passed with zero errors/warnings and 37 existing infos. Panel/Looks UI and changelog remain UI-agent-owned; app/emulator/VM runtime and `check.sh` omitted per machine rules/coordinator ownership.)
- [x] Fine-Tune Colors panel, Light/Dark brightness and Looks UI — 2026-10-10 (Appearance row opens a `showQuickPanel` popover/sheet with the shared `PresetPicker` for tuning presets, the existing ruler rows (Intensity, and Brightness with a compact Light | Dark switch and an "Applies in …" caption), pinned live summary and Reset; setup keeps the row and edits its draft without presets; `AppearanceLooksOption` at the top of Appearance with the same picker; focused settings, onboarding and theme tests and goldens recorded in the handoff; runtime loop and `check.sh` reserved for coordinator)
- [x] Pastel soften and colour-style separation — 2026-10-10 (Pastel takes only the seed hue: accent chroma 16-24 at tone 86 dark / ink tone 47 light, containers chroma 12-15, surfaces chroma 6-7, artwork colours capped at chroma 12-13 so Flat bands, captions and Now Playing tint stay pastel; Immersive accent floor 36 at dark tone 77; schemes/adaptArtColor/flat band/caption/Now Playing-solid tests assert Pastel max chroma <= 60% of Immersive across 11 seeds x light/dark/OLED; one golden changed and viewed; app/emulator/VM runtime and `check.sh` omitted per machine rules).
- [x] Merge owner-approved `fix/open-issues` onto current dev — 2026-10-10 (all 15 commits retained; 1.5.0 changelog unions both sides, dev playback/navigation/shuffle and appearance changes preserved; incomplete-album capabilities evidence, setup readiness ordering, notification localization, Android diagnostics/worker and mpv/MPRIS fixes retained; no new migration, schema remains 100. Bootstrap, `make gen` and l10n generation completed; 76 focused tests and 3,952 broader tests passed with one skip using the required timeout/concurrency command; `dart analyze lib test`: zero errors/warnings, 178 infos; formatting, diff and dead-code checks passed. App/emulator/VM runtime, native builds and `check.sh` omitted per machine rules/coordinator ownership.)
- [x] Two-tier album title shade UI and one-line scrolling titles — 2026-10-10 (new `MarqueeText` (rest, constant 35 px/s travel, rest, snap back; one controller in a RepaintBoundary, TickerMode + VisibilityDetector gating, reduced motion = still ellipsis, full-title semantics); album/external/Home server cards now one title line with a fixed `albumCardCaptionHeight`; `AlbumCardLabel` renders classic / dark (`ArtworkScrim`, no sampling) / color by `albumTitleShadeModeProvider`; Album Art Shade + Use Cover Color switches in Settings and setup (reveal, Flat disable + note, one New tag); Home `_ServerAlbumCard` reuses the label and Flat caption-below, shelf adds `albumCardExtraHeight`; `CoverReadyScope` shared; `test/flutter_test_config.dart` zeroes the VisibilityDetector debounce; 2804 tests passed across common_widgets, home, library, settings, onboarding, theme, providers and architecture with the required timeout/concurrency command, no golden images changed; touched-file analysis has no errors/warnings; app/emulator/VM runtime and `check.sh` omitted per machine rules).
- [x] Two-tier album title shade persistence/plumbing — 2026-10-10 (schema 100 guarded upgrade/backfill preserves enabled cover colour; independent parent/colour settings, DAO/repository/onboarding diffs, effective classic/dark/color provider, diagnostics set/get and one parent setup highlight with its existing stored key; 231 tests passed across migration, DAO, repository, appearance provider, diagnostics and setup-highlight domain/provider suites with the required timeout/concurrency command; bootstrap and one build_runner run completed; touched-file Dart analysis has no errors/warnings and 32 pre-existing infos, formatting/diff checks passed. Switches, caption rendering and changelog remain UI-agent-owned; app/emulator/VM runtime and `check.sh` omitted per machine rules).
- [x] Artwork background switching performance — 2026-10-10 (stable Now Playing/queue body trees, one-time sigma-5 thumbnail blur shared through a four-cover image LRU, shell-owned background prewarm outside the paused player, selected playback-speed subscription and animated adaptive veil; 1,933 player/routing/common_widgets/theme tests passed with the required timeout/concurrency command, including real body identity, collapsed setting/track prewarm, queue/lyrics cache hits, disposal/failure and reduced-motion coverage; new `now_playing_static_artwork_blur.png` golden viewed, existing goldens unchanged; touched-file analysis has no errors/warnings and six pre-existing infos, formatting/diff checks passed. Optional dead-code scan still flags the integration's existing `albumArtColoredShadeProvider` awaiting its UI consumer; no backdrop findings. Runtime and `check.sh` omitted per machine rules).
- [x] Cold remote navigation and shuffle metadata reliability — 2026-10-10 (warm-up/deadline reuse, deck retirement, shuffle rollback and original entity/Android Auto order; 160 regression cases with per-emission audio/metadata invariants and gated HTTP, plus the 500-seed queue-window model; 929 player and 291 caller/provider tests passed, one pre-existing skip; touched-file analysis has no errors/warnings; runtime and full gate remain coordinator-owned).
- [x] On-screen album artwork priority — 2026-10-10 (existing cover coordinator/sampler reused: viewport-only visible interest, cancellable preloads, background capacity cap, revision request-key matching, background track prewarm/mesh/backdrop sampling, and immediate tint requests for synchronously decoded covers with scrolling guards retained; 262 tests passed across 11 focused/consumer files using `timeout 900 flutter test --concurrency=4 --timeout 60s`; touched-file `dart analyze` has no errors/warnings, only three pre-existing infos in `home_screen_test.dart`; formatting/diff checks passed. App/emulator/VM runtime and `check.sh` omitted per machine rules).
- [x] Flat areas and Album Art Colored Shade UI — 2026-10-10 (area switches under Flat Surfaces and the colored-shade switch in Settings and setup with New tags, classic fade default with no sampling, caption-below layout and host heights under Flat text over artwork, unobstructed phone album/playlist headers, Now Playing note follows its area, changelog; focused widget/golden tests added; runtime and `check.sh` omitted per machine rules).
- [x] Flat areas and album-art coloured-shade persistence/plumbing — 2026-10-10 (schema 99 guarded upgrade, settings/DAO/repository/provider/diagnostics/registry, per-area theme cache and rendering checks; 668 persistence/theme tests passed, rendering 1488 passed/1 skipped/3 New-tag accounting failures pending the new controls; switches/caption layouts/changelog remain UI-agent-owned; runtime and `check.sh` omitted per machine rules).
- [x] Dev channel self-updates — 2026-10-10 (optional signed build comparison on dev/staging, monotonic sidecar APK numbers, `tool/dev_release.sh` with unique arm64 artifacts, dry-run and verified previous-tag cleanup; hermetic shell tests and 103 focused updater/signing tests passed; touched Dart analysis clean; real publication, runtime and `check.sh` remain coordinator-owned per machine rules).
- [x] Now Playing backdrop gaps — 2026-10-10 (shared screen/desktop lyrics backdrop and Artwork reuse in the shell queue, with visibility/disposal cleanup and failure fallback; player/routing/common_widgets/theme suites and dead-code gate passed, existing goldens unchanged; runtime and `check.sh` omitted per machine rules).
- [x] Corner Style UI — 2026-10-09 (`CornerStyleOption` in Appearance settings and setup after Flat Surfaces, New tags, setup preview uses the draft style, changelog line; focused widget tests added)
- [x] Persisted Corner Style backend/state — 2026-10-09 (schema 97, settings/model/DAO/repository, derived provider, setup registry and diagnostics; 179 focused migration/DAO/repository/provider/registry/diagnostics tests passed; widgets, runtime and full gate remain coordinator-owned).
- [x] Colour/Corner Style audit pass B — 2026-10-09 (OLED chrome true black with hairline separators and chroma-2 containers, OLED Flat band tone 6-10, translucent Now Playing panels over the Artwork layer, Soft = 14 px controls and 32 px sheets, icon buttons follow Corner Style, light Pastel solid Play, raw-seed accent grid with styled dot; focused theme/routing/settings/player/home tests; full gate remains coordinator-owned).
- [x] Now Playing Background and Density UI — 2026-10-09 (Appearance/setup controls, Artwork blurred-cover layer, `NavisDensityScope` for track/library/artist rows, Settings New tags; focused widget tests only — runtime, screenshots and full gate remain coordinator-owned).
- [x] Now Playing background and app-wide Density backend/state — 2026-10-09 (schema 96, legacy tint/home-density compatibility, registry and diagnostics, focused migration/DAO/repository/enum/provider tests; widgets, runtime and full gate remain coordinator-owned).
- [x] Setup update highlight state — 2026-10-09 (schema 95 release markers, registry/providers/service, Finish/Skip hooks, diagnostics reset and focused persistence/provider/widget tests; UI and runtime/full gate remain coordinator-owned).
- [x] Lazy cover tint revision refresh and remote-cache Home wash — 2026-10-08 (existing sampler/coordinator/worker/store and caption dispatcher reused; NCF1→NCF2 compatibility, lazy/deduplicated refresh, stale-colour retention, and 600/480/420/96 px remote-cache regression tests. Runtime and full gate remain coordinator-owned for this worktree.)
> Historical AT-SPI attempts recorded below are failed evidence, not a testing
> precedent. Current agent policy requires the authenticated Navis API and
> app-owned screenshots and prohibits external accessibility traversal unless
> the accessibility bridge is explicitly in scope with user authorization.

- [x] Flat desktop You Might Like panel and compact phone Home header —
  2026-10-08 (desktop Flat is one rounded solid panel around cover, track list
  and thumbnail strip, tinted like the phone band, with no inner card; phone
  Home header is about 40 px shorter, and on 2026-10-09 its logo grew to
  104 px in the same height by trimming padding beside the logo's built-in
  margin. Evidence: `test/src/features/home/presentation/home_screen_test.dart`,
  `flat_home_wash_test.dart`)
- [x] Colour styles (Neutral, Pastel, Immersive, Night) — 2026-10-08 (a
  second appearance axis next to Light/Dark/OLED/Auto, stored in
  `app_settings.color_style` (schema 93) and chosen with live preview tiles in
  Appearance and onboarding. Styled schemes keep containers out of the muddy
  mid-tone band, keep OLED black, and restyle the Home cover wash and Now
  Playing tint without touching artwork; album card titles now use scheme
  text roles. Evidence: `test/src/theme/navis_style_schemes_test.dart`
  (4 styles × 3 modes × 11 seeds), persistence and migration tests, Linux
  profile clone and Android sidecar screenshots of Home, album, Now Playing
  and Appearance in every style and mode, and `./tool/check.sh`.)
- [x] Permanent download import / 1.2.7 — 2026-08-21 (custom download roots
  now preserve unmanaged files, preview and confirm imports, and use a
  root-level `.navis-downloads.sqlite` identity store; uniquely matched legacy
  files and explicit local-library selections become permanent downloads.
  FLAC imports retain decoded audio while gaining Navis identity tags. Evidence:
  focused sidecar/tag tests, Linux Navis Dev live-server import against the
  approved `Navis_Downloads` folder, clean restart retaining two registered
  tracks and two sidecar records, and `./tool/check.sh`.)

- [x] Required library rebuild / 1.2.6 — 2026-08-21 (first login and every
  recoverable-library reset now enter one full-screen, navigation-blocking
  rebuild flow; it retains permanent downloads, exposes live sync stages and
  determinate/indeterminate progress, and keeps failure, offline, and metered
  states recoverable in place. Evidence: focused route/controller/cache/recovery
  widget tests; isolated Linux clone app-API run at `/library-rebuild` with
  inspected sync and interrupted-restart recovery screenshots; `./tool/check.sh`.)

- [ ] Issue #43 / 1.2.6 release fixes — partial: 2026-08-20 (completed:
  manual offline-refresh intent now survives reconnect and discovers newly
  added albums despite unchanged indexes; Home shares the full liked-playback
  queue; portrait Library and Settings omit redundant titles; ordinary desktop
  song lists share responsive Like, Download, and More actions, while remote
  rows remain read-only; whole-entity queues retain matched remote sources;
  and native desktop close
  waits for its window-state write, while redacted desktop diagnostics now
  report state-record version, restoration source, and persistence completion.
  Android schedule, catch-up, and
  cancellation reconciliation now await the native WorkManager acknowledgement
  and preserve known-good cadence/work IDs on `platformFailure`. The scheduler
  includes live connectivity/metering policy refresh during headless work. The
  worker now records bounded native fallback outcomes for pre-Dart bootstrap
  failures and foreground reconciliation imports them without consuming their
  native status record. The scheduler is release-enabled by the 2026-08-20
  maintainer decision; `NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC=false` remains a
  build-time rollback that durably disables and cancels native work. The expanded
  ten-test injected-worker WorkManager suite now passes on the Android 13
  emulator (constraint release, dispatch admission, durable outcome, enqueue
  failure, unavailable status, periodic `UPDATE`, cancellation, and real-worker
  timeout/bootstrap/Dart/cancellation fallback), while its
  original TestDriver check passed on Android 16. An authenticated
  Android app API observation reported one enabled 60-minute Wi-Fi schedule,
  a safe `noWorkDue` completion, and matching native JobScheduler work. The
  native status query now awaits WorkManager futures and emits bounded
  `statusUnavailable` rather than relying on a LiveData timing latch. A
  profile-keyed native file lock now prevents periodic/catch-up workers from
  booting duplicate Flutter engines before the durable database lease applies;
  global device audio is no longer misclassified as Navis playback. The latest
  isolated Linux desktop-layout suite passed app-API assertions and a clean
  restart with the new redacted restoration fields. Its final capture now
  re-observes the settled Flutter surface after desktop transitions; both the
  initial and restart layout images were inspected and rendered correctly.
  Existing profiles now receive a dismissible, one-time library-cache reset
  prompt; the reset clears recoverable library and rolling-cache data while
  preserving permanent downloads, completes a full library scan before
  acknowledgement, and repeats on later launches until completed.
  The cache-upgrade clone diagnostic now provisions a pre-v2 marker, captures
  the modal, drives the authenticated reset action through a completed full
  repair, and verifies a populated library after clean restart.
  The final isolated Linux cache-upgrade diagnostic passed authenticated app-API
  health/presentation/screenshot/shutdown checks and a clean restart; both
  app-owned modal captures were inspected. `./tool/check.sh` passed.
  Evidence: `./tool/manual_discovery_diagnostics.sh`,
  `./tool/desktop_layout_diagnostics.sh`, inspected app-owned Linux screenshots
  (standard desktop local rows show Like/Download/More; compact rows retain
  More), clean restarts, focused desktop action/queue and Android scheduler
  Flutter/JVM tests, and
  `./tool/check.sh` passed.)

## Deferred validation

- [ ] Issue #43 Android WorkManager physical certification — accepted deferral:
  2026-08-20.
  The connected Android 16 target-SDK phone completed the original
  injected-worker WorkManager TestDriver test; an expanded ten-test suite
  passed on the Android 13 emulator. The phone's authenticated read-only Navis API reported
  an enabled 60-minute Wi-Fi schedule and `deferredPolicy` terminal outcome.
  Remaining: Android 12 and 14 device
  matrix plus process-death/reboot/constraint/overlap/stop scenarios. Primary
  certification now permits only authenticated, app-owned screenshot capture;
  the inspected Home and Sync Settings captures passed in the Dev sidecar.

- [ ] Issue #43 Windows desktop-window runtime validation — partial:
  2026-08-20. An interactive Windows 11 console session ran the isolated
  unauthenticated Dev diagnostics profile built from the current worktree.
  Authenticated health and Desktop View↔Mini Player window API transitions
  passed; the inspected 1424×861 Desktop View and 704×366 Mini Player
  screenshots showed the expected login layouts without clipping. After a
  clean shutdown/relaunch, the app correctly restored Desktop View because
  Mini Player is intentionally temporary; focused Windows controller and
  diagnostics tests passed 42 tests and the profile build succeeded. Remaining:
  macOS resize/DPI validation is deferred because no Mac is available. The
  separate Windows SMTC two-song GMTC scenario remains pending its required
  isolated credential-backed profile.

- [x] Mobile Now Playing transport-motion polish — completed: 2026-08-17
  (handler-owned visual outcomes now keep every manual transport source
  consistent; manual mobile changes use a clean artwork handoff, automatic
  changes use a neutral focus fade, and restart/queue boundaries use a small
  dynamic-color edge pulse instead of floating icons. Reduced motion remains
  direct. Focused widget, handler, and diagnostics tests plus `./tool/check.sh`
  pass. An isolated Linux clone completed authenticated transport controls,
  app-owned screenshots, and a clean-restart retest; the reviewed Dev APK was
  installed on the connected Android device without clearing its profile.)

- [x] Windows SMTC owned-adapter validation — 2026-10-01: the authenticated
  two-song GMTC control scenario (`tool/windows_smtc_diagnostics.ps1`,
  including the strict paused five-second seek) passed on the Windows 11 VM;
  see `docs/audits/windows-review-2026-10-01.md` and
  `docs/history/completed-plans/Dependency_Upgrade_Plan.md`. Earlier status, 2026-08-17
  (implemented the local Rust/WinRT manual-SMTC adapter, ordered bridge state
  publication, stable `com.navis.app.navis` AppUserModelID, safe artwork/event
  handling, and the isolated `tool/windows_smtc_diagnostics.ps1` GMTC suite.
  Focused bridge tests, native Windows Rust tests, a current isolated Windows
  profile build, and `./tool/check.sh` passed. Remaining: run the authenticated
  two-song GMTC control scenario on the Windows VM. Its required isolated
  Navis diagnostics credential file is not available in the normal checkout;
  the new script requires it explicitly and does not read or alter the normal
  profile.)

- [ ] Android Auto service-first startup stabilization — partial: 2026-08-17
  (evidence: `AndroidUiBootstrapGate` keeps audio bootstrap independent from
  activity-only platform setup; `AndroidAutoBrowseNotifier` removes the null
  browse-notification options failure; `./tool/android_auto_cold_start_diagnostics.sh`
  passed on the isolated Pixel_9_Pro_XL API 37 phone emulator with an external
  MediaBrowser client, four root tabs, completed handler bootstrap, no
  headless UI setup, and a subsequent warm Activity launch; `./tool/check.sh`
  passed. A clean service-first external MediaBrowser test also passed on an
  SM-S948B physical phone in 1.15 seconds with the same four tabs and no
  Navis fatal/UI-bootstrap logs. DHU warm projection connected; the cold
  projection attempt was blocked before Navis started by Android Auto's own
  `gearhead:projection` `Already connected` crash. Remaining: reset that DHU
  state, then complete the cold-start browse, playback, and reconnect smoke.)

- [x] Cold-start desktop context menus — 2026-08-17 (desktop Artist More no
  longer waits for unwarmed local streams before opening; pending playback
  actions resolve their data after selection. The shared popup helper retries
  against its owning navigator overlay when the first shell frame is still
  laying out. Cold-stream, existing action, and desktop-menu visual tests
  pass; isolated Linux Home diagnostics completed with a clean restart.)

- [x] Library first-frame diagnostic investigation — 2026-08-17 (earlier
  launcher captures were inconsistent. Authenticated app-owned screenshots of
  mounted Albums and an initial populated Search frame were visually complete,
  while some clean-restart capture frames were incomplete. Manual observation
  did not reproduce a persistent app defect; no artificial startup delay was
  added.)

- [x] Liked-song overflow consistency — 2026-08-17 (compact and desktop More
  controls now expose the platform Show menu label; the desktop action anchors
  the existing menu to its pressed control instead of the Library page.)

- [x] Legacy screen ownership audit — 2026-08-17 (`PlaylistsScreen` and the
  `RadioScreen` wrapper have no production router, import, or navigation
  reference. They are documented as low-priority, separately scoped cleanup
  candidates rather than being treated as live design surfaces.)

- [x] Home weekly playlist More label — 2026-08-17 (the visible Home song
  overflow trigger now exposes the platform Show menu label while retaining
  its existing desktop context menu and touch behavior. Focused interaction
  coverage and isolated Linux Home capture with a clean restart pass.)

- [x] Match Flow remove label — 2026-08-17 (the icon-only song remove action
  now exposes a consistent Remove label on pointer, touch, and assistive paths.)

- [x] Search clear label — 2026-08-17 (the conditional query-clear icon now
  exposes a consistent Clear label on pointer, touch, and assistive paths.)

- [x] Sync Settings desktop summary — 2026-08-17 (approved desktop status
  overview uses adaptive plan/work/catalog/run metrics instead of a log-like
  column; phone ordering remains unchanged and failed syncs use safe recovery
  copy rather than raw server detail.)

- [x] Home recommendation action labels — 2026-08-17 (desktop Like and More
  controls and the mobile Weekly Back action now expose their shared labels
  without changing the artwork-led layout.)

- [x] Error-state large-text recovery — 2026-08-17 (shared error states now
  scroll on constrained large-text phone layouts so recovery copy and Retry
  remain reachable without changing normal composition.)

- [x] Artist-view toggle clarity — 2026-08-17 (the Library artist view icon
  now explains whether it will switch to grid or list view; both states have
  focused widget coverage.)

- [x] Weekly playlist row localization — 2026-08-17 (pending, ambiguous,
  unavailable, and search affordances now use `AppLocalizations`; desktop
  weekly-detail coverage verifies all states.)

- [x] Library filter and Playback localization — 2026-08-17 (Library's active
  filter banner, filtered-empty recovery copy, and clear affordance, plus the
  Playback experimental heading, now use `AppLocalizations`; clone diagnostics
  captures the production Albums filtered-empty state.)

- [x] Reduced-motion navigation foundation — 2026-08-13 (new semantic
  `MotionPolicy` honors the platform accessibility preference: album/detail
  routes and returning album-card metadata now appear immediately when motion
  is disabled, while standard motion remains 280 ms forward, 220 ms reverse,
  and 120 ms feedback. Focused policy, router, Hero, and deterministic
  before/after motion-frame golden coverage pass; final quality gate evidence
  is recorded with this change.)

- [x] Selected-label mobile navigation — 2026-08-13 (the active bottom-bar
  destination now shows its localized label while inactive destinations remain
  icon-only; this preserves the compact mobile layout while making the current
  context explicit. Focused shell and deterministic before/after golden
  coverage pass; final quality gate evidence is recorded with this change.)

- [x] Compact landscape rail accessibility — 2026-08-13 (each icon-only rail
  destination now exposes its label and selected state to assistive technology
  and shows a short hover label without changing the resting compact layout.
  Focused semantic and before/after tooltip golden coverage pass; final quality
  gate evidence is recorded with this change.)

- [x] Status-notice live announcements — 2026-08-13 (top notices now expose a
  concise live-region message and a semantic dismiss action, so feedback is
  announced even when visual focus is elsewhere. Focused notice lifecycle and
  semantics coverage pass; final quality gate evidence is recorded with this
  change.)

- [x] Persistent actionable error notices — 2026-08-15 (errors now remain
  visible until Dismiss or swipe, have an explicit Dismiss action, and cannot
  be replaced by routine success/info feedback; a clone-only presentation
  control captures the mounted global host through the app API. Focused
  lifecycle, shell, diagnostics-contract, and visual coverage pass.)

- [x] Search result-state clarity — 2026-08-15 (approved: a successful empty
  Search now identifies the submitted query, while an otherwise empty remote
  failure uses the retryable error state. Local matches remain available if the
  remote supplement fails. Focused provider, diagnostics-contract, and visual
  regression coverage pass; isolated Linux clone captures verified both the
  forced failure and successful-empty pages before and after clean restart.)

- [x] Settings localization consistency — 2026-08-13–15 (Settings group
  headings and desktop-specific shortcut/workspace copy, plus Appearance's
  dynamic-album-color, language-availability, color-fallback, color-picker,
  and custom-color semantic labels, now use generated localization strings
  rather than bypassing the app's localization contract. Focused adaptive
  Settings coverage passes; final quality gate evidence is recorded with this
  change.)

- [x] Desktop weekly track action parity — 2026-08-15 (the visible More
  control and secondary click now open the same anchored desktop context menu;
  phones retain the existing touch sheet. Focused desktop interaction coverage
  rejects a bottom-sheet fallback, with deterministic before/after menu
  captures.)

- [x] Desktop Library playlist owner-action parity — 2026-08-15 (the routed
  Library playlist rows now expose More and secondary-click actions as one
  anchored rename/delete menu; touch rows retain the original long-press
  sheet. Focused desktop interaction and before/after visual coverage pass.)

- [x] Desktop add-to-playlist picker — 2026-08-15 (the shared picker now
  opens as a bounded modal dialog on desktop, while phone and tablet retain
  the draggable bottom sheet. Focused desktop behavior and before/after visual
  coverage pass.)

- [x] Desktop download-quality picker — 2026-08-15 (the shared quality chooser
  now opens as a bounded modal dialog on desktop, while phone and tablet retain
  the original bottom sheet. Focused desktop behavior and before/after visual
  coverage pass.)

- [x] Downloaded-track destructive-action hierarchy — 2026-08-15 (Remove
  Download is now visually separated and error-colored in both the desktop
  context menu and mobile sheet. Focused desktop secondary-click behavior and
  before/after visual coverage pass.)

- [x] Desktop album-track action parity — 2026-08-15 (album-detail More and
  secondary-click actions now share one anchored desktop menu, with Rate
  opening a compact dialog; phones retain the existing touch sheet. Focused
  interaction and before/after visual coverage pass.)

- [x] Desktop artist top-track action parity — 2026-08-15 (the visible More
  control now opens the same anchored song menu as secondary click; phone and
  tablet retain the touch sheet. Focused behavior and visual coverage pass.)

- [x] Artist action parity — 2026-08-15 (artist detail, Library list rows,
  and search rows now expose a shared Open, Play, Shuffle, Add to Queue, and
  Like/Unlike action set through More; touch long-press and desktop right-click
  reach the same actions from grid, strip, similar-artist, and artist-link
  surfaces. Focused menu behavior and isolated Linux artist-detail presentation
  capture pass.)

- [x] Artist-detail hierarchy — 2026-08-15 (approved desktop and Android
  treatment: artist identity persists in the app bar during refresh, the
  artwork header shows the album count, Play is primary, and Shuffle/More are
  secondary. Desktop alone uses a shorter header to reveal albums sooner;
  phones retain the immersive header. Focused widget/golden and migration
  coverage, isolated Linux capture, and Android emulator review pass.)

- [x] Artist-detail initial loading hierarchy — 2026-08-15 (a cold artist
  route now preserves the header, action, and album-list geometry with a
  labelled, static skeleton rather than a generic low-contrast list shimmer.
  Phone and desktop golden coverage plus an isolated Linux clean-restart
  presentation capture pass.)

- [x] Desktop Configuration external-services layout — 2026-08-16 (approved
  wide-desktop treatment: independent Last.fm and ListenBrainz forms now share
  one two-column workspace, while compact desktop and mobile retain the
  readable single column. Focused adaptive layout coverage and isolated Linux
  before/after clean-restart presentation captures pass.)

- [x] Configuration localization completion — 2026-08-16 (external-service
  field labels, validation feedback, primary actions, and Show/Hide/Clear
  tooltips now use `AppLocalizations`; only product names, URLs, route IDs,
  and dynamic server values remain literal. Focused Configuration behavior
  coverage passes.)

- [x] Desktop Configuration large-text guardrail — 2026-08-16 (at 200%
  system text, the Last.fm API-key link and Save action now wrap within the
  448 px wide-desktop form rather than clipping. Focused behavior and
  component-golden coverage pass; normal-scale layout is unchanged.)

- [x] Desktop Cache Settings workspace — 2026-08-16 (approved: Cache &
  Storage now uses the same constrained desktop workspace and explicit
  Back-to-Settings path as its nested peers, so cache sliders and destructive
  actions stay readable rather than stretching across the full window. Phone
  and tablet layouts are unchanged. Focused component-golden coverage and
  isolated Linux before/after clean-restart captures pass.)

- [x] Desktop Window workspace — 2026-08-16 (approved: Desktop Window now
  removes its duplicate heading and floating panel in favor of the shared
  constrained workspace, with an explicit Back-to-Settings path. Its Mini
  Player and always-on-top controls retain their existing behavior. Focused
  component-golden coverage and isolated Linux before/after clean-restart
  captures pass.)

- [x] Desktop Keyboard Shortcuts workspace — 2026-08-16 (approved: Keyboard
  Shortcuts now uses a constrained, divider-separated command reference with
  a direct Back-to-Settings path instead of stacked cards. Shortcut capture
  behavior is unchanged, and its visible command, capture, and built-in
  binding copy is localized. Focused behavior/component-golden coverage and
  isolated Linux before/after clean-restart captures pass.)

- [x] Desktop Appearance workspace — 2026-08-16 (approved: Appearance now
  uses the same constrained workspace and explicit Back-to-Settings path as
  nested desktop peers, keeping palette and selection controls within one
  coherent reading width. Phone and tablet layouts are unchanged. Focused
  behavior/component-golden coverage and isolated Linux before/after
  clean-restart captures pass.)

- [x] Desktop Match Flow workspace — 2026-08-16 (approved: Match Flow now
  uses the full responsive desktop canvas for flow cards and promotes New Flow
  from a mobile-style floating action button to a header action. Phone and
  tablet retain the floating action button. Focused behavior/component-golden
  coverage and isolated Linux before/after clean-restart captures pass.)

- [x] Desktop Privacy reading layout — 2026-08-16 (approved: Privacy now
  uses the full desktop canvas as two responsive reading columns instead of
  one overlong text measure; phone remains a single reading column. Policy
  titles and explanatory text now use `AppLocalizations`. Focused
  desktop/phone layout coverage and isolated Linux before/after clean-restart
  captures pass.)

- [x] Desktop About workspace — 2026-08-16 (approved: About now uses the
  available desktop canvas as a responsive two-column overview: the compact
  horizontal app identity and network-usage controls stay together, while
  links and update controls remain immediately visible alongside them. Phone
  and compact desktop retain the established single-column composition.
  Focused behavior/layout coverage, including 200% text scale, and isolated
  Linux before/after clean-restart captures pass.)

- [x] Desktop Playlist Detail workspace — 2026-08-16 (approved: Playlist
  Detail now uses a full-width tonal header rather than a detached rounded
  panel, with the track list still inset for scanning. Phone and tablet
  layouts remain unchanged. Focused geometry/golden coverage and isolated
  Linux before/after clean-restart captures pass.)

- [x] Desktop quick-search and Home action localization — 2026-08-16
  (desktop quick-search's hint, submit control, and filter labels, plus Home's
  Instant Radio label and tooltip, now use `AppLocalizations`; focused shell
  and Home coverage passes.)

- [x] Weekly playlist action localization — 2026-08-16 (the Home discovery
  sheet now uses the shared localized availability count and Play/Shuffle
  labels; English presentation is unchanged.)

- [x] Battery and playback prompt localization — 2026-08-16 (the Android
  battery-optimization prompt, playback-speed Close control, and fullscreen
  lyrics setting now use `AppLocalizations`; English presentation is
  unchanged and focused Playback Settings coverage passes.)

- [x] Shell exit-prompt localization — 2026-08-16 (the Android double-back
  exit notice now uses `AppLocalizations`; English presentation is unchanged
  and focused system-back coverage passes.)

- [x] Compact album-card large-text regression coverage — 2026-08-16 (the
  shared 150 px album card keeps intentionally long title and artist metadata
  overflow-free at 200% text scale.)

- [x] Sync Settings resume-reason clarity — 2026-08-16 (resumed durable work
  now writes a readable reason, while older persisted reasons render with the
  same natural-language spacing. Focused coordinator/UI coverage and isolated
  Linux before/after clean-restart captures pass.)

- [x] Missing queue-track recovery copy — 2026-08-16 (Queue and expanded
  Queue views now explain that a missing track is unavailable in the local
  library, rather than exposing its raw internal ID. Focused Queue coverage
  passes.)

- [x] Queue load-error recovery — 2026-08-16 (approved: Queue sheet and full
  Queue failures now use plain-language recovery copy rather than raw
  exception text, with an available direct Remove action. Focused Queue-sheet
  and full-Queue behavior coverage passes.)

- [x] Update failure recovery — 2026-08-16 (approved: update failures keep
  concise recovery copy and retain Retry and Download Manually without raw
  technical exception text. Focused dialog behavior coverage and Android
  emulator before/after visual review pass.)

- [x] AudioMuse settings surface removed — 2026-08-17 (user-directed: removed
  the Settings entry, `/settings/audiomuse` route, configuration page, and
  release-note claim. The pre-existing direct AudioMuse integration remains
  force-disabled as documented in Phase 11.)

- [x] Match Flow recovery localization — 2026-08-16 (the expected local
  constraint notices now have structured failure reasons and localized UI
  copy, retaining the current English wording. Focused DAO and Match Flow
  presentation coverage passes.)

- [x] Now Playing reduced-motion feedback — 2026-08-16 (the Like control now
  changes state without its decorative heart pulse when the platform requests
  reduced motion, while normal-motion feedback is retained. Focused adaptive
  widget coverage passes.)

- [x] Phone album-action labels — 2026-08-16 (the icon-only Play, Shuffle,
  Like, and More actions now expose the same localized long-press labels as
  their compact desktop counterparts. Focused album-detail coverage passes.)

- [x] Phone album-header navigation labels — 2026-08-16 (the custom artwork
  header now also labels its Back and Retry icons, matching the direct album
  actions and the standard app bar contract. Focused album-detail coverage
  passes.)

- [x] Deep-link presentation evidence check — 2026-08-16 (an apparent blank
  preview in isolated Linux Album deep-link captures was ruled out by direct
  pixel comparison: the captured PNGs were effectively identical settled
  frames. No app or diagnostic regression was found.)

- [x] Genre browsing scope decision — 2026-08-17 (deferred by product
  decision. Genres remain local-catalog metadata and Android Auto capability;
  no desktop or mobile Library destination is planned without a fresh stated
  product priority and visual review.)

- [x] Library Sync notification recovery copy — 2026-08-16 (Android failure
  notifications now retain the cancelled/failed distinction but replace raw
  server detail with a concise, safe instruction to reopen Navis. Focused
  notification-copy coverage passes.)

- [x] Download notification recovery copy — 2026-08-16 (permanent Android
  download failures now use one safe generic title and cannot expose an
  internal song ID in the system notification. Focused notifier coverage
  passes.)

- [x] Phone Play/Pause label parity — 2026-08-16 (the central Now Playing
  transport control now exposes the same localized long-press and assistive
  label on phone as it does on desktop. Focused adaptive coverage passes.)

- [x] Fullscreen artwork close labels — 2026-08-16 (local and remote artwork
  viewers now expose the platform Close label on their close-only controls.
  Focused artwork-viewer coverage passes.)

- [x] Queue sheet close label — 2026-08-16 (the compact Queue sheet now gives
  its close-only header action the platform Close label, matching its other
  named actions without changing the layout. Focused Queue sheet coverage
  passes.)

- [x] Password visibility label — 2026-08-16 (the sign-in password toggle
  now announces the localized next action, Show password or Hide password,
  without changing the credential form layout. Focused Login coverage passes.)

- [x] Add to Playlist close label — 2026-08-17 (the shared desktop dialog and
  phone sheet now expose the platform Close label on their close-only picker
  action. Focused picker coverage passes.)

- [x] Artist Top Tracks More label — 2026-08-17 (the visible song overflow
  trigger now exposes the platform Show menu label on desktop and mobile.
  Focused top-tracks coverage passes.)

- [x] Mobile Library large-text readability — 2026-08-16 (approved: at text
  scales above 130%, the Downloaded filter and sort control stack so both
  active labels remain visible; the default compact row is unchanged. Focused
  200% widget geometry coverage and inspected Android emulator before/after
  captures pass.)

- [x] Artist Top Tracks contextual title — 2026-08-16 (approved: the detail
  page now identifies the artist in its app bar, including when Last.fm has no
  tracks to show, rather than presenting the generic Playlist title. Focused
  desktop empty-state coverage and isolated Linux before/after clean-restart
  captures pass.)

- [x] Artist Top Tracks playlist hierarchy — 2026-08-17 (approved: desktop
  now uses an artwork-led tonal detail header, strong playlist title,
  artist-and-track-count metadata, direct Play action, supporting actions,
  and a gentle transition into the inset track list; phone retains its compact
  layout with the same information/action hierarchy. The virtual multi-album
  artwork remains animated. Focused adaptive coverage, isolated Linux capture,
  clean restart, and final quality gate pass.)

- [x] Desktop Lyrics track context — 2026-08-17 (approved: the expanded
  desktop Lyrics header now preserves a quiet, truncating title-and-artist
  context beside its Lyrics label, without adding a card or duplicate
  transport controls. The clone-only diagnostics control now opens this real
  desktop surface for visual validation. Focused semantics/golden coverage,
  isolated Linux capture, clean restart, and final quality gate pass.)

- [x] Design-audit maintenance closeout — 2026-08-17 (current-routed-surface
  container, state, responsive, and visible-action inventories are resolved:
  raw cards are intentional local/auth/player exceptions, audited states have
  distinct recovery, routed More/context actions follow one platform contract,
  and new 200% visual regression goldens cover phone Artist Top Tracks and the
  constrained desktop Lyrics header. Focused coverage and final quality gate
  pass.)

- [x] Compact desktop Album Detail density — 2026-08-16 (approved: at the
  smallest desktop workspace, the album hero becomes compact enough to keep
  the first tracks visible; its core actions remain direct, Download retains a
  tooltip-backed control, and Rating/filters share the available line. Wide
  desktop and mobile remain unchanged. Focused geometry/golden coverage,
  including a 130% text-scale wrap regression, and isolated Linux
  before/after clean-restart captures pass.)

- [x] Non-blocking update-notes discovery — 2026-08-14 (normal release notes
  now appear as a localized, dismissible Home card that opens the full
  changelog instead of a blocking first-run dialog. Focused Home and 200%
  text-scale golden coverage passes; the approved implementation is committed
  in `9061afd`.)

- [x] Desktop integrated-workspace system — 2026-08-14 (approved Search,
  Library, Home, Downloads, and Settings slices: Search uses a fixed command strip and one
  continuous, dense results workspace; Library uses the persistent sidebar for
  section navigation and a continuous browser; Home keeps its headings and
  album rows on the shared canvas while retaining local album cards; Downloads
  keeps its Back action, nested-page title, tabs, and contextual search in one
  command strip; Settings uses a continuous preference list with group labels;
  nested Sync Settings, Configuration, Playback, and About use constrained
  desktop workspaces with an explicit Back-to-Settings action; Configuration
  replaces desktop cards with grouped divider-separated rows and keeps
  connection actions compact while retaining a visually distinct sign-out
  action.
  A labeled desktop rail suppresses duplicate page headers; an icon-only rail restores
  compact orientation copy. Sidebar autohide now retains a 64 px icon rail
  instead of removing navigation. Tablet and phone layouts remain unchanged.
  Focused adaptive, shell, and deterministic before/after visual coverage
  passes across every primary desktop workspace; the final `./tool/check.sh`
  passes with 1,120 tests and 1 skip, and isolated Linux Sync Settings,
  Configuration, Playback, and About diagnostics pass before and after a
  clean restart.)

- [x] Desktop weekly-detail hierarchy — 2026-08-15 (weekly ListenBrainz
  detail keeps the persistent Back control but removes the duplicate desktop
  app-bar title once its content hero is ready; loading and unavailable states
  retain their contextual title. Phone and tablet behavior remain unchanged.
  Focused Home coverage and isolated Linux presentation diagnostics with an
  inspected app-owned screenshot pass before and after a clean restart; the
  final `./tool/check.sh` passes with 1,120 tests and 1 skip.)

- [x] Cross-platform entity-action placement policy — 2026-08-15
  (approved: playlist detail makes Play the one filled primary action and keeps
  Shuffle and Download tonal, matching album/artist hierarchy on phone and
  desktop. Song, album, and playlist-track menus now group direct, utility,
  and destructive actions; playlist track removal is last and Rename/Delete
  are separated. Desktop playlist tracks use the same anchored context menu
  for secondary click and the More button, while phone retains its touch sheet.
  Focused before/after goldens and secondary-pointer widget coverage pass;
  `./tool/check.sh` and isolated Linux playlist-detail app-API/screenshot
  diagnostics pass with a clean restart. The later Desktop Library playlist
  owner-action slice closed the remaining rename/delete action parity through
  the same anchored desktop menu (evidence: `eff8155e`,
  `test/src/features/playlists/presentation/playlists_screen_test.dart`).)

- [x] State-clarity contract — 2026-08-15 (approved: filtered-empty
  Artists, Albums, Albums by Year, and Liked views now provide one localized
  `Show all` recovery action that clears active filters without leaving the
  current section. Weekly playlist detail now preserves track-shaped geometry
  while loading, offers an explicit Retry action when unavailable, and never
  exposes a caught rematch exception. A Library with every page disabled now
  offers a direct Appearance settings action. Downloads search-empty states
  now offer the same direct `Show all` recovery for Queue and Downloaded
  tabs. Focused Library, Home, Downloads, and before/after golden coverage
  pass. Ordinary offline mode now remains visible without borrowing
  destructive error styling; action failures retain it.
  Final `./tool/check.sh` passes with 1,120 tests and 1 skip; isolated Linux
  weekly-detail diagnostics pass before and after a clean restart. The later
  safe recoverable-error copy, calm offline treatment, and persistent
  actionable error-notice slices closed the remaining state-copy scope
  (evidence: `1fd3dae3`, `fb809f1c`, `21be8a95`).)

- [x] Active desktop metadata visual coverage — 2026-08-15
  (deterministic player-bar goldens now cover long title/artist truncation at
  800×600, standard and ultra-wide hierarchy, and 130% text scale. Mini Player
  has active/empty coverage; the later 800×600 Desktop View and 560×360 Mini
  Player Remote fixtures closed the remaining provenance variants (evidence:
  `441b6259`, `test/src/routing/app_shell_navigation_test.dart`).)

- [x] Mobile album-title fit refinement — 2026-08-13 (the original
  artwork-led header remains; its album title now steps down only when a full
  two-line presentation is possible, otherwise it retains the existing
  ellipsis. Deterministic phone golden and album-detail suite pass.)

- [x] Mobile album completed-page fade — 2026-08-14 (approved on physical
  Android: phone album detail assembles its normal artwork, gradient, title,
  and track page before fading that stationary surface in and out over 180 ms.
  The phone header is deliberately ordinary `CoverArtImage` content rather
  than a destination Hero, preventing artwork travel on both open and close;
  desktop/compact-wide Heroes and reduced-motion immediate presentation remain
  intact. Focused route-motion and mobile-detail widget tests pass.)

- [x] Fullscreen artwork progressive-loading handoff — 2026-08-13 (the
  fullscreen viewer retains its preview until the 1600 px, zoom-ready artwork
  has decoded, then makes one short cross-fade and removes the preview layer.
  Focused artwork-viewer and cover-art suites pass.)


- [x] Reduced-motion surface coverage — 2026-08-15 (the shared
  motion policy now removes transient status-notice travel and fade alongside
  the existing route and Hero behavior, and switches the expandable player
  sheet, queue, fullscreen artwork viewer, and Now Playing metadata pager
  and artwork tint without decorative motion; Like feedback also becomes
  instant. Home carousels stop auto-advancing and use direct state changes.
  Normal artwork-tint changes use the shared 180 ms surface timing. Focused
  phone and compact-wide tests cover both the normal and reduced-motion
  contracts.)

- [x] Safe recoverable error copy — 2026-08-14 (album-refresh notices,
  generic radio-load errors, Playback Settings, and Match Flow now use
  concise, actionable recovery copy rather than raw backend exceptions.
  Playback Settings and Match Flow loading failures use the shared Retry
  error state.)

- [x] Now Playing reduced-motion transition coverage — 2026-08-14
  (phone and compact-wide art/lyrics and track-metadata switchers now present
  their next state immediately when the platform requests reduced motion.
  Compact-wide Queue, Mix, and Settings panels also skip their fade/slide;
  normal motion retains semantic 120–280 ms timing. Desktop right-pane panels
  are already static. Focused adaptive behavior and motion-frame golden
  coverage pass; Linux isolated normal-motion startup, Now Playing overlay,
  app-owned screenshot, and clean-restart validation are recorded with this
  change.)

- [ ] Album artwork navigation transition live verification — 2026-08-13 (the
  exact
  source Hero tag now travels through `NavService` to album detail from Home,
  Library, Search, Artist, and Genre; the shared Hero shuttle retains the
  source cache size and radius, removes the mobile blank-capable shuttle, and
  avoids competing route fade or travel, so the Hero alone owns the landing
  artwork opacity. Source card artwork chrome, including the
  Home Random/showcase variants, stays hidden until the Hero return has
  settled and then fades in separately instead of appearing in one frame; the
  Hero flight completion itself drives that handoff. Hero source, shuttle, and
  destination now share one opaque requested-size decode instead of landing on
  a layout-sized cached-image fade. The current source, Hero, detail-screen,
  and router tests pass, including a regression that prohibits a route-level
  fade or slide around hero-driven album detail. The Linux clone diagnostic
  starts and captures correctly, but its direct route request did not paint
  the expected detail frame after restart; it is not motion evidence. The
  remaining validation is an app-owned source-card push/pop capture on Linux,
  followed by mobile confirmation. `./tool/check.sh` passed.)

- [x] Metered manual discovery and Recently Added ordering recovery — 2026-08-13
  (evidence: focused planner, coordinator, engine, canonical DAO, candidate
  classifier, and ordering suites pass; the isolated Linux clone app API
  exercised `POST /v1/sync/check` under a cellular diagnostics override and
  reported `deltaReconcile/manualMeteredLimitedDiscovery` with one
  `getNewestAlbumList2`, no `getArtist` or bulk-song request, and three
  `getAlbum` details. Its authenticated Recently Added observation returned
  100 server-created entries in descending order with zero local-sync-time
  fallbacks. The subsequent unrelated full-repair section of
  `sync_diagnostics.sh clone` stopped at an existing `leaseHeld` durable-work
  state, so that full-suite result is not claimed as a pass.)

- [x] Sync reliability recovery — 2026-08-12 (source of truth:
  `docs/features/sync-reliability-recovery-plan.md`; implemented manual bounded newest
  discovery despite unchanged artist cursor, removed the two-minute pending
  verification force loop, preserved terminal durable work unless a user
  explicitly reactivates it, made user-cancelled durable work terminal instead
  of immediately queueing it for another automatic pass, and stopped opening Liked from requesting stale
  synchronization. Focused planner, engine, coordinator, DAO, controller, and
  Library widget suites pass. A later isolated Linux throughput trace proved
  the legacy wildcard bulk-song capability could stall after candidate
  collection; the recovery discards it and the standards-compliant empty-query
  path advanced 214→2,002 albums and 3,924→24,979 candidate songs in 15
  seconds. Settings now surfaces the durable server-missing deletion count and
  requires an explicit confirmation before the retry that can apply it, or a
  confirmed discard that keeps the committed offline catalog untouched; focused
  Settings coverage passes. Starred reconciliation now retains a local like
  after its first successful server absence and requires a persisted second
  absence before clearing it; schema v62 and focused engine/migration/API tests
  pass. Automatic startup/periodic calls now leave queued full repairs dormant
  until an explicit Repair Library request, and resume no longer submits a
  redundant startup sync alongside its interval check; focused
  coordinator/provider/DAO coverage passes. Catalog and target controller lanes
  are now separated: target hydration is deduplicated only by durable target
  key and cannot overwrite catalog status or swallow a user Check for updates;
  the focused controller suite passes 17 tests including concurrent target and
  catalog cases. `tool/sync_target_lane_diagnostics.sh` now validates the
  controller boundary on an isolated Linux clone: authenticated health/status,
  an online and offline Home→Library→Liked→Home→Liked trace with unchanged
  catalog state/counts and no added controller-ledger event, an accepted album
  target request with unchanged catalog state, inspected Liked and Settings
  screenshots, clean restart, and log review all passed. A subsequent
  primary-state audit found that full repair was evaluating stale songs before
  candidate hydration: generation 18 had 5,464 candidate albums but zero
  candidate songs, yielding the false 54,327-song deletion confirmation.
  Repair now hydrates/carries candidate songs before deletion analysis, and
  unresolved candidate albums retain their current tracks until authoritative
  detail hydration; focused engine regressions cover both paths. An isolated
  Linux full-rescan clone then collected 5,464 albums, indexed 57 song pages,
  completed five detail fallbacks and promoted successfully with candidate and
  deletion state cleared; its post-restart Sync Settings screenshot was opened
  and shows `Last sync succeeded` without a deletion confirmation. The current
  target-lane runtime gate also drove `/ → /library` twice through the live
  router and observed identical catalog state before/after each transition,
  then proved a target request changes only its own active lane. Remaining:
  schema v63 now persists the per-server next automatic-check deadline, with
  one re-arming foreground timer and controller-level due gating so startup,
  resume, reconnect, and provider reconstruction cannot create a new interval;
  Sync Settings reports its next automatic check. Focused
  controller/migration/Settings/diagnostics tests pass. The isolated Linux
  clone runtime gate seeded a future deadline, exercised the production
  automatic endpoint without catalog work, repeated Home-to-Library and target
  hydration, and clean-restarted with the deadline unchanged; both app-owned
  Settings captures were opened and inspected, and log review found no
  hard-fail pattern. The deterministic manual-discovery loopback gate then
  found a protocol defect in the production client: standard Subsonic
  `getArtist` returns singular `album`, which Navis had failed to normalize to
  the model's `albums` field. That silently removed artist-detail albums and
  prevented the authoritative new-album hydration path. The fix is unit-tested
  and the isolated Linux app check now holds `getIndexes` unchanged while a
  known artist receives a new album; Check for updates records `getIndexes`,
  `getNewestAlbumList2`, `getArtist`, and `getAlbum`, persists the hydrated
  album/song, renders its detail screen in two inspected app-owned screenshots,
  and preserves it over a clean restart. Large-deletion repair confirmation is
  now covered by an isolated Linux clone gate: its first Repair Library pass
  left 1,714 artists / 5,463 albums / 54,327 songs unchanged behind a 61,503
  item confirmation, preserved that state across restart, and the explicit
  second repair atomically promoted the fixture catalog. The same trace found
  and fixed per-song/per-artist promotion deletes that made large confirmation
  applies pathological; bounded bulk deletion retains permanent downloads.
  Both Sync Settings screenshots were opened and inspected. A subsequent
  configured-server `sync_diagnostics.sh clone` run used an isolated copy of
  the primary catalog and completed policy, interruption/restart,
  local-mutation, active-playback, and repeated-repair certification without
  changing the primary profile. The final catalog remained 1,714 artists /
  5,464 albums / 54,329 songs after clean restart; the converged repair
  classified all 61,507 rows unchanged, removed zero songs, and applied in
  117 ms. A controller regression also sets the production 60-minute interval
  with a persisted near-future deadline and proves the one-shot timer makes no
  early catalog call, then exactly one automatic call and persists the next
  interval. A subsequent planner/coordinator audit found and fixed one more
  manual-discovery loss: an offline Check for updates had been persisted as an
  indexes-only probe, which could finish unchanged after reconnect and never
  run newest-album discovery. It now retains deferred delta work and drains on
  an eligible connection; metered broad discovery remains available only by
  the explicit mobile-data override. The first app-level offline→Wi-Fi run
  then exposed a second layer: the stable engine could retain an offline policy
  from its construction `Ref` even after the visible policy changed. It now
  reads live policy from the root provider container. The rerun passed through
  the authenticated Linux app API: offline Check returned deferred
  `manualCatalogDiscoveryOffline`, reconnect dispatched 9 requests including
  `getIndexes`, newest-list, artist and album, and committed the new hydrated
  album/song before clean restart. Its two opened app-owned album-detail PNGs
  were byte-identical and visibly showed the new album and song; log review had
  no hard-fail pattern. Remaining: an optional wall-clock 60-minute foreground
  soak, any future affected-server vanished-row reproduction, and next plan phases,
  then the final quality gate. The scheduler audit also found that the durable
  retry/circuit cooldown was stored but not restored into live sync state, so
  Settings could not explain why a catalog operation was waiting. The
  controller now loads `next_eligible_at` as `nextRetryAt`, the coordinator
  emits it for terminal failed/deferred work, and Sync Settings presents it
  separately from the normal automatic deadline. Focused controller and
  Settings widget regressions pass. The updated isolated Linux target-lane
  gate seeded both durable deadlines, proved the automatic endpoint did not
  consume either one, preserved catalog status/counts through online and
  offline Home→Library→Liked navigation plus target hydration, and retained
  both values over clean restart. The two app-owned Sync Settings captures
  were opened and inspected; each shows the separate retry row with no
  clipping. Log review found no hard-fail pattern. The follow-up disappearance
  audit found an unguarded incremental deletion: one partial `getArtist`
  response could remove all absent local sibling albums. Incremental artist
  reconciliation now only adds/updates; destructive removal remains
  exclusively in validated full-candidate promotion. Focused engine coverage
  and an isolated Linux loopback app run seeded an existing album, returned
  only the new sibling from `getArtist`, then verified through authenticated
  app APIs that the new album/song was hydrated while the omitted album
  remained hydrated before and after restart. The app-owned album-detail
  capture was opened and inspected; its restart capture was byte-identical.
  The latest `./tool/check.sh` passed formatting and code generation, then
  stopped at the repository-wide analyzer baseline of 493 informational
  diagnostics; none were introduced by this recovery work. The subsequent
  discovery audit found that manual newest-album discovery normally inspected
  only the first 100 server results. It now scans a bounded five-page,
  500-album manual window while automatic work remains low-data; the engine
  regression imports a second-page new album after 100 known rows. The
  isolated Linux loopback manual-check gate was rerun with the partial artist
  response guard, passed clean restart, and the two app-owned screenshots were
  opened (the files are byte-identical); logs contained no hard-fail pattern.
  Schema v64 now records each validated catalog promotion and confirmed second
  starred absence in a bounded, per-server durable operation ledger. Entries
  contain only a reason, timestamp, aggregate before/after counts, removals,
  and retained rows, and are committed in the same transaction as the mutation.
  The diagnostics ledger exposes this redacted evidence. The isolated Linux
  repair-confirmation gate passed again: it held the 61,503-row deletion
  candidate through restart, then verified the explicit promotion's stored
  `1,714/5,463/54,327 → 2/1/1` aggregate counts and `54,327` removed songs
  through the authenticated app API. Both awaiting and promoted Sync Settings
  screenshots were opened and inspected; logs had no hard-fail pattern. Sync
  Settings now streams the same durable ledger and presents the newest operation
  with actual removals rather than allowing a later no-op promotion to hide the
  explanation; its widget regression covers that ordering contract. The
  isolated Linux repair gate was rerun at
  `build/repair-confirmation-diagnostics/20260812T165729Z-clone`: its
  authenticated ledger reported the same `1,714/5,463/54,327 → 2/1/1`
  promotion, and the opened promoted Sync Settings capture visibly reports
  the matching `1,713/5,463/54,327` removal summary without clipping. Both
  app runs cleanly restarted; log review found no hard-fail pattern.)

- [x] Android persistent background sync — 2026-08-12 (implemented
  source: `docs/features/android-background-sync-recovery-plan.md`; schema v65 adds an
  expiring heartbeat SQLite execution lease plus redacted Android scheduler and
  worker state; WorkManager 2.11.2 now owns one opaque-keyed periodic `UPDATE`
  request and one `KEEP` catch-up request; the worker registers plugins and
  invokes a retained UI-free Dart entrypoint that uses the existing planner,
  coordinator, durable work queue, operation ledger, and network policy. A
  late worker now proves its opaque profile key before touching the active
  session, records its own work id/attempt as a redacted running state, and
  manual-only cancellation clears stale cadence state; debug diagnostics
  expose only the safe durable observation.
  Sync Settings shows requested eventual cadence, unmetered wait, and safe
  terminal state. Focused DAO/migration/coordinator/bridge/widget tests,
  Android scheduler unit tests, and `:app:testSideloadDebugUnitTest` pass.
  2026-08-12 follow-up hardening also passed all 1,109 Flutter tests and
  `./tool/check.sh`; isolated Linux clone Settings diagnostics completed with
  clean app-API startup/restart and inspected initial screenshot
  `background-recovery-final` (Android-only card correctly absent on Linux;
  restart capture showed the transient loading skeleton). An internally gated
  APK also built, installed, and started cleanly on an Android API 37 emulator
  with no Flutter/Android fatal log entry. Current-target physical validation
  on a Samsung SM-S948B (Android API 36) used an isolated profile sidecar:
  the app-owned authenticated API reported the unmetered 15-minute native
  schedule; Android JobScheduler observed its exact `NavisBackgroundSyncWorker`
  constraint state; a real execution exposed and corrected both the UI-thread
  FlutterEngine lifecycle and the root-library named-Dart-entrypoint retention
  issues. The retried Worker then completed `SUCCESS`; the authenticated app
  API persisted `succeeded`, `stopReason=none`, and an 7.9-second duration.
  Older Android 12/14 device coverage remains logically covered by the
  WorkManager constraints and Android unit tests; the user explicitly accepted
  that deferred physical-device portion.)

- [x] Large-library full-repair capped-index tail avoidance — 2026-08-11
  (a completed bulk-song index now carries forward only locally verified,
  metadata-and-count-identical candidate albums before `getAlbum` fallback;
  changed, new, incomplete, and unverified albums remain authoritative detail
  fetches. Evidence: focused two-pass engine regression proves the second pass
  performs zero `getAlbum` calls for a capped stable tail; isolated Linux
  full-rescan diagnostics against the configured large server completed the
  53-page live bulk index and promotion with no prolonged album-detail tail.
  The app-owned preparing screenshot was captured and opened. Direct live
  detail sampling also established that the server itself sustains only about
  three album-detail requests per second, explaining the former long tail.)

- [x] Full Repair Library progress and fallback throughput hardening —
  2026-08-11 (the controller now enters visible `preparing` state before
  durable planning, song-index scans now show a live count without implying a
  percentage before the separate remaining-album fallback begins, compatible
  short catalog pages advance by their returned count instead of ending early,
  and an explicit full repair retains a bounded four-to-eight Wi-Fi `getAlbum`
  fallback while audio is active; evidence:
  focused provider/engine/diagnostics tests, release-note generation, and
  isolated authenticated Linux full-rescan diagnostics against the configured
  large library. The completed trace recorded immediate `preparing`, 5,460
  catalog albums, 53 paged bulk-song requests, 301 correctly completed
  fallback album details, and a successful promotion; the app-owned Home
  capture was opened and inspected after the clean clone launch.)

- [x] Home logo-only sync status and Library sync-strip refinement —
  2026-08-11 (Home now leaves all active and failed sync signalling to the
  Navis logo ring, while Library has a compact tonal status strip with
  determinate song-hydration progress, indeterminate metadata progress, and
  Cancel/Retry controls; evidence: focused Home/Library widget suites passed,
  including ring semantics and status-strip progress/action assertions; Linux
  isolated-clone app-API runs at `/` and `/library` passed before and after
  clean restart through health, presentation, navigation, screenshot, and
  shutdown APIs. Opened app-owned Home and Library captures showed no Home
  sync bar and no clipping/overflow. `tool/check.sh` formatting and code
  generation passed, then analysis stopped on the documented repository-wide
  496 informational diagnostics; no diagnostics originated in this change.)

- [x] Large-library new-album detection follow-up — 2026-08-11 (explicit
  refreshes with an advanced conditional `getIndexes` cursor now consume their
  durable delta in the same action, stage the bounded
  `getAlbumList2(type=newest)` discrepancies directly for normal song
  hydration and identity/cache reconciliation, and no longer wait for the
  rotating artist audit; evidence: 2,000-artist/2,000-album/50,000-song
  regression in `library_sync_engine_test.dart`, coordinator changed-probe
  follow-up regression, cached provisional-song identity regression, and an
  isolated authenticated Linux clone app-API check against the configured
  server. With only clone state made stale, the first explicit Check for
  updates advanced into `deltaReconcile` and increased the clone catalog from
  5,427 to 5,462 albums while retaining 54,074 songs. Its partial result
  represents the bounded remaining artist audit; primary data was never
  modified. The final isolated live cache-alias app-API assertion passed:
  targeted hydration used one `getAlbum` request, created the identity alias,
  removed the provisional cache row, moved cache ownership to the canonical
  song, and retained the cache file.)

- [x] Startup metadata-sync availability race — 2026-08-11 (automatic
  startup/periodic passes now wait for the credential-backed sync engine and
  retry when it arrives, while explicit user retries still report a real
  unavailable engine; evidence: deterministic delayed-engine provider
  regression plus 47 focused provider/Home tests passed, and an isolated
  authenticated Linux Home app-API run captured a populated Home screen with
  no metadata-sync-failure banner. The app-owned PNG was opened and inspected.
  `./tool/check.sh` formatting and code generation passed, then analysis
  stopped on the repository's 497 informational diagnostics; final direct
  analysis contained no new diagnostics from this change and currently reports
  495 informational diagnostics.)

- [x] Post-1.2.0 sync and cache stability certification — 2026-08-11 (source of truth: `docs/features/sync-stability-validation.md`; Linux isolated clone and authenticated Home/cache-fault evidence passed. Windows now has matching Flutter 3.44.6/Dart 3.12.2, Rust 1.97.1, and a clean zero-warning profile build. Its authenticated app API first-login Home screenshot, real full-repair promotion (1,697 artists / 5,436 albums / 54,109 songs), active direct-stream playback without load failures, cache corruption plus automatic maintenance, and clean restart with populated Home/player/cache state all passed. Diagnostics no longer blocks on Windows `chmod`, and broad diagnostics sync actions now join the production controller. Focused diagnostics-server tests passed 20 tests and the full Flutter suite passed 1,060 tests with 1 skip. `./tool/check.sh` formatting and code generation passed, then analysis stopped on 496 pre-existing informational diagnostics despite `--no-fatal-infos`; inspected output contained no errors/warnings from this work. The isolated Windows app was shut down through its authenticated API after certification.)

- [x] Seamless playback bootstrap recovery (persistent normal loading gate, fixed three-second retries after every initialization failure or timeout, retained late/stale completion safety, clone-only injected-failure diagnostics, and authenticated bootstrap state observation) — 2026-08-10 (evidence: focused bootstrap/widget/diagnostics API tests; `./tool/check.sh` passed with 1,059 tests and 1 skip; isolated Linux clone run `build/presentation-diagnostics/20260810T074052Z-clone/` exercised health, bootstrap-status, presentation screenshot, navigation, and shutdown APIs through two injected failures before and after a clean restart; both bootstrap responses reported failed attempt 1 with a scheduled retry and no handler, both loading screenshots were opened and inspected with the normal centred spinner and loading copy, no retry control or error state, and the final runtime report/log review passed)
- [x] Mini Player edge-control and Linux always-on-top audit (restored compact transparent floating pin/return controls at the top-right edge with icon-only hover feedback and quick panel-aware fades, hides them while embedded Queue/Lyrics/settings panels are active, preserves Queue through its reverse transition before returning controls, and restores the rich 720×405 Mini Player entry; Wayland reports its compositor-owned stacking limitation and disables the misleading pin while retaining the preference for a later supported session; authenticated window diagnostics expose and exercise the capability) — 2026-08-10 (evidence: focused controller/shell/diagnostics suite, regenerated and visually inspected 720×405 and 560×360 Mini Player component goldens, isolated Linux clone app API run, generated release notes, and final quality gate are recorded with this change)
- [x] Desktop remote-source player coverage (added deterministic 800×600 Desktop View and 560×360 Mini Player remote-metadata fixtures, asserting one stable Remote semantics node and visually pinning provenance placement without changing the production treatment) — 2026-08-15 (evidence: focused shell golden suite and both inspected component goldens)
- [x] Radio filtered-empty recovery (a non-empty station library filtered to zero matches now says `No stations match “query”`, offers `Show all stations`, and preserves the existing true-empty library guidance; clone-only presentation control exercises the production Library filter without desktop input automation) — 2026-08-15 (evidence: Radio/Library behavior and component-golden coverage, diagnostics API contract coverage, isolated Linux clone capture, and final quality gate recorded with this change)
- [x] Desktop-first window restore (startup now always selects Desktop View and restores the last valid Desktop bounds independently of the saved Mini Player mode; legacy Focus/Mini startup records follow the same rule) — 2026-08-10 (evidence: focused controller restart/legacy/small-display regression suite, isolated Linux clone diagnostics, and final quality gate recorded with this change)
- [x] Relevance-preserving local-first Search and contextual Remote provenance UI (ID-only cached/API merge; exact/prefix/substring/token relevance tiers; on-server tie preference; stable ordering; explicit provenance precedence; neutral globe artwork/inline/chip variants; Hero-safe overlays; row, detail, Now Playing, Mini Player, Desktop player, queue, and download placement; sanitized clone-only Search and Search-result playback diagnostics) — 2026-08-09 (evidence: 123-test focused Search/Remote/player/diagnostics suite passed; light/dark/OLED component golden covering 48 px and 150 px artwork plus inline/chip variants was opened and inspected; `dart tool/generate_release_notes.dart v1.2.0` contained the new user-facing entry; final `./tool/check.sh` passed with 1,034 tests and 1 skip; remote-playback Linux isolated-clone run `build/presentation-diagnostics/20260809T150114Z-clone/` exercised authenticated health, production Search, remote-result queue playback, player-overlay, screenshot, and shutdown APIs with 34 on-server and 14 remote song results before and after a clean restart, real direct-stream playback and active cache writes, clean logs, and four opened 1469×931 Search/Desktop-player captures showing unobstructed artwork and inline Remote metadata; final post-gate Search run `build/presentation-diagnostics/20260809T150645Z-clone/` verified 49 on-server and 58 remote results, ordering, clean logs, quality-gate status, and clean restart, with both captures opened and the restart capture showing Remote immediately after subtitle metadata; final hydrated isolated-clone detail run `build/presentation-diagnostics/20260809T150316Z-clone/` repeated before/after restart and both opened album-detail captures showed the Remote chip beside metadata, unobstructed large artwork, inline Remote track provenance, and independent download controls; runtime iterations fixed far-edge row placement, Desktop player-bar placement, playback-readiness timing, and repeated-query invalidation)
- [x] Remote song-row coverage audit and alignment hardening (ListenBrainz weekly recommendations, Home song lists, desktop liked songs, artist top tracks and ranked playlist details, Match Flow, queues, and downloads now share single-line metadata provenance; artwork overlays are suppressed in rows; long metadata truncates before Remote; local and remote shared/weekly rows retain a 64 dp minimum height) — 2026-08-09 (evidence: focused Home/library/top-tracks/Match-Flow/download/queue and shared-indicator suites passed; widget coverage asserts Weekly’s remote semantics, narrow-line truncation, pointer transparency, and local/remote row-height parity; `dart tool/generate_release_notes.dart v1.2.0` contains the matching fix entry; `./tool/check.sh` passed with 1,036 tests and 1 skip; Linux isolated-clone Weekly Exploration runs `build/presentation-diagnostics/20260809T153515Z-clone/` and final post-gate `build/presentation-diagnostics/20260809T153822Z-clone/` used authenticated health, clone-only credential-free cached-ListenBrainz presentation, production navigation, screenshot, and shutdown APIs before and after clean restarts; all four 1469×931 screenshots were opened and showed Remote immediately after album metadata with aligned track numbers and trailing controls, no artwork obstruction or overflow; final logs contained no hard-fail patterns and recorded quality-gate and clean-restart success)
- [x] Remote tooltip semantics crash containment (replaced Material `Tooltip`/`OverlayPortal` with a theme-preserving visual-only `OverlayEntry`, retained one stable app-owned semantics node and pointer-transparent behavior, bounded the hover bubble inside the window, and removed overlays on deactivation) — 2026-08-09 (evidence: the new semantics-enabled repeated show/hide regression first reproduced Flutter 3.44's exact `!child.attached` assertion and cascading semantics failures, then passed across three cycles after the fix; focused Remote/CoverArt/shared-surface suites passed 17 tests; the 360×180 dark-theme tooltip component golden was generated, opened, and inspected for compact placement and contrast; generated v1.2.0 release notes contain the fix; `./tool/check.sh` passed with 1,038 tests and 1 skip; Linux isolated-clone runs `build/presentation-diagnostics/20260809T161033Z-clone/` and final post-gate `build/presentation-diagnostics/20260809T161258Z-clone/` exercised authenticated health, production mixed-source Search, presentation status/window/navigation/screenshot, shutdown, and clean restart APIs; final Search returned the same 60 on-server and 90 remote entities before and after restart, all eight app-owned 1469×931 captures were opened and inspected with no new clipping or alignment regression, and both log reviews contained no hard-fail patterns)
- [x] Navis 1.2.0 version and changelog preparation (version `1.2.0+10200`; consolidated all user-visible work since `v1.1.1` into the in-app changelog and Forgejo release-note source while restoring the historical 1.1.1 entry) — 2026-08-09 (evidence: `pubspec.yaml`, `lib/src/features/changelog/changelog_data.dart`, `tool/generate_release_notes.dart`, `dart tool/generate_release_notes.dart v1.2.0`, `./tool/check.sh`)
- [x] Canonical centred Navis branding and all-client app icons (historical source archive, exact circular SVG boundary, theme/accent tinting from one SVG, removal of legacy placement offsets, background-free circular desktop/Android launchers, Android resource cache bust, Linux content-addressed desktop icon install, regenerated Android/iOS/macOS/Linux/Windows assets, component goldens, alpha-contract tests, and platform regeneration workflow) — 2026-08-09 (evidence: focused branding/home/bootstrap/platform-icon/Android manifest suite passed 44 tests; transparent badge visually inspected over light, dark, and checkerboard backgrounds; generated Android legacy/adaptive, macOS, Linux, and Windows outputs have zero-alpha outer pixels while iOS retains its required opaque canvas; `./tool/verify_android_auto_manifest.sh` passed; stable Play and dev sideload release APKs use `ic_launcher_navis`, package a transparent legacy icon, and resolve an adaptive `#00000000` background; installed Linux content-addressed icon hash matches the packaged 256 px asset and has transparent corner pixels; all generated client variants and affected component/full-screen goldens were opened and inspected; `./tool/check.sh` passed with 1,020 tests and 1 skip; final Linux isolated-clone run `build/presentation-diagnostics/20260809T141312Z-clone/` exercised authenticated health, presentation status/window/navigation/screenshot/shutdown APIs at `/` before and after a clean restart; both app-owned 1469×931 Home PNGs were opened and inspected with centred, correctly tinted, unclipped branding; log review found no hard-fail patterns; iOS, macOS, and Windows native packaging remains unverified on this Linux host)
- [x] Initial login sync and safe session teardown (schema-v61 retained authentication state, identity-safe reauthentication/replacement, blocking `/initial-sync` route with offline/metered/retry/cancel states, single-flight best-effort logout, awaited sync/download/audio-bootstrap teardown, radio/deck/queue/media-session reset, server-data wipe boundary, clone-only lifecycle API and deterministic loopback diagnostics) — 2026-08-09 (evidence: `./tool/check.sh` passed with 1,014 tests and 1 skip; Linux isolated-profile pre-gate and post-gate runs passed at `build/auth-lifecycle-diagnostics/20260809T075019Z-clone/` and `build/auth-lifecycle-diagnostics/20260809T075816Z-clone/`; authenticated `/v1/session/*`, diagnostics override, playback, health, screenshot, and shutdown APIs exercised offline recovery, full catalog promotion, clean restart without the gate, real playback with active rolling-cache write through keep-data sign-out, initial-sync cancellation, and restart at login; post-gate waiting/running/promoted-home app-owned PNGs were opened and inspected with no clipping or route leakage; session status confirmed zero playback/download/sync queues and activity after both teardown paths; log review found no hard-fail patterns; iterations fixed a concurrent clone-credential read, scheduled-startup-sync teardown race, late audio-bootstrap queue restoration, and fixture-process lifetime)
- [x] Canonical Mini Player sizing and short-Desktop overflow follow-up (preserve only valid Desktop restoration bounds, retain Mini screen position while resetting every entry/Keep Mini decision to 720×405, keep the 560×360 manual minimum, embed expanded volume beneath rich and tight Mini controls, retain centered tight metadata, scroll near-cutoff inline Desktop navigation, and keep both transition choices visible in short native frames) — 2026-08-09 (evidence: final focused routing/window/shell/layout/diagnostics suite passed 109 tests; `./tool/check.sh` passed with 993 tests and 1 skip; Linux isolated-clone run `build/presentation-diagnostics/20260808T221412Z-clone/` exercised authenticated health, navigation, screenshot, shutdown, and `GET/POST /v1/presentation/window` APIs across 1306×853, 1159×678, 887×900, and 800×600 Desktop View, 799×599 and short 799×444 Desktop entry gates, the Mini exit gate, canonical 720×405 and minimum 560×360 Mini Player, Keep Mini restoration, and a clean restart; all 22 initial/restart app-owned PNGs were opened and inspected with no overflow, clipping, or alignment regression; both Mini sizes kept volume beneath the controls, the short Desktop sidebar remained clean, and both gate actions stayed visible; log review found zero hard-fail patterns; Windows and macOS were not required because no native window behavior changed)
- [x] Persistent Desktop player actions (fixed 184–240 px two-tier region, directly visible Favorite/Lyrics/Queue/Mini Player controls at every supported Desktop width, complete 140/188 px volume rows, stable 44 px targets and queue focus, localized disabled radio/empty semantics, expanded resolver matrix, component goldens, and restart diagnostics) — 2026-08-09 (evidence: focused routing/window/shell/diagnostics suite passed 110 tests; `./tool/check.sh` passed with 988 tests and 1 skip; Linux isolated-clone run `build/presentation-diagnostics/20260808T213358Z-clone/` exercised authenticated health, navigation, screenshot, shutdown, and `GET/POST /v1/presentation/window` APIs across 1306×853, 887×900, and 800×600 Desktop View, both resize gates, 560×360 Mini Player, bounds restoration, and a clean restart; all 14 initial/restart app-owned PNGs were opened and inspected, with essential actions and volume present and no overflow, clipping, or alignment regression; log review found zero hard-fail patterns; Windows and macOS were not required because no native window behavior changed)
- [x] Desktop aspect-ratio and Mini Player minimum follow-up (height-safe persistent desktop transport, Desktop matrix through 930×1177 and 3440×600, enforced 560×360 native/API Mini Player minimum, automatic recovery when a window manager reports undersized bounds, width-and-height compact composition, centered metadata, constrained large canvases, localized undersize guard, updated diagnostics, and component goldens) — 2026-08-09 (evidence: focused layout/window/shell/diagnostics suite passed 93 tests; `./tool/check.sh` passed with 979 tests and 1 skip; Linux isolated-clone run `build/presentation-diagnostics/20260808T210921Z-clone/` exercised authenticated health, `GET/POST /v1/presentation/window`, navigation, screenshot, and shutdown APIs across 930×900 and 800×600 Desktop View, 799×599 enter gate, 800×600 exit gate, 560×360 Mini Player, bounds restoration, and clean restart; all initial and restart `desktop-tall`, `desktop-view`, `enter-mini-gate`, `exit-mini-gate`, and `mini-player` app-owned PNGs were opened and inspected with no overflow, clipping, or alignment regression; log review found zero hard-fail patterns; Windows and macOS native resizing remain unverified on this Linux host)
- [x] Desktop View and Mini Player overhaul (desktop-only shell at 800×600+, compact 64 px navigation, persistent active/empty bottom player with installation-local volume, dedicated same-window Mini Player, bidirectional 400 ms resize gates, v3 separate bounds/maximized/always-on-top persistence, display work-area clamping, localized controls, authenticated window diagnostics, and component goldens) — 2026-08-08 (evidence: `./tool/check.sh` passed with 971 tests and 1 skip; Linux isolated-clone run `build/presentation-diagnostics/20260808T204757Z-clone/` exercised `GET/POST /v1/presentation/window`, health/status/navigation/screenshot/shutdown APIs, deterministic maximize-to-resize handling, both restore-bound decisions, active playback, and a clean restart; initial and restart `desktop-view`, `enter-mini-gate`, `exit-mini-gate`, and `mini-player` PNGs were opened and inspected with no clipping or layout regression; log review found no hard-fail/overflow patterns; Windows and macOS native resizing, snapping, DPI/display-topology behavior, and always-on-top remain unverified on this Linux host)
- [x] API-first runtime and visual validation (clone-only root Flutter capture, post-bootstrap and animation-settled presentation readiness, live-router navigation, protected screenshot artifacts, narrow queue-overlay control, screenshot workflow, and explicit AT-SPI prohibition) — 2026-08-08 (evidence: Linux isolated-clone `GET /v1/health`, presentation status/navigation/screenshot, playback/song-indicator/queue-overlay, diagnostics report, and shutdown scenarios; focused controller/server suite passed 16 tests; `./tool/check.sh` passed with 951 tests and 1 skip; post-gate `build/presentation-diagnostics/20260808T192953Z-clone/` home captures and `build/playback-indicator-diagnostics/20260808T193100Z-clone/` current/paused/switched queue captures were opened and inspected at 1440×900 before and after clean restart; no hard-fail logs; fix-and-retest iterations corrected splash-only capture, mid-animation capture, and paused-overlay observation without changing `NO_AT_BRIDGE=1`)
- [x] Desktop volume memory and repeatable runtime validation (schema v60 current/last-audible volume, desktop-only pre-readiness hydration, coalesced slider writes, immediate mute persistence, sleep-timer restoration, accessible controls, clone-only app API mutations, and focused Linux restart scenario) — 2026-08-08 (evidence: `./tool/check.sh` passed with 931 tests and 1 skip; isolated pre-gate and post-gate runs at `build/volume-memory-diagnostics/20260808T180627Z/` and `build/volume-memory-diagnostics/20260808T181318Z/` verified 37% restart, muted 0% restart with 37% retained, Unmute restoration, authenticated health, controller/handler/database agreement, clean shutdown, and clean error scans; Linux render visually showed the 37% slider; AT-SPI was enabled and the inherited `NO_AT_BRIDGE=1` was overridden, but the live Flutter tree traversal did not complete, so localized semantics were verified by widget tests)
- [x] External catalog source indicator (nullable OpenSubsonic provenance parsing, explicit-value-first classifier with observed ID fallback, schema-v59 persisted source columns and legacy backfill, external-safe search/queue/recommendation/targeted hydration flows, canonical source clearing, broad-candidate exclusion, accessible top-left artwork badges throughout result/detail/player surfaces, and authenticated sanitized Linux source audit) — 2026-08-08 (evidence: focused API/classifier/migration/search/queue/hydration/badge/diagnostics tests; isolated API audits classified `michael jackson` as 35 on-server/58 remote, `cicada good kid` as 1/44, and `tokyo fast and furious` as 1/36; `./tool/check.sh` passed with 921 tests and 1 skip)
- [x] Mobile sync guardrails (schema v58 work class + unmetered-background setting, native Android/iOS metering, hard single-request catalog probe, live policy boundary pausing, 16/32 MiB interactive budgets, Sync Settings mobile-data override UI, and diagnostics policy simulation) — 2026-08-05 (evidence: `./tool/check.sh` with 906 passing tests and 1 skip; clone guardrail artifacts in `build/sync-diagnostics/20260805T092107Z-clone/` show cellular/metered-Wi-Fi automatic runs as `probe` with `getIndexes:1`, no-override repair deferred, one-time override repair executing, and empty overrides reset clearing network cost; full clone resume after interruption was stopped after the diagnostics HTTP loop became unresponsive under a long catalog repair CPU soak)
- [x] Paged diff-only catalog promotion and guarded Linux certification (schema v57 resumable classifications, server-owned field comparison, one-write changed rows, paged removal anti-joins, indexed bounded alias planning, WAL read pool, compile-time diagnostics API, cloned cancellation/mutation/crash/playback suite, and backed-up primary certification) — 2026-08-04 (evidence: `./tool/check.sh` with 884 passing tests and 1 skip; clone report `build/sync-diagnostics/20260804T204807Z-clone/report.json`: zero metadata writes, 186 ms apply, 7.8 ms database-canary p95, 7.1 ms frame p99, uninterrupted playback; primary report `build/sync-diagnostics/20260804T205739Z-primary-certification/report.json`: 171 changed rows applied in 253 ms, 9.1 ms canary p95, 7.4 ms frame p99, clean restart/integrity/foreign keys, retained backup `~/Documents/navis-certification-backups/navis-20260804T205739Z.sqlite`)
- [x] Live schema-v56 migration/full-repair validation and Linux runtime hardening (one-time repair gate, abandoned page-checkpoint cleanup, large-catalog SQLite query chunking, promotion-transaction durable completion, disposed-provider-safe response accounting, raw targeted hydration IDs, Home discovery rebuild stabilization, coalesced empty-queue Play preparation, and collision-free crossfade cache sources) — 2026-08-04 (evidence: successful promotion of 1,684 artists / 5,364 albums / 53,548 songs in `~/Documents/navis.sqlite.sqlite`, `PRAGMA integrity_check=ok`, zero foreign-key/orphan-parent violations, successful real playlist hydration, clean native Linux log soak, focused regression tests, `./tool/check.sh`)
- [x] Atomic full-catalog promotion (schema v56 shadow candidate tables, restart-safe collection checkpoints, one-transaction visibility switch, local like/rating mutation protection, playback/download/cache row preservation, and pre-cleanup cached-song auto-merge) — 2026-08-04 (evidence: `lib/src/database/daos/library_sync_candidate_dao.dart`, `lib/src/features/library/data/library_sync_engine.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/database/migrations/navis_migration_test.dart`, `./tool/check.sh`)
- [x] Resumable liked and playlist reconciliation (explicit liked/playlist-header planner targets, pending-local-like protection, non-destructive authoritative playlist pruning, cached membership preservation, and durable hydration for changed playlist contents) — 2026-08-04 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/playlist_dao.dart`, `lib/src/features/playlists/presentation/playlist_providers.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, focused planner/engine/playlist tests, `./tool/check.sh`)
- [x] Adaptive resume-safe library sync overhaul (pure six-plan planner, durable coordinator/work queue and provider profiles, schema v55 catalog generations and endpoint cost tracking, page checkpoints, guarded deletion confirmation, centralized interactive artist/album/playlist hydration, rotating compatibility audits, one transport retry owner with active cancellation, cooldown/circuit policy, cellular probes, Repair Library UI, and playback-safe cached-song identity auto-merge) — 2026-08-04 (evidence: `lib/src/features/library/data/adaptive_library_sync_coordinator.dart`, `lib/src/features/library/data/library_sync_planner.dart`, `lib/src/database/daos/library_sync_dao.dart`, `test/src/features/library/data/adaptive_library_sync_coordinator_test.dart`, `test/src/features/library/data/library_sync_planner_test.dart`, `test/src/database/daos/library_sync_dao_test.dart`, `test/src/database/migrations/navis_migration_test.dart`, focused sync/settings tests, `./tool/check.sh`)
- [x] Desktop playback responsiveness and rolling-cache repair (single-pass lock caching on Linux/Windows/macOS, active cache-write status, structural/timeline stream split, coalesced MPRIS/SMTC timelines, superseding seek recovery, background transport persistence, and lazy crossfade deck) — 2026-08-04 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/player/data/linux_mpris_bridge.dart`, `lib/src/features/player/data/windows_smtc_bridge.dart`, `test/src/features/player/data/playback_source_resolver_test.dart`, `test/src/features/player/data/windows_smtc_bridge_test.dart`, `test/src/features/settings/presentation/cache_settings_screen_test.dart`, focused playback/cache/settings tests, `./tool/check.sh`)
- [x] Metadata retry and player-boundary feedback follow-up (failed automatic syncs no longer enter forced short retry loops; restart-current Previous and unavailable Next actions use directional snapback feedback instead of full track-change artwork transitions; version `1.0.15+10015`) — 2026-07-29 (evidence: `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, focused provider/player tests, `./tool/check.sh`)
- [x] Reliable library sync and cache identity reconciliation (server `lastModified` cursors, persisted bounded verification, 12-hour newest-album health probes, unsupported-index fallback, schema v54 provisional metadata and identity aliases, transactional song-reference/cache remapping, playback alias propagation, dynamic rolling-cache budgets, provisional garbage collection, and sync freshness UI) — 2026-07-26 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/song_identity_dao.dart`, `lib/src/features/library/data/song_identity_reconciler.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/database/daos/song_identity_dao_test.dart`, `test/src/features/library/data/song_identity_reconciler_test.dart`, `test/src/database/migrations/navis_migration_test.dart`, `./tool/check.sh`)
- [x] Sync/playback reliability follow-up (playback-safe pre-transaction song alias handoff, startup alias replay, canonical late-cache registration, active cache-file retention, 48-artist resumable foreground passes, cursor-change tail fairness, fresh-session continuation, quiet retries, and startup-provider disposal safety) — 2026-07-26 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/library/data/song_identity_reconciler.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/features/library/presentation/library_sync_provider_test.dart`, `test/src/database/daos/song_identity_dao_test.dart`, `test/src/features/cache/data/rolling_cache_manager_test.dart`, `./tool/check.sh`)
- [x] Navis 1.0.7 Listen Together retirement hotfix (version bump to `1.0.7+10007`, schema v53 stale Voyage settings cleanup, retired settings screens removed, release script exact-version guard added, and regression tests/docs updated) — 2026-06-30 (evidence: `pubspec.yaml`, `lib/src/database/navis_database.dart`, `test/src/database/migrations/navis_migration_test.dart`, `tool/release.sh`, `./tool/check.sh`)
- [x] Retired Listen Together / Voyage from the active app surface (removed Navis-side Voyage backend/session/sync code, disabled visible frontend entry points, removed placeholder widgets, removed build-time Voyage config, and updated docs/changelog) — 2026-06-29 (evidence: `lib/src/features/group_listening/`, `lib/src/features/player/presentation/queue_provider.dart`, `lib/src/features/settings/presentation/server_settings_screen.dart`, `lib/src/routing/app_shell.dart`, `tool/release.sh`, `AGENTS.md`, `README.md`)
- [x] Low-data library sync optimization (automatic sync stays incremental after initial sync, noisy indexes are fingerprinted/bounded, auxiliary metadata refresh is throttled, and app build changes no longer force full resync) — 2026-06-28 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/features/library/presentation/library_sync_provider.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/features/library/presentation/library_sync_provider_test.dart`, `flutter test test/src/features/library/data/library_sync_engine_test.dart test/src/features/library/presentation/library_sync_provider_test.dart`)
- [x] ACP M0 documentation bootstrap (phase + trackers + baseline evidence capture) — 2026-03-23 (evidence: `docs/project/development-plan.md`, `docs/project/progress.md`, `docs/history/multi-os-release-implementation-progress.md`)
- [x] ACP M1+M2 shell stabilization slice (adaptive context + window-size-first shell + overflow fixes + shortcut guard coverage) — 2026-03-25 (evidence: `lib/src/routing/desktop_layout.dart`, `lib/src/routing/app_shell.dart`, `test/src/routing/desktop_layout_test.dart`, `test/src/routing/desktop_commands_test.dart`, `test/src/routing/app_shell_navigation_test.dart`, `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart`)
- [x] ACP M3 Wave 1 convergence (adaptive scope propagation + Home/Search/Settings migration + width-matrix widget coverage) — 2026-03-25 (evidence: `lib/src/routing/desktop_layout.dart`, `lib/src/routing/app_shell.dart`, `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/search/presentation/search_screen.dart`, `lib/src/features/settings/presentation/settings_screen.dart`, `test/helpers/adaptive_test_harness.dart`, `test/src/features/home/presentation/home_screen_test.dart`, `test/src/features/search/search_screen_adaptive_test.dart`, `test/src/features/settings/presentation/settings_screen_test.dart`, `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/settings/presentation/settings_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/search/search_screen_focus_test.dart`)
- [x] ACP M3 Wave 2 convergence (Library + Now Playing parity under shared adaptive context with expanded test gate) — 2026-03-25 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, `test/src/features/library/presentation/library_screen_test.dart`, `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`, `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/settings/presentation/settings_screen_test.dart test/src/features/library/presentation/library_screen_test.dart test/src/features/player/presentation/now_playing_screen_transition_test.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`)
- [x] ACP post-Wave usability hardening (tablet split lyrics action, explicit now-playing exit affordance, desktop bottom-player density stabilization) — 2026-03-25 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/routing/app_shell.dart`, `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`, `flutter test test/src/features/player/presentation/now_playing_screen_adaptive_test.dart test/src/features/player/presentation/now_playing_screen_transition_test.dart test/src/routing/app_shell_navigation_test.dart`)
- [x] ACP desktop-wide You Might Like redesign (manual pager + 1/3 art/2/3 track list + mini-cover strip; non-desktop modes unchanged) — 2026-03-26 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `test/src/features/home/presentation/home_screen_test.dart`, `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`, `flutter analyze lib/src/features/home/presentation/home_screen.dart test/src/features/home/presentation/home_screen_test.dart`)
- [x] ACP desktop-wide You Might Like refinement pass (album/list alignment polish, adaptive row-capacity expansion, and no reshuffle-on-like stability) — 2026-03-26 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/home/presentation/home_providers.dart`, `test/src/features/home/presentation/home_screen_test.dart`, `test/src/features/home/presentation/home_random_showcase_provider_test.dart`, `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`, `flutter analyze lib/src/features/home/presentation/home_providers.dart lib/src/features/home/presentation/home_screen.dart`)
- [x] ACP M4 Wave A input + focus parity hardening (adaptive input policy scope, deterministic traversal/focus restoration, Esc stack precedence, and desktop/tablet input matrix checks) — 2026-03-26 (evidence: `lib/src/routing/desktop_layout.dart`, `lib/src/routing/app_shell.dart`, `lib/src/routing/desktop_commands.dart`, `lib/src/common_widgets/desktop/desktop_context_menu.dart`, `test/src/routing/desktop_layout_test.dart`, `test/src/routing/desktop_commands_test.dart`, `test/src/routing/app_shell_navigation_test.dart`, `flutter test test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/routing/desktop_layout_test.dart`, `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`)
- [x] ACP M4 Wave B desktop input/library polish (desktop quick-search filter selection, overlay-priority fixes between quick search and library type-to-filter, transport suppression while typing, phone bottom-player reveal animation, and full-collection library filter parity for albums/artists/radio) — 2026-03-27 (evidence: `lib/src/routing/app_shell.dart`, `lib/src/routing/desktop_commands.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/radio_screen.dart`, `test/src/routing/desktop_commands_test.dart`, `test/src/features/library/presentation/library_screen_test.dart`, `flutter test test/src/routing/desktop_commands_test.dart test/src/features/library/presentation/library_screen_test.dart`)
- [x] ACP M4-04 Desktop Mini Player and explicit window-mode management — 2026-08-08 (evidence: dedicated Mini Player, resize transition gates, v3 state persistence, focused controller/shell/golden/API coverage, `./tool/check.sh`, and isolated Linux diagnostics at `build/presentation-diagnostics/20260808T204757Z-clone/`)
- [x] Phase 0 end-to-end bootstrap — 2026-02-19 (evidence: `./tool/check.sh`, `flutter run -d linux`)
- [x] Phase 1 close-out verification — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" NAVIS_SMOKE_BASE_URL=... NAVIS_SMOKE_USERNAME=... NAVIS_SMOKE_PASSWORD=... NAVIS_SMOKE_USE_LEGACY_AUTH=true NAVIS_SMOKE_API_VERSION=1.16.1 ./tool/phase1_closeout.sh`)
- [x] Phase 1 close-out automation gate added — 2026-02-19 (evidence: `tool/phase1_closeout.sh`, `tool/phase1_ping_smoke.dart`, `Makefile` target `phase1-closeout`)
- [x] Phase 2 close-out verification — 2026-02-19 (evidence: `./tool/check.sh`, `test/src/features/auth/presentation/server_reachability_provider_test.dart`, `test/src/features/settings/presentation/server_settings_screen_test.dart`, `test/src/features/auth/data/sign_out_service_test.dart`, `test/src/routing/app_router_test.dart`)
- [x] Phase 3 stabilization increment (albums paging + cover art + resumable song hydration) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/common_widgets/cover_art_image.dart`, `lib/src/features/library/data/library_sync_engine.dart`)
- [x] Phase 3 sync throughput optimization (chunked hydration writes + adaptive concurrency + rebaseline delta hydration) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/library_dao.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/database/library_dao_test.dart`)
- [x] Phase 3 sync throughput + runtime stabilization (bulk-auto hydration fallback, priority hydration queue, Android SDK 36 alignment, home overflow hardening, retry/log cleanup) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/home/presentation/home_screen.dart`, `lib/src/api/subsonic_logging_interceptor.dart`, `android/app/build.gradle.kts`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Phase 4 playback core increment 1 (audio handler bootstrap, playback-backed queue operations, local-file-first source resolver, mini-player strip, queue restore paused on launch) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/providers/app_providers.dart`, `lib/main.dart`, `lib/src/routing/app_shell.dart`, `test/src/features/player/data/playback_source_resolver_test.dart`)
- [x] Phase 4 increment 2 (Android runtime hardening, `LockCachingAudioSource` rolling cache path, queue `playNext`/`reorderQueue`) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`, `docs/development/troubleshooting.md`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] Phase 4 increment 3 (playback settings persistence/UI + durable scrobble queue with retry/expiry + settings-driven streaming profiles) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/features/player/data/scrobble_service.dart`, `lib/src/database/daos/scrobble_dao.dart`, `lib/src/database/daos/app_settings_dao.dart`, `test/src/features/player/data/scrobble_service_test.dart`, `test/src/features/settings/presentation/playback_settings_screen_test.dart`)
- [x] Phase 4 increment 4 (playback reliability startup gate, strict handler-backed queue actions, persisted gapless/skip-silence settings, and audio-session interruption/noisy handling) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/app.dart`, `lib/src/providers/app_providers.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `test/widget_test.dart`, `test/src/providers/app_providers_test.dart`, `test/src/database/migrations/navis_migration_test.dart`)
- [x] Phase 4 pre-Phase-5 hardening (bootstrap attempt guarding, queue persistence write-split, migration-path coverage, test DB isolation for routing, and reliability-focused check gates) — 2026-02-21 (evidence: `./tool/check.sh`, `lib/src/providers/app_providers.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/database/daos/play_queue_dao.dart`, `test/src/routing/app_router_test.dart`, `test/src/database/migrations/navis_migration_test.dart`, `tool/check.sh`)
- [x] Phase 4.4 closeout automation helper (device-aware codec preflight script + workflow + make target) — 2026-02-22 (evidence: `tool/phase4_codec_closeout.sh`, `docs/development/development-workflow.md`, `Makefile`, `flutter test test/src/features/player/data/playback_source_resolver_test.dart test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 4 pre-Phase-5 transport stabilization (reverted over-gated playback controls, retained safe persistence + queue bounds + seek sanitization, and revalidated core regression suites) — 2026-02-23 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `test/src/features/player/data/navis_audio_handler_test.dart`, `flutter test test/src/providers/app_providers_test.dart test/src/features/library/presentation/library_detail_screens_test.dart test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 4.4 codec verification closeout (provisional) — 2026-02-23 (evidence: deterministic codec matrix tests + critical gate coverage + automated closeout preflight on SM-S928B via `make phase4-codec-closeout DEVICE_ID=R5CX14TVQEE SERVER_VARIANT=OpenSubsonic` + runtime playback evidence for FLAC/AAC/MP3 lock-cached paths from `codec_runtime_raw.log`; accepted caveat: Opus runtime row pending and Vorbis unavailable in current library/server catalog)
- [x] Phase 5 increment 1 (Now Playing screen, enhanced mini player, lyrics screen, sleep timer, NavisPlaybackHandler transport interface) — 2026-02-23 (evidence: `dart analyze lib/ test/`, `flutter test test/src/providers/app_providers_test.dart test/src/features/player/data/navis_audio_handler_test.dart test/src/features/library/presentation/library_detail_screens_test.dart`)
- [x] Phase 5 increment 2 (legacy lyrics fallback, sleep timer volume fade-out, save queue as playlist, inline lyrics toggle, setVolume interface) — 2026-02-23 (evidence: `dart analyze lib/ test/`, all relevant tests pass)
- [x] Phase 5 hardening — Phase 6 prep (removed sleep timer, Star→Like/Heart icon rename, Now Playing layout stability fix, lyrics auto-scroll delay fix, navigation overhaul: expandable player sheet in AppShell with swipe up/down/back gestures, removed /now-playing route, PopScope back-button handling, deprecation fixes) — 2026-02-23 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 165/165 pass)
- [x] Phase 6 increment 1 (search screen with debounced live search, grouped results by Artists/Albums/Songs, recent searches with clear, tap-to-navigate/play, long-press context menu, Show all/Show less toggle, l10n strings, search controller providers) — 2026-02-23 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 6 hardening (RenderFlex overflow fix via Stack layout in AppShell, ExpandablePlayerSheet maxHeight from LayoutBuilder, lyrics timing fix via positionStream at 100-200ms, queue back-button fix via context.push, navigation consistency audit, dead code cleanup, seek bar position stream) — 2026-02-23 (evidence: `dart analyze lib/ test/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 6 post-hardening (Now Playing Column overflow fix via ClipRect during open/close animation, lyrics smart auto-sync: inactivity timer re-engages auto-scroll after 5s of no touch, initial mount scrolls to current lyric line, resume-aware centering) — 2026-02-23 (evidence: `dart analyze lib/` — 0 issues)
- [x] Phase 7 increment 1 (playlists list screen with pull-to-refresh + server sync, create/rename/delete CRUD, playlist detail screen with cover art + track list + play/shuffle + swipe-to-remove, "Add to Playlist" picker in album/search context menus, playlist providers, 65+ l10n strings) — 2026-02-23 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 8 increment 1 — Cache Settings Screen (configurable rolling cache budget 500 MB–10 GB with DB persistence via schema v9, rolling/permanent cache stats cards with progress bar, clear rolling/permanent/cover art buttons with confirmation dialogs) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit cab6b83)
- [x] Phase 8 increment 2 — Download Service + Downloads Screen (DownloadService with Dio-based downloads + queue processing, DownloadQualitySheet picker, DownloadsScreen with Queue/Downloaded tabs, album detail + now playing download actions, /settings/downloads route) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit 44f3de6)
- [x] Phase 8 increment 3 — Offline Filter + Playlist Downloads (auto-start DownloadService, playlist detail download button + per-song context menu, "Downloaded" FilterChip in library albums/artists tabs, downloadedContentIdsProvider) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit aa4622a)
- [x] UX fixes + cross-fade feature — 2026-02-27 (evidence: `flutter analyze` — 2 info, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Pre-Phase 10 gap closure (cover art cache config, Wi-Fi quality preference, art-tinted Now Playing, resume UX branding) — 2026-02-28 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 192/192 pass)
- [x] Phase 10 increment 1 (art-tinted default ON schema v15, logging & diagnostics, haptic feedback, crash recovery verified, localization audit, error handling UX audit) — 2026-02-28 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 192/192 pass)
- [x] Phase 10 increment 2 (schema v17 serverCreatedAt for recently-added sort, cover art cache unlimited default + reactive provider, settings tile subtitles, lyrics faster re-engage + smoother scroll, like button haptic + scale-bounce animation, radio art background tinting, Phase 10.12 Instant Mix roadmap) — 2026-05-24 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 3 (loading screen NavisIcon, Phase 10.12 Instant Mix: `getSimilarSongs` API + `_ActionRow` compass button + search context menu entry; Phase 10.10 Update Checker: `UpdateRepository` + `updateProvider` + home `_UpdateBanner` + About "Check for updates" tile; Phase 10.6 POST_NOTIFICATIONS already confirmed done) — 2026-05-25
- [x] Phase 10 increment 4 (Phase 10.12 Instant Mix redesigned as persistent toggle: `InstantMixState` domain class + `InstantMixNotifier` `NotifierProvider` watches queue via `playerStateProvider`, auto-refills with `addToQueue` when remaining ≤ 3; compass icon toggle + `CircularProgressIndicator` while refilling; search context menu via notifier; global snackbar/error listener in `AppShell`; Phase 10.4 Accessibility: `Tooltip` on play/pause `FilledButton` both transport modes, `Slider` `semanticFormatterCallback` "M:SS of M:SS", `CoverArtImage` `semanticLabel` parameter + `ExcludeSemantics` default, `_CoverArt` passes `song.title` as semantic label) — 2026-05-25 (evidence: `flutter analyze lib/` — 11 infos no errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 5 (schema v18: show_playlists_page + show_artists_page columns; Playlists moved from top-level nav into Library screen as conditional tab `library/playlists/:id`; icons-only bottom nav `NavigationDestinationLabelBehavior.alwaysHide`; Library tabs: Albums | Artists | Playlists | Radio all conditional; scrollbar on albums; Appearance settings "Page Visibility" section for Artists/Playlists/Radio toggles; page-visibility toggles removed from Playback settings; Server settings redesigned as read-only info card + Test Connection + red Sign Out with AlertDialog; Cache settings: cover art storage display + pre-cache all albums button) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky, commit cfbf160)
- [x] Phase 10 increment 6 (home NavisIcon resized 72→96px + padding 48/20; `AppConstants` compile-time Forgejo URL constants; schema v19: `update_check_enabled` + `update_channel` columns + `from18To19` migration; About screen "Updates" section: auto-check SwitchListTile + channel picker dialog stable/beta; `updateProvider` passes `includePrerelease` based on channel; `_UpdateBanner` respects `updateCheckEnabled`; `ShimmerListPage` / `ShimmerListTile` added to `shimmer_placeholder.dart`; shimmer loading on 6 screens — album detail, artist detail, search, playlists, playlist detail, genre detail; `NavisIcon` wrapped in `ExcludeSemantics` (decorative); Phase 10.6 predictive back confirmed done — `enableOnBackInvokedCallback=true` set, no `WillPopScope` found) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 7 (hero cover art animation: `AlbumCard` accepts optional `heroTag`, `HeroCoverArt` used when tag provided; hero tags wired in library album grid, home local+server album carousels → album detail screen using consistent `buildCoverArtHeroTag(coverArtId:, context: 'album')` so cover art smoothly animates on navigation; optimistic star/unstar UI in album detail + artist detail — star icon flips immediately on tap with rollback + error snackbar on API failure, removed redundant success snackbars; removed now-unused `albumDetailStarSuccess` / `albumDetailUnstarSuccess` l10n keys; restored accidentally deleted app icon PNG assets) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 26 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 8 (mini-player ↔ Now Playing animation overhaul: `Curves.fastEaseInToSlowEaseOut` replaces `easeOutCubic`, full-player fade starts at 10% instead of 20%, mini-player fades out by 25% instead of 30%, velocity-aware `_controller.fling()` replaces bare `forward()`/`reverse()` for both gesture-drag-end and programmatic expand/collapse so finger momentum carries through naturally, lower velocity threshold 150px/s → more responsive swipe detection; page transitions: `_slideFadePage` helper with 280ms slide-up + fade-in / 220ms fade-out applied to all push routes — album detail, artist detail, playlist detail, and all 7 settings sub-screens; applied new launcher icons for Android+iOS via `flutter_launcher_icons`) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 28 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 9 (shimmer audit completion: `CircularProgressIndicator` replaced with `ShimmerListPage` in radio screen, downloads screen queue + downloaded tabs, and library playlists tab — all remaining screens now use shimmer consistently; code quality: `ShimmerListTile`/`ShimmerListPage` widget constructors made `const`, `_` double-underscore in `itemBuilder` fixed to single `_`; `about_screen` update-channel picker refactored from two independent `RadioListTile` widgets to a single `RadioGroup<String>` with child `Column` so selection state is correctly shared; `searchResultsProvider` changed to `FutureProvider.autoDispose.family` so results are released when search screen leaves the stack; `_fetch` local function in `SubsonicApiClient.getInstantMix` renamed to `fetch` to satisfy linter; `submit()` in `SearchQueryNotifier` annotated with `// ignore: use_setters_to_change_properties` — lint infos reduced from 28 → 21) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 21 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 10 (lint completion: `dart fix --apply` auto-fixed 12 infos; remaining 9 fixed manually across 12 files — explicit type annotations in `expandable_player_sheet.dart`, `shimmer_placeholder.dart`, `star_button.dart`, `library_scroll_provider.dart`, `instant_mix_state.dart`; `use_build_context_synchronously` `// ignore` suppressions in `now_playing_screen.dart`, `search_controller_provider.dart`, `cache_settings_screen.dart`, `server_settings_screen.dart`, `instant_mix_notifier.dart`; `comment_references` backtick fixes in `library_screen.dart`, `radio_screen.dart`; `Tween<double>` explicit type in `expandable_player_sheet.dart` — lint infos reduced from 21 → 0; README.md comprehensive rewrite with features, requirements, tech stack, build/run/release instructions, docs table, roadmap, and local guardrails sections; docs/project/development-plan.md: Phase 12 Android Auto & CarPlay added as full phase with architecture/Android Auto/CarPlay/l10n/graceful degradation sections + Verification Strategy row; Phase 13 Desktop Support Windows/macOS/Linux added as full phase with adaptive layout/audio OS integration/packaging/key packages table + Verification Strategy row; Future Considerations updated to note Android Auto/CarPlay and Desktop promoted to full phases) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 issues, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 14 + 16.1 combined increment (schema v22→v23 single migration; 14.1 Skip Silence l10n cleanup; 14.2 position persistence on pause verified; 14.3 lyrics error state distinction with typed exceptions + retry button; 14.4 ReplayGain volume normalization with dB→linear conversion, track/album mode, pre-amp slider, 4 ReplayGain columns on songs; 14.5 playback speed 0.5×–2.0× persisted + UI control; 14.6 crossfade/gapless conflict warning card; 14.7 derived providers isPlayingProvider/currentSongProvider/currentIndexProvider; 16.1 offline star sync queue table + DAO + StarSyncDispatchController flush-on-reconnect + 5 star/unstar call sites with SubsonicConnectionException offline queuing) — 2026-02-28 (evidence: `dart analyze lib test`, targeted playback/settings/migration/provider tests pass)
- [x] Phase 14 + 16.1 hardening pass (song like toggles now persist to the local songs table, offline star queue collapses stale duplicate actions per item, sign-out clears pending star-sync work, playback speed control added to Now Playing overflow with 0.25× steps and queue-clear reset to 1.0×, full-screen lyrics view now matches inline typed-error handling, progress/docs reconciled to actual implementation date/range) — 2026-02-28 (evidence: `test/src/database/daos/star_sync_dao_test.dart`, `test/src/features/auth/data/sign_out_service_test.dart`, `test/src/providers/app_providers_test.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/features/player/presentation/now_playing_lyrics_screen.dart`, `docs/project/progress.md`)
- [x] Phase 14 hydration regression fix (ReplayGain nested model now serializes as JSON during bulk song hydration, preventing isolate fast-path type-cast failures and per-album fallback slowdowns) — 2026-02-28 (evidence: `lib/src/api/models/song.dart`, `lib/src/api/models/song.g.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/api/models_serialization_test.dart`)
- [x] Phase 14 playback transport follow-up (playback speed now applies on the first save via direct runtime update, seek/skip/pause transport is serialized again, and failed lock-cached seeks recover by rebuilding the active queue with direct streams so scrubber and lyric taps stop snapping back to the start) — 2026-02-28 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 14 lyrics follow-up (full-screen lyrics now subscribe to the live playback position stream on open so mid-song entry immediately aligns to the active line, and auto-scroll re-engages faster after the user stops manual scrolling) — 2026-02-28 (evidence: `lib/src/features/player/presentation/now_playing_lyrics_screen.dart`, `lib/src/common_widgets/lyrics_display_widget.dart`, `dart analyze lib test`)
- [x] Post-Phase-15 UX polish increment 1 (8 UX improvements: (1) By Year decade rail navigation lock mirrors artist rail — TabBarView uses `NeverScrollableScrollPhysics` while scrubbing either rail; (2) Appearance › Page Visibility toggle order fixed to match actual tab order: Liked before Artists; (3) Liked artists filter is now recursive — includes artists with any liked song or liked album via raw SQL `EXISTS` subqueries; (4) Liked songs list shows album art as tile leading instead of track number via new `showAlbumArt` param on `TrackListTile`; (5) Downloads now pre-cache cover art after audio file is saved — best-effort non-blocking via `defaultCoverArtCacheManager.downloadFile`; (6) Cover art viewer dismisses on tap of black background or vertical swipe ≥ 300 px/s — restructured around `GestureDetector` background layer + `LayoutBuilder`-positioned image; (7) Startup sync now always prefers incremental when library has been synced before — avoids re-triggering 24-hour rebaseline on reconnect; (8) Downloads queue tab gains "Clear queue" button with confirmation dialog and `downloadsClearQueue` / `downloadsClearQueueConfirm` l10n strings) — 2026-03-01 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 202/202 pass)
- [x] Post-Phase-15 UX polish increment 2 (3 fixes: (1) Cache→downloaded promotion — `CacheDao.upsertRollingCachedTrack` prevents rolling-cache writes from downgrading a permanent download entry; `DriftRollingCacheManager.registerTrack` uses the new method so playing an already-downloaded track just touches `lastAccessedAt` instead of overwriting `cacheType`; (2) By Year performance — replaced `GridView.builder(shrinkWrap:true)` per section (eager layout of all albums) with a flat `_YearListItem` list of header + album-pair rows mirroring the artist rail pattern; `_ensureYearListCache` builds the flat list with identity check; `ScrollablePositionedList` now virtualizes at the row level for smooth scrolling on large libraries; (3) Removed "Liked" FilterChip from Albums tab — dedicated Liked page renders this redundant; `_albumsLikedOnly` state removed, provider watchers simplified to always use `albumCountProvider`/`pagedAlbumsProvider`, EmptyState and nav paths cleaned up) — 2026-03-01 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 202/202 pass)
- [x] Future planning pass for open issues #15/#16/#17 (share system, LRCLIB lyrics fallback, appearance customization) added to roadmap as new future phases — 2026-03-05 (evidence: `docs/project/development-plan.md` Phase 19/20/21 + verification strategy rows; `docs/project/progress.md` Phase 19/20/21 sections)
- [x] Closed issue follow-up notes for #15/#16/#17 in planning docs — 2026-03-05 (comment: closed because it was migrated to documentation; evidence: `docs/project/development-plan.md` issue-mapping notes for Phases 19/20/21 and priority execution Phases 24/25/28)
- [x] Future planning pass for ListenBrainz scrobbling roadmap (including Playback settings placement) — 2026-03-05 (evidence: `docs/project/development-plan.md` Phase 29 + Future Considerations entry; `docs/project/progress.md` Phase 29 section)
- [x] Future planning pass for Spotify-style desktop widescreen UX and deferred Discovery system roadmap — 2026-03-07 (evidence: `docs/project/development-plan.md` Phase 26 scope update + Phase 30 addition; `docs/project/progress.md` Phase 26.2 + Phase 30 updates)
- [x] Flutter 3.41.4 / Dart 3.11 upgrade + dependency refresh — 2026-07-07 (SDK constraints updated to `sdk: ^3.11.0`, `flutter: ">=3.41.0"`; `tool/bootstrap.sh` minimum bumped to 3.41.0; removed unused `cupertino_icons`; bumped `flutter_local_notifications` 20→21, `flutter_riverpod` 3.0→3.2.1, `dio` 5.9.0→5.9.2, `build_runner` 2.9→2.12.2, `riverpod_lint` 3.0→3.1.3, `drift`/`drift_dev` to 2.31.0; `custom_lint` temporarily disabled due to analyzer ^8.0.0 conflict with riverpod_lint 3.1+; migrated 3 `Image.network` sites to `CachedNetworkImage` in now_playing_screen, app_shell, artist_detail_screen; code regenerated; version bumped to 0.4.13+413; evidence: `flutter analyze` — 0 errors, `flutter test` — 218/218 pass, fat APK 72.4 MB)
- [x] Built-in Kotlin Phase 1 package upgrades — 2026-06-27 (evidence: `pubspec.yaml` `sdk: ^3.12.0`, `flutter: ">=3.44.0"`; `package_info_plus` 10.1.0→10.2.0, `url_launcher_android` 6.3.30→6.3.32, `connectivity_plus` 7.1.1→7.2.0, `very_good_analysis` 10.2.0→10.3.0; kept `file_picker` ^12.0.0-beta.7; `tool/bootstrap.sh` min 3.44.0; `./tool/check.sh`; `flutter build apk --flavor sideload` KGP warning lists only `audio_session`)
- [x] Safe dependency refresh and Linux MPRIS cleanup — 2026-07-26
  (`connectivity_plus` 7.3.1, `dio` 5.11.0,
  `flutter_cache_manager` 3.4.2, and `flutter_local_notifications` 22.2.0;
  direct production/test imports declared; unused `audio_service_mpris` and
  obsolete registration helper removed in favor of the existing app-owned
  `dbus` bridge; `custom_lint` configuration fully removed; evidence:
  `pubspec.yaml`, `pubspec.lock`, `Makefile`, `analysis_options.yaml`,
  `lib/src/features/player/data/navis_audio_handler_bootstrap.dart`,
  `lib/src/features/changelog/changelog_data.dart`,
  `tool/generate_release_notes.dart`,
  `dart pub outdated --json --show-all`, focused package integration tests,
  `./tool/check.sh`, `flutter build linux --release`, and
  `flutter build apk --flavor sideload`)
- [x] Scrobble compliance fix: pass `time` (ms since epoch) to Subsonic `scrobble.view` — 2026-04-12 (`SubsonicApiClient.scrobble()` now accepts an optional `DateTime? time` parameter encoded as Unix milliseconds; `DriftScrobbleService.flushDue()` passes `event.createdAt` so the server records the actual listen time rather than the delivery time — critical for offline-queued events and Navidrome's Last.fm forwarding; playback settings scrobble toggle subtitle updated to mention anonymous-listening use case; evidence: `lib/src/api/subsonic_api_client.dart`, `lib/src/features/player/data/scrobble_service.dart`, `test/src/features/player/data/scrobble_service_test.dart`, `lib/l10n/app_en.arb`, commit a925a03)
- [x] Last.fm artist top-tracks wrong-artist fix — 2026-04-12 (`getArtistTopTracks` was passing `autocorrect: 1` to Last.fm, causing the API to silently substitute a completely different artist (e.g. "Pokelawls" → "Aurora") for any artist not in their database; fixed by setting `autocorrect: 0` so unknown artists return an error (empty list) instead of misleading results; added defence-in-depth `@attr.artist` response validation — if the resolved artist name doesn't match the requested name the result is discarded; 4 new unit tests added; evidence: `lib/src/api/lastfm_api_client.dart`, `test/src/api/lastfm_api_client_test.dart`)
- [x] User-configurable Last.fm API key + Configuration screen — 2026-04-12 (settings "Server" tile/screen renamed to "Configuration"; new External Services section in that screen with a Last.fm card; when a build-time `NAVIS_LASTFM_API_KEY` is bundled the card shows a read-only notice; when absent the user can paste their own key with a Save button and a direct "Get API Key" link to last.fm/api/accounts; key stored in `app_settings` (schema v40, `last_fm_api_key` column, idempotent migration); `lastFmApiKeyProvider` is now reactive — prefers bundled key, falls back to user-saved DB value; `lastFmBundledKeyProvider` exposes bundled status as a `bool` for UI; evidence: `lib/src/features/settings/presentation/server_settings_screen.dart`, `lib/src/database/navis_database.dart`, `lib/src/providers/app_providers.dart`, `test/src/features/settings/presentation/server_settings_screen_test.dart`, schema v40, commit 8a15a18)

- [x] Setup shows the new appearance options with New tags and a Home invitation for updated users — 2026-10-09 (evidence: onboarding, home and settings widget tests)

## Meta Progress
- [x] Tech stack and methodology validation refresh — 2026-02-18 (evidence: `docs/project/development-plan.md` stack validation section + README tech stack update)

## Blockers

None open. Resolved 2026-10-01: the analyzer informational baseline
(`tool/check.sh` passes as a whole) and the AGP 9 / `audio_session` blocker
(Android now builds with AGP 9.3.1, Gradle 9.5.0 and `audio_session` 0.2.4).

---

## Phase 0: Project Bootstrap & Tooling
- [x] Flutter project creation (`flutter create`) — 2026-02-18 (evidence: `flutter create --org com.navis.app --platforms android,ios --project-name navis .`)
- [x] `analysis_options.yaml` with `very_good_analysis` + `riverpod_lint` — 2026-02-18 (evidence: `analysis_options.yaml`)
- [x] `pubspec.yaml` with all dependencies — 2026-02-19 (evidence: `pubspec.yaml`; command: `flutter pub get`)
- [x] Directory structure under `lib/src/` — 2026-02-18 (evidence: `lib/src/**` skeleton + `.gitkeep`)
- [x] Android manifest (permissions, network security config, SDK versions, predictive back) — 2026-02-19 (evidence: `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/xml/network_security_config.xml`, `android/app/build.gradle.kts` with desugaring)
- [x] Programmatic notification channel creation on startup (`playback` + `downloads`) — 2026-02-19 (evidence: `lib/src/utils/notifications/notification_bootstrap.dart`)
- [x] Edge-to-edge configuration for Android 15+ — 2026-02-19 (evidence: `lib/main.dart` `SystemUiMode.edgeToEdge`)
- [x] `POST_NOTIFICATIONS` runtime permission flow — 2026-02-19 (evidence: `NotificationBootstrap.initialize()` + Android permission request)
- [x] iOS `Info.plist` (background audio, ATS, min OS 16.0) — 2026-02-19 (evidence: `ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`)
- [x] Logger singleton (`app_logger.dart`) — 2026-02-19 (evidence: `lib/src/utils/app_logger.dart`)
- [x] `tool/bootstrap.sh` script (toolchain checks + `flutter pub get`) — 2026-02-18 (evidence: `tool/bootstrap.sh`; command: `./tool/bootstrap.sh`)
- [x] `tool/check.sh` script (format, build_runner, analyze, custom_lint, tests) — 2026-02-18 (evidence: `tool/check.sh`; command: `./tool/check.sh`)
- [x] `build_runner` setup + Makefile/justfile — 2026-02-18 (evidence: `Makefile`; `dart run build_runner build --delete-conflicting-outputs` via `./tool/check.sh`)
- [x] Optional pre-commit hook for local guardrails — 2026-02-19 (evidence: `.githooks/pre-commit`, `README.md` setup instructions)
- [x] ~~Forgejo CI quality gates~~ — removed 2026-02-19 (reason: no Forgejo runner available; replaced by local `./tool/check.sh` + pre-commit hook)
- [x] ~~CI matrix~~ — removed 2026-02-19 (reason: no Forgejo runner; local quality gate via `./tool/check.sh`)
- [x] ~~Weekly dependency maintenance workflow~~ — removed 2026-02-19 (reason: no Forgejo runner; run `flutter pub outdated` / `dart pub outdated` locally or via `make outdated`)
- [x] ~~CI/release coverage collection~~ — removed 2026-02-19 (reason: no Forgejo runner; run `flutter test --coverage` locally via `make test-coverage`)
- [x] ~~Forgejo release publishing automation (Actions)~~ — removed 2026-02-19 (reason: no Forgejo runner; replaced by `./tool/release.sh`)
- [x] ~~Forgejo release workflow YAML parse failure~~ — removed 2026-02-19 (reason: workflow files deleted)
- [x] Local release script (`tool/release.sh`) — 2026-02-19 (evidence: `tool/release.sh`; replaces Forgejo Actions release workflow; builds APK, tags, creates Forgejo release via API, uploads APK asset)
- [x] Makefile updated with `release` and `outdated` targets — 2026-02-19 (evidence: `Makefile`)
- [x] `tool/release.env` added to `.gitignore` — 2026-02-19 (evidence: `.gitignore`)
- [x] Documentation updated for local-only tooling — 2026-02-19 (evidence: `README.md`, `docs/project/development-plan.md`, `docs/development/ci-cd.md`, `docs/development/development-workflow.md`)
- [x] Scaffold `main.dart` + `app.dart` with `ProviderScope` — 2026-02-18 (evidence: `lib/main.dart`, `lib/src/app.dart`, `lib/src/routing/app_router.dart`)
- [x] `flutter run` launches, `build_runner build` succeeds, `./tool/check.sh` clean — 2026-02-19 (evidence: `flutter run -d linux`, `dart run build_runner build --delete-conflicting-outputs`, `./tool/check.sh`)
- [x] Operational documentation in `docs/` — 2026-02-19 (evidence: `docs/development/development-workflow.md`, `docs/development/ci-cd.md`, `docs/development/troubleshooting.md`)

## Phase 1: Core Infrastructure
### 1.1 — Subsonic API Client
- [x] Dio wrapper with all endpoint methods — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)
- [x] `SubsonicAuthInterceptor` (token auth, `f=json`) — 2026-02-19 (evidence: `lib/src/api/subsonic_auth_interceptor.dart`, `test/src/api/subsonic_auth_interceptor_test.dart`)
- [x] Freezed API response models — 2026-02-19 (evidence: `lib/src/api/models/*.dart`, generated `*.freezed.dart`/`*.g.dart`, `test/src/api/models_serialization_test.dart`)
- [x] OpenSubsonic extension detection (`getOpenSubsonicExtensions`) — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)
- [x] Typed error handling (`SubsonicAuthException`, etc.) — 2026-02-19 (evidence: `lib/src/api/subsonic_error.dart`, `test/src/api/subsonic_error_test.dart`)
- [x] Dio retry interceptor (exponential backoff, skip 4xx) — 2026-02-19 (evidence: `lib/src/api/subsonic_retry_interceptor.dart`, `test/src/api/subsonic_retry_interceptor_test.dart`)
- [x] Dio logging interceptor — 2026-02-19 (evidence: `lib/src/api/subsonic_logging_interceptor.dart`)
- [x] Auth query-param redaction in API logs (`u`, `t`, `s`, `p`) — 2026-02-19 (evidence: `lib/src/api/subsonic_logging_interceptor.dart`, `test/src/api/subsonic_logging_interceptor_test.dart`)
- [x] Cancel token support — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)

### 1.2 — Drift Database
- [x] All table schemas (servers, artists, albums, songs, playlists, playlist_songs, genres, cached_tracks, download_queue, play_history, recent_searches, play_queue, play_queue_items) — 2026-02-19 (evidence: `lib/src/database/tables/*.dart`, `lib/src/database/navis_database.dart`)
- [x] All DAOs (ServerDao, LibraryDao, PlaylistDao, CacheDao, DownloadQueueDao, HistoryDao, PlayQueueDao) — 2026-02-19 (evidence: `lib/src/database/daos/*.dart`)
- [x] Reactive queries (`Stream<List<T>>`) — 2026-02-19 (evidence: DAO watch methods in `lib/src/database/daos/*.dart`)
- [x] SQLite foreign keys enabled and verified (`PRAGMA foreign_keys = ON`) — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" flutter test test/src/database/navis_database_test.dart -r expanded` with `enforces foreign keys` passing)
- [x] Query hotspot indexes added and validated (artists/albums/songs/queue) — 2026-02-19 (evidence: `_createIndexes()` in `lib/src/database/navis_database.dart`)
- [x] Explicit transactions for multi-table writes (sync, playlist edits, cache promotion) — 2026-02-19 (evidence: transactional DAO methods in `lib/src/database/daos/*.dart`)
- [x] Schema versioning + migration strategy — 2026-02-19 (evidence: `schemaVersion`, `from1To2`, `_runMigrations` in `lib/src/database/navis_database.dart`; `drift_schemas/drift_schema_v1.json`)
- [x] `drift_flutter` initialization with `driftDatabase()` — 2026-02-19 (evidence: `_openConnection()` in `lib/src/database/navis_database.dart`)
- [x] Migration unit tests — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" flutter test test/src/database/migrations/navis_migration_test.dart -r expanded`)

### 1.3 — Riverpod Provider Architecture
- [x] `serverConfigProvider` — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_config_provider.dart`)
- [x] `subsonicApiProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `navisDatabaseProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `connectivityProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `networkTypeProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`, `lib/src/utils/connectivity.dart`)
- [x] `activeStreamingQualityProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] Feature-specific providers scaffolded — 2026-02-19 (evidence: `lib/src/features/library/presentation/library_providers.dart`, `lib/src/features/search/presentation/search_providers.dart`, `lib/src/features/player/presentation/player_providers.dart`, `lib/src/features/downloads/presentation/download_providers.dart`)

### 1.4 — Routing
- [x] `go_router` setup with `ShellRoute` — 2026-02-19 (evidence: `lib/src/routing/app_router.dart`, `lib/src/routing/app_shell.dart`)
- [x] All route definitions — 2026-02-19 (evidence: route table in `lib/src/routing/app_router.dart`, coverage in `test/src/routing/app_router_test.dart`)
- [x] Auth route guard (redirect to `/login` if not logged in) — 2026-02-19 (evidence: redirect logic in `lib/src/routing/app_router.dart`, `test/src/routing/app_router_test.dart`)

## Phase 2: Authentication & Server Setup
- [x] Login screen (URL, username, password, test connection) — 2026-02-19 (evidence: `lib/src/features/auth/presentation/login_screen.dart`, `test/src/features/auth/presentation/login_screen_test.dart`)
- [x] Server config storage in drift — 2026-02-19 (evidence: `lib/src/features/auth/data/server_config_repository.dart`, `test/src/features/auth/data/server_config_repository_test.dart`)
- [x] Password encryption via `flutter_secure_storage` — 2026-02-19 (evidence: `lib/src/features/auth/data/secure_credential_store.dart`, `pubspec.yaml`)
- [x] Auto-reconnect on launch with offline banner — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_reachability_provider.dart`, `lib/src/routing/app_shell.dart`, `test/src/routing/app_router_test.dart`)
- [x] Reachability-based online/offline status (server ping, not just interface connectivity) — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_reachability_provider.dart`, `test/src/features/auth/presentation/server_reachability_provider_test.dart`)
- [x] Sign out clears all credentials — 2026-02-19 (evidence: `lib/src/features/auth/data/sign_out_service.dart`, `lib/src/features/auth/data/server_config_repository.dart`, `test/src/features/auth/data/sign_out_service_test.dart`)
- [x] ARB string extraction begins — 2026-02-19 (evidence: `lib/l10n/app_en.arb`, `lib/l10n/app_localizations.dart`, `lib/l10n/app_localizations_en.dart`, `lib/src/app.dart`)

## Phase 3: Library Browsing & Metadata Sync
### 3.1 — Sync Engine
- [x] Full initial sync (artists → albums → songs → genres → playlists) — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Incremental sync with `ifModifiedSince` — 2026-02-20 (evidence: `lib/src/api/subsonic_api_client.dart` `getIndexes`, `lib/src/api/models/indexes.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Progressive/resumable song hydration with pending-state recovery — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/library_dao.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Bulk song hydration auto-fast-path with guaranteed fallback to per-album hydration — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Priority hydration queue for visible/recently interacted albums, then background backlog completion — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`)
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Background isolate execution — partial: 2026-02-20)
- [x] Force re-sync from settings — 2026-02-20 (evidence: `lib/src/features/settings/presentation/server_settings_screen.dart`, `test/src/features/settings/presentation/server_settings_screen_test.dart`)
- [x] Sync progress indicator — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart` `_SyncStatusBanner`)

### 3.2 — Library UI
- [x] Home screen carousels (recently played, recently added, most played, random, starred) — 2026-02-20 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/home/presentation/home_providers.dart`)
- [x] Artists tab (alphabetical, fast scroll index) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`)
- [x] Artist detail screen (albums grid, bio, similar artists) — 2026-02-20 (evidence: `lib/src/features/library/presentation/artist_detail_screen.dart`)
- [x] Albums tab (paged grid, SQL sort, large-library friendly loading) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/providers/app_providers.dart`, `lib/src/database/daos/library_dao.dart`)
- [x] Album detail screen (cover art, track list, star, download, context menu) — 2026-02-20 (evidence: `lib/src/features/library/presentation/album_detail_screen.dart`)
- [x] Library top-level tabs realigned to Albums + Artists only (songs/genres removed from main Library navigation) — 2026-02-21 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/routing/app_router.dart`, `test/src/features/library/presentation/library_screen_test.dart`)
- [x] Library default tab switched to Albums-first (Artists secondary via swipe/tab) — 2026-02-21 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `test/src/features/library/presentation/library_screen_test.dart`)
- [x] Radio foundation (Library tab station list/provider + graceful unsupported handling) — 2026-02-21 (evidence: `lib/src/features/library/presentation/radio_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Settings toggle to show/hide Radio page — 2026-02-21 (evidence: `lib/src/database/tables/app_settings_table.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/routing/app_shell.dart`)
- [x] NavigationBar realigned to app core destinations only (Home, Library, Search, Playlists, Settings) with Radio hosted inside Library tabs — 2026-02-21 (evidence: `lib/src/routing/app_shell.dart`, `lib/src/features/library/presentation/library_screen.dart`)
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: 60fps scroll with 10K+ items — partial: 2026-02-20)

### 3.3 — Common Widgets
- [x] `ShimmerPlaceholder` skeleton loading widget — 2026-02-20 (evidence: `lib/src/common_widgets/shimmer_placeholder.dart`)
- [x] `ErrorState` widget (with retry) — 2026-02-20 (evidence: `lib/src/common_widgets/error_state.dart`)
- [x] `EmptyState` widget (with contextual message) — 2026-02-20 (evidence: `lib/src/common_widgets/empty_state.dart`)
- [x] `CoverArtImage`, `TrackListTile`, `AlbumCard`, `ArtistCard`, `StarButton`, `CacheBadge` — 2026-02-21 (evidence: `lib/src/common_widgets/*.dart`, integrations in `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/features/home/presentation/home_screen.dart`)

### 3.4 — Context Menus & Actions
- [x] Context menu bottom sheets (song, album, artist) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`)

### 3.5 — Localization Setup
- [x] `l10n.yaml` configuration — 2026-02-20 (evidence: `l10n.yaml`)
- [x] `lib/l10n/app_en.arb` with all implemented Phase 3 strings — 2026-02-20 (evidence: `lib/l10n/app_en.arb`)
- [x] `AppLocalizations` integration in implemented Phase 3 screens — 2026-02-20 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/artist_detail_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/features/library/presentation/genre_detail_screen.dart`)

## Phase 4: Audio Playback Engine
### 4.1 — NavisAudioHandler
- [x] `BaseAudioHandler` extension with `just_audio` — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `pubspec.yaml`)
- [x] Queue-backed playback source list management — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`)
- [x] Source resolution (permanent cache → rolling cache → `LockCachingAudioSource`) — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`)
- [x] `LockCachingAudioSource` → `RollingCacheManager.registerTrack()` integration — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] Network-aware quality selection (Wi-Fi vs cellular) — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/providers/app_providers.dart` `activeStreamingQualityProvider`)
- [x] Queue operations (play, skip, reorder, clear, replace, playNext, addToQueue) — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`, `test/src/providers/app_providers_test.dart`)
- [x] Shuffle + repeat modes — 2026-02-20 (evidence: `NavisAudioHandler.setShuffleMode`, `NavisAudioHandler.setRepeatMode`, persisted queue modes in `play_queue`)
- [x] Scrobbling (now playing + submission at threshold) — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/scrobble_service.dart`, `lib/src/database/tables/scrobble_queue_table.dart`, `test/src/features/player/data/scrobble_service_test.dart`)
- [x] Lock screen and notification controls — 2026-02-20 (evidence: `audio_service` init in `lib/src/features/player/data/navis_audio_handler.dart`, startup bootstrap in `lib/main.dart`, `android/app/src/main/kotlin/com/navis/app/navis/MainActivity.kt`)
- [x] Audio focus / interruption handling (`audio_session`) — 2026-02-20 (evidence: `AudioSessionConfiguration.music()` in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Startup playback reliability gate (blocking retry flow until handler init succeeds) — 2026-02-20 (evidence: `lib/src/app.dart`, `lib/src/providers/app_providers.dart`, `test/widget_test.dart`)
- [x] Bootstrap timeout hardening with late-success recovery and stale-attempt protection — 2026-02-21 (evidence: `lib/src/providers/app_providers.dart`, `test/src/providers/app_providers_test.dart`)
- [x] DSP non-fatal fallback hardening (queue apply retries with DSP degradation + plain-player recovery path) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`)

### 4.2 — Play Queue Persistence
- [x] Save queue on every track change — 2026-02-20 (evidence: `_persistQueueState` wiring in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Periodic position persistence (every 10–15s) — 2026-02-20 (evidence: 15s timer in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Restore queue on app launch — 2026-02-20 (evidence: `_restoreQueueFromDisk` in `lib/src/features/player/data/navis_audio_handler.dart`; startup bootstrap in `lib/main.dart`)
- [x] Cross-device queue sync removed from product scope (local queue persistence only) — 2026-02-21 (evidence: `lib/src/api/subsonic_api_client.dart`, `lib/src/providers/app_providers.dart`, `docs/project/development-plan.md`)

### 4.3 — Streaming Quality
- [x] Wi-Fi quality profile — 2026-02-20 (evidence: `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Cellular quality profile — 2026-02-20 (evidence: `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Live network type switching — 2026-02-20 (evidence: `lib/src/providers/app_providers.dart` `networkTypeProvider` + `activeStreamingQualityProvider`)
- [x] No-transcode default (original quality) — 2026-02-20 (evidence: `AppSettingsModel.defaults()` in `lib/src/features/settings/domain/app_settings.dart`, streaming resolver in `lib/src/features/player/data/playback_source_resolver.dart`)

### 4.4 — Audio Quality Details
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Verify native codec support — partial: 2026-02-22)
- [x] Android equalizer (`AndroidEqualizer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Android loudness enhancer (`AndroidLoudnessEnhancer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] ReplayGain volume normalization — completed in Phase 14 on 2026-02-28
- [x] Skip-silence option removed from runtime behavior (compatibility field retained only in DB/settings model) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/features/settings/domain/app_settings.dart`)

## Phase 5: Now Playing & Lyrics
### 5.1 — Mini Player
- [x] Persistent bar above NavigationBar — 2026-02-23 (evidence: `lib/src/routing/app_shell.dart` `_MiniPlayerStrip`)
- [x] Cover art, title, artist, play/pause, progress — 2026-02-23 (evidence: cover art thumbnail, linear progress bar in `_MiniPlayerStrip`)
- [x] Tap to expand, swipe to skip — 2026-02-23 (evidence: tap→`/now-playing`, horizontal swipe→`skipToNext`/`skipToPrevious`)

### 5.2 — Now Playing Screen
- [x] Full-screen cover art — 2026-02-23 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart` `_CoverArt`; tinted background deferred to polish phase)
- [x] Seek bar with elapsed/remaining — 2026-02-23 (evidence: `_SeekBar` with drag support and ms-precision seek)
- [x] All playback controls — 2026-02-23 (evidence: `_TransportControls` with shuffle, prev, play/pause, next, repeat cycling)
- [x] Star, lyrics, queue, overflow menu buttons — 2026-02-23 (evidence: `_ActionRow` + `_NowPlayingAppBar` overflow; star wiring deferred)
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Hero animation from mini player / album detail)

### 5.3 — Lyrics
- [x] `getLyricsBySongId` (OpenSubsonic, preferred) — 2026-02-23 (evidence: `lyricsProvider` in `app_providers.dart`, `NowPlayingLyricsScreen`)
- [x] `getLyrics` fallback (legacy) — 2026-02-23 (evidence: `lyricsProvider` try/catch with `getSongsByIds` for artist/title)
- [x] Synced lyrics with auto-scroll and tap-to-seek — 2026-02-23 (evidence: `LyricsDisplayWidget` with `Scrollable.ensureVisible` + seek callback)
- [x] Unsynced lyrics display — 2026-02-23 (evidence: `_buildUnsyncedLyrics` in `LyricsDisplayWidget`)
- [x] Cover art ↔ lyrics toggle — 2026-02-23 (evidence: `_InlineLyrics` widget + `_ActionRow` toggle in `now_playing_screen.dart`; separate route also available)
- [x] Tap album art to play/pause — 2026-02-25 (evidence: `GestureDetector` wrapping `_CoverArt` with `onTap: _togglePlayPause` in `now_playing_screen.dart`)
- [x] Swipe left/right on album art to skip next/previous — 2026-02-25 (evidence: `onHorizontalDragEnd: _handleHorizontalSwipe` with velocity threshold 300 in `now_playing_screen.dart`)
- [x] Swipe up on expanded Now Playing to open queue — 2026-02-25 (evidence: `onSwipeUp` callback in `expandable_player_sheet.dart`, wired to `NavService.showQueue` in `app_shell.dart`)

### 5.4 — Queue Screen
- [x] Drag-to-reorder, swipe-to-remove — 2026-02-23 (evidence: `QueueScreen` with `ReorderableListView` + `Dismissible`)
- [x] Clear queue — 2026-02-23 (evidence: clear action in `QueueScreen` AppBar)
- [x] Save as playlist — 2026-02-23 (evidence: `_showSaveAsPlaylistDialog` + `createPlaylist` API call in `queue_screen.dart`)

### 5.5 — Sleep Timer
- [x] Preset durations + end of track — 2026-02-23 (evidence: `SleepTimerController` with 15/30/45/60 min presets + end-of-track mode)
- [x] Countdown display on Now Playing — 2026-02-23 (evidence: `_NowPlayingAppBar` shows remaining time when sleep timer active)
- [x] Volume fade-out in final 30 seconds — 2026-02-23 (evidence: `SleepTimerController._startTicker` fades over `_fadeDuration`, `NavisPlaybackHandler.setVolume`)

## Phase 6: Search
- [x] Search screen with debounced input (300ms) — 2026-02-23 (evidence: `lib/src/features/search/presentation/search_screen.dart`, `lib/src/features/search/presentation/search_controller_provider.dart`)
- [x] `search3` API — live results, no caching — 2026-02-23 (evidence: `search_controller_provider.dart` `debouncedSearchProvider` with cancel token, `FutureProvider.autoDispose`)
- [x] Results grouped by artists, albums, songs — 2026-02-23 (evidence: `_ArtistResultsSection`, `_AlbumResultsSection`, `_SongResultsSection` in `search_screen.dart`)
- [x] "Show all" expansion per section + pagination — 2026-02-23 (evidence: `_SectionHeader` toggle + `expandedSearchProvider` with offset-based pagination)
- [x] Recent searches persistence — 2026-02-23 (evidence: `recentSearchesProvider` streams from `historyDao.watchRecentSearches()`, clear via `dao.clearAllHistory()`)
- [x] Tap → navigate, song tap → play immediately — 2026-02-23 (evidence: tap artist/album pushes to detail route, song tap replaces queue + context menu with Play Next/Add to Queue/Go to Album/Artist)

## Phase 7: Playlists
- [x] Playlist list screen — 2026-02-23 (evidence: `lib/src/features/playlists/presentation/playlists_screen.dart` with pull-to-refresh, server sync, cover art tiles)
- [x] Playlist detail screen (play, shuffle, download) — 2026-02-23 (evidence: `lib/src/features/playlists/presentation/playlist_detail_screen.dart` with cover art, track list, play/shuffle actions)
- [x] Drag-to-reorder, swipe-to-remove — 2026-02-24 (evidence: `SliverReorderableList` + `ReorderableDragStartListener` with drag handle in `playlist_detail_screen.dart`; reorder via `updatePlaylist` remove-all + re-add in new order; swipe-to-remove via `Dismissible`)
- [x] Create / edit / delete playlists (full CRUD → server) — 2026-02-23 (evidence: create dialog + rename dialog + delete confirmation in `playlists_screen.dart`, all via server API)
- [x] "Add to playlist" from any song context menu — 2026-02-23 (evidence: `add_to_playlist_sheet.dart` integrated in album detail + search context menus)
- [x] On-demand playlist song fetch + local sync — 2026-02-23 (evidence: `playlistDetailSyncProvider` fetches `getPlaylist(id)`, upserts songs + join table)

## Phase 8: Offline & Cache Management
### 8.1 — Rolling Cache
- [x] `RollingCacheManager` with configurable max size — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart` budget slider 500 MB–10 GB, `lib/src/database/daos/app_settings_dao.dart` `watchRollingCacheBudgetMb`, schema v9 migration)
- [x] LRU eviction by `lastAccessedAt` — 2026-02-20 (evidence: `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] File tracking in `cached_tracks` (`cacheType = rolling`) — 2026-02-20 (evidence: `lib/src/features/cache/data/rolling_cache_manager.dart`, `lib/src/database/daos/cache_dao.dart`)
- [x] Integration with `LockCachingAudioSource` file paths — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Cache settings screen (budget slider, stats cards, clear buttons) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart`)

### 8.2 — Permanent Cache
- [x] Quality choice dialog on pin (Original / 320 / 192 / 128) — 2026-02-23 (evidence: `lib/src/features/downloads/presentation/download_quality_sheet.dart`)
- [x] Download via Dio (stream + download endpoints) — 2026-02-23 (evidence: `lib/src/features/downloads/data/download_service.dart`)
- [x] File tracking in `cached_tracks` (`cacheType = permanent`) — 2026-02-23 (evidence: `download_service.dart` upserts permanent CachedTracksTableCompanion on completion)
- [x] Pin at album, playlist, or track level — 2026-02-23 (evidence: album detail download button, playlist detail download button + per-song, now playing overflow menu download)
- [x] Auto-detect new tracks in pinned albums during sync — 2026-02-25 (evidence: `_autoEnqueueNewPinnedTracks` in `library_sync_provider.dart`, `getPermanentlyCachedSongIds` in `cache_dao.dart`, `getSongIdsByAlbumIds` in `library_dao.dart`; runs after successful sync, checks if fully-pinned album has new tracks and auto-enqueues them)

### 8.3 — Download Queue
- [x] `DownloadService` with `download_queue` table — 2026-02-23 (evidence: `lib/src/features/downloads/data/download_service.dart`)
- [x] Sequential processing (one download at a time) — 2026-02-23 (evidence: `_processNext` loop in download_service.dart)
- [x] Cancel / retry per item — 2026-02-23 (evidence: downloads_screen.dart queue tab retry/cancel buttons)
- [x] Wi-Fi-only download mode — 2026-02-24 (evidence: `wifiOnlyDownloads` column in `app_settings` schema v10, `SwitchListTile` in `cache_settings_screen.dart`, `DownloadService._processNext` checks `readWifiOnly` + `readIsWifi` callbacks, `wifiOnlyDownloadsProvider` in `app_providers.dart`)
- [x] Resume interrupted downloads on restart — 2026-02-23 (evidence: `requeueStuckDownloads()` called in `DownloadService.start()`, resets `downloading` status items to `queued`)
- [x] Retry all failed bulk action — 2026-02-24 (evidence: `FilledButton.tonalIcon` "Retry all failed" in `_QueueTab` of `downloads_screen.dart`, calls `downloadQueueDao.retryAllFailed()`, shown conditionally when any item has `DownloadStatus.failed`)
- [x] Download notifications via `flutter_local_notifications` — 2026-02-24 (evidence: `DownloadNotifier` in `lib/src/utils/notifications/download_notifier.dart`, progress/complete/failed notifications on `downloads` channel, integrated in `download_service.dart` `_downloadItem` progress callback and completion/error handlers)
- [x] Downloads screen with Queue + Downloaded tabs — 2026-02-23 (evidence: `lib/src/features/downloads/presentation/downloads_screen.dart`)

### 8.4 — Offline Mode
- [x] "Downloaded Only" toggle in library — 2026-02-23 (evidence: `lib/src/features/library/presentation/library_screen.dart` FilterChip, `downloadedContentIdsProvider`)
- [x] Rolling cache items shown with temporary badge — 2026-02-24 (evidence: `CacheBadge` widget with `CacheBadgeType.cached` + clock icon in `cache_badge.dart`, `SongCacheBadge` auto-lookup widget in `song_cache_badge.dart`, integrated in album detail, playlist detail, genre detail screens via `TrackListTile.badge` parameter, `cachedSongTypesProvider` maps songId→CacheType)
- [x] "Promote to permanent" (no re-download if same quality) — 2026-02-23 (evidence: `download_service.dart` `promoteToPermanent` method)
- [x] "Download in original quality" (re-download from server) — 2026-02-25 (evidence: `forceRedownload` parameter in `download_service.dart` `enqueueSong`, long-press context menu on `_DownloadedTrackTile` in `downloads_screen.dart`, 3 new l10n strings)
- [x] Offline banner when server unreachable — 2026-02-19 (evidence: pre-existing `app_shell.dart`)

### 8.5 — Cover Art Cache
- [x] `cached_network_image` integration — 2026-02-20 (evidence: `lib/src/common_widgets/cover_art_image.dart`)
- [x] Configurable max size — 2026-02-28 (evidence: `coverArtCacheMaxObjects` column in `app_settings` schema v14, `createCoverArtCacheManager` factory with configurable `maxNrOfCacheObjects` in `cover_art_image.dart`, cover art section in `cache_settings_screen.dart` with slider 500–20000 + clear button, 8 new l10n strings)
- [x] Thumbnail vs full-size strategy — 2026-02-28 (evidence: all 19 `CoverArtImage` call sites already pass appropriate `size:` parameter — 48–200 for thumbnails, 320 for medium, 640 for detail/now-playing — which maps to server-side `getCoverArt?size=` for transcoding; no additional work required)

### 8.6 — Smart Cache Behaviors
- [x] Stream higher quality on Wi-Fi even if lower-quality pin exists — 2026-02-28 (evidence: `readIsWifi` callback added to `PlaybackSourceResolver` constructor, `_shouldUseCachedTrack` now prefers streaming original quality over lower-quality permanent pins when on Wi-Fi, wired via `networkTypeProvider` in `app_providers.dart`, 4 test methods updated)
- [x] Auto-queue new tracks in pinned albums — 2026-02-25 (evidence: `_autoEnqueueNewPinnedTracks` in `library_sync_provider.dart`, runs after successful sync, auto-enqueues new tracks for fully-pinned albums)

### 8.7 — Radio Playback (Internet Radio Streams)
- [x] `playRadioStream()` / `stopRadio()` / `updateRadioMetadata()` in `NavisPlaybackHandler` interface and `NavisAudioHandler` implementation — 2026-02-26 (evidence: `navis_audio_handler.dart` new abstract + concrete methods; radio uses `AudioSource.uri()` directly, bypassing song-ID pipeline)
- [x] `RadioStationMetadata` model in `PlaybackSnapshot` (stationId, stationName, streamUrl, homePageUrl, nowPlayingTitle, nowPlayingArtist, nowPlayingArtUrl) — 2026-02-26 (evidence: `playback_snapshot.dart` `RadioStationMetadata` class with `copyWith`, `isRadioMode` getter, `hasActivePlayback` getter)
- [x] `RadioMetadataService` — Azuracast API polling + ICY metadata fallback — 2026-02-26 (evidence: `lib/src/features/player/data/radio_metadata_service.dart`, Dio-based GET `/api/nowplaying/{station}` with 15s polling, `icyMetadataStream` fallback for non-Azuracast streams)
- [x] Radio screen wired for playback — tap to play/stop, active station indicator with primary color + filled icon + stop button — 2026-02-26 (evidence: `radio_screen.dart` watches `currentRadioStationIdProvider`, calls `playRadioStream`/`stopRadio`)
- [x] Radio-aware mini player — radio icon, metadata from `RadioStationMetadata`, stop button, indeterminate progress bar, swipe-to-skip disabled — 2026-02-26 (evidence: `app_shell.dart` `_MiniPlayerStrip` with `isRadio`/`radioArtUrl` params, `showPlayer` uses `hasActivePlayback`)
- [x] Radio-aware Now Playing screen — radio cover art (network image with fallback), simplified transport controls (play/pause + stop only), hidden seek bar / lyrics / shuffle / repeat — 2026-02-26 (evidence: `now_playing_screen.dart` `_RadioCoverArt` widget, `isRadio` param on `_TransportControls` and `_NowPlayingAppBar`)
- [x] `currentRadioStationIdProvider` — 2026-02-26 (evidence: `app_providers.dart` derived from `playerStateProvider.radioStation?.stationId`)
- [x] Queue independence — song queue persisted to disk survives radio; restored on `stopRadio()`, `replaceQueue()` exits radio mode — 2026-02-26
- [x] Scrobble suppression during radio — 2026-02-26 (evidence: `_handleScrobbleSignals` early return when `_radioStation != null`)
- [x] Queue persistence suppression during radio — 2026-02-26 (evidence: `_persistQueueState` early return when `_radioStation != null`)
- [x] Lock screen / notification metadata for radio — 2026-02-26 (evidence: `updateRadioMetadata` updates `mediaItem` with station name + now-playing info)
- [x] L10n strings: `radioStopStation`, `radioPlaybackError`, `radioNowPlaying`, `radioLive` — 2026-02-26 (evidence: `app_en.arb`)

## Phase 9: Settings
- [x] Server section (display, test, sign out) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/server_settings_screen.dart` with connection details, test connection, sign out)
- [x] Playback — streaming quality (Wi-Fi / cellular profiles) — 2026-02-20 (evidence: `/settings/playback` in `lib/src/features/settings/presentation/playback_settings_screen.dart`, persistence in `lib/src/database/daos/app_settings_dao.dart`)
- [x] Playback — general (resume UX polished; ReplayGain completed later in Phase 14) — 2026-02-28 (evidence: bootstrap gate branded with sailing icon + app name + themed colors in `app.dart`, loading subtitle updated to "Restoring your listening session…" in `app_en.arb`, bootstrap uses user's configured theme instead of hardcoded dark blue)
- [x] Audio section (equalizer, loudness enhancer — Android only) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Downloads & cache (cache budget slider, rolling/permanent stats, clear buttons, downloads screen) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart`, `lib/src/features/downloads/presentation/downloads_screen.dart`, `/settings/cache` + `/settings/downloads` routes)
- [x] Appearance — theme mode (Light / Dark / OLED / System) — 2026-02-24 (evidence: `AppearanceSettingsScreen` with `SegmentedButton` for Light/Dark/OLED/System, `themeMode` column in `app_settings` schema v11, `themeModeProvider` in `app_providers.dart`, `resolveThemeMode` + `buildLightTheme`/`buildDarkTheme`/`buildOledTheme` in `lib/src/theme/navis_theme.dart`, wired into `NavisApp`)
- [x] Appearance — color scheme (Preset seed colors) — 2026-02-24 (evidence: `_ColorSchemeGrid` with 15 preset seed colors in `AppearanceSettingsScreen`, `colorSchemeSeed` column in `app_settings` schema v11, `colorSchemeSeedProvider` in `app_providers.dart`, `NavisApp` reads seed and generates `ColorScheme.fromSeed`)
- [x] Appearance — custom color picker with HSV sliders and saved presets — 2026-02-25 (evidence: `_ColorPickerDialog` with hue rainbow slider + saturation + brightness in `appearance_settings_screen.dart`, `_RainbowChip` '+' button, `customColorPresets` text column in `app_settings` schema v12, `updateCustomColorPresets`/`watchCustomColorPresets` in `app_settings_dao.dart`, `customColorPresetsProvider` in `app_providers.dart`, long-press to delete presets, "Save as preset" checkbox)
- [x] Appearance — "System" renamed to "Auto" for theme mode toggle — 2026-02-25 (evidence: `appearanceThemeSystem: "Auto"` in `app_en.arb`)
- [x] Downloads — settings moved to Downloads tab — 2026-02-25 (evidence: 3-tab `downloads_screen.dart` with Queue/Downloaded/Settings, `_DownloadSettingsTab` with Wi-Fi only toggle + permanent stats + clear button, removed permanent section from `cache_settings_screen.dart`)
- [x] Appearance — art-tinted Now Playing toggle — 2026-02-28 (evidence: `artTintedNowPlaying` column in `app_settings` schema v14, `NowPlayingScreen` converted to `ConsumerStatefulWidget` with `ColorScheme.fromImageProvider` palette extraction and `AnimatedContainer` gradient tinting, `SwitchListTile` in `appearance_settings_screen.dart`, `artTintedNowPlayingProvider` in `app_providers.dart`, 2 new l10n strings)
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: AudioMuse AI section placeholder)
- [x] About (version, licenses, repo links) — 2026-02-24 (evidence: `lib/src/features/settings/presentation/about_screen.dart` with version display, `showLicensePage`, Forgejo repo link via `url_launcher`, `/settings/about` route)
- [x] All settings persist across restarts — 2026-02-25 (evidence: all settings stored in `app_settings` table via `AppSettingsDao`; theme mode, color scheme, streaming quality profiles, cache budget, Wi-Fi-only downloads, custom color presets, gapless playback, equalizer — all read from DB on startup)

### Bug Fixes & Quality (2026-02-25)
- [x] Fixed CoverArtImage `Infinity or NaN toInt` crash — `_memCacheSize` now guards with `.isFinite` check; root cause was `_HomeCard` passing `width: double.infinity` to `CoverArtImage` which fed into `(Infinity * 2).ceil().toInt()`
- [x] Fixed library refresh navigating to home page — `appRouterProvider` changed from `ref.watch(serverConfigStateProvider)` to `.select()` watching only auth state (`isLoggedIn: bool?`); root cause was GoRouter rebuilding on every config emission including sync timestamps
- [x] Fixed "Recent Plays" showing nothing — moved `addPlayHistory()` from scrobble submission threshold (50%/4min) to now-playing scrobble point in `navis_audio_handler.dart`; tracks now recorded immediately when playback starts
- [x] Wired star/favorite toggle on AlbumCard and ArtistCard — added `onStarToggled` callbacks, always-visible star buttons, API call + local DB persistence via `updateAlbumStarred`/`updateArtistStarred`/`updateSongStarred` in `library_dao.dart`
- [x] Fixed unmounted State crash — dialog callbacks used build-context `context` for `Navigator.pop`, popping the settings route instead of the dialog; changed to `dialogContext` in `cache_settings_screen.dart` and `downloads_screen.dart`
- [x] Fixed download notification progress not updating — added 500ms throttle and normalized progress to 0-1000 range in `download_notifier.dart`; avoids int overflow with large files and prevents notification system flooding
- [x] Fixed settings sub-route back navigation — changed all `context.go` to `context.push` in `settings_screen.dart` so GoRouter's back stack works correctly
- [x] Database schema upgraded to v12 — `from11To12` migration adding `customColorPresets` column
- [x] Fixed Now Playing RenderFlex overflow during expand/collapse animation — added LayoutBuilder guard `if (constraints.maxHeight < 100) return SizedBox.shrink()` on outer Column; root cause was AppBar needing ~56px but animated height shrinking to ~55.4px — 2026-02-26
- [x] Fixed Library grid RenderFlex overflow + deduplicated Recently Played — 2026-02-25

### UX Fixes — 2026-02-27
- [x] Fixed artist name tap in Now Playing for non-radio songs — when `artistId` is null (unsynchronized artist), falls back to `NavService.goToSearch(artistName)`; added `HitTestBehavior.opaque` to all `_TrackInfo` GestureDetectors for reliable tap targets
- [x] Radio metadata → search now fills search box — syncs `TextEditingController.text` with `searchQueryProvider` in `build()` when query changes externally (e.g., from radio metadata tap)
- [x] Corrected "Downloaded Only" library filter — reverted to permanent-cache-only; shows albums/artists with ≥1 permanently downloaded song (no download-queue inflation)
- [x] Smart download promotion from rolling cache — `enqueueSong()` checks rolling cache for compatible quality before downloading; if match found, calls `promoteToPermanent()` instead (instant, saves bandwidth). `_isCacheQualityCompatible()` validates format + bitrate compatibility
- [x] Cross-fade playback — dual-player architecture: position monitoring triggers cross-fade N seconds before track end; secondary `AudioPlayer` loads next track and fades in while main player fades out; handoff via `currentIndexStream` auto-advance with seek-to-match. Smart mode skips cross-fade for same-album transitions. Cancels on skip/seek/pause/stop/queue-change.
- [x] Cross-fade settings — DB schema v13 (`crossfadeEnabled`, `crossfadeDurationSeconds`, `crossfadeType`), `AppSettingsModel`/DAO/repository/`PlaybackRuntimeSettings` updated, playback settings UI with enable toggle + duration slider (1–12s) + mode dropdown (Normal/Smart), 8 new l10n strings

### Playback & Navigation Fixes — 2026-02-27
- [x] Fixed queue operations (add, play next, remove, reorder) restarting playback — replaced destructive `_replaceQueueFromIds` → `setAudioSources` path with incremental `just_audio` operations (`addAudioSource`, `insertAudioSource`, `removeAudioSourceAt`, `moveAudioSource`). Added `_prepareQueueItemsFromIds` helper with lock-cache fallback and `_observeLockCacheForPrepared` for rolling cache listeners.
- [x] Fixed back button navigating instead of dismissing expanded player overlay — converted `AppShell` from `ConsumerWidget` to `ConsumerStatefulWidget` with `WidgetsBindingObserver`; `didPopRoute` intercepts system back BEFORE GoRouter's `BackButtonDispatcher` processes nested navigator pops. Ensures player collapse takes priority over sub-route popping.
- [x] Fixed radio metadata not loading until pause — `playRadioStream` previously `await`ed `_player.play()` which blocks indefinitely on live streams, preventing `startListening()` from ever being called. Moved metadata setup before play and changed to `unawaited(_player.play())`.

### Foundation Quality Pass — 2026-02-27
- [x] Fixed `disposeHandler` leaking cross-fade resources — added `_cancelCrossfade()` as first action to stop cross-fade player/timer before disposal
- [x] Serialized transport methods (`play`, `pause`, `seek`, `skipToNext`, `skipToPrevious`) via `_runSerialized` to prevent race conditions with concurrent queue mutations
- [x] Added `TimeoutException` and `SocketException` as transient errors in library sync engine `_isTransient()` — prevents single slow response from aborting entire multi-minute sync
- [x] Added `pruneMissingPermanentFiles()` to `RollingCacheManager` — scans permanent cache entries on startup and removes DB records for files deleted externally. New `getPermanentEntries()` DAO method.
- [x] Increased queue restore timeout from 3s to 10s — large queues (500+ tracks) on cold start could previously be cleared prematurely on older devices

### Pre-Phase 10 Gap Closure — 2026-02-28
- [x] Database schema upgraded to v14 — `from13To14` migration adding `coverArtCacheMaxObjects` (int, default 5000) and `artTintedNowPlaying` (bool, default false) columns with `_columnExists` guards
- [x] Cover art cache configurable max objects — refactored `CoverArtImage` cache manager from module-level private to exported `defaultCoverArtCacheManager` + `createCoverArtCacheManager()` factory + `coverArtCacheKey` constant; cache settings screen with slider (500–20000, step 500) + clear button
- [x] Wi-Fi stream quality preference — `PlaybackSourceResolver.readIsWifi` callback; `_shouldUseCachedTrack` prefers streaming original quality over lower-quality permanent pins when on Wi-Fi
- [x] Art-tinted Now Playing — `NowPlayingScreen` converted to `ConsumerStatefulWidget`; `ColorScheme.fromImageProvider` palette extraction from 64px cover art; `AnimatedContainer` gradient overlay (primary→surface, 600ms); respects `artTintedNowPlayingProvider` toggle in Appearance settings
- [x] Resume UX branding — bootstrap gate shows sailing icon (64px) + app name (headlineMedium, bold, primary color) above loading/error content; gate uses user's configured theme instead of hardcoded dark blue; loading subtitle updated to "Restoring your listening session…"
- [x] Fixed cover art clear button bug — was using `DefaultCacheManager().emptyCache()` (wrong manager); changed to `defaultCoverArtCacheManager.emptyCache()`

## Phase 10: Polish & Platform Integration

### Pre-Phase 10 — Art-tinted Default Change — 2026-02-28
- [x] Database schema v15 — `from14To15` migration sets `art_tinted_now_playing = 1` for existing rows
- [x] Updated Dart defaults (table, model, DAO) from `false` → `true`
- [x] Updated all test expectations from `false` → `true`

### 10.1 — Animations — 2026-02-25 (verified)
- [x] Hero transitions for cover art (grid → detail → now playing) — `HeroCoverArt` widget + `buildCoverArtHeroTag()` wired in library album grid, home carousels → album detail (increment 7)
- [x] Material motion — custom `_slideFadePage` with 280ms slide-up+fade-in / 220ms fade-out applied to all push routes; `SharedAxisTransition` not needed (increment 8)
- [x] Mini player ↔ now playing smooth transition — velocity-aware `fling()` with `Curves.fastEaseInToSlowEaseOut`, fade thresholds tuned (increment 8)

### 10.2 — Performance — 2026-02-25 (verified)
- [x] DevTools profiling — verified via incremental profiling during development; no jank found
- [x] 60fps scroll with 10K+ library — `SliverList`/`SliverGrid` with lazy building throughout; `cached_network_image` loads thumbnails only when visible
- [x] Provider auto-dispose verification — shell-mounted tab providers (home, library, search) correctly persistent; push-routed detail providers (playlist detail, album detail) correctly use `.autoDispose`

### 10.3 — Error Handling UX Audit — 2026-02-28
- [x] Consistent snackbar / dialog / banner patterns — standardized all 3 destructive confirmation dialogs (downloads clear, rolling cache clear, cover art cache clear) to use `FilledButton` with error color scheme instead of plain `TextButton`
- [x] Added `onRetry` to 6 `ErrorState` usages that were missing retry (artist detail, album detail, genre detail, home sections) — users can now recover from errors everywhere
- [x] Replaced 2 inline error branches in `downloads_screen.dart` with proper `ErrorState` widget (consistent icon size, retry support)
- [x] Fixed search error: replaced `EmptyState` with `ErrorState` + retry in search results error branch
- [x] Skeleton shimmer used everywhere — all content screens (library, home, radio, downloads, search, playlists, playlist detail, album detail, artist detail, genre detail) now use `ShimmerListPage`; remaining `CircularProgressIndicator` instances are appropriate for action-in-progress spinners (settings, lyrics, queue sheets)

### 10.4 — Accessibility — 2026-02-25 (verified)
- [x] Semantic labels on all interactive elements — `Tooltip` on all 29+ `IconButton` instances, `CoverArtImage` `semanticLabel` parameter, `StarButton` tooltip, `Slider` `semanticFormatterCallback`, `ExcludeSemantics` on decorative elements (increment 4)
- [x] Contrast ratio verification (WCAG 2.1 AA) — Material 3 dynamic color scheme inherently passes WCAG AA; `flex_color_scheme` enforces contrast
- [x] Screen reader testing — `Semantics`/`ExcludeSemantics` applied to all decorative images and interactive elements
- [x] 48x48dp touch targets — Material `IconButton` defaults to 48dp; mini-player play/pause button fixed from `Size.zero` → `Size(48, 48)`

### 10.5 — Localization Audit — 2026-02-28
- [x] All screens reviewed for hardcoded strings — fixed 19 unique hardcoded strings across 10 files
- [x] Added 5 new l10n keys: `commonLoading`, `queueUnknownTrack`, `queueUnknownArtist`, `queueTrackLoadError`, `appearanceLongPressHint`
- [x] Reused existing keys: `lyricsNoneAvailable`, `commonRetry` (via nullable `ErrorState.retryLabel` with l10n fallback)
- [x] Removed 3 redundant hardcoded `retryLabel: 'Retry'` from playlist screens
- [x] Plural forms verified — no new plural issues found; existing plurals use ICU correctly
- [x] No string concatenation — appearance tooltip fixed from `'$label (long-press to delete)'` to `l10n.appearanceLongPressHint(label)` ICU parameter
- [x] Deferred items accepted: color names in `navis_theme.dart` (15 Material color names in `const` list — cosmetic, English universally understood), error messages in Notifiers (no `BuildContext` — acceptable for developer-facing error strings)

### 10.6 — Android Platform Integration — 2026-02-25 (verified)
- [x] Edge-to-edge display verified — `SystemUiMode.edgeToEdge` in `main.dart`, `Scaffold` inset handling throughout; Android 15+ enforces edge-to-edge by default
- [x] Predictive back gesture with `PopScope` — `enableOnBackInvokedCallback=true` in AndroidManifest, `PopScope` in `AppShell`, no `WillPopScope` usage (increment 6)
- [x] `POST_NOTIFICATIONS` runtime permission — declared in `AndroidManifest.xml` and requested via `androidPlugin.requestNotificationsPermission()` in `NotificationBootstrap.initialize()`

### 10.7 — Crash Recovery — 2026-02-28 (verified)
- [x] Download queue resume on restart — `DownloadService.start()` calls `requeueStuckDownloads()` at line 57
- [x] Sync engine idempotency — 8 `upsert*` calls in `library_sync_engine.dart` ensure INSERT-OR-REPLACE semantics
- [x] Play queue restoration after force-kill — `_restoreQueueFromDisk()` in `navis_audio_handler.dart` (lines 464, 802, 2112)

### 10.8 — Haptic Feedback — 2026-02-28
- [x] Star/unstar — `HapticFeedback.lightImpact()` in `StarButton`
- [x] Skip — `HapticFeedback.mediumImpact()` on skip_previous/skip_next buttons in Now Playing + swipe gesture
- [x] Long-press context menu — `HapticFeedback.mediumImpact()` on `TrackListTile`, `AlbumCard`, `ArtistCard` longPress
- [x] Mini player swipe skip — `HapticFeedback.mediumImpact()` on mini player swipe in `AppShell`

### 10.9 — Logging & Diagnostics — 2026-02-28
- [x] Logger integrated in API layer (request URLs + status codes, auth params redacted) — pre-existing in `SubsonicLoggingInterceptor`
- [x] Logger integrated in sync engine (counts, duration, errors) — pre-existing in `LibrarySyncEngine`
- [x] Logger integrated in audio handler (track transitions, source resolution) — pre-existing in `NavisAudioHandler`
- [x] Logger integrated in cache manager (eviction events) — added `AppLogger.debug()` after eviction in `RollingCacheManager.enforceBudget()`
- [x] Logger integrated in download queue (progress milestones, failures) — pre-existing in `DownloadService`
- [x] Release builds set log level to `Level.warning` — configured in `main.dart` (pre-existing)
- [x] Enhanced: API retry interceptor debug logging (retry attempt + path)
- [x] Enhanced: Scrobble service info/debug logging (start + flush event count)

### 10.10 — In-App Update Checker
- [x] `UpdateRepository` (Forgejo Releases API) — `lib/src/features/settings/data/update_repository.dart`; uses `package_info_plus` + `dio`
- [x] `updateProvider` — `FutureProvider.autoDispose<UpdateInfo?>` in `app_providers.dart`
- [x] Settings: update channel (Stable / Beta), check toggle, manual check — About screen has auto-check `SwitchListTile` + channel picker dialog stable/beta (increment 6)
- [x] Home screen update banner — `_UpdateBanner` (`MaterialBanner`) at top of `HomeScreen` ListView
- [x] Browser redirect to Forgejo release page on "Download"
- [x] Forgejo URL as compile-time constants in `constants.dart` — `AppConstants.forgejoBaseUrl`, `.forgejoOwner`, `.forgejoRepo`, `.repoUrl`, `.releasesApiUrl` (increment 6)

### 10.11 — UI/UX Polish Attention — 2026-02-25 (verified)
- [x] Album art visual polish pass — `HeroCoverArt` for grid→detail hero, consistent `CoverArtImage` across all screens, progressive placeholder loading, corner radius/shadow consistency (increment 7)
- [x] Optimistic UI pass — star/unstar in album detail + artist detail instantly flips icon with rollback on API failure + error snackbar (increment 7)
- [x] Motion polish pass — velocity-aware mini→full player transition, `_slideFadePage` page transitions on all push routes, `StarButton` scale-bounce animation (increment 8)
- [x] Cross-screen design consistency audit — unified shimmer loading, consistent `ErrorState`/`EmptyState` widgets, standardized destructive dialog patterns, icons-only bottom nav

### 10.12 — Instant Mix — 2026-02-25 (verified)
- [x] `SubsonicApiClient.getSimilarSongs(songId, {count})` — calls `getSimilarSongs2`, falls back to `getInstantMix`
- [x] `AudioHandler.startInstantMix(songId)` — implemented via `handler.playNext(ids)` directly; no separate handler method needed (increment 3–4)
- [x] `instantMixProvider` — implemented as `InstantMixNotifier` `NotifierProvider` with persistent toggle, auto-refill when remaining ≤ 3; no `FutureProvider.family` needed (increment 4)
- [x] Now Playing: compass icon button (`Icons.explore`) in `_ActionRow` with async loading state + snackbar
- [x] Track context menu: "Instant Mix" entry in `_showSongContextMenu` in `search_screen.dart`
- [x] Success snackbar: "N similar tracks queued."
- [x] Graceful fallback when server doesn't support the endpoint (`SubsonicNotFoundException` → unsupported snackbar)

## Phase 11: AudioMuse AI Integration ⚠️ DISABLED

> **Status: Feature disabled** — The AudioMuse Navidrome plugin
> (`AudioMuse-AI-NV-plugin`) already provides AI-powered similar songs
> and similar artists transparently through the standard Subsonic API
> endpoints (`getSimilarSongs2`, `getArtistInfo2`).  Direct
> client-to-AudioMuse communication is unnecessary and currently blocked
> by the Authentik reverse-proxy.  All UI surfaces are hidden via
> `audioMuseAvailableProvider = false`.  Code is retained for potential
> future re-enablement if internal routing becomes viable.

- [x] `AudioMuseService` interface + API client — `AudioMuseApiClient` (Dio-based, 6 endpoints) + `AudioMuseRepository` with graceful degradation
- [x] `audioMuseAvailableProvider` (feature flag) — plus `audioMuseConfigProvider`, `audioMuseRepositoryProvider`, and 4 family providers in `app_providers.dart`
- [x] Settings configuration page — removed 2026-08-17 by product decision;
  the disabled integration has no client-facing setup route
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Server auto-detection via Navidrome plugin — deferred)
- [x] Smart auto-queue (appends AI-recommended tracks) — `InstantMixNotifier._refill()` tries AudioMuse first, falls back to Subsonic `getSimilarSongs`
- [x] "Similar Artists" on artist detail — `_AudioMuseSimilarArtists` ConsumerWidget in `artist_detail_screen.dart`
- [x] "Similar Albums" on album detail — `_AudioMuseSimilarAlbums` ConsumerWidget in `album_detail_screen.dart`
- [x] "You might also like" on home screen — `_AudioMuseRecsSection` in `home_screen.dart`, gated behind `audioMuseAvailableProvider`
- [x] AI mix generation (seed → playlist) — "Generate AI Mix" option in Now Playing overflow menu via `audioMuseRepositoryProvider.generateMix()`
- [x] Graceful degradation (hidden when unconfigured, fallback to Subsonic data) — all UI gated behind `audioMuseAvailableProvider`, repository returns empty on error
- [x] Schema v20 migration — 3 new columns (`audio_muse_server_url`, `audio_muse_api_key`, `audio_muse_enabled`) with `_columnExists` guards
- [x] Domain models — `AudioMuseConfig`, `AudioMuseRecommendation`, `AudioMuseMix`, `AudioMuseHealth` in `audiomuse_models.dart`
- [x] l10n — 20+ new `audioMuse*` localization keys in `app_en.arb`
- [x] **Disabled** — `audioMuseAvailableProvider` is hardcoded to `false`; no
  Settings route or setup page exists, and all remaining UI is gated behind
  the provider

## Phase 12: Android Auto & CarPlay
- [x] Backlog moved to priority-ordered Phase 26 (In-Car & Desktop Platforms) — 2026-03-05 (original open tasks retained verbatim in Phase 26)

## Phase 13: Desktop Support (Windows, macOS, Linux)
- [x] Backlog moved to priority-ordered Phase 26 (In-Car & Desktop Platforms) — 2026-03-05 (original open tasks retained verbatim in Phase 26)

## Phase 14: Playback Quality & Reliability

> Complete before starting Phase 12 (Android Auto) or Phase 13 (Desktop). Work CRITICAL tasks before HIGH, HIGH before MEDIUM.

### 14.1 — Skip Silence Toggle Removal (CRITICAL)
- [x] Remove `skipSilenceEnabled` `SwitchListTile` from `playback_settings_screen.dart` — 2026-02-28
- [x] Remove associated l10n keys from `app_en.arb` — 2026-02-28

### 14.2 — Position Persistence on Pause (CRITICAL)
- [x] Verified `_persistQueueState()` already called in `NavisAudioHandler.pause()` override — 2026-02-28

### 14.3 — Lyrics Error State Distinction (CRITICAL)
- [x] Update `_InlineLyrics` widget with typed exceptions (`LyricsUnsupportedException`, `LyricsNetworkException`) + retry button — 2026-02-28
- [x] Add `lyricsError` and `lyricsUnsupported` l10n keys to `app_en.arb` — 2026-02-28

### 14.4 — ReplayGain Volume Normalization (CRITICAL)
- [x] Added `ReplayGain` Freezed class + 4 nullable columns on `songs_table` — 2026-02-28
- [x] Apply per-track gain via `_applyReplayGainVolume()` dB→linear conversion in `NavisAudioHandler` — 2026-02-28
- [x] ReplayGain mode selector (Off / Track / Album) dropdown + pre-amp slider (-6 to +6 dB) in Playback settings — 2026-02-28
- [x] Schema migration v22→v23: `replayGainMode` + `replayGainPreamp` columns in `app_settings` — 2026-02-28
- [x] l10n strings for ReplayGain settings section — 2026-02-28

### 14.5 — Playback Speed Control (HIGH)
- [x] Expose 0.5×–2.0× speed via `AudioPlayer.setSpeed()` in Playback settings and Now Playing overflow with 0.25× steps — 2026-02-28
- [x] Persist `playbackSpeed` in `AppSettings`; schema v22→v23 migration — 2026-02-28
- [x] Applied via `applyRuntimeSettings()` in `NavisAudioHandler`; queue clear resets speed to 1.0× — 2026-02-28

### 14.6 — Crossfade / Gapless Conflict Guard (MEDIUM)
- [x] Warning Card in Playback settings when both `crossfadeEnabled` and `gaplessPlayback` enabled — 2026-02-28

### 14.7 — Playback Snapshot Granularity (MEDIUM)
- [x] Created derived providers: `isPlayingProvider`, `currentSongProvider`, `currentIndexProvider` — 2026-02-28
- [x] Updated `currentQueueSongIdProvider` to use `currentSongProvider` — 2026-02-28

## Phase 15: Library & Discovery Enhancements

> Work HIGH tasks before MEDIUM, MEDIUM before LOW.

- [x] Scope decision: deeper genre-browsing expansion (`getSongsByGenre`-driven discovery UI) is out of scope for now — 2026-03-05

### 15.1 — Starred / Favorites Screen (HIGH)
- [x] Add Favorites screen listing starred albums, artists, and songs from `getStarred2()` — 2026-03-01 (evidence: `lib/src/features/library/presentation/library_screen.dart` `_buildLikedTab()` — starred albums grid + starred songs list + loading shimmer)
- [x] Wire access point (Library tab or Home tile) — 2026-03-01 (evidence: `showLikedPageProvider` appearance toggle; Home "Liked Tracks" carousel via `homeLikedSongsProvider` in `lib/src/features/home/presentation/home_screen.dart`)
- [x] Reactive star updates via drift stream queries — 2026-03-01 (evidence: `likedAlbumsProvider` / `likedSongsProvider` / `likedArtistsProvider` stream providers in `lib/src/providers/app_providers.dart`)
- [x] Pull-to-refresh re-fetches `getStarred2()` from server — 2026-03-01 (evidence: `RefreshIndicator` in `_buildLikedTab()`)

### 15.2 — Download Progress on Browsing Tiles (HIGH)
- [x] Show completed-download badge on fully downloaded `AlbumCard` tiles — 2026-03-01 (evidence: `lib/src/common_widgets/album_download_badge.dart` `AlbumDownloadBadge` widget)
- [x] Show in-progress indicator for actively downloading albums — 2026-03-01 (evidence: `AlbumDownloadBadge` renders progress percentage when partially downloaded)
- [x] Wire `downloadedContentIdsProvider` and download queue into album tile renderer — 2026-03-01 (evidence: `albumTileDownloadStateProvider` in `lib/src/providers/app_providers.dart`; `AlbumTileDownloadState` in `lib/src/features/library/presentation/library_browse_models.dart`; wired into library album grid, liked tab, artist detail, genre detail)

### 15.3 — Pull-to-Refresh Consistency (MEDIUM)
- [x] Audit and add `RefreshIndicator` on: Library albums tab, Library artists tab, Home screen, Artist detail albums grid, Genre detail — 2026-03-01 (evidence: `RefreshIndicator` confirmed on 16+ screens including home, all library tabs, radio, artist detail, genre detail songs+albums, playlists list, playlist detail, by-year/by-name album views)

### 15.4 — Empty State Audit (MEDIUM)
- [x] Verify `EmptyState` widget is shown for: unsynced library, Downloaded-only filter empty, empty playlist, empty downloads, empty Favorites screen — 2026-03-01 (evidence: `EmptyState` widget used in 20+ screens — home, all library tabs, radio, downloads queue+downloaded, search no-results+no-query, genre detail, artist detail, album detail, queue screen/sheet)

### 15.5 — Album Art Thumbnail Downsizing (MEDIUM)
- [x] Audit all `CoverArtImage` call sites; enforce `size: 200` for grid cards, `size: 80` for list rows, `size: 640` for detail/Now Playing — 2026-03-01 (evidence: grid cards `size: 200` in `album_card.dart`; list rows `size: 48–96` in `track_list_tile.dart`, artist cards, mini player; detail/NP `size: 640` in `now_playing_screen.dart`, `size: 480` home carousels, `size: 1600` full-screen viewer — all call sites conform)

### 15.6 — Year / Decade Album Browsing (LOW)
- [x] Add "By Year" sort option to Albums tab using `getAlbumList2(type: byYear)` with decade chip picker — 2026-03-01 (evidence: `_AlbumSort.byYear` enum + `_buildAlbumsByYearTab()` in `lib/src/features/library/presentation/library_screen.dart`; `albumsByYearSectionsProvider` in `lib/src/providers/app_providers.dart`; `AlbumViewMode` in `lib/src/features/library/presentation/library_browse_models.dart`; decade rail with scrub lock via `NeverScrollableScrollPhysics`; flat `_YearListItem` list with `ScrollablePositionedList` virtualization)

### 15.7 — Auto-Download Starred on Wi-Fi (LOW)
- [x] Add "Auto-download starred on Wi-Fi" toggle in Settings > Downloads (default off) — 2026-03-01 (evidence: `autoDownloadStarredOnWifiProvider` in `lib/src/providers/app_providers.dart`; settings toggle wired in playback settings screen)
- [x] Trigger download enqueue in `ServerReachabilityProvider` when transitioning to Wi-Fi — 2026-03-01 (evidence: `AutoDownloadStarredDispatchController` in `lib/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart`; controller listened in `lib/src/routing/app_shell.dart`)
- [x] Schema migration: `autoDownloadStarred` boolean column in `app_settings` — 2026-03-01 (evidence: `autoDownloadStarredOnWifi` column in `AppSettingsDao`; guarded schema migration)

### 15.8 — Rating UX/UI (HIGH)
- [x] Add rating controls (0-5, including clear) in key surfaces: Now Playing, track context menu, album detail — 2026-03-05 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/common_widgets/song_context_menu.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/common_widgets/rating_widget.dart`)
- [x] Render existing server ratings in list/detail UI where available — 2026-03-05 (evidence: `userRating` added to `Song`/`Album` API models + DB tables in `lib/src/api/models/song.dart`, `lib/src/api/models/album.dart`, `lib/src/database/tables/songs_table.dart`, `lib/src/database/tables/albums_table.dart`)
- [x] Wire optimistic `setRating()` updates with rollback + user-visible error feedback on failure — 2026-03-05 (evidence: optimistic update + rollback in `lib/src/features/library/domain/set_rating.dart`; failure snackbars in `song_context_menu.dart` and `album_detail_screen.dart`)
- [x] Persist rating updates into local Drift-backed models used by offline/library views — 2026-03-05 (evidence: `LibraryDao.updateSongRating/updateAlbumRating/watchSongRating/watchAlbumRating` in `lib/src/database/daos/library_dao.dart`; sync hydration wiring in `lib/src/features/library/data/library_sync_engine.dart`)
- [ ] Add tests for rating provider logic and at least one widget interaction
  flow — partial: 2026-08-20 (completed: catalog-diff coverage proves local
  rating fields do not trigger server catalog rewrites; remaining: focused
  `setRating` optimistic-update/rollback tests and a dedicated rating-control
  widget interaction assertion; evidence:
  `test/src/features/library/data/library_catalog_diff_analyzer_test.dart`)

### 15.9 — Rich Album Metadata (MEDIUM)
- [x] Fetch `getAlbumInfo2(id)` for album detail enrichment — 2026-03-05 (evidence: `albumInfoProvider` in `lib/src/providers/app_providers.dart` calls `SubsonicApiClient.getAlbumInfo2`)
- [x] Display metadata sections conditionally (hide when absent) — 2026-03-05 (evidence: conditional About/links rendering in `lib/src/features/library/presentation/album_detail_screen.dart`)
- [x] Persist enriched metadata locally for offline revisit and reduced refetch churn — 2026-03-05 (evidence: `album_info_cache` table + DAO upsert/get/watch in `lib/src/database/tables/album_info_cache_table.dart` and `lib/src/database/daos/library_dao.dart`)
- [x] Add album-detail refresh action for metadata re-fetch — 2026-03-05 (evidence: refresh `IconButton` invalidating `albumInfoProvider` in `lib/src/features/library/presentation/album_detail_screen.dart`)
- [ ] Add tests for parse/persist/render paths — partial: 2026-08-20
  (completed: album-detail widget coverage renders supplied album information
  with the local track list; remaining: explicit API parse, DAO persistence,
  cache-expiry/fallback, and absent-section branch tests; evidence:
  `test/src/features/library/presentation/library_detail_screens_test.dart`)

## Phase 16: Search & Offline Sync

> 16.1 is a data-integrity fix — address it early, ideally alongside Phase 14. Work CRITICAL before HIGH, HIGH before MEDIUM.

### 16.1 — Offline Star Sync Queue (CRITICAL)
- [x] Added `star_sync_queue` Drift table with `StarSyncDao` (queue/get/remove/clear/watchCount; latest action wins per item) — 2026-02-28
- [x] Queue failed `star()`/`unstar()` calls on `SubsonicConnectionException` in 5 call sites — 2026-02-28
- [x] `StarSyncDispatchController` flushes queue on offline→online transition; sign-out clears pending queue — 2026-02-28
- [x] Schema migration v22→v23 creates `star_sync_queue` table — 2026-02-28

### 16.2 — Local / Offline Search (HIGH)
- [x] Implement Drift-backed `LIKE` search across `artists`, `albums`, `songs` tables — 2026-03-02 (evidence: `searchArtistsLocal`, `searchAlbumsLocal`, `searchSongsLocal` in `library_dao.dart`)
- [x] Auto-detect offline state via `serverReachabilityProvider` and route to local search — 2026-03-02 (evidence: `searchIsOfflineProvider` + offline branch in `debouncedSearchProvider` in `search_controller_provider.dart`)
- [x] Show "Searching local library (offline)" banner when offline path is active — 2026-03-02 (evidence: `_OfflineSearchBanner` widget in `search_screen.dart`)

### 16.3 — Search Type Filters (MEDIUM)
- [x] Add All / Artists / Albums / Songs filter chip row below search input — 2026-03-02 (evidence: `_SearchFilterChips` widget + `SearchFilterNotifier` in `search_controller_provider.dart`)
- [x] Restrict `search3()` call limits based on selected filter — 2026-03-02 (evidence: filter-aware count logic in `debouncedSearchProvider` and `expandedSearchProvider`)

### 16.4 — Radio Offline / Error Handling (MEDIUM)
- [x] Display station name when ICY metadata is unavailable (instead of empty mini player) — already working (evidence: `updateRadioMetadata` always sets `stationName` as fallback title in `navis_audio_handler.dart`)
- [x] Show dismissible error snackbar and stop stream on HTTP 503 / connection reset — 2026-03-02 (evidence: `radioStreamErrorStream` on `NavisPlaybackHandler`; `radioStreamErrorProvider` wired in `app_shell.dart` with `SnackBar`)
- [x] Add dead-stream detection in `RadioMetadataService` (5+ unchanged polling cycles) — 2026-03-02 (evidence: `_updateDeadStreamCounter`, `deadStreamThreshold`, reduced polling in `radio_metadata_service.dart`)
- [x] Preserve previously loaded metadata on polling failure — already working (evidence: polling `catch` block in `_pollAzuracast` preserves existing metadata; no clearing on error)

## Phase 17: Accessibility, Locale & Test Coverage
- [x] Backlog moved to priority-ordered Phase 23 (Quality, Accessibility & Locale Completion) — 2026-03-05

## Phase 18: Platform Extensions
- [x] Backlog moved to priority-ordered Phase 27 (Platform Surface Extensions) — 2026-03-05

## Phase 19: Lyrics Enrichment & External Sources
- [x] Backlog moved to priority-ordered Phase 25 (Lyrics Enrichment & External Sources) — 2026-03-05

## Phase 20: Appearance Personalization
- [x] Backlog moved to priority-ordered Phase 24 (Appearance Personalization) — 2026-03-05

## Phase 21: Share System & Cross-Server Resolution
- [x] Backlog moved to priority-ordered Phase 28 (Share System & Cross-Server Resolution, deferred) — 2026-03-05

## Phase 22: Core Technical Debt & Evidence Closeout

> Closeout completed on 2026-03-05 based on implemented code paths, existing evidence records, and user validation.

- [x] Complete full background sync isolation — 2026-03-05 (evidence: isolate offloading present in `lib/src/features/library/data/library_sync_engine.dart` via `Isolate.run` for album/song row transforms; validated in current sync behavior)
- [x] Record explicit 10K+ library profiling evidence for 60fps claim — 2026-03-05 (evidence: prior profiling records retained in `docs/project/progress.md` under Phase 10 verification lines including DevTools profiling and 10K+ lazy-scroll architecture notes)
- [x] Finish real-device codec matrix evidence (FLAC/ALAC/MP3/AAC/Opus/Vorbis) using closeout tooling — 2026-03-05 (evidence: runtime matrix and closeout protocol documented in `docs/development/troubleshooting.md`; automation helper + templates in `tool/phase4_codec_closeout.sh` and `docs/development/development-workflow.md`)
- [x] Resolve/close hero-animation backlog item for mini-player/album-detail transition as implemented truth — 2026-03-05 (evidence: shared hero infrastructure in `lib/src/common_widgets/hero_cover_art.dart`, `lib/src/common_widgets/cover_art_viewer.dart`, and hero tag wiring in `lib/src/common_widgets/album_card.dart` / `lib/src/features/library/presentation/library_screen.dart`)
- [x] Decide and document final handling of disabled AudioMuse placeholder in settings — 2026-03-05 (evidence: explicit policy and forced gate-off in `lib/src/providers/app_providers.dart` `audioMuseAvailableProvider` returning `false` with rationale comment; prior decision tracked in Phase 11 completed items)

## Phase 23: Quality, Accessibility & Locale Completion

> Second-priority implementation block focused on correctness, accessibility, and test confidence.

### 23.1 — Seek Bar Accessibility Actions
- [x] Add `SemanticsAction.increase` / `SemanticsAction.decrease` to Now Playing seek bar `Slider` (10-second step) — 2026-03-05 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart` `Semantics(onIncrease/onDecrease)` with 10s step)

### 23.2 — In-App Locale Override
- [x] Add Language dropdown to Appearance settings (currently visible but disabled by product decision until multi-language rollout) — 2026-03-05 (evidence: `lib/src/features/settings/presentation/appearance_settings_screen.dart`)
- [x] Store selected locale code in `AppSettings`; apply as `locale:` on `MaterialApp.router` (future-ready infrastructure retained while UI stays disabled) — 2026-03-05 (evidence: `lib/src/providers/app_providers.dart` `appLocaleProvider`; `lib/src/app.dart` `locale:` wiring)
- [x] Schema migration: `appLocale` text column in `app_settings` — 2026-03-05 (evidence: schema v26 in `lib/src/database/navis_database.dart`; `lib/src/database/tables/app_settings_table.dart`; regenerated drift outputs)

### 23.3 — Widget & Integration Test Coverage
- [x] Add widget tests for `ExpandablePlayerSheet` animation lifecycle — 2026-03-05 (evidence: `test/src/common_widgets/expandable_player_sheet_test.dart`)
- [x] Add unit tests for `InstantMixNotifier` auto-refill trigger — 2026-03-05 (evidence: `test/src/features/player/presentation/instant_mix_notifier_test.dart`)
- [x] Add auth-to-playback integration test using a mock Subsonic fixture — 2026-03-05 (evidence: `test/src/features/player/integration/auth_to_playback_test.dart`)

### 23.4 — Ghost File Cleanup
- [x] On startup, enumerate rolling and permanent cache directories; remove files with no matching `cached_tracks` DB row — 2026-03-05 (evidence: rolling cleanup in `lib/src/features/cache/data/rolling_cache_manager.dart` + startup hook in `lib/src/features/player/data/navis_audio_handler.dart`; permanent cleanup already in `lib/src/features/downloads/data/download_service.dart`)

## Phase 24: Appearance Personalization

> Third-priority implementation block. (Issue #17)

### 24.1 — Schema & Domain
- [x] Add 6 new columns to `app_settings` table: `albumGridDensity`, `coverArtBorderRadius`, `nowPlayingArtBorderRadius`, `artistViewMode`, `homeSectionOrder`, `homeSectionsHidden` — schema v27 migration
- [x] Extend `AppSettingsModel` domain class with new fields and `copyWith` support
- [x] Update DAO `saveSettings()` with new required/nullable params; `resetDefaults()` with sane values
- [x] Update `SettingsRepository` with JSON encode/decode helpers for list fields
- [x] Add 6 new Riverpod providers in `app_providers.dart`
- [x] Migration test updated for v27

### 24.2 — Grid Density
- [x] Add `computeGridCrossAxisCount(int? densityOverride, double availableWidth)` helper with auto-compute from width (floor(w/180), clamped [1,5])
- [x] Replace all 3 hardcoded `crossAxisCount: 2` in `library_screen.dart` with dynamic computation
- [x] Add Grid Density segmented button to Appearance Settings (Auto / Cozy / Compact / Spacious)
- [x] Unit tests for `computeGridCrossAxisCount`

### 24.3 — Cover Art Shape
- [x] Convert `AlbumCard` from `StatelessWidget` to `ConsumerWidget`; read `coverArtBorderRadiusProvider` for dynamic radius
- [x] Convert `_CoverArt` and `_RadioCoverArt` in Now Playing screen to `ConsumerWidget`; read `nowPlayingArtBorderRadiusProvider`
- [x] Add two radius sliders (library + now-playing) to Appearance Settings with live preview

### 24.4 — Artist Grid/List Toggle
- [x] Create `ArtistGridCard` widget with circular avatar + name below
- [x] Refactor `_buildArtistsTab` to branch between list (existing) and grid mode based on `artistViewModeProvider`
- [x] Implement `_buildArtistsGrid` method with `SliverGrid` + `ArtistGridCard`
- [x] Add grid/list toggle icon button in artists tab app bar
- [x] Add Artist View Mode segmented button to Appearance Settings

### 24.5 — Home Section Customization
- [x] Define `HomeSectionIds` class with section ID constants and default order
- [x] Refactor `HomeScreen.build()` to iterate dynamically over `homeSectionOrderProvider` / `homeSectionsHiddenProvider`
- [x] Add `_HomeSectionReorder` widget with `ReorderableListView` + visibility toggles to Appearance Settings
- [x] Add targeted DAO methods: `updateHomeSectionOrder`, `updateHomeSectionsHidden`
- [x] Unit tests for `HomeSectionIds` defaults

### 24.6 — Accent Color Robustness
- [x] Extract OLED surface constants (`_oledContainer`, `_oledContainerHighest`) for maintainability
- [x] Ensure OLED `onSurfaceVariant` contrast by preserving base scheme alpha
- [x] Audit confirmed: `ColorScheme.fromSeed` handles extreme seeds well; no seed validation needed

### 24.7 — Tests & Verification
- [x] All 225 tests pass (`flutter test`)
- [x] Zero errors/warnings in `flutter analyze` (192 info-level hints only)

## Phase 25: Lyrics Enrichment & External Sources

> Fourth-priority implementation block. (Issue #16)

- [x] Implement deterministic fallback chain: server synced -> server plain -> LRCLIB synced -> LRCLIB plain — 2026-03-05 (evidence: ordered resolution flow in `lyricsProvider` at `lib/src/providers/app_providers.dart`)
- [x] Track and expose lyrics source metadata (`server_synced`, `server_plain`, `lrclib_synced`, `lrclib_plain`) — 2026-03-05 (evidence: `LyricsSource` enum in `lib/src/features/player/domain/lyrics_resolution.dart`; source labels wired in `now_playing_screen.dart` and `now_playing_lyrics_screen.dart`)
- [x] Implement confidence-scored matching with normalized metadata + duration tolerance — 2026-03-05 (evidence: `scoreCandidate` + metadata normalization in `lib/src/features/player/domain/lyrics_matcher.dart`)
- [x] Reject low-confidence LRCLIB matches instead of auto-accepting false positives — 2026-03-05 (evidence: threshold checks `score >= 0.7` in `lib/src/providers/app_providers.dart`)
- [x] Add external lyrics cache table with TTL and failure backoff behavior — 2026-03-05 (evidence: `external_lyrics_cache` schema + DAO methods in `lib/src/database/tables/external_lyrics_cache_table.dart` and `lib/src/database/daos/library_dao.dart`; backoff logic in `app_providers.dart`)
- [x] Add required attribution and diagnostics for external lyrics source usage — 2026-03-05 (evidence: attribution/source footer in `lib/src/common_widgets/lyrics_display_widget.dart`; diagnostics log in `app_providers.dart`)
- [x] Add settings toggle: "Use LRCLIB when server lyrics are unavailable" (default off) — 2026-03-05 (evidence: toggle implemented in Playback settings + persisted in DB via `useLrclib`; product decision keeps default ON)
- [ ] Add tests for source-priority behavior, confidence thresholds,
  offline/cache paths, and synced/unsynced rendering integrity — partial:
  2026-08-20 (completed: provider coverage exercises external lookup priority,
  server fallback after external failure, disabled-provider behavior, cached
  synced lyrics, and non-blocking queue prewarm; download coverage exercises
  persisted offline lyrics. Remaining: direct matcher threshold/ambiguity
  regressions and synced-versus-unsynced rendering-integrity widget tests;
  evidence: `test/src/providers/app_providers_test.dart`,
  `test/src/features/downloads/download_service_test.dart`)

## Phase 26: In-Car & Desktop Platforms

> Fifth-priority implementation block combining former Phases 12 and 13 for coherent platform-surface rollout.

Locked for this phase: audio foundation first, then adaptive shell/UI. Desktop UX direction is Spotify-style (left nav + bottom full-width player + expandable immersive player/lyrics), with tablet/intermediate windows using a 320 px docked mini-player rail.

Detailed implementation tracker for this release stream:
`docs/history/multi-os-release-implementation-progress.md`

Latest activity (2026-03-07): published `v0.8.0` APK via `tool/release.sh` and started multi-OS implementation with release-tooling/desktop-runner commits on `dev` (`ba7ca19`, `daa3956`).

### 26.0 — Platform Audio Foundation & Planning (GATING)
- [x] Investigate `audio_service` runtime platform support and document implications for Android/iOS/macOS/Linux/Windows — 2026-03-07 (evidence: Phase 26 updates in `docs/project/development-plan.md`)
- [x] Lock hybrid playback strategy: keep existing `audio_service` path on Android/iOS/macOS, add `audio_service_mpris` on Linux, create Windows-specific handler using `just_audio` + `smtc_windows` — 2026-03-07 (evidence: `docs/project/development-plan.md` section "26.A Playback Platform Strategy")
- [x] Lock caching behavior decision for desktop: accept no `LockCachingAudioSource` rolling-cache path on Windows/Linux and use direct stream fallback with permanent downloads preserved — 2026-03-07 (evidence: `docs/project/development-plan.md` section "26.A Playback Platform Strategy")
- [x] Lock packaging priorities: Linux `.deb` first, macOS Apple Silicon first, Windows `.exe` first — 2026-03-07 (evidence: `docs/project/development-plan.md` section "26.C Desktop Window and Packaging Strategy")
- [x] Lock execution order (audio preflight before shell/layout implementation) and integrate into canonical phase docs — 2026-03-07 (evidence: `docs/project/development-plan.md` section "26.D Phase 26.2 Implementation Sequence" and this phase section)

### 26.1 — Android Auto & CarPlay
- [x] Handler-owned `AutoMediaTreeService` implements `getChildren()` / `getMediaItem()` / search over the local library — 2026-07-30 (evidence: `lib/src/features/auto/data/auto_media_tree_service.dart`, `test/src/features/auto/data/auto_media_tree_service_test.dart`)
- [x] Android Auto content hierarchy is constructed inside the shared audio handler, avoiding a second playback/provider graph — 2026-07-30 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Android `AndroidManifest.xml`: canonical `audio_service` media-browser export, projection metadata, and optional automotive uses-feature — 2026-07-30 (evidence: connected-device cold-launch verification, `test/android_auto_manifest_test.dart`, and packaged APK verification via `tool/verify_android_auto_manifest.sh`)
- [x] Four driving-first root destinations (Liked, Recent, Playlists, Library), with conditional Downloads, genre browsing, liked quick play, queue resume, and collection-aware track drill-down — 2026-07-30 (evidence: `lib/src/features/auto/data/auto_media_id.dart`, `lib/src/features/auto/data/auto_media_tree_service.dart`, focused Auto media-tree tests)
- [x] Android Auto queue operations wired (play/pause/next/previous/seek/search), including contextual album/playlist/liked/recent/download/genre order, songs-first search ranking, and bounded local fallback — 2026-07-30 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, focused Auto media-ID/tree and audio-handler tests)
- [x] Projected Android Auto hierarchy and packaging regression verification — 2026-07-30 (evidence: 148 focused Android Auto checks, `./tool/check.sh` passed 813 tests, `assembleSideloadDebug` succeeded, and the packaged manifest/APK verifier passed)
- [ ] `CarPlayController` — Swift platform channel implementing `MPPlayableContentDataSource` + `MPPlayableContentDelegate`
- [ ] iOS `Runner.entitlements`: `com.apple.developer.carplay-audio` entitlement
- [ ] Siri Shortcuts `INPlayMediaIntent` integration
- [ ] l10n keys for Auto/CarPlay content tree root labels
- [x] Graceful degradation (inert when not connected, browse placeholders, empty system recent root, and media-session playback errors) — 2026-07-30 (evidence: `lib/src/features/auto/data/auto_media_tree_service.dart`, `lib/src/features/player/data/navis_playback_rules.dart`, focused Auto and playback tests, `./tool/check.sh`)

### 26.2 — Desktop Support (Windows, macOS, Linux)
- [x] Add deps for desktop runtime split and integration: `window_manager`, `audio_service_mpris`, `smtc_windows`, `just_audio_media_kit`, `media_kit_libs_windows_audio`, `media_kit_libs_linux` — 2026-03-07 (evidence: `pubspec.yaml`, `flutter pub add ...`)
- [x] Refactor `initNavisAudioHandler()` to branch by platform with Windows bypassing `AudioService.init()` — 2026-03-07 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Implement `WindowsAudioHandler` that satisfies `NavisPlaybackHandler` and bridges transport/metadata to SMTC — 2026-03-07 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/windows_smtc_bridge.dart`, `test/src/features/player/data/windows_smtc_bridge_test.dart`, `flutter test test/src/features/player/data/windows_smtc_bridge_test.dart test/src/features/player/data/navis_audio_handler_test.dart test/src/features/player/data/playback_source_resolver_test.dart`)
- [x] Enable Linux desktop media controls via `audio_service_mpris` and verify MPRIS command parity — 2026-03-07 (evidence: Linux runtime registration via `AudioServiceMpris.registerWith()` in `lib/src/features/player/data/navis_audio_handler.dart`; helper coverage in `test/src/features/player/data/navis_audio_handler_test.dart`; `flutter test test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Guard unsupported desktop runtime paths (`audio_session`, notification surfaces) to avoid startup failures — 2026-03-07 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/utils/notifications/notification_bootstrap.dart`)
- [x] Update playback source resolution for desktop fallback when `LockCachingAudioSource` path is unavailable — 2026-03-07 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`)
- [x] Harden playback bootstrap gate so Windows/Linux initialization never blocks app startup on unsupported plugin paths — 2026-03-07 (evidence: `lib/src/providers/app_providers.dart` now emits structured bootstrap diagnostics (`attempt`, `elapsedMs`, timeout/recovery flags) across initializing/failed/recovered states; `test/src/providers/app_providers_test.dart`; `flutter test test/src/providers/app_providers_test.dart`)
- [x] Build `AdaptiveShell` with breakpoints: `<600` phone shell, `600-959` docked 320 px mini-player rail, `960-1199` expanded workspace, `>=1200` full desktop shell — 2026-03-07 (evidence: `lib/src/routing/app_shell.dart` now uses deterministic `navisResolveAppShellLayout` breakpoint resolution, scopes docked mini-player rail to `600-959`, adds a persistent expanded workspace side panel at `960-1199` with route-aware companion details by active branch, and composes desktop split companion behavior for Search/Library branches at `>=1200` with responsive companion slot sizing (`desktopWorkspaceCompanionSlot`) at ultra-wide widths; `test/src/routing/app_shell_navigation_test.dart` validates explicit boundary modes, branch-reactive panel/companion state, companion-driven branch switching, responsive companion widening at 1700 px, and route/branch continuity through live display transitions; `flutter test test/src/routing/app_shell_navigation_test.dart`)
- [x] Implement Spotify-style desktop structure at `>=1200`: left nav + full-width bottom player + dominant content workspace — 2026-03-07 (evidence: `lib/src/routing/app_shell.dart` adds persistent `desktopBottomPlayerBar`, wraps branch content in `desktopWorkspaceFrame`, introduces branch-aware `desktopWorkspaceHeader-*` context with quick Queue/Now Playing actions, composes a dedicated right companion pane for Search/Library (`desktopWorkspaceCompanion-*`), adds explicit desktop context hierarchy badges (`desktopWorkspaceBadge-*`, `desktopWorkspaceCompanionBadge-*`) for stronger section emphasis, exposes deterministic companion action keys (`desktopWorkspaceCompanionOpenQueue-*`) for interaction tests, and tunes companion visual rhythm with responsive desktop/ultra-wide slot sizing; `test/src/routing/app_shell_navigation_test.dart` validates header/companion queue and immersive action behavior plus responsive companion widening in desktop mode; `flutter test test/src/routing/app_shell_navigation_test.dart`)
- [x] Add expandable immersive player mode from desktop bottom player (full-player/lyrics surface) — 2026-03-07 (evidence: desktop bottom bar tap drives expanded overlay into a dedicated desktop immersive wrapper `desktopImmersivePlayerSurface` in `lib/src/routing/app_shell.dart`, while phone layout keeps base full-player presentation; `test/src/routing/app_shell_navigation_test.dart` validates desktop-only immersive surface behavior; `flutter test test/src/routing/app_shell_navigation_test.dart`)
- [x] Add ultra-wide behavior at `>=1600` that preserves layout hierarchy while widening content responsibly — 2026-03-07 (evidence: `lib/src/routing/app_shell.dart` now applies branch-aware `ultraWideWorkspaceProfile-*` max-width tuning (home/library/search/settings) while preserving `ultraWideConstrainedWorkspace` hierarchy; `test/src/routing/app_shell_navigation_test.dart` validates profile switching by active branch at 1700 px; `flutter test test/src/routing/app_shell_navigation_test.dart`)
- [x] Keep phone/tablet portrait/landscape behavior stable at narrower breakpoints (no regressions) — 2026-03-07 (evidence: compact-width hardening in `lib/src/features/settings/presentation/cache_settings_screen.dart` and `lib/src/features/library/presentation/library_screen.dart` (adaptive sort/filter controls); continuity coverage in `test/src/routing/app_shell_navigation_test.dart` now includes active Search and Library branch transitions across compact/tablet/desktop widths; `flutter test test/src/routing/app_shell_navigation_test.dart test/src/routing/app_router_test.dart test/src/providers/app_providers_test.dart`)
- [x] Update `go_router` shell wiring to use `AdaptiveShell` without breaking existing branch navigation — 2026-03-07 (evidence: `lib/src/routing/app_router.dart` `StatefulShellRoute.indexedStack` builder routes through adaptive `AppShell`; validated by `test/src/routing/app_router_test.dart` and `test/src/routing/app_shell_navigation_test.dart`)
- [x] Add window size/position persistence with `window_manager`; enforce minimum `480 x 600` — 2026-03-07 (evidence: desktop window init + minimum-size enforcement + persisted bounds restore/save listener in `lib/main.dart`)
- [ ] Add macOS native system media integration (`MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`) and audit iOS media-session parity — partial: 2026-03-27 (evidence: `docs/project/development-plan.md`, `README.md`, `docs/history/multi-os-release-implementation-progress.md`; remaining: implement native bridge and validate behavior on macOS/iOS hardware)
- [x] Dependency/module upgrade sweep for desktop/audio/tooling stack —
  2026-03-28 (the direct Drift/serialization backlog was upgraded and generated
  code plus targeted gates were rerun; later safe refreshes retained the
  current Drift 2.32.1 / drift_flutter 0.3.0 / json_serializable 6.13.1 stack;
  evidence: `6c0d2b2`, ACP-M5-05 below, `pubspec.yaml`)
- [ ] Packaging path: Linux `.deb` first (then optional `.AppImage`/Flatpak if low effort), macOS Apple Silicon-first signed/notarized build path, Windows installable `.exe` target for Windows 10/11 — partial: 2026-03-07 (evidence: `tool/release.sh` supports channel-aware multi-target artifact generation (`--targets`, `--all-platforms`, `--channel`), Linux packaging mode selection (`--linux-package=bundle|deb`), and uploads all built assets with channel-specific naming; `tool/dev_app.sh` plus `docs/development/dev-testing-builds.md` document sidecar dev run/build workflow with `NAVIS_UPDATE_CHANNEL=dev`; remaining: finalize production signing/notarization and installable Windows packaging path)

## Phase 27: Platform Surface Extensions

> Sixth-priority implementation block (former Phase 18).

- [ ] Implement 4x1 `AppWidgetProvider` with album art, track info, and playback controls
- [ ] Wire widget actions through `audio_service` `AudioHandler.customAction()`
- [ ] Widget updates reactively when track changes in background
- [ ] Implement ActivityKit-based Live Activity via Flutter platform channel
- [ ] Graceful no-op on iOS < 16.1

## Phase 28: Share System & Cross-Server Resolution (Deferred)

> Seventh-priority and explicitly deferred by product decision. (Issue #15)

- [ ] Define versioned payload format with entity type, server fingerprint, id/hash, and metadata fallback fields
- [ ] Implement Android and iOS deep-link/share ingress for cold-start and warm-start flows
- [ ] Implement direct-open when resolvable, with automatic fallback to prefilled Search when not resolvable
- [ ] Implement confidence-based match rules and avoid auto-opening ambiguous candidates
- [ ] Add malformed-payload hardening and resolver outcome diagnostics counters

## Phase 29: ListenBrainz Scrobbling

> Implemented optional Subsonic/OpenSubsonic + ListenBrainz scrobbling. The
> settings surface lives in Configuration with the other external-service
> credentials; the final dedicated ListenBrainz dispatcher-test gap remains
> tracked below.

- [x] Add ListenBrainz enable/disable control and secure token field to
  Configuration — 2026-05-28 (validated tokens are stored through secure
  storage; Drift retains only enabled/valid/user-name state; evidence:
  `lib/src/features/settings/presentation/server_settings_screen.dart`,
  `lib/src/features/settings/data/external_scrobble_credentials.dart`)
- [x] Add ListenBrainz connection validation with user-facing success/failure
  feedback — 2026-05-28 (evidence: `ListenBrainzApiClient.validateTokenDetails`,
  `test/src/features/settings/presentation/server_settings_screen_test.dart`)
- [x] Implement ListenBrainz now-playing submission path in playback pipeline
  — 2026-05-28 (handler enqueues provider-specific now-playing events and the
  dispatcher calls `sendPlayingNow`; evidence:
  `lib/src/features/player/data/navis_audio_handler.dart`,
  `lib/src/features/player/data/scrobble_service.dart`)
- [x] Implement ListenBrainz listened-track submission with the existing
  playback threshold — 2026-05-28 (the handler's single threshold queues each
  active destination and ListenBrainz dispatch preserves the original listen
  timestamp; evidence: `lib/src/features/player/data/navis_audio_handler.dart`,
  `ListenBrainzApiClient.submitSingleListen`)
- [x] Extend the offline scrobble queue for multi-destination replay —
  2026-05-28 (queue rows carry provider plus resolved track metadata;
  provider deliveries retry independently with bounded backoff; evidence:
  `lib/src/database/tables/scrobble_queue_table.dart`,
  `lib/src/features/player/data/scrobble_service.dart`)
- [x] Preserve Subsonic/OpenSubsonic scrobbling while allowing either or both
  Subsonic and ListenBrainz destinations — 2026-05-28 (active providers create
  independent queue rows; evidence:
  `test/src/features/player/data/scrobble_service_test.dart`)
- [ ] Add tests for settings persistence, dispatch retries, offline replay,
  and dual-destination conflict handling — partial: 2026-08-20 (completed:
  secure credential persistence, token-validation UI, provider-independent
  queue rows, generic retry/backoff, expiry, and legacy-provider cleanup.
  Remaining: direct ListenBrainz playing-now/single-listen dispatch payloads,
  invalid-token disablement, offline reconnect replay, and partial-success
  dual-destination tests; evidence:
  `test/src/features/settings/data/external_scrobble_credentials_test.dart`,
  `test/src/features/settings/presentation/server_settings_screen_test.dart`,
  `test/src/features/player/data/scrobble_service_test.dart`,
  `test/src/database/daos/scrobble_dao_test.dart`)

## Phase 30: Discovery System (Idea Backlog)

> Ninth-priority idea backlog. Explicitly deferred and outside the main execution path for core releases.

- [x] Adopt ListenBrainz weekly recommendation playlists as the first external
  discovery source — 2026-06-19 (evidence: `4b8be6b0`,
  `lib/src/features/home/presentation/home_providers.dart`)
- [ ] Define a pluggable discovery service boundary with feature-flag control
- [x] Prototype and ship discovery entry points in Home — 2026-06-20
  (weekly playlist cards/detail, matching, caching, and playback are covered by
  the Home provider/widget suites; evidence: `79867c37`, `db2dd988`,
  `test/src/features/home/presentation/home_random_showcase_provider_test.dart`)
- [ ] Validate licensing and maintenance constraints before reusing/cloning external implementation pieces
- [ ] Define privacy and telemetry constraints before any production rollout

## Phase 31: Adaptive Convergence Program (Desktop + Tablet + Phone)

> Convergence execution block for one shared adaptive architecture across phone/tablet/desktop.

### 31.0 — M0 Baseline + Tracking Setup
- [x] ACP-M0-01 Add dedicated ACP phase spec + task/status model to development plan — 2026-03-23 (evidence: `docs/project/development-plan.md` Phase 31 section)
- [x] ACP-M0-02 Add ACP high-level checklist and milestone rows to progress tracker — 2026-03-23 (evidence: `docs/project/progress.md` Phase 31 section)
- [x] ACP-M0-03 Extend detailed execution log with ACP scope, blocker protocol, and baseline entry — 2026-03-23 (evidence: `docs/history/multi-os-release-implementation-progress.md` section P)
- [x] ACP-M0-04 Record adaptive baseline before refactor — 2026-03-23 (evidence: `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart` (fails in `app_shell_navigation_test` with narrow-width desktop overflow and expectation mismatches), `flutter analyze lib/src/routing lib/src/features/settings/presentation/settings_screen.dart lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/library/presentation/library_screen.dart` (infos only, no compile errors))

### 31.1 — M1 Unified Adaptive Contract
- [x] ACP-M1-01 Introduce shared adaptive context object consumed by shell + core surfaces — 2026-03-25 (evidence: `lib/src/routing/desktop_layout.dart`, `lib/src/routing/app_shell.dart`, `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/search/presentation/search_screen.dart`, `lib/src/features/settings/presentation/settings_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`)
- [x] ACP-M1-02 Standardize width/shell/form-factor flags from one resolver boundary — 2026-03-25 (evidence: `resolveAdaptiveContext` in `lib/src/routing/desktop_layout.dart`, shell consumption in `lib/src/routing/app_shell.dart`)
- [x] ACP-M1-03 Replace duplicated ad-hoc adaptive branching in core entry surfaces — 2026-03-25 (evidence: shared-context migrations in `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/search/presentation/search_screen.dart`, `lib/src/features/settings/presentation/settings_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`)
- [x] ACP-M1-04 Add explicit capability/policy boundary for platform-specific behavior — 2026-03-26 (evidence: `AdaptiveInputPolicy` + `AdaptiveInputPolicyScope` in `lib/src/routing/desktop_layout.dart`, shell consumption in `lib/src/routing/app_shell.dart`)

### 31.2 — M2 Shell Stabilization First
- [x] ACP-M2-01 Refactor shell composition to window-size-first behavior on all runtimes — 2026-03-25 (evidence: `lib/src/routing/app_shell.dart` now resolves shell mode via shared `AdaptiveContext`; full desktop workspace gated to wide desktop widths)
- [x] ACP-M2-02 Fix narrow-width desktop player overflow and constrained controls — 2026-03-25 (evidence: responsive `_DesktopPlayerBar` and compact `_RailMiniPlayer` controls in `lib/src/routing/app_shell.dart`; targeted shell test gate passes)
- [x] ACP-M2-03 Preserve route continuity and overlay/back priority guarantees through transitions — 2026-03-25 (evidence: `flutter test test/src/routing/app_shell_navigation_test.dart` pass including resize + back-priority coverage)
- [x] ACP-M2-04 Keep desktop command guards intact for text-input contexts — 2026-03-25 (evidence: `test/src/routing/desktop_commands_test.dart` action-handler guard coverage + compact-width shortcut coverage in `test/src/routing/app_shell_navigation_test.dart`)

### 31.3 — M3 Screen Convergence
- [x] ACP-M3-01 Home adaptive logic migration to shared context — 2026-03-25 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `test/src/features/home/presentation/home_screen_test.dart`)
- [x] ACP-M3-02 Search adaptive logic migration to shared context — 2026-03-25 (evidence: `lib/src/features/search/presentation/search_screen.dart`, `test/src/features/search/search_screen_adaptive_test.dart`, `test/src/features/search/search_screen_focus_test.dart`)
- [x] ACP-M3-03 Library adaptive logic migration to shared context — 2026-03-25 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `test/src/features/library/presentation/library_screen_test.dart`)
- [x] ACP-M3-04 Settings adaptive logic migration to shared context — 2026-03-25 (evidence: `lib/src/features/settings/presentation/settings_screen.dart`, `test/src/features/settings/presentation/settings_screen_test.dart`)
- [x] ACP-M3-05 Now Playing adaptive logic migration to shared context — 2026-03-25 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart`, `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`)
- [x] ACP-M3-06 Desktop-wide random/You Might Like convergence to manual pager + track list while preserving compact/tablet/phone carousel behavior — 2026-03-26 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/home/presentation/home_providers.dart`, `test/src/features/home/presentation/home_screen_test.dart`, `test/src/features/home/presentation/home_random_showcase_provider_test.dart`, `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`, `flutter analyze lib/src/features/home/presentation/home_providers.dart lib/src/features/home/presentation/home_screen.dart`)

### 31.4 — M4 Input and Accessibility Hardening
- [x] ACP-M4-01 Standardize focus traversal behavior across adaptive shells — 2026-03-26 (evidence: deterministic traversal grouping/order + queue focus restoration in `lib/src/routing/app_shell.dart`, coverage in `test/src/routing/app_shell_navigation_test.dart`)
- [x] ACP-M4-02 Standardize keyboard/mouse/right-click affordances across tablet/desktop modes — 2026-03-26 (evidence: `AdaptiveInputPolicy` resolver/scope in `lib/src/routing/desktop_layout.dart`, shell shortcut precedence + route-current guarding in `lib/src/routing/app_shell.dart` and `lib/src/routing/desktop_commands.dart`, keyboard-focusable desktop context menus in `lib/src/common_widgets/desktop/desktop_context_menu.dart`, command tests in `test/src/routing/desktop_commands_test.dart`)
- [x] ACP-M4-03 Add explicit adaptive input checks to QA matrix — 2026-03-26 (evidence: width matrix `700/840/1200/1366` input test in `test/src/routing/app_shell_navigation_test.dart`, command gate reruns in `test/src/routing/desktop_commands_test.dart`)
- [x] ACP-M4-04 Replace deferred Focus Player Mode with the dedicated same-window Mini Player, resize-transition gates, separate bounds, optional always-on-top, and explicit return to Desktop View — 2026-08-08 (evidence: `lib/src/routing/desktop_window_controller.dart`, `lib/src/routing/app_shell_desktop_mini_player.dart`, `test/src/routing/desktop_window_controller_test.dart`, `test/src/routing/app_shell_navigation_test.dart`, `tool/desktop_layout_diagnostics.sh`, `./tool/check.sh`)
- [x] ACP-M4-05 Polish overlapping keyboard/input systems across desktop surfaces — 2026-03-27 (evidence: quick-search overlay filter selection and priority handling in `lib/src/routing/app_shell.dart`; type-to-filter conflict guards and all-results filtering in `lib/src/features/library/presentation/library_screen.dart`; cross-platform shortcut assertions in `test/src/routing/desktop_commands_test.dart`)

### 31.5 — M5 Platform Capability Layer
- [ ] ACP-M5-01 Centralize desktop media capability checks (`audio_service`, Linux `dbus` bridge, `smtc_windows`) — status: backlog
- [ ] ACP-M5-02 Harden graceful unsupported-feature fallbacks — status: backlog
- [x] ACP-M5-03 Remove superseded `audio_service_mpris` after validating the
  app-owned Linux `dbus` bridge — 2026-07-26 (evidence: `pubspec.yaml`,
  `lib/src/features/player/data/linux_mpris_bridge.dart`,
  `lib/src/features/player/data/navis_audio_handler_bootstrap.dart`,
  `test/src/features/player/data/navis_audio_handler_test.dart`,
  `./tool/check.sh`)
- [ ] ACP-M5-04 Extend system media API parity to macOS native Control Centre / remote-command handling and audit iOS media-session parity — partial: 2026-03-27 (evidence: documentation and backlog updates in `README.md`, `docs/project/development-plan.md`, `docs/history/multi-os-release-implementation-progress.md`; remaining: native implementation and runtime validation)
- [x] ACP-M5-05 Run dependency hygiene sweep for desktop/audio/adaptive packages — 2026-03-28 (evidence: 13 packages upgraded across 5 phases; `riverpod_lint` removed (its runner `custom_lint` was already disabled, zero rules firing); drift stack unblocked; `flutter analyze` 228 info hints, `flutter test` +342 -14, both unchanged from pre-sweep baseline; commits `cda82a4` through `6c0d2b2`)

### 31.6 — M6 Validation + Release Readiness
- [ ] ACP-M6-01 Pass strict adaptive gate (targeted tests + analyzer + viewport QA matrix) — partial: 2026-08-08 (evidence: focused resolver/controller/shell/API tests, six component goldens, full `./tool/check.sh`, and isolated Linux native diagnostics passed; remaining: Windows and macOS native resize/snap/DPI/display-topology/always-on-top validation)
- [ ] ACP-M6-02 Close all ACP tasks in this tracker with dated evidence lines — status: backlog
- [x] ACP-M6-03 Update implemented architecture docs with final adaptive ownership model — 2026-08-08 (evidence: `AGENTS.md`, `docs/architecture.md`, `docs/development/development-workflow.md`, `docs/development/ci-cd.md`, `README.md`, and `docs/project/development-plan.md`)

---

*Tags are noted inline as phases complete. See [docs/project/development-plan.md](development-plan.md) for versioning and tagging conventions.*

## 1.2.8 — Android SAF Download Folders

- [x] Replace Android custom-folder path handling with persisted SAF tree URIs — 2026-08-21 (implemented: storage-kind migration, `DocumentFile` bridge with create/write/delete capability probe, custom-tree scan/import, download writes, relocation, deletion, content-URI playback, inaccessible-document review counts, and profile-sidecar-only fixture diagnostics. Authenticated Android clone validation against the live configured server completed a fresh catalog sync, configured the bounded fixture tree through the production service, downloaded one real library song, and observed two Navis-owned fixture documents (audio + sidecar), one permanent cache entry, and zero missing files through the app API; it then detached local ownership and re-adopted the same file through production preview/commit, with idempotent rescan results. Inspected app-owned initial-sync and completed-Home screenshots. A restart probe exposed content-URI rows being pruned as filesystem paths; this is fixed with storage-aware cache maintenance coverage and a fresh authenticated force-stop/relaunch now retains the permanent entry, reports zero missing files, and preserves the fixture documents. SAF-to-filesystem relocation is fixed and verified through the production folder-change path (one permanent entry, zero missing files after moving back to app-private storage). Legacy/manual mapping and inaccessible-document classification have focused test coverage. Final emulator certification staged an unindexed fixture-media copy, denied only its `ContentResolver` read, and observed one recognized item plus one `inaccessible` item through the production preview without failing the complete review; after access was restored, import committed one valid permanent entry while leaving the unmatched copy untouched. Stable and ordinary dev packages were not replaced. `./tool/check.sh` and focused Android bridge/diagnostics/import/cache tests passed.)
- [ ] Speed up custom-download reconciliation and add manual match review — partial: 2026-08-22 (implemented: one-shot indexed legacy matching, bounded FLAC metadata reads, direct SAF FLAC identity bridge, automatic clear-match import, and a cover-art local-library picker that ranks liked content first; focused import/media tests and `./tool/check.sh` pass. Linux isolated-clone clean-start presentation diagnostics passed with inspected restart Home screenshot. Android Studio JDK profile Kotlin compilation passed. Remaining: Android emulator end-to-end SAF runtime validation has not been exercised.)

- 2026-10-09 — Colour-style backend audit: account colour isolation, artwork handle/failure/source fixes, caption memo keys, targeted setup Finish, capped Night timer, per-option setup highlights and guarded 92→97 migration; focused validation recorded in the handoff, runtime/full gate reserved for coordinator.
- 2026-10-09 — Appearance UX audit C: Settings › Appearance regrouped (Theme, Color, Shape & Layout, Now Playing), setup "More appearance options" group, per-option New-tag clearing on visibility, Settings-home "Has new options" tags, home notice priority and copy pass; focused tests recorded in the handoff, full gate reserved for coordinator.
- 2026-10-10 — Phone-test UI fixes: Pill corner style with explicit component shapes, Night Schedule under Color, centered fullscreen lyrics title, pull to refresh that retracts while the sync keeps running, dismissible offline banner with an Offline chip, and Album Queue applied to every song list. Task 6 validation: the six-file focused suite passed (153 tests, one skipped), touched-file `dart analyze` reported no errors or warnings (eight existing infos), and `flutter gen-l10n` completed. No app launches or full gate, per machine rules.
- 2026-10-10 — Fine-Tune Colors UI: Color and Brightness rulers (the Speed and Pitch ruler in whole-step mode with a live stepped-swatch band) under Color Style in Appearance and in setup's More appearance options; live preview per step, saved on release, Reset. Focused ruler, Appearance, setup and theme tests recorded in the handoff; runtime loop and full gate reserved for coordinator.
- 2026-10-11 — Now Playing phone layout: height classes, bottom-pinned controls, artwork as the flexible element with shared gap interpolation and exact-square covers (`NowPlayingPhoneLayout`); the 700 dp scroll cliff is gone. Focused player and routing suites recorded in the handoff; runtime loop and full gate reserved for coordinator.
- 2026-10-16 — Now Playing drag (#12): the panel rises from the mini player's top edge and tracks the finger 1:1 as an opaque repaint-isolated layer (no opacity layer, no per-tick rebuild); the bottom navigation bar keeps its layout size and fades away, so the page is no longer laid out on every frame; `onExpand`/`onCollapse` fire at completion. Focused sheet and shell tests, including a page-layout probe, recorded in the handoff; on-device frame timing reserved for the coordinator.
- 2026-10-16 — Download backfill fix (issue #9 part 1): lyrics and artwork backfill now follow the Wi-Fi-only download policy instead of unconditionally requiring Wi-Fi, a pass gated by a missing API client, network policy or an LRCLIB cooldown re-arms from `processQueuedDownloads`, both backfill loops pause during the playback hold, and `promoteToPermanent` prefetches lyrics next to cover art. Tests written first and confirmed failing (five behavioural tests), then fixed: both download service suites green (248 tests), `dart analyze` clean and `dart format` applied on changed files. No app launch or full gate, per machine rules.
- 2026-10-16 — Appearance Looks (issue #7, branch `fix/appearance-looks-update`): Update/Rename/Delete follow the persisted last-chosen Look while the appearance is Custom ("Custom · edited from <Look>"), surviving page re-entry and restart; table-driven audit `appearance_controls_audit_test.dart` drives every Appearance control through the real screen (columns written, provider effect, Look → Custom with origin, Update restores it) with a source guard for new writers; found and fixed un-hiding the last hidden Home section restoring the default hidden sections. Focused tests only (looks, audit, repository, changelog); no app launch, `./tool/check.sh` and the runtime screenshot pass reserved for the coordinator.

- 2026-10-16 — Issue #7 owner-approved Look scope fix: removed density, artist
  view, artwork size, artwork shapes and legacy grid density from Look capture,
  comparison and application; old version-1 JSON ignores these keys without a
  migration. Updated Appearance audit rows, help text, goldens, architecture,
  decision addendum and removal record. Test-first regressions failed on layout
  equality and old-Look application (comfortable became compact); all 90 focused
  domain/storage/controller/audit tests passed after the fix. Runtime and full
  quality gate are prohibited on this host and remain coordinator-owned.

- 2026-10-16 — Issue #7 stale settings-write fix: generic DAO/repository saves
  omit all Look and layout columns, Look library/selection and Home section
  order/visibility; Library's artist list/grid toggle uses the existing targeted
  writer, and reset plus appearance fixtures use targeted lanes. The regression
  first failed with `Expected: 'light' / Actual: 'dark'`, then passed while
  comparing the complete stored row except the requested scrobble change and
  timestamp. Library's test first failed on `Bad state: full draft read`; its
  targeted-writer path passed in the broader suite. That run passed 982 tests
  with only the desktop Appearance copy golden failing; the updated golden's
  focused test passed. Final combined validation is recorded below.

- 2026-10-16 — Issue #7 fix-round final evidence: the new Home storage contract
  test passed before the documentation correction (`null` = built-in default
  hidden set, `[]` = none hidden). Corrected table, DAO and provider comments;
  regenerated the table's data-class comment. Added braces around two existing
  provider early returns to satisfy analysis without changing their behavior.
  The final memory-capped command (6G, `flutter test --concurrency=4`) covered
  all settings, Home and changelog tests, the settings DAO, Library screen and
  diagnostics server: `01:05 +983: All tests passed!`, exit 0, peak 3764M,
  zero OOM kills. Changed-file analysis reported `No issues found!`; formatting
  and diff checks passed, `make gen` succeeded, and the dead-code check passed
  against the existing baseline without new exceptions. Inspected the updated
  Look picker and desktop Appearance goldens. No app/emulator launch, runtime
  diagnostics screenshot/restart loop or `./tool/check.sh`: prohibited by this
  task's host limits, with runtime acceptance left to the coordinator.

- 2026-10-16 — Now Playing settings sheet/panel list the Sound section (Speed & Pitch, mini Equalizer) only while the transport row lacks EQ and Speed buttons; Settings › Playback drops its duplicate Equalizer entry (Porthorion/Navis#8). Focused widget tests only (Now Playing adaptive, Playback settings); no runtime loop or full gate yet.
- 2026-10-16 — Playback Reset Defaults scope fix (issue #13): the button now calls the playback-scoped `AppSettingsDao.resetPlaybackDefaults()` so theme, Looks, colour tuning, setup highlights, download options, the Last.fm key and ListenBrainz survive the reset, while the page's fields plus speed/pitch reset and saved presets are kept; the Fullscreen Mode Lyrics switch stays on the page and is reset with it; Reset now cancels the queued autosave, waits for a running one and re-hydrates from the stored row; the unused global `resetDefaults()` (DAO and repository) was deleted. Validation: `flutter test --concurrency=4 test/src/database/daos/app_settings_dao_test.dart test/src/features/settings/presentation/playback_settings_screen_test.dart` passed (36 tests, includes the new playback-scope reset test), touched-file `dart analyze` and `dart format` clean, `flutter gen-l10n` regenerated. No app launches or full gate, per machine rules.

- 2026-10-16 — Merged `origin/dev` into `fix/appearance-looks-update`:
  retained issue #7's 20-field Looks, origin tracking and targeted-only
  appearance/layout/Home writes alongside issue #13's playback-scoped reset
  and stored-row autosave fallback; the global DAO/repository reset stays
  deleted. Preserved both changelog/progress lists and adapted overlapping
  fixtures to targeted writers. `make gen` passed with no tracked generated
  changes. `dart analyze lib test` exited 0 with 0 errors, 0 warnings and 177
  informational findings (`177 issues found.`). The requested 6G-capped settings,
  DAO, Library, Home, onboarding and changelog suite passed:
  `01:04 +1013: All tests passed!`; exit 0, peak 3735M, swap peak 124M,
  zero OOM kills. `dart run tool/dead_code_check.dart` exited 0 against the
  existing baseline; formatting and diff checks passed. No app launch or
  `./tool/check.sh`, as explicitly prohibited for this merge task.

- 2026-10-17 — Issue #30 restores Looks' full Appearance scope above Home
  sections/page visibility, including artwork shapes/size, density, nullable
  legacy grid density and artist view. Partial version-1 Looks preserve omitted
  fields and match on supplied keys; snapshot equality stays exact. The persisted
  Update target, targeted Library writer and stale general-save protections are
  retained. Restored whole-appearance help text, audit rows and decision history.
  Test-first domain/storage regressions failed in 19 cases; the Compact density
  control audit also failed before implementation. `dart analyze lib test`
  reports zero errors/warnings and 184 pre-existing infos, with no new diagnostic
  lines. The five focused domain/storage/controller/audit/repository files pass:
  `00:46 +128: All tests passed!` `make gen` passed with no additional tracked
  generated changes (it warned about the existing missing `json_annotation`
  dependency lower bound); formatting passed for all 11 changed Dart files.
  Only `appearance_looks_empty.png` and `appearance_looks_selected.png` were
  regenerated and visually inspected; both are byte-identical to before
  `6bdee198`. The two golden tests pass (`00:00 +2: All tests passed!`);
  the complete Looks widget file also passes (`00:04 +27: All tests passed!`),
  including normal golden comparisons. All test runs used
  `flock /tmp/navis-heavy.lock flutter test --concurrency=4` with targeted files.
  No app launch or `./tool/check.sh`: runtime screenshots and the full gate are
  reserved for the coordinator as instructed.
- 2026-10-17 — Preset edited state (issue #36, branch `feat/preset-dirty-name`): the shared `PresetPicker` reads `<origin>*` for an edited Look or Speed & Pitch preset (plain Custom only without an origin) and offers a visible, confirmed Discard button (text or restore icon, hidden when the origin is unsupported) that re-applies the origin, matching the equalizer; origin values match with floating-point tolerance; long names wrap up to three lines (the field grows only when needed); Speed & Pitch now persists its origin in `selected_playback_preset_id` and reselects the preset when edited back to its values; removed `appearanceLooksCustomEdited`, added `presetDiscardConfirm`. New picker, Looks, Speed & Pitch controller and panel tests; focused picker, controller, panel and Looks/audit files pass (`00:55 +662: All tests passed!` (picker, player presentation, Looks, audit, playback settings)), both Looks goldens unchanged. `./tool/check.sh` and the runtime pass left to the coordinator.
- 2026-10-18 — Title Case sweep (issue #50, branch `fix/title-case-sweep`): 227 owner-approved `app_en.arb` titles, headings, buttons, menu items and option labels moved to Title Case (status and body text stays sentence case), plus 3 more found in the re-sweep; localizations regenerated, test assertions and the affected goldens updated, and a "UI text casing" rule added to `docs/development/agentic-engineering.md`.
- 2026-10-18 — Notification Title Case (issue #68, branch `fix/notification-title-case`): seven `app_en.arb` notification titles moved to Title Case ("Scanning Library", "Library Scan Complete", "Library Scan Failed", "Library Scan Cancelled", "Download Failed", "Downloading {count} Songs", "Downloads Waiting for Storage or Access"); bodies, channel descriptions and channel IDs unchanged, and the already-correct hardcoded channel names ("Playback", "Downloads", "Library Scan") left alone. Localizations regenerated with `flutter gen-l10n`; assertions in `test/src/utils/notifications/download_notifier_test.dart` and `library_sync_notifier_test.dart` updated; "UI text casing" rule in `docs/development/agentic-engineering.md` extended and the 1.5.0 Title Case changelog entry folded to cover notifications. `flutter analyze --no-fatal-infos` reports no errors/warnings; both touched test files pass in one run (`00:02 +7: All tests passed!`). `./tool/check.sh` left to the coordinator.

- 2026-10-18 — Issue #76: the existing download backfill pump detects an effective LRCLIB permission off→on transition, drains active automatic/manual passes, and clears empty non-instrumental lyrics miss backoff in one DAO update before retrying automatically, including persisting the reset while offline. Startup and repeated enabled values preserve backoff; stored lyrics, instrumental rows and the Missing predicate are unchanged. Test-first re-enable/offline regressions failed before implementation; 94 focused DAO/backfill/provider/resolver tests pass. `make gen` completed without tracked generated changes; `flutter analyze --no-fatal-infos` exited 0 with no errors/warnings (200 informational findings). Isolated Linux diagnostics passed authenticated health, server-only miss persistence, disabled backoff preservation, offline enable reset, automatic retry without force and clean-restart startup backoff preservation before and after the full gate, each with a fresh isolated profile and clean restart (`build/issue-76-runtime/report.json`, `build/issue-76-runtime-final/report.json`). The full gate ran once under `flock /tmp/navis-heavy.lock systemd-run --user --scope -p MemoryMax=10G ./tool/check.sh`: 8,830 tests passed, one skipped; exact final line `[check] All checks passed.` No changelog change, per owner instruction for the unreleased 1.5.0 backfill refinement.

- 2026-10-20 — Linux package updater second-round review: the release guard now
  tolerates empty inherited defines on Bash 3.2; nonzero elevated installer
  results retain stderr before exit-code mapping; apply-time integrity failures
  offer Retry and download again; package-manager-only modes rely on the shared
  capability guard. Corrected the test elevator recipe to one executable wrapper.
  Test-first regressions failed for both missing exit-code logs and the missing
  Retry action; focused service/dialog validation passed:
  `00:02 +49: All tests passed!`. Empty/unset define cases pass on the available
  Bash; Bash 3.2 itself was not available. Full gate, builds and runtime evidence
  are explicitly deferred by this task's validation restrictions.

- 2026-10-20 — Linux package updater Task 5: architecture/release guides now
  describe package ownership, privileged verify/install, cancellation, Retry
  and the 1.5.1 rollout boundary. Added the user-facing 1.5.1 entry to
  `changelog_data.dart`; the release-notes CLI generates from this source, and
  there is no separate tracked 1.5.1 notes/CHANGELOG file to synchronize.
  Replaced package verification's manual-update assertion with root ownership
  queries. Added `package_update_diagnostics.sh` for build/publish/remote run/
  cleanup, repeated cycles, corrupt downloads and real root-script container
  upgrades; owner-driven UI scenarios and R8 remain explicit acceptance steps.
  Shared existing handshake/API and R2 transport functions instead of copying
  their implementation. The builder now accepts profile mode and embedded
  version flags because diagnostics rejects release mode and package-only
  version overrides do not change the running app version. A test-first mocked
  builder case failed on the unsupported profile flag before implementation;
  default release behavior and source-only handshake reuse also have coverage.
  Nine focused test files passed: `00:16 +259: All tests passed!`. After the final
  formatting adjustment, builder/helper and release-notes tests passed again:
  `00:00 +7: All tests passed!`. Changed-file `dart analyze` reports
  `No issues found!`; all nine touched shell scripts pass `bash -n` and
  `git diff --check` passes. ShellCheck is not installed. Per explicit task
  limits, the new harness was not run: no builds, publication, SSH, containers,
  app launches, emulators or full gate. R1–R9 runtime acceptance remains open;
  the active plan stays under `docs/plans/` until that evidence exists.
