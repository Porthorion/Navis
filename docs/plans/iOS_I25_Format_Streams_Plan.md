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

New `NavisTapFormats.c/.h` (pure C11 + pthread, tested by
`tool/equalizer_native_test.sh`) takes over the stream, pitch, lock and counters
from `NavisTapContext`; `NavisEqualizer.m` keeps the MediaToolbox glue, the
item records and the meter.

```c
typedef struct {                      // AU behind a renderer; NavisPitchAU on iOS, a fake in tests
    void *(*create)(double rate, int channels, int maxFrames, NavisPitchRenderer *out);
    void (*destroy)(void *au);
    uint64_t (*mismatches)(const void *au);
} NavisPitchFactory;
#define NAVIS_TAP_MAX_FORMATS 16
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
Publish: release-store the pointer, then release-increment the count; the
render thread acquires both. The AU, stage and stream are built **outside** the
mutex, as in I21 (AU creation is slow; `state()` locks on the main thread).

### 2. Lifetime: slots live until finalize (decided after review)

- **prepare**: look up key `(round(rate), channels)` under the mutex; if absent,
  unlock, build, relock and look again (keep one build if another prepare won).
  In that same locked section `live++` and `prepareCount++`, so this pipeline's
  first process always finds its slot. An existing slot is reused untouched (no
  rebuild, no history reset).
- **unprepare**: `live = max(live - 1, 0)` (log an extra one). It frees nothing.
  Pause, resume, seek and song changes therefore never rebuild AUs, and the
  snapshot / `retired*` bookkeeping leaves the common path: `state` reads the
  live slots under the mutex.
- **Cap** `NAVIS_TAP_MAX_FORMATS` = 16 (realistic keys: about 6 rates × 2
  channel counts; continuous play never reaches `live == 0`). A new key when
  all 16 are taken: if `live == 0`, free-all first, then insert; otherwise the
  pipeline plays dry with "Too many audio formats in this queue; this song
  plays unchanged."
- **Free-all** (only that cap case, and finalize): in one locked section set
  `lastSlot = NULL` (atomic), then `slotCount = 0`, add every slot's frames,
  resets and mismatches to `retired*` (so totals stay monotonic), then free
  each slot (stage, AU, stream). Safe because each pipeline's process runs only
  between its own prepare and unprepare (header contract), so at `live == 0`
  none is running.
- **Dispose**: unchanged; `tapFinalize` → `contextRelease` →
  `navis_tap_formats_free` frees everything. Drop the "prepared again without
  an unprepare" NSLog (now a normal path).
- Memory: at most 16 × (EQ banks + one AUNewTimePitch) per player for its
  lifetime; normally 1–3.

### 3. Picking the slot per block (render thread)

`tapProcess` computes `blockRate = frames * duration.timescale / duration.value`
(int64 → double) when the range is valid with `value > 0` and frames > 0, else
0, and passes `mNumberBuffers` after the existing layout checks. `process`:

1. Read `slotCount` (acquire). **Exactly one slot**: use it on a channel match
   alone, ignoring rate and range validity (today's behaviour for single-format
   queues and invalid-range blocks).
2. **Several slots**: among slots with matching channels pick the **nearest**
   rate to `blockRate`, accepted within 4 % (22.05/24, 44.1/48 and 88.2/96
   stay apart). Also accept it when the slot rate lies inside the CMTime rounding
   interval `frames*ts/(value+1) .. frames*ts/(value-1)`, so a short block on a coarse
   timescale (600) still finds its slot. The probe always saw timescale =
   source rate.
3. `blockRate == 0` with several slots, or no match: pass dry, add the frames to
   `unmatchedFrames`.
4. Match: `atomic_flag_test_and_set(&slot->busy)`; if it was already set, pass
   dry and count `overlapBlocks`. Otherwise run
   `navis_pitch_stage_begin_block(pitch, eq, startOfStream, flushGeneration,
   frames)`, then pitch, then EQ as now; store `lastSlot`; clear `busy`.

No StartOfStream latch. In 92 StartOfStream flags across 3896 probe blocks
(I10, I23 and I25 logs, including pause, seek and insert runs) it always came on an
audio block, never on an empty one. The stream's own `startPending` still
covers that case for the matched slot. No locks, allocation, logging or
Objective-C; at most 16 pointers scanned.

### 4. Reset and flush semantics (I23, I21)

- **Start of a new pipeline.** StartOfStream reaches the slot that runs that
  pipeline's first audio block, so a reused slot (48→44.1→48) starts fresh and
  its pitch stage is wet from the reset (I21 `note_reset`).
- **Interleaving.** B's StartOfStream arrives on B's first audio block, at B's
  rate, so it resets only B's slot, never A's playing one.
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
| `sampleRate`, `enabled`, `headroomDb`, `pending`, `reason`, `levelDeltaDb` | the slot that processed the last audio block (`lastSlot`), so the song now playing, about 0.1 s behind the clock at a change; the last slot used before a pause |
| `processedFrames`, `resetCount` | sum over the live slots (+ `retired*` after a free-all) |
| pitch fields (`pitchActive`, `pitchInputHz`/`OutputHz`, `pitchLatencyFrames`) | from `lastSlot` |
| `pitchResetCount`, `pitchPullMismatches` | sum over the live slots (+ `retired*`) |
| `tapPrepareCount`, `flushCount`, `transitionGapsMs` | unchanged; `tapPrepareCount` = pipelines prepared, 3 for 22.05→48→96 |
| new `formatStreams` | `[{sampleRate, channels, processedFrames, levelDeltaDb}]`, one per slot (slots outlive their pipelines, so this is the queue's formats) |
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
2. **Reuse:** prepare(44100,2) twice, unprepare twice: same slot pointer,
   history kept, `slotCount == 1`, no destroy.
3. **Free-all only at the cap:** fill 16 keys, unprepare all, prepare a 17th:
   16 destroys, then the new slot; with `live > 0` the 17th plays dry with the
   reason. Retired totals stay monotonic.
4. **Stale `lastSlot`** (ASan): process a block (sets `lastSlot`), force a
   free-all, process again: no use-after-free, `lastSlot` was NULL.
5. **Extra unprepare** at `live == 0` is clamped.
6. **Matching:** with 48000/2 and 96000/2 slots a 22050 block and a 3-buffer
   block pass bit-exact into `unmatchedFrames`; 44100 vs 48000 and 88200 vs
   96000 pick correctly. Coarse timescales 600 and 90000 (4096- and 136-frame
   blocks) find the right slot. Single slot: a block at another rate, or with
   an invalid range, still uses it; a 3-buffer block does not.
7. **Interleaved start:** A's blocks, then B's StartOfStream block, then
   A's again: A's slot keeps its history and reset count; B's resets once and
   its pitch is wet from frame 0. Flush: a bump resets the next block's slot
   once, and an idle slot that had audio resets once at its next block.
8. **Fan-out:** `configure` (−6 dB) and `set_cents` reach both live slots; a
   later slot is seeded with them.
9. **Concurrency** (ASan on Linux, TSan on macOS): a render thread loops
    `process` over A's rate, then B's, then C's while a control thread
    interleaves prepare(B) mid-A, unprepare(A), prepare(C), a cap free-all at
    `live == 0`, configure,
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
  (mono, stereo) with frames, total ≥ 0.9 × 4 × 88200, `unmatchedFrames == 0`
  and `overlapBlocks == 0` (monoFloat → mono16 is a same-key transition across
  two pipelines). If `overlapBlocks` is ever non-zero, the builder stops and
  reports; the coordinator decides on a bounded spin-wait, not the builder.
- Rerun the pitch phase unchanged (reword its filler comment: no longer a
  workaround). One full harness run under the lockf gate; evidence in the PR.

## Edge cases

- A key reused with a larger `maxFrames` (96 kHz uses 8208): the stage chunks
  to its own `maxFrames`, which its AU was built with.
- Unsupported (not planar float) format: `live++`, no slot, format reason set;
  its blocks fail the planar-float layout checks in `tapProcess` and pass dry
  before any slot is picked, so the single-slot fallback cannot catch them.
- Two prepares of one key on two threads: the locked re-check keeps one build
  and frees the other outside the lock.
- Crossfade decks keep their own tap; loop `playerItem2` shares its original's
  slot; a seek re-prepares and reuses the slot (StartOfStream + flush reset
  once).

## Docs (same PR)

- `docs/features/equalizer.md` iOS section: one tap, one stream per audio
  format; the pipeline split rule; the new diagnostics fields; the
  format-change gap as a known limit, with the numbers above.
- Fix the "`tapPrepareCount` 1 per queue unless the audio format changes"
  line. Keep the I23/I21 plans as history.

## Open questions for review

- Prepare/unprepare balance on a device: it now only affects the cap path
  and the `live` diagnostic, not safety in the common path.
- `overlapBlocks` on a device (see the harness rule above).
