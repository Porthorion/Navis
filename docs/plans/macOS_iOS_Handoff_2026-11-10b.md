# macOS/iOS coordinator hand-off, 2026-11-10 (b)

Replaces [the 2026-11-10 hand-off](macOS_iOS_Handoff_2026-11-10.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I36-I40). Rolled over after
three item PRs merged (#508, #512, #511).

## State

- Owner 2026-11-10: parity gaps and fixes found after the 1.5.2 sweep ship in
  **1.5.2**, not 1.6 (scope rule: 1.5.2 brings iOS up to Android; new features
  go to 1.6 on every platform).
- I36 #489 iOS haptic kinds: merged #508 (`7e445058`). Intensities are a
  judgement call (simulator plays no haptics): retune if the owner's device
  pass says so.
- I37 #496: closed, not a defect (just_audio position extrapolation, 6-8 ms,
  mpv never restarts; evidence `build/i37-i38/20261110T081851Z/`).
- I38 (#479a residual, corrected): the cut was held on the **seek path** for
  any manual skip during a pending load, not the phase-2 rebuild. Merged #511
  (`a9a1376c`): `_loadingSourceInPlayer` guard, held while a
  `setAudioSources` is in flight. **iOS simulator runtime check outstanding**
  (skip during an active load; read `playerVolume` from `/v1/playback/status`
  while `queueSettled=false`).
- I40 #509 (new): every desktop mpv skip stopped and rebuilt the queue in a
  new player since 1.4.0 (media_kit `jump()` returns before its index event).
  Merged #512 (`34b0461c`): bounded wait for the index in `_seekPlayerToIndex`.
  macOS runtime PASS `build/i40/20261110T093952Z-pr/`. Linux/Windows not run.
- I39 #490 macOS ReplayGain boost: **ready to build**. Flash proved the
  bundled libmpv (mpv 0.41.0 `eb0ee103`, FFmpeg 8.0.git, pin
  `libmpv-macos-universal-lgpl-20261104`) has lavfi `volume` and
  `af-command`, and a live `af-command` gain change at runtime. Plan: drop
  `isMacOS` in `navisReplayGainBoostSupported` and `navisReplayGainInPipeline`
  (`navis_playback_rules.dart:70-93`) and in the adapter default
  `_replayGainFilter` (`third_party/just_audio_media_kit/lib/mediakit_player.dart:35`);
  delete the stale `ponytail:` notes (they say libmpv 0.36); flip the macOS
  cases in `test/src/features/player/data/replay_gain_db_test.dart:429-520`
  and `test/src/third_party/mediakit_replay_gain_test.dart:~246`; check the
  macOS cases in `navis_audio_handler_replay_gain_load_test.dart` (#498/#511)
  and the 11 macOS-local navigation failures (ReplayGain boost on mpv); docs
  `docs/architecture.md:~5338`, changelog. Side effect: macOS stops applying
  the cut through mpv's cubic volume (`media_session.dart:729-741`); cut and
  boost ride the filter like Linux/Windows. Risky (playback): Sonnet build,
  Sonnet review, macOS runtime pass (loopback harness from `build/i40/`).
- #392 (exact-boundary ReplayGain, all platforms) is a new feature: 1.6 by the
  scope rule unless the owner says otherwise; needs owner decisions D1-D7.

## Owner actions

- I5 device-pass results from TestFlight 1.5.2 (37437428), with the 479d/e
  pitch checks (repeated seeks at +12 semitones, first song start, a 44.1→48
  kHz queue change, all with pitch on). Haptics feel (I36) is a dev-only
  change, not in that build.
- #392: in 1.5.2 or 1.6? If in, D1-D7.
- I36-I40 are on `dev` only. If 1.5.2 ships from `release/1.5`, they need
  backport PRs there; asked the release/1.5 coordinator on #209 (comment
  6615510482). Settle with the owner/#209 before the next 1.5.2 build.

## Next steps

1. Build I39 (plan above), review, merge.
2. One batch runtime pass after I39: iOS simulator I38 check, macOS I39 boost
   and skip (I40) on the loopback harness.
3. Triage the owner's I5 results when they arrive.

## Notes learned

- Required checks on `dev`: `ci` (aggregate) and `no-session-links`;
  auto-merge is disabled, so merge by hand once `ci` is green.
- On mpv, `seek(index:)` returns before `currentIndex` updates; tests that
  model mpv need a Timer-lagged index (`seekIndexLag` fake in the navigation
  test).
- `test (2)` has a flaky temp-dir cleanup test
  (`navis_audio_handler_navigation_test.dart` ~12702, errno 39); re-run.

## Worktrees and branches

- None of ours. All agent worktrees and branches from this coordinator are removed (I36, I37/I38 investigation, I38, I40, the Flash research worktree). Older T3 worktrees from earlier coordinators remain (`t3-1187c7d6`, `t3-2409cd4e`, `t3-45692a45`, `t3-5cc396e7`, `t3-b723854b`, `t3-fee050b4`).
