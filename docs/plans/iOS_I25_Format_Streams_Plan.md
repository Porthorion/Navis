# iOS I25: one tap stream per audio format (cause and build plan)

Opus, 2026-11-08, against `origin/dev` at `17d0d21a` (I23 shared tap + I21
pitch). Risky: render-thread concurrency and memory lifetime. Sonnet `high`
builds it test-first. Review: a fresh Sonnet `high` reviewer, then a fresh Opus
review before merge.

## Cause (proven)

Evidence (local): `.claude/worktrees/i25-probe/build/ios-diagnostics/I25-run/`
(`summary.txt`, `probe/analysis.txt`, `probe/ios_*.log`), iOS 27.2 simulator.

- AVQueuePlayer runs one audio pipeline per run of items with an identical
  **source** format. Any change of rate, channels, int16/float WAV, AAC/WAV or
  FLAC 16/24 bit starts a new one.
- Each pipeline prepares the shared tap (same `MTAudioProcessingTapRef`) at
  preroll (0–50 ms after `currentItem` moves to the item before it, or mid-song
  after an insert) and unprepares when its last item ends, on non-render
  threads. Unprepare carries no pipeline identity.
- The single `stream` / `pitch` / `pitchAU` in `NavisTapContext` therefore runs
  song N at song N+1's format, holds nothing after each unprepare, and leaves
  the last pipeline with no EQ or pitch. The I21 app run shows it:
  `sampleRate` 48000 during the 22.05 kHz song, 96000 during the 48 kHz song,
  and `processedFrames` frozen at 315128 during the 96 kHz song.
- Use-after-free window: a prepare (t=0.4906 s) fell between two render blocks
  of the playing pipeline (0.4729 s, 0.5690 s) and frees what they use. No
  crash was seen.
- Audio speed and pitch are correct (block rate equals source rate, speed
  1.0000); the I21 "958.6 Hz" readings were the meter using the declared rate.

## Scope

In scope: EQ and pitch at each song's own format on every song; no free that
a live render thread can reach; diagnostics that prove both.

Out of scope: the 0.43–0.47 s gap at every format change. Per-item taps
(`413dabc7`) give 0.43 s, the iOS 27 preferred-format tap 0.36–0.38 s, no tap
0.09–0.10 s: it is AVQueuePlayer's pipeline switch with any tap installed, not
something the tap context controls. The harness keeps its "< 1500 ms, not
gapless by design" rule.

Rejected: a same-rate requirement (same-rate formats split too); a resampler in
the tap (lifecycle bug stays); a tap per format group from server metadata
(the split key is undocumented); `MTAudioProcessingTapCreateWithPreferredFormat`
(iOS 27 only, target 16.0, pipelines still split); evicting slots while
pipelines are live (needs hazard pointers; a cap covers it).

## Design

### 1. A per-format slot set, in portable C

New `NavisTapFormats.c/.h` next to `NavisPitchStage.c`. Pure C11 + pthread, so
it runs under `tool/equalizer_native_test.sh`.

- It takes over the stream, pitch, lock and counters from `NavisTapContext`.
- `NavisEqualizer.m` keeps the MediaToolbox glue, the item records and the
  meter.

```c
typedef struct {                      // AU behind a renderer; NavisPitchAU on iOS, a fake in tests
    void *(*create)(double rate, int channels, int maxFrames, NavisPitchRenderer *out);
    void (*destroy)(void *au);
    uint64_t (*mismatches)(const void *au);
} NavisPitchFactory;
#define NAVIS_TAP_MAX_FORMATS 8
typedef struct NavisTapFormats NavisTapFormats;
NavisTapFormats *navis_tap_formats_new(const NavisEqConfig *, int32_t cents, NavisPitchFactory);
void navis_tap_formats_free(NavisTapFormats *);                 // tap finalize only
bool navis_tap_formats_prepare(NavisTapFormats *, double rate, int channels, int maxFrames, bool planarFloat);
void navis_tap_formats_unprepare(NavisTapFormats *);
void navis_tap_formats_process(NavisTapFormats *, bool startOfStream, uint32_t flushGeneration,
                               double blockRate, float *const *channels, int count, int frames); // realtime
void navis_tap_formats_configure(NavisTapFormats *, const NavisEqConfig *);
void navis_tap_formats_set_cents(NavisTapFormats *, int32_t cents);
void navis_tap_formats_state(NavisTapFormats *, NavisTapFormatsState *out);
```

A slot is `{ int rate (Hz, rounded); int channels; int maxFrames; NavisEqStream *eq;
NavisPitchStage *pitch; void *au; atomic_flag busy; }`. Slots live in
`_Atomic(Slot *) slots[NAVIS_TAP_MAX_FORMATS]` with `_Atomic int slotCount`.
A slot is published by a release store of the pointer, then a release
increment of the count. The render thread reads the count, then the
pointers, with acquire.

The AU, stage and stream are built **outside** the mutex, as in I21. Creating
an AudioUnit is slow, and `state()` takes the mutex on the main thread.

### 2. Lifetime: count live pipelines, free only at zero

- **prepare**: look up key `(round(rate), channels)` under the mutex; if absent,
  unlock, build, relock and look again (keep one build if another prepare won;
  insert if the set emptied meanwhile). In that same locked section do `live++`
  and `prepareCount++`, so this pipeline's first process always finds its slot.
  An existing slot is reused untouched (no rebuild, no history reset).
- **unprepare**: `live = max(live - 1, 0)` (log an unbalanced one). Only at
  `live == 0`: snapshot the last-used slot (as `hasSnapshot` /
  `hasPitchSnapshot` do now), add every slot's frames, resets and mismatches to
  `retired*`, set `slotCount = 0`, free every slot (stage, AU, stream). Safe
  because each pipeline's process runs only between its own prepare and
  unprepare (header contract); at zero none is live. The probe saw balanced
  pairs in every run; seek, stop and queue end bring `live` to 0.
- **Cap** `NAVIS_TAP_MAX_FORMATS` = 8 keys between zeros; a 9th plays dry with
  "Too many audio formats in this queue; this song plays unchanged." Memory is
  at most 8 × (banks + one AUNewTimePitch).
- **Dispose**: unchanged; `tapFinalize` → `contextRelease` →
  `navis_tap_formats_free` frees everything. Drop the "prepared again without
  an unprepare" NSLog (now a normal path).

### 3. Picking the slot per block (render thread)

`tapProcess` computes `blockRate = frames * duration.timescale / duration.value`
(int64 → double) when the range is valid with `value > 0` and frames > 0, else
0, and passes `mNumberBuffers` after the existing layout checks. `process`:

1. Scan the published slots (acquire), `lastSlot` first. Match = same channels
   and `|slot.rate - blockRate| <= 0.005 * slot.rate` (the probe saw the
   timescale equal the source rate exactly).
2. `blockRate == 0`: no DSP; a StartOfStream sets `startLatched` for the next
   audio block. Flush needs no latch (each stream keeps `seenGeneration`).
3. No match: pass dry, add to `unmatchedFrames`.
4. Match: `atomic_flag_test_and_set(&slot->busy)`; if already set (two
   pipelines on one slot at once, never seen) pass dry and count
   `overlapBlocks`; else `navis_pitch_stage_begin_block(pitch, eq, start ||
   exchange(startLatched, false), flushGeneration, frames)`, pitch, then EQ as
   now; store `lastSlot`; clear `busy`.

No locks, allocation, logging or Objective-C; at most 8 pointers scanned.

### 4. Reset and flush semantics (I23, I21)

- **Start of a new pipeline.** StartOfStream reaches the slot that runs that
  pipeline's first audio block, so a reused slot (48→44.1→48) starts fresh and
  its pitch stage is wet from the reset (I21 `note_reset`).
- **Flush.** `flushGeneration` stays one counter for the whole set. The slot
  playing at a seek or skip resets once. A slot that sat idle resets at its
  next audio block if it had audio before, which is a new song anyway.
- **Same-format songs.** A 440→660 pair in one pipeline still gets no reset at
  the song change. That is the I21 check and is unchanged.

### 5. Configuration and pitch reach every slot

- `setConfiguration`: under the mutex, set `config` and call
  `navis_eq_stream_request` on every slot.
- `setPitchCents`: store `pitchCents`, then call `navis_pitch_stage_request`
  on every stage.
- New slots seed from `config` / `pitchCents` and re-check after building,
  like today's `now != seeded`.
- `tapState`: call `navis_eq_stream_sweep` on every slot.

### 6. State and diagnostics (`/v1/equalizer` `application`)

| Field | Value |
|---|---|
| `sampleRate`, `enabled`, `headroomDb`, `pending`, `reason`, `levelDeltaDb` | the slot that processed the last audio block (`lastSlot`), so the song now playing, about 0.1 s behind the clock at a change; else the snapshot |
| `processedFrames`, `resetCount` | retired + sum over all slots |
| pitch fields (`pitchActive`, `pitchInputHz`/`OutputHz`, `pitchLatencyFrames`) | from `lastSlot` |
| `pitchResetCount`, `pitchPullMismatches` | retired + sum over all slots |
| `tapPrepareCount`, `flushCount`, `transitionGapsMs` | unchanged; `tapPrepareCount` = pipelines prepared, 3 for 22.05→48→96 |
| new `formatStreams` | `[{sampleRate, channels, processedFrames, levelDeltaDb}]`, one per live slot; the last snapshot list when the set is empty |
| new `unmatchedFrames`, `overlapBlocks` | 0 in a healthy run |

Add the new fields to `eq_platform_support.dart` / `eq_configuration.dart`
only if they are typed there; otherwise they pass through as raw map entries.
Check how `tapPrepareCount` travels and follow that.

## Functions to change and infrastructure to reuse

- `NavisEqualizer.m`: `NavisTapContext` shrinks to refs, `NavisTapFormats *`,
  `flushGeneration` and the reasons; `tapPrepare` / `tapUnprepare` /
  `tapProcess` become glue; `retirePitch` moves into C; `setConfiguration`,
  `setPitchCents`, `tapState`, `addPitchStateTo`, `baseState`, `state` go
  through the C API; `ensureTap` passes a factory wrapping `navis_pitch_au_*`.
  `warmUpPitchAudioUnit` unchanged.
- Reuse: `NavisEqStream`, `NavisPitchStage` (incl. `begin_block` glue),
  `NavisPitchAU`, the fake renderer from `darwin/test/navis_pitch_stage_test.c`
  (copy it; no shared header for one user). `Package.swift` lists no sources
  (directory build), so no manifest change.
- `tool/equalizer_native_test.sh`: build the new test next to the pitch stage
  test (ASan/UBSan); on Darwin also a separate `-fsanitize=thread` build of the
  concurrency test, skipped when TSan is unavailable.

## Failing tests first: `darwin/test/navis_tap_formats_test.c`

Fake factory and renderer, real `NavisEqStream`, −12 dB preamp so "processed"
shows as a level change.

1. **Format follows the block** (fails today): prepare 22050 and 48000;
   22050 blocks come out at −12 dB with slot rate 22050; unprepare; 48000
   blocks at −12 dB; prepare 96000 (maxFrames 8208), unprepare, 96000 blocks
   at −12 dB; every slot has frames; `unmatchedFrames == 0`.
2. **Reuse while live:** prepare(44100,2) twice, unprepare once: same slot
   pointer, history kept, `slotCount == 1`.
3. **Free only at zero:** after the last unprepare `slotCount == 0`, one
   destroy per create, snapshot is the last slot, retired sums correct.
4. **Unbalanced unprepare** at `live == 0` is a no-op.
5. **No match:** a 44100 or 3-buffer block with only a 48000/2 slot passes
   bit-exact and counts `unmatchedFrames`.
6. **Latched start:** StartOfStream on a frames=0 block, then audio: one reset,
   pitch wet from frame 0.
7. **Flush:** a bump resets the next block's slot once; an idle slot that had
   audio resets once at its next block.
8. **Fan-out:** `configure` (−6 dB) and `set_cents` reach both live slots; a
   later slot is seeded with them.
9. **Cap:** a 9th key plays dry with the reason; `live` still balances.
10. **Concurrency** (ASan on Linux, TSan on macOS): a render thread loops
    `process` over A's rate, then B's, then C's while a control thread
    interleaves prepare(B) mid-A, unprepare(A), prepare(C), configure,
    set_cents and state thousands of times with random yields. No sanitizer
    report, every audio block handled by a slot of its own rate, balanced
    create/destroy. Variant: two render threads on one key exercise `busy`.

## Runtime proof: `tool/ios_gapless_diagnostics.sh`, phase `rates`

- Fixture: `--song-wav SONG_ID=CHANNELS:BITS` in
  `auth_lifecycle_fixture_server.py` (BITS 16, or 32 = float, format tag 3,
  header by hand). `fixture-song-14` = 22.05 kHz stereo 16-bit,
  `fixture-song-15` = 22.05 kHz mono float. Both splits are proven in the probe
  (`mono44`, `int44`); WAV→M4A would need an encoder on the fixture host.
- `run_rates` (songs 4, 5, 6): drop the wrong "may resample" assumption.
  `sampleRate` at at3/at7/at11 equals 22050/48000/96000 and `levelDeltaDb` is
  −12 ± 0.6; at the end `formatStreams` holds the three rates, each with
  `processedFrames` ≥ 0.9 × 4 s of its rate; `unmatchedFrames` and
  `overlapBlocks` are 0; `tapPrepareCount == 3`.
- New queue `formats` (songs 4, 14, 15, 3: mono16, stereo16, monoFloat,
  mono16): at each mid-song 22050 and −12 dB; at the end two `formatStreams`
  (mono, stereo) with frames, total ≥ 0.9 × 4 × 88200, `unmatchedFrames == 0`.
- Rerun the pitch phase unchanged (reword its filler comment: no longer a
  workaround). One full harness run under the lockf gate; evidence in the PR.

## Edge cases

- A key reused with a larger `maxFrames` (96 kHz uses 8208): the stage chunks
  to its own `maxFrames`, which its AU was built with.
- Unsupported (not planar float) format: `live++`, no slot, format reason set;
  its blocks pass dry and count in `unmatchedFrames` (fixtures are all
  supported, so the harness `== 0` holds).
- 44.1/48 and 88.2/96 kHz are > 0.5 % apart.
- Two prepares of one key on two threads: the locked re-check keeps one build
  and frees the other outside the lock.
- Crossfade decks keep their own tap; loop `playerItem2` shares its original's
  slot; a seek empties and rebuilds the set, and its first block is a
  StartOfStream.

## Docs (same PR)

- `docs/features/equalizer.md` iOS section: one tap, one stream per audio
  format; the pipeline split rule; the new diagnostics fields; the
  format-change gap as a known limit, with the numbers above.
- Fix the "`tapPrepareCount` 1 per queue unless the audio format changes"
  line. Keep the I23/I21 plans as history.

## Open questions for review

- Whether the "free only at `live == 0`" rule holds on a device. Prepare and
  unprepare were balanced in every simulator run; the device run is the
  check.
- Whether the 8-key cap should instead evict the slot least recently used by
  `lastSlot`. Left out: there is no safe moment for it without hazard pointers.
