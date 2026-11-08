# iOS I23: gapless playback broken by the I9 equalizer tap (cause and build plan)

Opus root cause, 2026-11-08, on `origin/dev` at `77e7098c`. The regression is
**confirmed in Navis**. It affects every iOS user, with the EQ switched on or
off: on iOS the tap is installed whenever the EQ pipeline exists
(`navisEqualizerSupported(ios: true)`), and the EQ toggle only bypasses the DSP
inside it.

Evidence (local, not committed): `build/ios-diagnostics/I23-run/` in the main
checkout.

- `probe/`: the AVFoundation harness (`probe.m`, its modes and logs), on the iOS
  27.2 simulator (`ios_*`) and natively on macOS 27.2 (`mac_*`).
- `navis-run1` … `navis-run4`, `navis/`: Navis runs on the iPhone 17 simulator,
  driven by the diagnostics API.
- The scripts: `navis_gap.sh` (driver), `navis_gap.py` (native-clock gaps),
  `dartgap.py`, `events.py`, `boundary.py`, `gap2.py`, `runprobe.sh`.

## How it was measured

**Navis.** Driven only through the authenticated diagnostics API.

- An empty clone signs in to the loopback fixture server
  (`auth_lifecycle_fixture_server.py --scenario downloads --song-count 4`).
- Four songs, each the same 4.000 s 22.05 kHz mono 440 Hz WAV. 1760 whole
  cycles, so consecutive songs are a phase-continuous pair.
- Gapless on, crossfade off (fresh-profile defaults).
- Played through `POST /v1/playback/queue`, first as proxied streams, then as
  permanent downloads (`/v1/downloads/enqueue`).

A temporary native patch (reverted) did three things:

- logged the AVPlayer clock every 20 ms (`mach_absolute_time`, current item,
  `currentTime`, rate, queue length), plus tap prepare/unprepare, mix
  installs, queue inserts/removes and item seeks;
- read `I23Mode` from `NSUserDefaults`, so one build switched between tap
  modes;
- added the end-action log.

How the numbers are worked out:

- `off = wall − currentTime` per item, from the first and last advancing samples.
- `gap(n→n+1) = startOff(n+1) − endOff(n) − duration(n)`, so 0.000 means
  sample-continuous on the player clock.

The same method on the harness gives −0.001/0.000 s with no tap.

**Sample-level check (harness).** The right channel of each fixture carries the
source frame index (`frameIndex · 2⁻²⁴`).

- With a shared tap, the block that straddles the boundary holds item 1's
  frames 86016…88199 followed directly by item 2's frames 0…1911 (`got` 4096).
  The silent tail blocks are gone.
- With per-item taps, item 1's tap is fed four silent post-end blocks
  (0.37 s), and item 2's first block comes only after item 1's tap unprepares.

## Results

Navis, native clock, gaps for the transitions 1→2, 2→3 and 3→4:

| Mode | proxied | download | tap prepares per 4 songs |
|---|---|---|---|
| 0 shipped (one tap per item, head-of-queue attach) | 0.80–1.22 / 0.79–0.96 / 0.80–0.85 s | 0.81–0.98 / 0.81–0.95 / 0.81–0.84 s | 4–7 |
| 1 no tap | 0.000–0.16 / 0 / 0 | 0.14–0.20 / 0 / 0 | 0 |
| 2 one shared tap, async track load (as shipped otherwise) | 0.19–0.86 / 0.87 / 0 | 0.88–1.00 / 0.88 / 0 | 3–4 |
| 3 one shared tap, `trackID = 1` mix, every queued item, synchronous | 0.000–0.875 / 0 / 0 | 0.858–0.875 / 0 / 0 | 1–2 |
| 4 = 3 plus `actionAtItemEnd` always Advance | **0 / 0 / 0** (×2) | **0 / 0 / 0** | 1 |

The Dart `playerPositionMs` clock shows the same gaps:

- mode 0: 0.89 / 0.87 / 0.93 s;
- no tap: 0.14 / 0.09 / 0.00 s.

So the gap is visible from the diagnostics API too. The I9 run never computed
it.

Harness, two items, `automaticallyWaitsToMinimizeStalling = YES` (the Navis
default):

| Mode | iOS sim | macOS |
|---|---|---|
| no tap | 0.000 | 0.000 |
| one tap per item | 0.443 | 0.464 |
| tap on item 2 only | 0.451 | – |
| item 2's mix set 1 s after start (`latewait`) | 0.455, plus a **0.52 s stall inside item 1** | 0.458, plus 0.54 s stall |
| same `AVAudioMix` object on both items | 0.000 | – |
| same tap, a new mix per item (`sharetap`) | 0.000 | 0.000 |
| shared tap, item 2 inserted 1 s in with its mix already set | 0.000, no stall | – |
| shared tap, mix set in the same run-loop turn as `insertItem:` | 0.000 | – |
| shared tap, item 2's mix set later on an already-queued item (`sharetaplate`) | 0.000, but **0.51 s stall in item 1** | – |
| `trackID = 1` mix built without loading tracks (`tid1`) | 0.000 (tap prepares) | – |
| `trackID = 2` on a track-1 file | tap never prepares, plays dry | – |
| one `AVMutableComposition` with one tap | 0.000 | – |
| 44.1 → 48 kHz pair, shared tap | 0.430 (re-prepare) | – |
| 44.1 → 48 kHz pair, no tap | 0.090 | – |
| 44.1 → 48 kHz pair, per-item taps | 0.433 | – |
| `actionAtItemEnd` Pause with one item, Advance on insert at 0.5 s (22.05 kHz) | 0.864 with tap, 0.139 without | – |
| the same at 44.1 kHz | 0.528 with tap, 0.133 without | – |
| the same flip at 0.05 s | 0.000 | – |

## Root cause

There are three independent defects. Defects 1 and 2 are I9's; defect 3 is
older and made worse by the tap.

### 1. One tap per item breaks AVQueuePlayer's gapless join

Each `AVPlayerItem` with its own `MTAudioProcessingTap` gets its own render
chain.

- AVQueuePlayer starts processing item n+1's chain only after item n's chain
  has drained.
- Item 1's tap is fed about 0.37 s of post-end silence, unprepares, and only
  then does item 2's tap receive its first block.
- So the gap equals one tap pipeline start: 0.44 s at 44.1 kHz and about
  0.79–0.87 s at 22.05 kHz, since it scales with the 4096-frame blocks.
  `startLatency1` is 0.44 s with a tap against 0.09 s without.
- Item 2's tap is already prepared at queue start, so the fault is not late
  preparation. The two chains are serialized.

The same happens on macOS AVFoundation (0.464 s, real CoreAudio output), so it
is not a simulator artefact. No public report of this AVQueuePlayer + tap
behaviour was found; the closest prior art is generic gapless advice (encoder
padding, matching HLS formats).

When every item carries the **same** `MTAudioProcessingTapRef`, AVFoundation
keeps one chain. It is prepared once for the whole queue and is
sample-continuous across items.

### 2. Setting `audioMix` on an item already in the queue rebuilds the chain

When `audioMix` is set on an item that is already queued, the chain is torn
down and rebuilt. The **current** item's tap unprepares and prepares again,
and its clock stands still for about 0.5 s (`latewait`, `sharetaplate`).

Navis does exactly this. `attachToItem:` loads the tracks asynchronously and
sets the mix when they arrive, and `attachEqualizerToQueueHead` reaches item
n+1 only when it becomes `items[1]`. In the mode 0 log (`navis-run1`) every
song shows this sequence within about 40 ms:

1. `MIX item=<next> current=0`
2. `UNPREPARE ctx=<current>`
3. `PREPARE ctx=<current>`

In mode 2 (shared tap, still async) the same late mixes keep the first two
transitions broken.

### 3. just_audio's end action at queue start (pre-existing; the tap amplifies it)

The steps:

1. Queue replacement phase 1 loads only the start song
   (`navis_audio_handler.dart`, `_replaceQueuePhase2` comment "the first batch
   is small…"; the native log shows `ENDACTION count=1`).
2. `updateEndAction` (`AudioPlayer.m:1208`) then sets
   `actionAtItemEnd = AVPlayerActionAtItemEndPause`.
3. About 0.33 s later phase 2 inserts the rest and sets Advance
   (`ENDACTION count=4`).
4. If AVPlayer has already committed item 1's pipeline by then, the 1→2 join
   is not gapless.
   - Without a tap that costs about 0.13–0.15 s, intermittently (0.000 in
     some runs). 1.5.1 has it too.
   - With a tap it costs a full tap restart (0.86 s at 22.05 kHz, 0.53 s at
     44.1 kHz).

The harness reproduces this exactly with the same flip. A flip at 0.05 s, before
the chain starts, is gapless.

### What the I9 gapless proof measured

The I9 ledger row and PR #335 report "gapless track change: PASS (every sample
−12.000, sampleRate set, pending false)". That checks three things:

- the song changed;
- the next item's tap applied the EQ (`levelDeltaDb` −12);
- the state stayed consistent.

It never measured the time between the songs, on the native or the Dart
clock. The claim was wrong because it tested EQ continuity, not gapless
timing. The "late tap install" numbers in the same PR measured unprocessed
audio at the start of an item, not the gap either.

## Chosen fix

Each step was measured in Navis (modes 3 and 4) or in the harness. The fix has
three parts.

- **One tap per `NavisEqualizer`** (that is, per player and per crossfade deck),
  created once.
- **Every item gets its mix before it plays, synchronously, without loading
  tracks.** Use `[AVMutableAudioMixInputParameters audioMixInputParameters]`
  with `trackID = 1` and the shared tap. Install it on every item in
  `_player.items` in the same run-loop turn as `insertItem:`, so no mix is ever
  set on an item AVQueuePlayer is already prerolling. Mode 3 fixes 2→3 and 3→4
  (0.000) with one prepare per queue.
- **Never start a known multi-song queue with a single native item**, so
  `actionAtItemEnd` is Advance from the first render. Mode 4 shows this closes
  1→2: 0.000 on every transition, proxied and download.
  - Mode 4's way of doing it (always Advance) is **rejected**: after the queue
    completed, `seek 0` took 12 343 ms against 327 ms in mode 3.
  - The fix is on the Dart side instead: queue replacement phase 1 hands the
    start song **and the next song** to `setAudioSources` when the next is
    known. iOS only, unless the reviewer finds it neutral elsewhere.

Rejected alternatives:

- **No tap while EQ and pitch are neutral.** Adding or removing a mix on a
  playing or queued item causes the 0.5 s stall (defect 2), and a shared tap
  makes it unnecessary.
- **Attach the next tap earlier.** Item 2's tap was already prepared at t = 0
  in the harness and the gap stayed at 0.44 s.
- **Preroll.** The gap is chain serialization, not loading.
- **A composition (`AVMutableComposition`, one tap).** It is gapless, but it
  replaces just_audio's queue model; far larger.
- **AVAudioEngine or AVSampleBufferAudioRenderer rewrite.** Out of proportion
  to the fix.

## Functions to change

`third_party/just_audio/darwin/just_audio/Sources/just_audio/`:

`NavisEqualizer.m`

- Add `ensureTap` (new, private): it creates the single `MTAudioProcessingTap`
  and `NavisTapContext` lazily, keeps one `NavisEqTap` entry, and holds the
  creation reference until `dispose`.
- `attachToItem:` / `installOnItem:`: become one synchronous method.
  - It builds a fresh `AVMutableAudioMix` whose input parameters have
    `trackID = 1` and `audioTapProcessor = sharedTap`.
  - It sets `item.audioMix` once and marks the record installed.
  - Remove the `loadValuesAsynchronouslyForKeys:@[@"tracks"]` path. Remove the
    `NavisEqItemAttaching` / `NoTrack` / `LoadFailed` states, or keep only
    what the state reasons still need.
  - Never reassign the mix of an item that is in the queue.
- `state`, `sweepFinished`, `_taps`, `retiredFrames`: one context now.
  - `processedFrames` comes from it directly.
  - The `refs == 1` sweep and the per-item records simplify to "installed on
    this item: yes/no".
  - "The current item speaks for the player" still holds through the record,
    and the reason strings stay.
  - With trackID 1, a file whose audio track ID is not 1 plays dry; the tap
    simply does not see it. Report this with a reason once the item is
    `ReadyToPlay` and `tracks` shows the first audio track's ID ≠ 1. Do not
    re-mix (defect 2), and log it.
- `tapProcess` discontinuity rule. With a shared tap the source time range is
  **re-based** without any audio jump:
  - each time a next item is inserted (harness `sharetapinsert`: 0.836 →
    −1.071 mid-song, frames 40959→40960 continuous);
  - and from the second block when the queue starts with two items.
  - Navis mode 3 reported `resetCount` 4 for 4 songs, all spurious.

  Replace "range jump ⇒ reset" with three triggers:
  - StartOfStream (prepare);
  - a host flush generation, an `_Atomic uint32_t` in the context that the
    main thread bumps;
  - the existing zero-duration-flush seek rule, if it is kept for I21 (see
    below).

  Then a range re-base on its own never resets.
- Add `- (void)noteFlush` (new): bumps the generation.
- `dispose`: release the shared tap and its context.

`AudioPlayer.m`

- `attachEqualizerToQueueHead` → `attachEqualizerToQueue`:
  - Covers every item in `_player.items`, dropping the `TREADMILL_SIZE` limit.
    It is cheap now: no track loading, so no network.
  - It stays called at the end of `enqueueFrom:` (`:639`), the same turn as
    the inserts (measured safe).
  - The `currentItem` KVO call (`:963`) becomes a no-op safety net.
  - The loop items `playerItem2` (`:626`, `:633`) are covered because they are
    inserted in `enqueueFrom:`.
- `seek:index:completionHandler:` (`:1280`) and the other user-driven jumps
  (`seek` on the current source; loop-one restart in `onComplete:`): call
  `[_equalizer noteFlush]` before the seek.
- `updateEndAction` stays as is: Pause at the real queue end keeps the fast
  seek-after-completion.

`lib/src/features/player/data/navis_audio_handler.dart`

- Queue replacement phase 1: when the queue has a song after the start one,
  resolve it alongside the start song and pass both in the initial
  `setAudioSources`.
  - Phase 2 then appends from start + 2.
  - Keep `_queueItems = [startSong]` semantics. The second native item is
    covered by the existing "player holds more than Dart shows" handling, so
    confirm against `playerSequenceLength`.
  - Gate it to iOS (just_audio Darwin) unless the reviewer finds it neutral on
    Android/desktop.
- Measure the startup cost with `startupAttempts`. The extra resolve is local
  for downloads and builds a proxy URL for streams.

## Tests and measurements to add first (they must fail on `dev` today)

1. **C test** (`tool/equalizer_native_test.sh`, CI `native` job): the new
   discontinuity rule.
   - A block sequence whose range re-bases with frame-continuous audio and no
     generation change does **not** reset the history.
   - A generation bump resets once on the next audio block.
   - StartOfStream resets.
   - Zero-duration blocks pass through.
   - This fails today, because the current range-jump check resets on the
     re-base.
2. **Native transition gap meter**, which reuses the existing
   `getEqualizerState` channel and `/v1/equalizer`.
   - In `AudioPlayer.m`, at each `currentItem` change, record
     `(hostTime − newItem.currentTime) − (lastSample(prev) hostTime − prev.currentTime) − prev.duration`
     from a 20 ms sampler that runs only while playing, the same arithmetic as
     `navis_gap.py`.
   - Expose `transitionGapsMs` (the last 8) in the equalizer state, add it to
     the Dart message and the diagnostics JSON with contract tests, and
     document it in `development-workflow.md`.
   - Diagnostics builds only, if the sampler's cost is a concern. It is a main
     thread timer, not the render thread.
3. **Focused diagnostics script** `tool/ios_gapless_diagnostics.sh`: a port of
   `I23-run/navis_gap.sh` onto `tool/lib/diagnostics.sh`.
   - Fixture server with 4 songs, proxied then downloaded.
   - Assert every `transitionGapsMs` ≤ 20 ms.
   - Assert the EQ `processedFrames` grows by about 4 × 88200, so the tap really
     ran.
   - Assert `resetCount` stays flat over the 4 songs.
   - Repeat with EQ enabled (−12 dB flat), and assert `levelDeltaDb` is −12 on
     song 4.
   - On `dev` today it fails at 0.8–1.0 s.
4. **Dart unit test** for phase 1: a 4-song replacement on iOS issues an
   initial `setAudioSources` with 2 sources. Fake the player as the existing
   handler tests do.

## Edge cases (each needs a check in the runtime pass or the review)

- **Sample-rate or channel change between items.**
  - The shared tap re-prepares, costing 0.43 s against 0.09 s with no tap
    (harness 44.1→48 kHz).
  - Accepted, because a format change is rarely a gapless pair.
  - `tapPrepare` must rebuild the DSP stream for the new rate. It already
    frees the old stream in prepare.
  - Measure 44.1→48 in the script as a non-gapless expectation.
- **Crossfade on.** Each deck has its own `NavisEqualizer`, so its own tap. A
  tap must never be shared between two players. The crossfade run from I9
  must still pass.
- **Seek, pause/resume, next/previous, shuffle reorder, queue edits.**
  - Generation bumps reset the history.
  - Inserts and reorders (`enqueueFrom:` remove/insert) must not stall
    playback. Measure a mid-song "play next" insert with the gap meter: no
    clock stall.
- **Loop all / loop one.** `playerItem2` gets its mix at insertion; check the
  loop-one restart at the item boundary.
- **Audio track ID ≠ 1** (rare for mp3/flac/m4a/wav; possible in multi-track
  mp4 or video containers). The file plays without EQ and with a reason; no
  stall. Find a fixture or build one with `AVAssetExportSession`.
- **HLS / items without tracks at insert time.** `trackID 1` needs no loading.
  Verify a proxied stream (done: mode 3 proxied) and, if Navis ever plays HLS,
  check it there.
- **Start latency.** The tap still adds about 0.35 s of start latency on the
  simulator (0.44 against 0.09 s); I9 already had it. Device check in I5.
- **Late mix by design is now impossible.** No code path may set `audioMix` on
  a queued item after insertion. Add a debug assertion in the attach path:
  "item not in `_player.items`, or inserted in this turn".
- **State reporting.** The "current item speaks for the player" reasons, the
  `resetCount` semantics (now real discontinuities only) and `processedFrames`
  stay meaningful. Update the I9 diagnostics docs accordingly.
- **Memory.** One context per player instead of per item. Banks are freed in
  unprepare as today.

## Effect on I21 (pitch, `AUNewTimePitch` in the same tap)

See `origin/ios-i10-pitch-probe:docs/plans/iOS_I10_Pitch_Plan.md`. I23 must
land first, and I21 builds on the shared tap.

- **Gapless improves for pitch.**
  - With one tap and one AU instance for the whole queue, the AU stays
    prepared across items.
  - Item 1's latency tail flows into item 2's first block, so a pitched
    gapless album is continuous: no per-item latency of silence and no lost
    tail.
  - This removes two artefacts the pitch plan lists ("each item starts with
    one AU latency of silence", "the tail plays only if AVPlayer renders its
    post-end blocks") for gapless transitions. The post-end silent blocks no
    longer exist inside a shared chain.
  - They remain only at queue start, after a seek, and at format-change
    re-prepares.
- **The pitch plan's discontinuity rule must change.** "An audio-block jump
  with no flush is a discontinuity: reset" would reset, and so flush 4096
  frames of the AU, on every queue insertion re-base: an audible dropout
  mid-song.
  - Use the same host flush generation as the EQ (one shared rule).
  - Seek resets come from `noteFlush`, not from inferring them from ranges.
  - The pitch plan's pause/resume rule (a flush at `expectedStart` means no
    reset) can stay as a secondary check.
- **The pitch plan's "Tap requirement" stays true** (never add or remove the
  tap by pitch value). The reason is now the measured defect 2 (late mix ⇒
  0.5 s stall), not "each tap costs gapless".
- **The `currentTime` alignment note** (heard audio lags `currentTime` by one
  AU latency) still holds within the shared chain.
- **The pitch plan's runtime case** "two-tone gapless … equals the pitch-0
  baseline (the I9 gap)" changes. The baseline is now 0 ms, measured with
  `transitionGapsMs`.

## Status of this investigation

- Temporary native patches in `NavisEqualizer.m` and `AudioPlayer.m`
  (`I23Mode`, clock log) were reverted. The branch carries only this plan.
- **Device check (I5) before release:**
  - the shared-tap gap on hardware, which is expected to match macOS;
  - start latency;
  - an audible A/B at a gapless boundary with EQ on.

## Implementation notes (2026-11-08, PR #381)

Built as planned, with these differences, each found while measuring:

- **`enqueueFrom:` keeps the queued items already in order at the head.**
  Phase 2 of a queue fill appends through `enqueueFrom:`, which removed and
  re-inserted the prefetched next item; with a shared tap that restarted the
  pipeline at the first song change (2 prepares, 0.86 s gap). Keeping them gives
  one prepare per queue.
- **Flush rule in C.** `navis_eq_stream_begin_block` (StartOfStream latched
  across empty blocks, flush generation, one reset per event) replaces the
  source-range check. It counts a reset only for a stream that has seen audio,
  and treats an invalid source range as not audio (StartOfStream arrives on the
  block after the first, invalid one). Pause and resume no longer reset.
- **`noteFlush`** is called from `seek:index:completionHandler:` and `load:`,
  not from `onComplete:` (that runs for every natural advance) nor the loop-one
  restart (the restarted item is a different `AVPlayerItem`; nothing is flushed).
- **Gap meter** is in `NavisEqualizer` (median of five 50 Hz samples while
  playing), with `tapPrepareCount` and `flushCount` beside `transitionGapsMs`
  in the equalizer state. The meter shows an occasional negative reading of a
  few tens of ms; the transport trace shows no overlap, so it is a clock
  reading.
- **Not achieved:** "play next" in the middle of a song still stalls the playing
  song for about 0.8 s, because any change to the prefetched next item rebuilds
  the shared pipeline (dev stalled in one of two runs with per-item taps). Not
  measured: a file whose audio track ID is not 1, HLS, hardware.
- The start latency (about 0.8 s from play to the first sample on the simulator)
  is the same on dev and on the fix.
