# I42 (#528): Pitch Lock as one Varispeed stage on iOS, build plan

Opus plan, 2026-11-10, against `dev` 34170299. Evidence and measurements:
`build/i528/20261110T153617Z/README.md` (this Mac only). Ledger row: I42 in
[iOS_Parity_Plan.md](iOS_Parity_Plan.md).

## Cause (proven on metrics, owner confirmed Pitch Lock was on)

With Pitch Lock on (`pitchFactor == speed`), iOS shifts pitch in the tap
(AUNewTimePitch phase vocoder, `NavisTapFormats.c`) and then AVPlayer
time-stretches the result with `AVAudioTimePitchAlgorithmTimeDomain`
(`UriAudioSource.m:77`). Two lossy stages do what one resample does. Android
Sonic resamples once. Locked 1.25x: iOS -20 dB out-of-bin vs Sonic -47 dB vs
Varispeed -65 dB. The tap also renders ~0.4 s ahead, so pitch lags speed.

## Change (iOS only, `TARGET_OS_IOS`)

When locked (and not 1x), use AVPlayer's own resampler: every item gets
`AVAudioTimePitchAlgorithmVarispeed`, tap pitch 0, and the EQ bands move to
`f / speed` so they are heard where the user set them (the EQ runs in the tap
before the rate; Android runs EQ after Sonic). Everything else stays as today:
unlocked speed keeps TimeDomain, unlocked pitch keeps the tap AU.

### 1. Pure C planner (new, test first)

`NavisRatePlan.h/.c` beside `NavisBoost.c` (pure C11, no platform headers):

```c
typedef enum { NAVIS_RATE_TIME_DOMAIN = 0, NAVIS_RATE_VARISPEED = 1 } NavisRateAlgorithm;
typedef struct { NavisRateAlgorithm algorithm; float tapCents; double eqFrequencyScale; } NavisRatePlan;
NavisRatePlan navis_rate_plan(double speed, double pitch);
/// Copies `in` with each filter frequency x scale. Scaled > 20000 Hz: filter disabled
/// (no source content maps there). Scaled < 20 Hz: clamped to 20. scale 1: exact copy.
void navis_eq_config_scaled(const NavisEqConfig *in, double scale, NavisEqConfig *out);
```

Rules: locked when `fabs(speed - pitch) <= 1e-4 * pitch` (speed arrives as a
float, pitch as a double; 1.1f vs 1.1 differ by ~2e-8). Locked and not
`fabs(speed - 1) <= 1e-4` -> `{VARISPEED, 0, 1/speed}`. Otherwise
`{TIME_DOMAIN, 1200*log2(pitch), 1}`. Invalid input (non-finite, <= 0) ->
`{TIME_DOMAIN, 0, 1}`. `navis_eq_config_scaled` may live in
`NavisEqualizerDsp.c` instead if that keeps includes simpler; it must keep
the 20 Hz clamp and the > 20000 disable, because `navis_eq_bank_new` turns
the whole EQ off when any enabled band is at or above Nyquist
(`NavisEqualizerDsp.c:150-155`).

Host test `third_party/just_audio/darwin/test/navis_rate_plan_test.c`, added
to `tool/equalizer_native_test.sh` like `navis_boost_test.c`. Cases:
locked 1.25/1.25 and 0.8/0.8 -> Varispeed, 0 cents, 1/speed; locked with
float speed `(float)1.1` vs double 1.1 -> Varispeed; 1/1 -> TimeDomain/0/1;
speed only 1.25/1 -> TimeDomain/0/1; pitch only 1/1.25 -> TimeDomain/+386.3/1;
both 1.25/1.12 -> TimeDomain/1200*log2(1.12)/1; NaN, 0, negative -> TimeDomain/0/1.
Scaled config: 1000 Hz x 0.8 -> 800; 31 Hz x 0.5 -> 20 (clamp, stays enabled);
16000 Hz x 2 -> disabled; other fields (gain, q, type, preamp, autoHeadroom)
unchanged; scale 1 equals input under `navis_eq_config_same`.

EQ placement test (in `navis_equalizer_dsp_test.c` or the new test): a bank
built from a 1 kHz +12 dB peaking config scaled by 1/1.25 has its maximum
response at 800 Hz (`navis_eq_biquad_db_at`), i.e. heard at 1 kHz after a
1.25x resample.

### 2. `NavisEqualizer` frequency scale

- New `- (void)setFrequencyScale:(double)scale` (declared in
  `NavisEqualizer.h`). Stores `_frequencyScale` (init 1). If it changed and
  `_context` exists, call `navis_tap_formats_configure` with the scaled copy
  of `_config`.
- `setConfiguration:` keeps comparing and storing the **user** config in
  `_config`, but sends the scaled copy to `navis_tap_formats_configure`.
- `contextNew(&_config, ...)` at `NavisEqualizer.m:440` gets the scaled copy
  too, so a tap prepared later starts on the right frequencies.
- Reuse: `navis_tap_formats_configure` already builds banks off the audio
  thread and swaps them at a block boundary with the existing crossfade. No
  new threading.
- Add `frequencyScale` to the state dictionary (`stateDictionary`, ~line
  295) so the diagnostics API shows it.

### 3. `AudioPlayer.m` applies the plan

- Store `_pitch` (double, init 1) in `setPitch:`; `_speed` already exists.
- `setSpeed:` and `setPitch:` both keep their current side effects
  (`_player.rate`, `updatePosition`, `refreshReplayGainBoost`, the
  `pitch_invalid` check) but no longer call `setPitchCents:` directly. They
  call `scheduleRatePlan`, which sets a `_ratePlanPending` flag and, if it
  was clear, `dispatch_async(main)` one `applyRatePlan`. Dart sends
  `setSpeed` and `setPitch` back to back (`Future.wait` in
  `_applyAdjustmentsToPlayer`), so both messages are already queued and the
  plan runs once from the final pair: no TimeDomain/Varispeed flap between
  the two calls. `// ponytail: coalesces only messages already queued; a
  combined setSpeedPitch method if a flap is ever heard.`
- `applyRatePlan` (main thread): `plan = navis_rate_plan(_speed, _pitch)`;
  `[_equalizer setPitchCents:plan.tapCents]`;
  `[_equalizer setFrequencyScale:plan.eqFrequencyScale]`; if the algorithm
  changed, store `_timePitchAlgorithm` and set it on every item in
  `_player.items` **and** on every `_indexedAudioSources[i].playerItem` /
  `playerItem2` that exists (queued and not-yet-inserted items).
- New items: set `item.audioTimePitchAlgorithm = _timePitchAlgorithm` right
  before each `insertItem:` (`AudioPlayer.m:955, 973, 980`). Leave
  `UriAudioSource.m:77` as the default for items made before a plan exists.
- `pitch_unavailable` behaviour: without a tap, locked pitch now works
  (Varispeed needs no tap). Keep it simple: `setPitch:` succeeds when
  `_equalizer` exists (as today) **or** when the pair is locked; still
  fails for unlocked pitch != 1 with no tap. Dart side unchanged.
- Expose `timePitchAlgorithm` ("varispeed"/"timeDomain") next to the
  equalizer state returned at `AudioPlayer.m:280` (add the key to the
  returned dictionary there), for the runtime pass.
- The crossfade deck is a second native player; Dart already sends both
  values to both decks (`_applyToStableDecks`), so each player plans on its
  own. No Dart change.

### 4. Docs

`docs/features/equalizer.md` (pitch/tap section near line 57-75): Pitch Lock
on iOS is AVPlayer Varispeed with tap pitch 0 and EQ bands at f/speed; the
EQ retune and any tap cents land ~0.4 s late (render-ahead) while the rate is
immediate. Note the new state keys. Mention the planner test in the test
list (~line 150).

## Edge cases the build must handle

1. Lock toggled at a fixed speed (1.25/1 <-> 1.25/1.25): tap cents stay 0 on
   both sides, only the algorithm and EQ scale change.
2. Locked speed change (1.25 -> 1.5 locked): Varispeed stays, tap stays 0,
   EQ scale 0.8 -> 0.667. No flap via the coalescing.
3. Locked back to 1x: TimeDomain, EQ scale 1 (exact user config).
4. Radio: Dart sends 1/1 -> TimeDomain. Nothing special.
5. Gapless next item and items inserted by `enqueueFrom:` / loop items
   (`playerItem2`) get the current algorithm.
6. EQ band near the limits: 20 kHz band at locked 0.5x is disabled, not the
   whole EQ; 25 Hz at 1.5x clamps to 20 Hz.
7. EQ disabled or no tap (VolumeOnly item): algorithm still applies.
8. ReplayGain boost unchanged (gain only, last in the tap); rerun its tests.
9. Disposed player / `_player == nil`: `applyRatePlan` is a no-op apart
   from storing values; the next item insert picks them up.

## Out of scope

Widening the locked speed range (it is still bounded by the pitch factor
limits); Spectral for unlocked speed; the #479 first-block items; Android
and macOS (macOS plays through libmpv).

## Verification

- Builder: `tool/equalizer_native_test.sh` (new test fails first, then
  passes), `flutter build ios --simulator --debug --no-codesign` once, then
  `./tool/check.sh` is run by CI, not locally (8 GB Mac; one heavy job).
- Review: fresh Sonnet `high` (playback = risky).
- Runtime (Flash, Opus-written script): iOS simulator, diagnostics API;
  queue of fixture songs; for each step read the equalizer state and the
  new `timePitchAlgorithm`: 1/1 timeDomain scale 1; locked 1.25 varispeed
  scale 0.8 cents 0; next gapless item still varispeed; unlocked 1.25/1
  timeDomain scale 1; pitch only +2 st timeDomain cents 200; position
  advances at ~speed x wall time in each step; no stall, no error.
- Owed on a device, by ear: live algorithm switch takes effect without a
  glitch, locked 1.25 sounds clean, EQ retune lag after a locked speed sweep
  with a strong narrow band. If a live switch does not take effect on a
  playing item, the follow-up is to re-set the rate after the switch, then
  re-enqueue at the current position as a last resort.
