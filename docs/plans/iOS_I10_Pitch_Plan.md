# iOS I10: independent pitch (build plan)

Ledger row: I10 in [iOS_Parity_Plan.md](iOS_Parity_Plan.md). Risky (playback,
native, realtime): Sonnet builds from this plan test-first, then a fresh Sonnet
`high` review and a fresh Opus review before merge. Opus plan, 2026-11-08, on
dev `77e7098c`.

## Decision

**Bypass.** An `AUNewTimePitch` (rate 1) runs inside the existing I9
`MTAudioProcessingTap` only while the pitch is not 0 and the pitch is not locked to
the speed. At pitch 0 the tap passes the audio through untouched, so playback
is exactly as it is today. Lock-to-speed uses AVPlayer's own
`AVAudioTimePitchAlgorithmVarispeed` and leaves the AU off.

Prime/drain was rejected because the simulator probe showed that priming cannot
be done:

- A second `MTAudioProcessingTapGetSourceAudio` in the same process callback
  re-reads the same source position. It does not read ahead, and the next
  callback starts at the normal position.
- AVPlayer's block size already equals `maxFrames` (4096 at 44.1/48 kHz, 8208
  at 96 kHz). A larger request is clamped to `maxFrames`.
- So the tap has no lookahead, and the AU latency cannot be filled from future
  source.

Drain needs no code:

- AVPlayer never sets `kMTAudioProcessingTapFlag_EndOfStream`.
- After the last source frame it keeps calling process with about 0.37 s of
  silent blocks past the asset duration (valid, advancing ranges).
- The AU's tail comes out in the first of those blocks.

While the pitch is not 0, the remaining artefacts are:

- each item starts with one AU latency of silence (4096 frames at 44.1/48 kHz,
  8192 at 96 kHz; about 85–93 ms);
- the heard audio lags `currentTime` by the same amount;
- the tail plays only if AVPlayer renders its post-end blocks, which is a
  device check.

### Tap requirement

The pitch rides on the I9 tap. Since I9 the tap exists on iOS whenever the EQ
pipeline is on, and on iOS it is always on: `navisEqualizerSupported(ios:
true)`, and `equalizerConfiguration` is sent for every player. The user's EQ
toggle only bypasses the DSP; it never removes the tap. So pitch works with the
EQ switched off, with no new attach path. Do not add "attach a tap only when
pitch is not 0": the probe shows each tap costs gapless (see "I9 finding"
below), and the pipeline is never off on iOS.

### Processing order

Pitch runs first, then the EQ, as on Android (`NavisAudioProcessorChain.java`:
"applies EQ after Sonic pitch"). `levelDeltaDb` keeps measuring the EQ stage
alone, because its input is then the pitched signal. Both stages run before
AVPlayer's own speed effect (the tap is `PreEffects`), so pitch and speed are
independent: TimeDomain preserves the AU's pitch.

## Probe evidence

Evidence is in `build/ios-diagnostics/I10-run/probe/` in the main checkout:
`summary.txt`, `probe.m`, the logs and the scripts. The probe ran on the iOS
27.2 simulator (iPhone 17) as a command-line binary under `simctl spawn`. Its
fixtures encode the source frame index in the right channel, so each tap block
shows exactly which source frames it received.

| Question | Result | Log |
|---|---|---|
| Pull more than requested? | A second pull in the same callback returns the same frames again. An oversized pull is clamped to `maxFrames`. Pulling extra on every block made the reader pipeline end 3584 frames early. | `single_prime_a44`, `reader_prime_a44s`, `reader_look_a44s` |
| Frames after EOS? | No EOS flag is ever set. About 4 silent post-end blocks follow, then unprepare. The real AU's tail lands in the first post-end block (RMS 0.144). | `single_pass_a44`, `single_au1200_a44` |
| Seek / flush / discontinuity | Only StartOfStream, on the first block after prepare. Pause gives zero-duration blocks at the paused position. A seek gives a zero-duration block at the old position, then zero-duration blocks at the target, then audio at the target + 3072 frames. Resume after a pause also jumps +3072 frames: AVPlayer skips them, which happens today too. | `single_pass_a44`, `single_au1200_a44` |
| Real AU in the tap | One render-callback pull per render, pull = block size. +1200 c gives 883 Hz from 440. +700 c at 48 kHz gives 656 Hz. −1200 c at 96 kHz gives about 220 Hz. Latency 4096/4096/8192 frames. Works at rate 1.5. | `single_au*`, `rate_au1200_a44` |

The seek trace from `single_au1200_a44.log` (wall time, range start, range
duration):

```
1.8828 1.462857 0         zero-duration block at the old (expected) position
1.8936 0.500000 0         zero-duration blocks at the seek target
1.9788 0.500000 0
2.0748 0.569660 0.09288   audio resumes at the target + 3072 frames
```

### I9 finding (outside I10, for the coordinator)

With the just_audio/Navis default `automaticallyWaitsToMinimizeStalling =
YES`, two plain 2 s WAVs in an `AVQueuePlayer` measure as follows:

| Taps | Gap between items |
|---|---|
| none | −0.001 s (gapless) |
| plain tap on each item | 0.439 s |
| tap with the AU on each item | 0.445 s |

Item 2's process calls start only after item 1 unprepares. A `PostEffects` tap
gives 0.25 s; a tap on item 1 only gives 0.08 s (logs `queue_*wait_a44s`,
`queue_post_a44s`, `queue_passfirst_a44s`).

So gapless playback on iOS has likely been broken since I9 (#335). This is
simulator timing only: confirm it in Navis on the simulator, then on a device
(I5). It needs its own item. Bypass adds nothing to this gap, which is one more
reason to keep the AU off at pitch 0.

## Native changes

All paths are under `third_party/just_audio/darwin/just_audio/Sources/just_audio/`.

1. **`NavisPitchStage.c/.h` (new, plain C11, no Apple headers).** The pitch
   state machine, written against an injected renderer so that it can be tested
   on Linux:

   ```c
   typedef struct {
       void *user;
       int  (*render)(void *user, float *const *in, float *const *out, int channels, int frames);
       void (*reset)(void *user);
       void (*set_cents)(void *user, float cents);
       int  latencyFrames;
   } NavisPitchRenderer;
   NavisPitchStage *navis_pitch_stage_new(const NavisPitchRenderer *r, int channels, int maxFrames, double sampleRate); // prepare only
   void navis_pitch_stage_free(NavisPitchStage *);                                                          // unprepare only
   void navis_pitch_stage_request(NavisPitchStage *, float cents);                                          // any thread, atomic store
   void navis_pitch_stage_source_block(NavisPitchStage *, double startSeconds, double durationSeconds);     // every callback
   void navis_pitch_stage_process(NavisPitchStage *, float *const *channels, int channelCount, int frames); // audio thread, in place
   void navis_pitch_stage_state(NavisPitchStage *, NavisPitchState *out); // cents applied, active, latencyFrames, resets, Hz in/out
   ```

   Behaviour:
   - **Bypass** when the applied cents are 0: return without touching the
     buffer. This must be bit-exact.
   - **0 → not 0:**
     1. reset the renderer and set the cents;
     2. keep outputting the dry signal while the AU is fed, until it has had
        `latencyFrames` of input;
     3. crossfade dry → wet over 20 ms, a linear ramp like the EQ bank swap.

     The splice repeats one latency of audio; there is no dropout.
   - **Not 0 → 0:** crossfade wet → dry over 20 ms, then bypass. This skips one
     latency of audio.
   - **Not 0 → not 0:** call `set_cents` on the audio thread before the next
     render, with no reset.
   - **Discontinuities**, using `NAVIS_EQ_CONTINUITY_TOLERANCE` (2.5 ms, today private to `NavisEqualizerDsp.c:302`; move it to the header and share it):
     - keep `expectedStart`, the end of the last audio block;
     - keep `lastFlushStart`, the start of the last zero-duration block before
       audio resumes;
     - at the next audio block, a flush whose last start differs from
       `expectedStart` is a **seek**: reset;
     - a flush at `expectedStart` is **pause/resume**: no reset, so the AU's
       buffered pre-pause audio plays on;
     - an audio-block jump with no flush is a **discontinuity**: reset;
     - StartOfStream: reset.
     - Zero-duration blocks are never rendered; they pass through as today.
   - The dry copy goes into scratch allocated in `_new` at `maxFrames` per
     channel. The renderer reads its input from that scratch.

2. **`NavisPitchAU.c/.h` (new, Darwin only, AudioToolbox C API).** Binds
   `NavisPitchRenderer` to `AUNewTimePitch`:
   - `navis_pitch_au_new(format, maxFrames)` and `_free`.
   - Stream format in and out equals the tap format.
   - `MaximumFramesPerSlice = maxFrames`.
   - The render callback copies from the stage's input pointer, with one pull
     per render. If a pull size differs from the block, count it and zero-fill,
     never read past the input.
   - `latencyFrames = lround(kAudioUnitProperty_Latency × sampleRate)`.
   - `AudioUnitRender` gets a **monotonic internal sample counter** as its
     `mSampleTime`, never `start × sampleRate`, which goes backwards after a
     seek.
   - Used by both the app and the Darwin test.

3. **`NavisEqualizer.m`.** `NavisTapContext` gains `_Atomic float pitchCents`,
   `NavisPitchStage *pitch` and `void *pitchAU`.
   - **`tapPrepare` (:58):** create the AU and the stage whenever the format is
     planar float, even at 0 cents, so that turning pitch on later never
     allocates. Store both atomically, like `stream`.
   - **`tapUnprepare` (:88):** take both, snapshot the state, then free them.
   - **`tapProcess` (:106–143):** after the single `GetSourceAudio` and the
     buffer checks, call `navis_pitch_stage_source_block` and
     `navis_pitch_stage_process`, then the existing EQ calls, unchanged.
   - **New `setPitchCents:`:** store the cents in `_pitchCents` (new taps start
     with it via `contextNew`), then loop over `_taps` and call
     `navis_pitch_stage_request` (or store into `c->pitchCents` while the tap
     is not prepared), the same pattern as `setConfiguration:` (:238).
   - **`state` (:316):** adds `pitchCents`, `pitchActive`,
     `pitchLatencyFrames`, `pitchResetCount` (the stage's own resets; the EQ
     `resetCount` also counts every resume), `pitchInputHz` and
     `pitchOutputHz`. The last two are
     zero-crossing estimates over a rolling window, computed on the audio
     thread with integer counters only and read under the existing lock. They
     come from the current item's context.
4. **`AudioPlayer.m`:**
   - Add a `setPitch` branch next to `setSpeed` (:157).
   - `- (void)setPitch:(float)pitch lockToSpeed:(BOOL)lock`:
     - **locked:** `_pitchLocked = YES`, set
       `AVAudioTimePitchAlgorithmVarispeed` on every item in `_player.items`
       (current, next and the crossfade deck's own player), and send 0 cents
       to the equalizer;
     - **unlocked:** `TimeDomain` and `1200·log2(pitch)` cents.
     - Without `_equalizer`, pitch 1 unlocked is a no-op success. Anything else
       returns `FlutterError` code `pitch_unavailable`.
     - Validate a finite pitch in [0.25, 4].
   - Return `{}` as `SetPitchResponse`.
5. **`UriAudioSource.m:77`.** Items created later take the player's current
   algorithm (Varispeed when locked, TimeDomain otherwise) instead of the fixed
   TimeDomain. Pass it in the way `AudioPlayer` already reaches items (the
   `playerItem2` path at :170 as well).
6. **Build files.** Link AudioToolbox next to MediaToolbox, iOS only
   (`just_audio.podspec:18`, `Package.swift:25`). Add the new `.c` files to the
   target sources.

### Realtime rules (enforced in review)

- In `tapProcess`: no allocation, locks, Objective-C, logging or `pow`/`log`.
  The cents → parameter conversion is a plain store.
- Call `GetSourceAudio` **exactly once per callback**. Never pull extra frames.
- `AudioUnitSetParameter` and `AudioUnitReset` only on the audio thread, inside
  `navis_pitch_stage_process`.
  `AudioUnitReset`'s allocation behaviour is not documented. The probe used it
  at every seek without errors. Record the probe result as the evidence, and
  never call it from the main thread while the tap is prepared.
- The AU is created in prepare and disposed in unprepare, never elsewhere. The
  finalize path frees nothing the audio thread can still reach, matching the
  I9 ref-counting.
- The main thread talks to the audio thread only through atomics:
  `pitchCents` (relaxed store/load is enough; a missed block is harmless) and
  the stage pointer (acquire/release, as `stream`).

## Dart changes

- **Vendored platform interface**
  (`third_party/just_audio_platform_interface/lib/just_audio_platform_interface.dart:586`):
  `SetPitchRequest` gains `bool lockToSpeed = false`. It is sent in the map only
  when true, so other platforms ignore it.
- **Vendored `just_audio.dart`:** `setPitch(double pitch, {bool lockToSpeed =
  false})` stores the flag and re-sends it on platform reload (:1822).
- **NAVIS_CHANGES.md:** an entry for the new request field and the Darwin
  `setPitch`.
- **`playback_adjustments.dart`:** add `PlaybackAdjustmentCapabilities.ios`
  with `pitchSupported: true`, `minimumPitchFactor: 0.25` and
  `maximumPitchFactor: 4` (±2400 cents, the `AUNewTimePitch` range). Speed
  limits stay null, unchanged from today.
- **`navis_audio_handler.dart:3106` (`playbackAdjustmentCapabilities`):**
  return `.ios` when `Platform.isIOS && _equalizerPipelineEnabled`. Use
  `_isIOSRuntime` if a seam exists, otherwise add one next to
  `_isAndroidRuntime` for tests.
- **`navis_audio_handler_media_session.dart:888`:** pass `lockToSpeed:
  values.lockPitchToSpeed` to `setPitch`.
- **`pitch_unavailable`:** map this native error to a capability downgrade (the
  handler emits the default capabilities for the rest of the session). Without
  it, every adjustment would roll back forever.
- **`:2502-2511`:** no change. Its pitch gating already reads the
  capabilities.

## Tests to write first

1. **Pitch-stage test.** File `third_party/just_audio/darwin/test/navis_pitch_stage_test.c`,
   portable, run by `tool/equalizer_native_test.sh` with the same
   ASan/UBSan flags. That script runs in the **Linux** Android CI job
   (`.github/workflows/ci.yml:116`), so this test uses a fake renderer: a
   fixed delay of L frames that multiplies by a marker gain.
   - Pitch 0 is bit-exact passthrough.
   - Frame parity: output frames equal input frames for every block size,
     including 1, 512, 4096, 8208 and an odd final block.
   - 0 → not 0: dry until L frames have been fed, then a 20 ms ramp, with no
     sample above the input's peak and no NaN.
   - Not 0 → 0: the ramp, then bit-exact.
   - Seek rule: a flush at a new start resets, a flush at the expected start
     does not. Use the trace above as fixture data.
   - An audio jump without a flush resets; StartOfStream resets.
   - The tail: L post-end zero blocks bring out the delayed input exactly.
   - Alignment: after a reset, output frame k equals input frame k − L.
2. **AU test.** File `third_party/just_audio/darwin/test/navis_pitch_au_test.c`,
   Darwin only. In the same script, compile it only when `uname -s` is
   `Darwin` (link AudioToolbox); print `SKIPPED` elsewhere. Also run the script
   in the macOS `ios` CI job, or add a step there that runs just this test.
   - Frequency ratio by zero crossings on a 440 Hz sine at +1200, +700, −1200
     and ±2400 cents, at 44.1, 48 and 96 kHz, within 1%.
   - Measured onset latency equals the reported `latencyFrames` ± 64.
   - Frame parity per render.
   - The tail is recovered after L zero frames.
   - The offline harness in the Opus feasibility code (`pitchcheck/main.swift`
     under `$TMPDIR`) is the reference; port it, don't link it.
3. **Dart unit tests.**
   - `playback_adjustments_test.dart`: `.ios` supports +12 st (factor 2) and
     −24 st; it rejects +25 st and lock-to-speed at speed 5.
   - Handler tests: iOS with the pipeline on reports `.ios`; iOS with the
     pipeline off (the `_rebuildPlayerWithoutEqualizer` path) reports none;
     Android, macOS, Linux and Windows are unchanged.
   - `setPitch` gets `lockToSpeed` from `lockPitchToSpeed`.
   - `pitch_unavailable` downgrades the capabilities and does not loop.
   - `EqualizerStateMessage.fromMap` reads the new pitch fields (including
     `pitchResetCount`), with null when they are absent.
   - Diagnostics `/v1/equalizer` includes them.
   - Panel test: the pitch UI shows on iOS.

## Runtime evidence (simulator, diagnostics API)

Extend `tool/playback_adjustment_diagnostics.sh`; it already writes WAV
fixtures into a cloned cache. Run it with `NAVIS_DIAGNOSTICS_DEVICE=ios` and
the `navis` account, as in the I9 loop. Fixtures:

- a 440 Hz sine, 10 s;
- a gapless two-tone pair: 440 Hz, then 660 Hz, sample-continuous, 5 s each;
- the same sine at 44.1, 48 and 96 kHz.

Read `/v1/equalizer` (`pitchCents`, `pitchActive`, `pitchLatencyFrames`,
`pitchResetCount`, `pitchInputHz`, `pitchOutputHz`) and the existing EQ fields. Pass criteria:

| Case | Expect |
|---|---|
| pitch 0 | `pitchActive` false; output Hz equals input Hz; EQ `levelDeltaDb` as in I9 |
| +12 st / −12 st / +7 st | output/input Hz = 2 / 0.5 / 1.498, within 1%; latency 4096 (44.1/48 kHz) or 8192 (96 kHz) |
| local file, proxied stream, permanent download | same as above, `sourceKind` noted |
| crossfade on | both decks report the pitch; no stuck `pitchActive` on the idle deck |
| two-tone gapless at pitch 0 and at +5 st | the item change happens; the `currentTime` gap equals the pitch-0 baseline (the I9 gap); `pitchLatencyFrames` matches the rate. `currentTime` cannot see the AU's silent start, so the heard gap (baseline + one latency) and the tail are I5 device checks |
| speed 1.5 × pitch +5 st | output Hz ratio 1.335 in the tap; `currentTime` advances 1.5× |
| lock to speed 1.25 | algorithm Varispeed, `pitchActive` false, `currentTime` advances 1.25× |
| speed changed at runtime while pitch is set | pitch unchanged, no reset counted |
| EQ toggled while pitch is set | pitch unchanged; EQ `levelDeltaDb` follows the toggle |
| seek and pause/resume at pitch +5 st | `pitchResetCount` +1 per seek, +0 per pause/resume |

Device-only checks go to I5 (borrowed iPhone, with notice):

- the audible quality and the 0 ↔ not-0 splice;
- the tail at item end (are post-end blocks heard?);
- CPU on a 96 kHz file;
- the lock screen with pitch on;
- interruption and backgrounding with pitch on;
- AirPlay.

## Edge cases

- **Seek:** the reset rule above. The AU buffer is never carried across a seek.
- **Crossfade:** two players, each with its own equalizer and taps.
  `_applyToStableDecks` already sends `setPitch` to both. Each new tap takes
  `_pitchCents` from its equalizer.
- **Next-item taps:** taps attach to the queue head (`attachEqualizerToQueueHead`,
  `AudioPlayer.m:235`). A tap created after `setPitch` starts with the current
  cents; one already prepared gets the atomic store.
- **Speed × pitch:** independent by construction (PreEffects tap, TimeDomain).
  The AU latency in wall time shrinks with speed (L / speed).
- **Speed change at runtime:** never touches the stage.
- **Lock mode:** Varispeed on every item. Switching `audioTimePitchAlgorithm`
  on a playing item is unverified: it is a runtime check for the current item,
  the crossfade deck and the next item. If the current item ignores the
  switch, fall back to TimeDomain plus AU cents `1200·log2(speed)` for that
  item only.
- **EQ toggled while pitch is set:** the EQ bypasses inside its own DSP; the
  pitch stage is independent.
- **Pipeline rebuilt without EQ:** `_rebuildPlayerWithoutEqualizer` (an
  Android-only trigger today). The capability drops to none and the pitch
  resets to 0 through the existing `supports()` path.
- **Backgrounding and interruption:** the tap keeps running. An interruption
  pause behaves like a pause (no reset). A route change that re-prepares the
  tap creates a fresh AU at the new format.
- **Sample-rate change between items:** a new prepare with a new AU at the item's
  rate.
- **Non-float or interleaved formats:** pitch off for that item, with a
  `reason`, the same as the EQ.
- **Pitch at the range edges (±2400):** clamp natively as well as in Dart.

## Docs in the same PR

- **`iOS_Parity_Plan.md`:** update the I10 row and the Inventory "Speed /
  pitch" row.
- **`docs/platforms/ios-testing-playbook.md`:** add pitch to "Valid on the
  simulator", and the splice/tail/CPU check to the device list.
- **`lib/src/features/changelog/changelog_data.dart`:** a 1.5.2 entry.
- **`third_party/just_audio/NAVIS_CHANGES.md`:** the native and Dart changes.
- **`docs/project/progress.md`:** completion evidence.

The out-of-scope sentence in `iOS_Parity_Plan.md` (:108-110) already ends with
"notifications and background library sync" at `77e7098c`, so nothing needs
restoring.

## Size

Medium–large, one PR:

| Part | Estimate |
|---|---|
| Native | ~450 lines: stage ~200, AU binding ~120, wiring ~130 |
| C tests | ~350 lines |
| Dart | ~80 lines, plus ~150 of tests |
| Diagnostics script | ~100 lines |

About one Sonnet build session, then two review rounds and one simulator
runtime pass.
