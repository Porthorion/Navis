# I45 (#526): re-stamp the iOS position clock when it drifts, build plan

Opus plan, 2026-11-10, against `dev` 03d85b19. Ledger row: I45 in
[iOS_Parity_Plan.md](iOS_Parity_Plan.md). Probe and evidence (this Mac only):
`build/i526/20261110T161902Z/` (README, `run-20261110T165039Z`,
`run-20261110T165503Z-E`).

## Cause (proven on the iOS simulator)

Native just_audio stamps `updatePosition`/`updateTime` when
`timeControlStatus` turns Playing (`AudioPlayer.m` ~1307), but the item clock
starts later. Dart extrapolates from that stamp, so the reported position runs
ahead until something re-stamps it. On iOS 10+ nothing does: the only drift
corrector, `checkForDiscontinuity`, is installed only before iOS 10
(`AudioPlayer.m` ~1095). Any later re-stamp (a settings push calls `setSpeed`,
which calls `updatePosition`) then steps the position back.

Probe results: the push step reproduced (438 / 447 ms; issue ~445). A
speed-only push steps too (461 ms), so ReplayGain is not involved. The push
does not stall audio (R minus N = -102 ms). The tap renders 170 ms after
Playing while the clock starts later ("clock starts late"). The same offset,
smaller, appears after pause/play (152 ms) and on a gapless item (105 ms).
So the fix must correct drift at any time, not only on the first song.

## Change (native only, `AudioPlayer.m`)

Install the existing periodic observer on iOS 10+ too and make it a silent
drift re-stamp there, without the pre-iOS-10 buffering flip:

1. At the `_timeObserver` install site (~1090-1102) install the 200 ms
   observer on every OS version (drop the empty `@available` branch). It is
   already removed in dispose (~1779).
2. In `checkForDiscontinuity`, on iOS 10+ / macOS 10.12+
   (`@available`), replace both branches with:
   - return unless `_playing`, no seek pending (`_seekPos` invalid), not
     completed, and `_processingState == psReady` (buffering is
     `timeControlStatus`'s job on these versions);
   - `position = getCurrentPosition`; only act when the clock is running
     (`position > _lastPosition`), so a stall is never "corrected";
   - `expected = _updatePosition + (now - _updateTime) * _player.rate`;
     if `_updateTime != 0 && llabs(position - expected) > kRestampDriftMs`
     (50), call `updatePosition` and `broadcastPlaybackEvent`. Never
     `enterBuffering`.
   - always store `_lastPosition = position`.
   Keep the old body for the pre-iOS-10 branch unchanged.
   `// ponytail: 200 ms polling; a boundary observer if battery shows it.`
3. No Dart change. The Navis stale-stamp guard `keepCurrentStamp`
   (`third_party/just_audio/lib/just_audio.dart` ~1777) drops an event only
   when the position is equal **and** the stamp older; a re-stamp has a newer
   stamp, so it passes.

Reuse: `checkForDiscontinuity`, `_timeObserver`, `updatePosition`,
`broadcastPlaybackEvent` already exist; no new observer type, timer or flag.

## Tests first

1. Dart (`test/src/third_party/position_offset_test.dart`, next to the I32d
   stale-stamp guard tests): a platform event that keeps the index, carries a
   newer `updateTime` and a position lower than the current extrapolation
   must replace the stamp, and `position` must move back by the delta. Also
   one with the same position and a newer stamp. This guards the hand-over
   against `keepCurrentStamp`; it should pass today (write it first, confirm
   it runs, keep it as a regression guard).
2. Runtime (authoritative): rerun the probe after the fix. Pass when phase N
   first item over-run <= 80 ms, gapless <= 80 ms, R `r1` < 60 ms, E `e1` <
   60 ms and `e2` < 60 ms. There is no native XCTest target.

## Edge cases

1. Stall / rebuffer: clock not advancing -> no action; `timeControlStatus`
   Waiting still enters buffering as today.
2. Seek in flight: `_seekPos` valid -> skip.
3. Rate change: `setSpeed` already re-stamps; the next tick sees ~0 drift.
4. Paused or completed: skip.
5. Radio / live streams: position may not be monotonic; the
   `position > _lastPosition` guard plus psReady keeps it to real forward
   drift. Check the radio reconnect path from #539 (`build/i527-fix/`
   `run_fix.sh`) still passes in the runtime pass.
6. No event spam: in steady playback drift stays under 50 ms, so no
   broadcasts. The runtime pass counts native events per minute (from the
   diagnostics `transportTrace` or Dart event count) before and after.

## Order

`AudioPlayer.m` is also changed by I42 (#528, `fix/i528-varispeed`). Build
this after I42 merges, rebased on it.

## Verification

Builder: Dart test, `flutter build ios --simulator --debug --no-codesign`
under the heavy lock; CI runs `./tool/check.sh`. Review: fresh Sonnet `high`
(playback). Runtime: Flash reruns `run_i526_ios.sh` (`PHASES="N E R"`; if E
aborts on the previous queue as in run 1, rerun `PHASES="E R"`) plus the
#539 radio pass.
