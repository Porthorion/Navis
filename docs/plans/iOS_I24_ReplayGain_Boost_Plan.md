# iOS I24: ReplayGain boost (build plan)

Opus, 2026-11-08, against `origin/dev` at `ba31f71e` (I23 shared tap, I21
pitch, I25 format slots). Target 1.5.2. This is a risky item: playback,
native code, the realtime thread and the main/render handoff. Sonnet `high`
builds it test-first. A fresh Sonnet `high` review and then a fresh Opus
review are required before merge. macOS is out of scope: its libmpv 0.36
bundle has no `volume-gain`, so it needs a separate fix.

## Today

- `replayGainLevels` (`navis_playback_rules.dart:170-173`) returns
  `cutDb: math.min(db, 0)` and `boostDb: boostSupported ? math.min(math.max(db, 0.0), room) : 0`.
  For one song, either the cut or the boost is non-zero, never both.
  `room` is 0 without a valid peak (`ceilingDb == null`), so an untagged
  song or a tag without a peak is never boosted. The 1 dB margin
  (`replayGainBoostMarginDb`) and the 12 dB cap (`replayGainMaxBoostDb`) live
  there.
- iOS applies only the cut: `_replayGainVolumeFor` scales `AVPlayer.volume`
  by `10^(cutDb/20)`, clamped to 0..1.
  `navisReplayGainBoostSupported(usesMpv, isMacOS, androidProcessor)` is
  false on iOS, so `_applyReplayGainBoost` returns early and nothing is sent.
  The iOS `AudioPlayer.m` would answer `setReplayGainBoost` with
  `FlutterMethodNotImplemented`.
- Desktop (#367) sends a per-URI map through `_sendReplayGainBoostTo`. mpv's
  `on_load` hook switches files, starting a natural join at
  `min(lastApplied, own)` and raising after `replayGainBoostRaiseAfter`
  (500 ms). Android (#371) sends one value per index event. Dart computes the
  guard (`guardedBoostDb`, last 3000 ms of wall-clock time, latched), and the
  native bridge lowers the boost to 0 before every command that switches
  songs. That took 8 review rounds.

## Decisions

### 1. Where the gain lives: Option A, a per-slot gain stage in the tap after pitch and EQ

- **Reject B (the EQ preamp/headroom).**
  - `autoHeadroom` cancels a boost, as found on Android.
  - The preamp is a user setting.
  - Every song change would rebuild the banks off-thread, with a 20 ms
    crossfade.
- **Reject the other existing levers.**
  - `AVPlayer.volume` and `AVAudioMix` volume both stop at 1.0.
- **Keep the cut where it is.** It stays on `AVPlayer.volume`, unchanged. The
  boost goes only to the tap.
  - Because of the rule above, one song never gets both, so no gain is
    applied twice.
  - Add a Dart test that asserts this over a grid.
- **Gain state per slot, target per tap.** Each I25 slot gets a `NavisBoostRamp`:
  - The render thread owns the ramp, and the slot's `busy` flag serialises
    access to it.
  - One tap-wide `_Atomic float boostTarget` holds the linear target. It is
    lock-free; a test asserts `atomic_is_lock_free`.
  - The main thread computes the target, including the `powf` call. The
    render thread never calls `pow`.
- **Where in the process.** In `navis_tap_formats_process`, right after
  `navis_eq_stream_process`, multiply each frame by the ramp gain.
  - The ramp is linear in gain over 20 ms of the slot's rate, the same length
    as the EQ swap crossfade.
  - Blocks that pass dry get no boost. That covers unmatched, overlap-busy and
    non-planar blocks, and is only ever an under-boost.
  - The stage is independent of `enabled`: EQ off still boosts.
- **Snap on reset.** When `navis_pitch_stage_begin_block` returns true
  (StartOfStream, or a new flush generation), the ramp jumps to the target
  with no ramp. A flush or a new pipeline is already a discontinuity, so this
  makes no click. It also means a drop stored before `noteFlush` is in force
  from the first block after the flush.

### 2. Timing: a native policy on the main thread, with the existing map transport

**The contract.** A song's samples never get more than that song's own boost.
The head of song N+1 may be under-boosted for a bounded time.

**Rejected: per-item gain keyed by what the render thread can see.** In a
same-format pipeline the render thread cannot see an item boundary:

- I23 measured one 4096-frame block that holds item 1's frames 86016…88199
  followed directly by item 2's frames 0…1911.
- The source range re-bases mid-song on every insert.
- StartOfStream marks only a new pipeline, which happens at a format change
  (I25).
- The flush generation is bumped on the main thread when the command is
  issued, not at the audio boundary.

Frame counting against asset durations is not exact for AAC priming or
clipping. So exact first-frame placement cannot be done safely, and the plan
uses the guard-plus-hold rule that the other platforms already use.

**Transport.** Reuse the desktop path unchanged.

- `_sendReplayGainBoostTo` sends `SetReplayGainBoostRequest{currentDb, byUri}`
  to each deck.
- just_audio already de-duplicates the map. The keys are the URIs the load
  message carried, from `_toMessage()`, so the proxy URIs match.
- On iOS, `_usesAndroidBoost` stays false, so iOS takes the map branch. Dart
  needs no guard, latch or "lower before command" logic.

**Native policy.** `AudioPlayer.m`, main thread. Native knows the real next
item (`_player.items[1]`) and changes the queue in the same run-loop turn, so
the Dart round-trip race that Android has to guard against does not exist
here.

- `own(item)`:
  - The item resolves through `indexForItem:`, which covers `playerItem2`.
  - The URI comes from `UriAudioSource.uri`, or from a `ClippingAudioSource`'s
    child.
  - The value is clamped to 0..12. A URI not in the map, or NaN, gives 0.
- `next`:
  - Normally `_player.items[1]`.
  - Loop-one: `playerItem2` of the same source, so `own == next`.
  - No next item gives NaN, which means none.
- Guard: the C port of `replayGainBoostGuarded` / `guardedBoostDb`, with the
  same window (`replayGainBoostGuardWindowMs`, 3000).
  - Remaining wall-clock time is `(duration - position) / _speed`, from the
    `IndexedAudioSource` of `_index`, so clipping is respected.
  - An unknown duration, or a song shorter than window + 1 s, is guarded from
    its start.
  - Once guarded, the song stays latched until the next `currentItem` change
    or a seek within the item. Inside the window the target only ever goes
    down.
- Rise and hold. The hold length is a measured gate, not a proven constant
  (see the runtime proof).
  - A drop is stored at once.
  - A rise waits `kBoostRaiseAfterMs` (500, the desktop
    `replayGainBoostRaiseAfter`) after the last item event.
  - Item events are a `currentItem` change, a seek, `load`, and `enqueueFrom`
    when the current item changed.
  - While held, the target is `min(previous target, new)`.
  - The delayed rise is a `dispatch_after` keyed by an event generation, so a
    newer event cancels it.
  - This covers a `currentItem` KVO that fires before the tap has finished
    the old item, and old-item blocks rendered between a command and the
    flush taking effect.
- Call `refreshReplayGainBoost` at each of these points:
  - the end of `enqueueFrom:`, which covers every `insertItem:`/`removeItem:`
    at lines 642-695, treadmill top-ups, loop and shuffle changes,
    concatenating edits, and seek-to-index;
  - `seek:index:` and `load:`, **before** `noteEqualizerFlush` at lines 1334
    and 722, so the drop is snapped by the reset;
  - the `currentItem` KVO at line 1023;
  - `setSpeed:`;
  - `setReplayGainBoost`;
  - a periodic time observer, 250 ms on the main queue. It is installed only
    while the map has a positive value, and removed in `dispose`.
  - It reports the target to the tap through `[_equalizer setBoostDb:]`, which
    stores the atomic, once per change.
- Put the pure decision in C so it can be tested on the host:
  `navis_boost_decide(in, windowMs, &out)`.
  - Inputs: own, next, remaining, duration, speed, latch, held, previous
    target.
  - Outputs: target dB, guarded, new latch.
  - The test tables mirror the Dart tests in `replay_gain_db_test.dart` for
    `guardedBoostDb`.

**How the guard window maps here.** On Android the window covers the
processor running about 0.75 s ahead plus the Dart tick. On iOS the tap runs
about 0.1 s ahead (I25: `lastSlot` is about 0.1 s behind the clock at a
change), plus a 93 ms straddling block, plus the 250 ms observer tick.

3000 ms covers all of that many times over, at the cost of the old song's
last 3 s playing at `min(own, next)`. Narrowing the window is an owner
question.

**The error at a natural join.**

- N's tail plays at `min(N, N+1)`, which can be an under-boost.
- N+1 plays at that value until 500 ms after the KVO, then ramps up over
  20 ms.

**Skip, jump or seek.**

- A drop applies to the first block after the flush.
- A rise comes 500 ms in.

### 3. Clipping

- The 1 dB margin under the tagged peak, the cap and the "no peak, no boost"
  rule all stay in Dart. They are not duplicated in native code, which clamps
  only to the range 0..12.
- The EQ's `autoHeadroom` only offsets the EQ's own boost. It does not protect
  the stage after it. The tap has no limiter, and none is added. The output is
  float, so a sample above 1.0 clips downstream.
- **Clip counter.** After the gain, count `|x| > 1.0` into `boostClipSamples`,
  reusing Android's state key. It is a counter only. With the margin it stays
  at 0 for tagged songs. A lossy file can overshoot its tag, which is why the
  margin exists.
- **Interactions.**
  - Pitch (an AU with overshoot) and the EQ with `autoHeadroom` off can push
    a sample over. The counter shows it.
  - The cut never applies to a boosted song, so post-tap volume is the user
    volume only.

### 4. Realtime rules

- `process` adds one relaxed atomic load of the target per block, a
  per-frame multiply and step, a per-sample compare for the clip counter, and
  one relaxed `fetch_add`.
- No allocation, locks, ObjC, logging or `pow`.
- The ramp is click-free: it is linear over 20 ms, and it snaps only on
  reset blocks.
- The state reads the `lastSlot`'s gain as an atomic float, and the main
  thread converts it to dB.

### 5. Interactions

- **I21 pitch.** The gain comes after pitch and EQ, on the output samples.
  The AU's latency (4096 frames, about 93 ms) is covered by the window and
  the hold.
- **I25 slots.**
  - Every slot reads the one target.
  - A slot idle since an earlier pipeline snaps at its StartOfStream.
  - The two pipelines that overlap at a format change both sit inside the
    guard, at `min(N, N+1)`.
- **Crossfade.**
  - Each deck is its own `AudioPlayer`, with its own tap and its own map.
  - `navis_audio_handler_crossfade.dart:829` already sends the incoming deck
    its map before `play()`.
  - The volume fade stays on `AVPlayer.volume`.
- **EQ toggle.** No effect on the boost.
- **No tap.** iOS always builds the tap:
  - `navisEqualizerSupported` gives `ios: true`, and `_equalizerPipelineEnabled`
    is set from it.
  - It is dropped only by `_rebuildPlayerWithoutEqualizer`, after a DSP
    failure on load. That sets the flag to false.
  - So the capability is `iosTap: _usesIos && _equalizerPipelineEnabled`.
    After a rebuild it is false, the copy reverts and nothing is sent.
  - If native `_equalizer` is nil (its init failed), `setReplayGainBoost`
    answers `boost_unavailable`, Dart logs it, and the result is an
    under-boost only.

## Functions to change, infrastructure to reuse

- **Dart.**
  - `navisReplayGainBoostSupported` gets an `iosTap` parameter, and the
    getter in `navis_audio_handler.dart:827` passes it.
  - Add a `_usesIos` getter that uses the existing
    `PlaybackAdjustmentCapabilities.ios` injection, like `_usesAndroidNative`.
    This is the test seam.
  - Nothing else changes: the transport, the `_sendReplayGainBoostTo` map
    branch, crossfade and the copy all already exist.
- **New `NavisBoost.c/.h`**, pure C11:
  - `NavisBoostRamp` with init, set-rate, `snap` and `process(channels, count, frames, target, &clipCount)`;
  - `navis_boost_decide`.
- **`NavisTapFormats.c/.h`.**
  - Add the ramp to `Slot`.
  - Add the `boostTarget` atomic and `boostClipSamples`.
  - New `navis_tap_formats_set_boost(t, float linear)`.
  - Apply the ramp in `process` and snap it on reset.
  - The state gains `boostAppliedDb` (from the last slot) and
    `boostClipSamples`.
- **`NavisEqualizer.m`.**
  - `setBoostDb:` clamps and converts the value and calls the C function.
  - `state` adds `boostRequestedDb`, `boostAppliedDb`, `boostClipSamples` and
    `boostGuarded`, the keys `EqualizerStateMessage` already parses.
- **`AudioPlayer.m`.**
  - Add `setReplayGainBoost` to the method switch.
  - Add the map, `refreshReplayGainBoost`, the hold generation, and the time
    observer.
- Reuse: `NavisEqStream`, the I25 slot, `busy` and `lastSlot`, the reset
  decision of `navis_pitch_stage_begin_block`, `SetReplayGainBoostRequest`,
  `_sendReplayGainBoostTo`, the state keys, and the `tool/equalizer_native_test.sh`
  ASan/UBSan and TSan builds. Nothing changes in the `Package.swift`
  directory build.

## Failing tests first

**`darwin/test/navis_boost_test.c`**, added to `tool/equalizer_native_test.sh`:

1. `decide`: outside the window the target is own. Inside the window it is
   `min(own, next)`, and own when there is no next. It is latched, so a speed
   drop or a higher next never raises it. An unknown duration, or a song
   shorter than 4 s, is guarded. Speed 2 doubles the reach. While held, the
   target is `min(prev, new)`. NaN or negative input gives 0, and the result
   never exceeds 12.
2. Ramp:
   - A step from 1.0 to 3.162 reaches the target in exactly 20 ms of frames,
     is monotonic, and has a per-frame step no larger than `|Δ|/rampFrames`.
   - A snap is immediate.
   - Target 1.0 is bit-exact passthrough.
   - Clip count: 0.5 × 3.162 counts every sample.

**`navis_tap_formats_test.c`**:

3. With the boost at +10 dB, the output level is +10 ± 0.1 dB with the EQ
   disabled, and with the EQ at −12 dB preamp the result is −2.
4. A flush bump with a lowered target: the first block after it is entirely
   at the new gain, with no ramp.
5. Two slots (from I25 test 1): both follow the target, and a slot idle since
   its last block snaps at its StartOfStream.
6. The concurrency test adds `set_boost` to the control thread, under TSan.

**Dart:**

- `replay_gain_db_test.dart:434-458`: the new `iosTap` cases.
- A grid test that `boostDb > 0` implies `cutDb == 0`.
- A handler test with `PlaybackAdjustmentCapabilities.ios`:
  - the fake player receives the `byUri` map, with no index and no
    `guarded` flag;
  - with the EQ pipeline disabled (rebuild), nothing is sent and
    `replayGainBoostSupported` is false.

## Runtime proof: `tool/ios_gapless_diagnostics.sh`, phase `boost`

**Fixture.** In `auth_lifecycle_fixture_server.py`, line 364 hard-codes
`trackPeak 1.0`, which gives a room of 0. Add two options:

- `--song-gain ID=GAIN:PEAK`
- `--song-tone ID=HZ:RATE:SECS[:AMP]` (the default amplitude stays
  5000/32768)

Songs, each 12 s long:

| Song | Tone | Level | Tag | Expected |
|---|---|---|---|---|
| Q | 440 Hz, 44.1 kHz | amplitude 0.0316 (−30 dBFS) | gain +10, peak 0.0316 | boost 10 |
| H | 660 Hz, 44.1 kHz | amplitude 0.98 | gain −3, peak 0.98 | boost 0, cut −3 |
| Q48 | as Q, 48 kHz | | | format-change join |

H sits close to full scale, so any leak of Q's +10 dB onto H's samples
crosses 1.0 and shows in `boostClipSamples`.

**Runs.** Each run samples `/v1/equalizer` every 250 ms.

- **Boost on, queue Q H Q Q48 H.**
  - Mid-song `boostAppliedDb`: Q = 10 ± 0.1, H = 0.
  - `levelDeltaDb` is unchanged (EQ only). Add `boostAppliedDb` to it for the
    per-song delta.
  - `boostClipSamples == 0` over the whole queue.
  - `transitionGapsMs` ≤ 20 at the same-format joins. Q→Q48 keeps I25's
    < 1500 ms format-switch rule.
  - `boostGuarded` is true only in the last 3 s of each song.
  - Q's applied value is back to 10 within 1 s of each Q start.
- **Boost off** (mode `off`, then a pre-amp change, same queue).
  `boostAppliedDb` is 0 everywhere, and `boostClipSamples` is 0.
- **Skip, seek and insert.**
  - Skip from Q to H at mid-song.
  - Seek inside Q.
  - Insert H right after the playing Q, 2 s before Q's end. This is the latch
    and edit path.
  - In every case `boostClipSamples == 0`, and H's applied value is 0 within
    one sample.
- **Hold gate.**
  - Rerun the boost-on queue with `kBoostRaiseAfterMs` at 0, in a throwaway
    build.
  - If `boostClipSamples` stays 0 across 5 runs, 500 ms is not load-bearing.
    Report that; do not change it.
  - If clips appear, the hold is load-bearing. Record the margin.
- **Regressions.** Rerun the `main`, `rates`, `formats` and `pitch` phases.
- Run each under `lockf ~/.cache/claude-navis-logs/heavy.lock`. The numbers
  go in the PR and in `progress.md`.

## Docs (build PR)

- `docs/features/equalizer.md`, iOS section: the boost stage, its state keys,
  and the guard and hold.
- `docs/architecture.md` and `docs/project/progress.md`.
- The 1.5.2 entry in `changelog_data.dart`, which names Windows, Linux and
  Android: add iOS.
- `third_party/just_audio/NAVIS_CHANGES.md`.
- The stale comment at `just_audio_platform_interface/lib/equalizer.dart:132`
  ("Only the Android processor…").
- `iOS_Parity_Plan.md`: rows 33 and I24.

## Edge cases

- **Duplicate URI in the queue.** The same boost by definition.
- **Loop-all, wrapping to `playerItem2`.** Same as a normal join.
- **Repeat-one.** `own == next`, so no under-boost.
- **Load of a new queue.** The old map gives 0 for the new URIs until Dart
  sends the new one; then the 500 ms hold applies. This is the desktop
  "first file starts with the previous map" case, and it under-boosts only.
- **Paused inside the window.** It stays latched. A resume does not
  re-raise.
- **A map update that raises the playing song** (a sync refresh of its tag).
  The rise waits for the hold.
- **Speed change inside the window.** It stays latched. A speed rise outside
  the window can enter it at the next tick, which comes within 250 ms.
- **Radio, or an empty map.** The target is 0, and no observer is installed.
- **Dispose.** Remove the observer. Bumping the generation cancels any
  pending rise. Setting `_equalizer` to nil makes `refresh` a no-op.
- **Stream items with no duration yet.** Guarded, as covered by the rule
  above.

## Open questions

1. Keep the 3000 ms window on iOS, where the measured lead is about 0.5 s?
   Recommended: yes for 1.5.2 (parity, tested constants). Narrowing it would
   be a 1.6 item, backed by the hold-gate numbers.
2. Accept that a song's head is under-boosted for about 0.5 s after a join,
   skip or seek? Recommended: yes. Desktop and Android behave the same way.
