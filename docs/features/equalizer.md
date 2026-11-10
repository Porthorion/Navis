# Equalizer

Navis has a dedicated Equalizer page at `/settings/equalizer`, reachable from
Settings, Playback, and the player's compact equalizer surfaces. The Equalizer
button beside Instant Mix in the Now Playing transport and desktop player bar,
and the compact desktop Mini Player menu open a mini
equalizer: on/off, a read-only response graph and a preset dropdown (your
presets, imported headphone profiles and built-ins), with **Open Equalizer** (or
a tap on the graph) for editing. The Now Playing
settings sheet shows the same controls inline in its Sound section. Choosing a
preset there turns the EQ on; drafts behave exactly as on this page. The player
button is hidden, and settings entries disabled, when the backend has no EQ; it
is tinted while EQ is enabled and becomes a Close toggle while this page is
open. Leaving the page returns to where it was opened, re-expanding Now Playing
or Mini Player. EQ is installation-wide and is
independent of the current server account. The page is a graph-first
workspace built from the existing theme, typography, and adaptive shell; see
[Editing workspace](#editing-workspace).

## Platform support

| Backend | Current EQ support |
|---|---|
| Android Media3 | Native PCM processing on both playback decks; emulator bridge/lifecycle checks and APK builds are covered |
| Linux media-kit/libmpv | Native floating-point filter chain; actual captured output and clean restart are covered |
| Windows media-kit/libmpv | The Linux filter chain, on the full libmpv Navis pins and bundles (see [Releasing for Windows](../release/release-windows.md#bundled-libmpv)); a build without the filters falls back to EQ unavailable |
| macOS media-kit/libmpv | The same filter chain, on the Navis-built universal libmpv the macOS app bundles (see [Releasing for macOS](../release/release-macos.md#bundled-libmpv)); a build without the filters falls back to EQ unavailable |
| iOS AVFoundation | One `MTAudioProcessingTap` per player, shared by its queued `AVPlayerItem`s, runs the same biquads and auto-headroom in C (`NavisEqualizerDsp.c`); see [iOS](#ios) |
| macOS debug (AVFoundation) and web | UI disabled; processing is unavailable. The Darwin tap is compiled only for iOS (`TARGET_OS_IOS`), so macOS playback is unchanged |

### iOS

AVFoundation hands no PCM to just_audio, so the vendored Darwin player
(`third_party/just_audio/darwin`) gives each `AVPlayer` one `MTAudioProcessingTap`
(pre-effects, so the DSP sees the source sample rate before speed changes),
shared by every queued item, using the config map Android receives
(`equalizerConfiguration`, `setEqualizer`, `getEqualizerState`). One shared tap
matters for gapless playback: `AVQueuePlayer` runs an item that has its own tap
through its own audio pipeline and starts the next item's only after the
previous one drained (0.4 to 1.2 s of silence at every song change), while
items sharing one tap share one pipeline and join sample-continuously (I23).
Every item gets an audio mix naming the shared tap and the first audio track
(its real ID when the asset's tracks are already loaded, which is checked without
blocking; otherwise track 1; no track loading) in the same run-loop turn as its
insert into the queue, never later: changing
the mix of an item that is already queued rebuilds the pipeline and stalls
playback for about 0.5 s. The tap stays installed with EQ off and bypasses inside
the DSP. Banks are built off the audio thread and swapped at a block boundary
with the same 20 ms crossfade as Android; the render callback has no locks,
allocation, Objective-C or `log`/`pow`. Only non-interleaved 32-bit float PCM of
one to eight channels is processed; any other format plays unchanged and
`reason` says so, as it does for a file whose audio track ID is not the one the
mix named. Limit: the tracks are almost never loaded when an item is queued, so
the mix names track 1 and a file whose first audio track has another ID (rare
for mp3, flac, m4a and wav; possible in multi-track mp4) plays unchanged with
that reason; it is not re-mixed, because that stalls playback. This was not
tested with a real file. The tap runs before the player's own effects (speed,
volume), so gapless advance and 1.5× speed use the same path; each crossfade
deck owns its own equalizer instance and tap (a tap is never shared between two
players). `AVQueuePlayer` runs one audio pipeline per run of queued songs with
the same source format (rate, channels, int or float samples, codec, bit depth)
and prepares and unprepares the one shared tap for each of them, on other threads
than the render thread, so the tap keeps one EQ stream and one pitch stage per
audio format (`NavisTapFormats.c`, I25). Prepare adds the format's slot or
reuses the one it has; unprepare frees nothing, so a pause, seek or song change
never rebuilds a stage. Each block picks the slot of its channel count whose rate
is nearest to the block's own (frames over the source-range duration, within 4 %
or inside the rounding of the range's clock; when that admits several rates the
slot that played the last block, then the slot of the latest prepare, wins); with
only one slot that slot takes every block. A block with no usable rate (the first
block of every pipeline) goes to the slot of the latest prepare, and a block no slot
matches plays unchanged and is counted. Slots
live until the player is disposed, up to 16 formats; a 17th format is started over
(all slots freed) only when no pipeline is live, and otherwise that song plays
unchanged with a `reason`. Edits and pitch reach every slot. Known limit: the
pipeline switch itself leaves 0.4 to 0.9 s of silence at every change of source
format (measured on the simulator, 0.43 to 0.47 s for rates, about 0.85 s for
mono, stereo and float WAVs at one rate), with a tap installed or not; it is
AVQueuePlayer's, not the tap's. The filter history is dropped on a seek or skip, which the
player reports with a flush counter that the render thread compares at each
block with audio (like Android's onFlush), and on the first block of a new
stream. The source time range is not used: with a shared tap it re-bases
mid-song whenever an item is queued behind the playing one, without any jump in
the audio. Pause and resume no longer reset the history (the 21 ms that
AVFoundation re-reads on resume are not an audible discontinuity). While paused,
seeking or right after prepare the tap is called with empty or invalid source
ranges, which are not audio. `resetCount` in the diagnostics `application`
counts the histories dropped: 0 over steady playback and gapless song changes,
and 0 or 1 per seek or skip. AVFoundation re-prepares the tap on a seek or
skip (measured on every one); the new stream starts with an empty history and
counts nothing, so the history is dropped either by a counted reset (the old
stream saw the flush first) or by that re-prepare, never kept. A re-prepare of a
format the tap already holds (every pause, seek and skip) reuses its slot, and
the StartOfStream of that pipeline resets it, counted, when its first audio
arrives. The
reported `reason` names why the current item is not processed: still attaching,
the tap could not be created, an unsupported format, or an audio track that is
not the one mixed.

State adds iOS-only fields, surfaced in `/v1/equalizer` `application`:
`sampleRate`, `levelDeltaDb` and the pitch fields describe the format that
processed the last block of audio (the song playing, to about 0.1 s);
`formatStreams` lists every format of the queue (`sampleRate`, `channels`,
`processedFrames`, `levelDeltaDb`), and `unmatchedFrames` (audio no format took)
and `overlapBlocks` (blocks passed dry because another render thread held their
format) are 0 in a healthy run, as is `clampedUnprepares`, an unprepare that matched
no live pipeline (`livePipelines`, `prepareCalls` and `unprepareCalls` give the
balance; starting over at the format cap is only safe while it holds); `processedFrames` (frames processed by this
platform player, summed over its formats, which grows while
audio plays and restarts from zero when the app swaps decks or rebuilds the
player) and `levelDeltaDb` (output minus input level in dB over about the last
second of played audio, restarted when an edit takes effect; `null` before audio has played). The audio thread
only accumulates sums of squares; the dB conversion runs on the main thread.
Counters per native player (every queue replacement stops the player, which
disposes the native player and its equalizer, so they cover the current queue):
`tapPrepareCount` (audio pipelines prepared: 1 per queue of one source format,
3 for 22.05, 48 and 96 kHz songs, plus one per pause, seek or skip), `flushCount` (seeks and skips noted since the player was created) and
`transitionGapsMs`, the last 8 silences between songs measured on the player's
own clock (about 0 when gapless; a seek, skip or load clears them; the meter
runs only in builds that can run the diagnostics API, `diagnosticsBuildEnabled`,
which the app tells the player at creation, so a release build has no timer and
reports an empty list). The gap from
song n to n+1 is `startOffset(n+1) - endOffset(n) - duration(n)` with
`offset = wall time - item time`, as a median of five samples at 50 Hz from a
main-thread timer that runs only while playing. A song change now and then
reads a few tens of milliseconds early (a negative gap) when the main thread is
busy; that is a clock reading, not an overlap in the audio (the transport trace
intervals stay at the song length). `tool/ios_gapless_diagnostics.sh` plays the
fixture queues and checks these values.
The ReplayGain boost (I24) is the last step of each format slot, after pitch and EQ
(`NavisBoost.c`): a gain with a 20 ms linear ramp, independent of `enabled`, so quiet
songs are turned up with the EQ off or on. The cut stays on `AVPlayer.volume` and one
song never gets both. Dart sends the per-URI boost map (`setReplayGainBoost`) and
`AudioPlayer.m` decides the target on the main thread (`navis_boost_decide`): the
song's own boost, or in the last 3 s of wall-clock time (and for songs shorter than 4 s
or of unknown length) the lower of its and the next song's, latched until the next
song event. A drop applies at once, a rise waits 500 ms after a song event, so a song
head can be under-boosted for about 0.5 s but its tail is never over-boosted. The
target reaches the tap as one atomic gain; a slot snaps to it on its first block and
on a reset (StartOfStream or a flush), else it ramps. Blocks that pass unchanged (no
slot, another render thread in the slot) get no boost. The tap has no limiter: the
1 dB margin under the tagged peak is Dart's, and samples beyond full scale after the
gain are only counted. State adds `boostRequestedDb`, `boostAppliedDb` (the gain the
last block ended on), `boostGuarded` and `boostClipSamples` (0 in a healthy run).
Without the tap (after the EQ pipeline was rebuilt away) the capability is false and
nothing is sent. macOS has no boost stage.
The DSP is covered by `third_party/just_audio/darwin/test/navis_equalizer_dsp_test.c`,
run from `tool/equalizer_native_test.sh` (it needs only a C compiler), as are
`navis_pitch_stage_test.c`, `navis_boost_test.c` (the boost decision table and
ramp) and `navis_tap_formats_test.c` (the format slots with a fake pitch unit,
including concurrent pipelines, the boost and the layout checks the tap glue uses to
pass an unsupported format or buffer list unchanged; under ThreadSanitizer too on macOS).

The Android processor currently receives 16-bit PCM. Coefficients and filter
history use doubles internally; this is not a bit-perfect high-resolution path.
A physical Android listening check remains release validation. Emulator results
do not establish Bluetooth, Android Auto/car, OEM offload, or physical-device
latency behavior. Automatic device association is a later feature, not an
inactive control in this release.

## Modes and presets

- Simple uses five fixed peaking filters at 63, 250, 1,000, 4,000 and 16,000 Hz
  with Q 0.67. The 10-band mode uses ten octave-spaced filters beginning at
  31.25 Hz with Q √2.
- Advanced permits up to 32 peaking, low/high shelf, low/high pass, or notch
  filters. Frequency, gain, Q, enabled state, and preamp have exact numeric
  editors. Filter ranges are 20–20,000 Hz, ±24 dB, and Q 0.1–20; preamp is
  −60 to +24 dB. Invalid values are rejected, not silently clamped.
- Every preset retains its own mode and exact values. Imported fixed-band
  profiles retain their original frequencies and Q; parametric imports always
  open in Advanced, even when they contain ten filters.
- Each selected preset owns persistent working curves for its visited modes.
  First entering Advanced copies the current curve; first entering a fixed mode
  starts flat. Returning to a mode or preset resumes its retained work, including
  after restart. Master enablement is independent of draft comparisons.
- Modified presets retain their name with `*`. **Save changes** commits the active
  mode to a user preset; built-ins and unnamed work use **Save as New**. Other mode
  drafts remain available. **Discard changes** explicitly clears all mode drafts
  for that identity and restores the saved preset. An unnamed discard returns to
  Flat. Custom is listed only while an unnamed workspace exists and is selectable.
- Flat, Bass boost, and Vocal clarity are immutable built-ins. Names are unique
  ignoring case. Rename preserves drafts. Deletion with drafts requires saving
  all variants under a new identity or explicitly choosing **Discard and Delete**.
  Deletion otherwise retains the current sound as Custom and offers library Undo.
- Selecting a preset keeps master enable/bypass unchanged. An import preview
  offers **Save** without affecting playback, or **Save and enable** explicitly.

Undo/redo is scoped to each preset and mode within the editing session; one
completed drag, slider movement, wheel adjustment, or exact entry is one step.
Frequency/gain readouts use up to two decimals and Q up to three, trimming
fractional zeros (integers keep their digits). Storage and DSP retain full
precision; accepting an untouched numeric field does not round it.

## Editing workspace

The page has four regions, each with one job:

- **Header** — preset name (with `*` when a draft differs from the saved
  preset), one status line combining application state (Applying, Waiting for
  audio, Applied, Bypassed) with draft persistence, the preset menu, and the
  master switch. The mode control is a segmented Simple / 10-band / Advanced
  selector, plus Imported when that layout exists; it falls back to a dropdown
  when the segments do not fit. The header becomes one row from about 600
  logical pixels.
- **Graph** — the primary editing surface, described below. Its toolbar holds
  the only preamp control while the toolbar is visible, Fit response, and the
  Output response toggle.
- **Band inspector** — a strip of numbered band chips (authored order, with the
  short frequency; disabled bands are struck through), then three equal value
  tiles for Frequency, Gain and Q. Units appear once, beside the value. Editable
  tiles show an edit icon and open exact entry; values that a mode fixes show a
  lock and *Fixed*, and pass/notch gain reads *Not applicable*. Advanced adds the
  Wider/Narrower logarithmic Q slider, filter type, band on/off, and Add/Delete
  band; fixed modes offer *Edit in Advanced*.
- **Action bar** — always one row: Undo and Redo, then Discard and Save changes
  (user presets) or Save as New (built-ins and unnamed work). While a number is
  being entered it shows only Cancel and Done. Labels shorten to icons with
  tooltips when space is narrow.

### Layouts

Layout decisions use `AdaptiveContext` and the available constraints, not
device type. Phones in portrait stack the graph above a scrolling inspector,
sizing the graph to leave the strip and value tiles visible. Landscape phones,
short desktop windows, and wide layouts place the inspector (about a third of
the width, 300–360 px) beside the graph. Desktop windows at least 1,200 px wide
can pin the preset library as a side panel; elsewhere it opens as a sheet or
dialog. When the graph is short (large text, short windows) it becomes a compact
preview without a toolbar and the inspector gains a Preamp tile, so preamp
still has exactly one control.

During exact entry the inspector is replaced by an inline editor (field with
unit and range, −/+ steppers, live-preview note) and the graph keeps the
remaining height. Phones hide the header while entering a number; side-by-side
layouts dim and disable it. Nothing else — band, preset, or mode — can take
focus until Done or Cancel.

### Graph

The graph uses logarithmic 20–20,000 Hz spacing and a linear default ±24 dB
range. Fit response expands the range to show the whole curve and toggles back;
it is available only when the curve exceeds ±24 dB. Frequency ranges that
exceed the visible range are marked in the error colour at the plot edge. The
graph is a calculated filter response, not a measurement or a spectrum.

Selection is conveyed by fill, size and contrast rather than hue, so it stays
clear in Navis's restrained (for example white-seed) themes: the selected
filter's own response is shaded under the combined curve, its handle is larger,
filled, numbered, and haloed, a dashed guide and an axis marker show its exact
frequency. Other handles are quieter tonal dots; numbers are drawn only where
they do not collide, and profiles with more than 16 filters use smaller handles.
Disabled bands are hollow. When master EQ is off the combined curve is dimmed.
The optional Output response is a dashed curve with a legend; it includes
preamp and automatic attenuation, while the main curve and handles never do.

Handles show each filter's authored frequency and gain, independent of the
combined curve and headroom. Advanced peaking/shelf bands drag in both axes;
pass/notch bands move only in frequency; fixed modes allow gain only. A drag
keeps its initial grab offset, never reorders bands, and shows a live value
bubble above the finger. Shift gives finer drags and arrow-key steps.

Touches never add bands (use Add band). Pointer targets are resolved in
`EqGraphGeometry.target`: a drag that starts on overlapping handles moves the
band already selected (for example from the strip) when it is under the
pointer; a clearly nearest handle (12 px closer) wins; otherwise a chooser lists
each candidate with its type, gain, Q, and state. On desktop the mouse wheel over
a band adjusts its Q as one Undo step once the wheel rests (450 ms) or
another edit begins. The graph
shows a focus ring; arrow keys nudge the selected band.

### Interaction principles and sources

These references informed the design; they were adapted rather than copied:

- FabFilter Pro-Q: highlight the selected band's own shape on top of the
  combined curve, show values while dragging, wheel for Q, and Shift for fine
  control. Navis keeps click-to-create out of touch layouts and uses an explicit
  Add band, because accidental background touches are common on phones.
- RME ADI-2 Remote: every band exposes the same Gain, Frequency and Q controls,
  and a modified preset is marked until stored. Navis presents them as three
  equal tiles in axis order (Frequency, Gain, Q) and marks drafts with `*`.
- Nothing X Advanced Equaliser: a Simple/Advanced split with plainly named
  Frequency, Q and Gain parameters. Navis uses the same plain labels, with Wider
  and Narrower beside Q.

### Accessibility

Band chips announce the band number, frequency, type, gain, Q, and whether the
band is off. Value tiles are buttons whose label includes the value and unit and
whose hint says how to edit it or why it is fixed. Graph handles expose
selection plus increase/decrease actions for gain, the compact preamp control
exposes ±0.5 dB actions, and the Q and preamp sliders announce their values. All
controls are reachable by keyboard; Escape or Back cancels exact entry.

### Exact entry and previews

Frequency, gain, Q and preamp open inline numeric editing with live graph/audio
preview. Done or Enter commits one edit; Cancel, Escape, Back, or leaving the page
restores the previous sound. Invalid or incomplete text keeps the last valid
preview, shows the supported range, and blocks Done. Untouched readouts never
round stored values. Exact preamp entry reveals the Output response without
moving band handles.

First entering Advanced copies the current configuration. Edit in Advanced
protects an existing Advanced draft with a choice to resume it or create a named
new preset from the current curve. Ordinary mode switching resumes retained work.

The dense headroom calculation behind Output response is debounced and runs
outside painting in one background isolate at a time; stale results cannot
replace newer values. Response samples are computed once per configuration
change, never during painting, and canvas labels are cached across drag frames.
Import previews share the graph renderer and list every filter in authored
order. The earlier band-card list, modal band editor, scroll-triggered duplicate
mini graph, band dropdown, and duplicated preamp controls have been replaced.

The preset library lists unsaved Custom work, your presets, and built-ins in
separate groups, with AutoEQ search as its first action and file/paste import
beside Save as New. Output settings separate the preamp you set, automatic
attenuation, and the resulting effective output gain.

## DSP and gain

The main editing graph shows the authored filters even while bypassed. The
optional Output response overlay includes effective preamp. Both are calculated
responses, not headphone measurements.
Automatic headroom is on by default: dense full-Nyquist response sampling plus
peak refinement computes the maximum combined boost, including overlap. When
preamp plus peak exceeds 0 dB, additional attenuation includes a 0.5 dB margin.
The authored preamp is never rewritten. This reduces overload risk; it is not a
limiter and does not promise protection against every transient.

ReplayGain, volume, mute, ducking, and crossfade deck gains remain separate.
The Android processor also applies ReplayGain (one signed level per queue entry,
cuts and boosts), after the EQ bank and outside its preamp and automatic
headroom, so quiet songs are turned up with the EQ off or on. The iOS tap does the same ([iOS](#ios)).
The level switches to the next song at the first flush after Media3 reports the new
stream, or, when Media3 reports it late (opus: the new song's first decoded buffer is
the one that crosses the old song's last input), after the renderer hands that first
buffer over (`NavisAudioRenderer.processOutputBuffer`), so a boosted song's gain no
longer reaches the next song's first samples in that case. A join with no flush before
the new song's first buffer (a reused opus codec) can still leak that one buffer. A seek or disable drops the announced streams.
Android puts the app-owned processor after Media3's Sonic processing, delegates
its duration accounting, prevents encoded passthrough/offload, and crossfades
configuration banks over 20 ms at audio-block boundaries. Each channel owns its
filter history. Format/seek flushes reset history. Unrepresentable profiles are
bypassed completely with a reason instead of silently dropping filters.

The Linux adapter owns one complete labelled mpv audio-filter chain for tempo
and EQ, preserving speed/pitch when either changes. Application checks read the actual mpv filter graph
and reject stale coefficients or an EQ chain that remains after bypass. Biquad commands contain only
validated numeric values; imported text never reaches native commands. Filters
are designed for the audible frequency after mpv's pitch shift. The state
reports source and response sample rates separately. Output already buffered
before a desktop edit can take time to drain; captured-signal assertions measure
the settled segment, not that transition.

`EqController` binds graph gestures to preset/mode identity and serializes atomic
workspace writes. Graph updates publish immediately, checkpoint at most every
250 ms, and flush on release/navigation/backgrounding. Checkpoint storage has one
in-flight and one replaceable pending snapshot. Native previews use one in-flight
and one latest pending command with a 33 ms pacing interval. Numeric previews are
temporary until Done. Commit creates one Undo step; cancel restores the start.
Transitions invalidate old gestures and previews so delayed work cannot edit a
new workspace. Storage failures retain the
working curve in memory with retry and suppress the “Draft saved” message.
Engine failures retain the persisted draft while exposing retry and the actual
applied state. Desired and applied state remain separate. Paused edits are
checked again after resume. Both playback decks and recreation retain the
desired configuration; unavailable processing has an explicit bypass reason.

Schema v85 adds the singleton workspace JSON snapshot alongside the current
curve. The v84→85 migration wraps the exact working curve into its origin
workspace; hydration validates that identity and recovers unowned curves as Custom. Saved presets and
AutoEQ provenance are retained. Workspace and selection transitions, and preset
commits, use atomic writes. The preset export format remains version 1 and
exports the committed configuration.

## AutoEQ

The bundled official catalogue contains 8,850 result entries at revision
`7ae0f56d53074872b028649617a22bbb4232feb7`. It combines the recommended list and
full index, retaining distinct measurements and headphone variants. Search is
offline, with recommended-only filtering by default. Explicit refresh downloads
and validates both index files at one immutable revision, replacing the cached
index atomically. Existing saved presets never update automatically.

Downloading a selection obtains its `ParametricEQ.txt` export. Explicit refresh
and downloads contact `raw.githubusercontent.com` for content and
`api.github.com` for revision metadata. Both hosts are disclosed in Integrations
and Privacy; the bundled catalogue remains available offline. AutoEQ HTTP
requests include the shared Navis User-Agent with project and support contacts.

## Importing presets

File and paste imports go through one pipeline
(`lib/src/features/equalizer/data/eq_import_parser.dart` and `eq_import/`) that
recognises the format by content, never by file name:

| Format | Read as |
|---|---|
| Navis preset JSON (`format: navis-eq`, version 1) | As saved; the file's own name is kept and the EQ is never switched on by an import. |
| EasyEffects equalizer JSON | Left-channel bands; Bell, shelf, pass and notch types; `mute` disables a band; input plus output gain becomes the preamp. |
| AutoEQ `ParametricEQ.txt`, REW filter exports, Equalizer APO configs | Numbered or unnumbered `Filter:` lines with `PK`/`PEQ`, `LS`/`LSC`/`HS`/`HSC` (Q or a dB/octave slope), `LP`/`LPQ`, `HP`/`HPQ` and `NO`; `Fc`, `Gain`, `Q` or `BW Oct`. REW headers and empty `None` slots are skipped. |
| AutoEQ `FixedBandEQ.txt` | Detected when there are ten peaking bands at the AutoEQ frequencies with one shared Q, and kept as Imported fixed bands. |
| `GraphicEQ:` curves (AutoEQ, Wavelet) | Fitted with up to 31 third-octave peaking filters (damped Gauss–Newton against the curve on a log grid, using Navis's own biquad response); the preview reports the average error. |

Files may be UTF-8 (with or without a BOM), UTF-16 in either byte order (with
or without a BOM, as Windows Notepad writes "Unicode") or Windows-1252, and may
use CR/LF line endings and comma decimals. As in Equalizer APO, several
`Preamp:` lines add up and a missing preamp means 0 dB with automatic headroom.
Instructions that do not change the curve (`Device`, `Include`, `Copy`,
`Stage`, `Delay`, ...), band-pass and all-pass filters, and per-channel blocks
after the first are left out with a note in the preview. Values outside the
supported limits, unknown instructions, more than 32 filters, oversized input
(over 1 MiB) and unsupported versions are rejected with the offending line
before anything changes playback. Imports preserve preamp, filter order,
frequencies, gains, Q, on/off flags, source, revision, measurement attribution,
and original text, and exported Navis JSON round-trips them. Export file names
are made safe on every platform.

AutoEQ is by Jaakko Pasanen and contributors under the MIT licence; the bundled
licence is `assets/autoeq/LICENSE`. Rebuild the bundled index with
`python3 tool/update_autoeq_index.py --revision <verified-full-commit-sha>`.
Upstream sources: [recommended results](https://github.com/jaakkopasanen/AutoEq/blob/master/results/README.md)
and [full index](https://github.com/jaakkopasanen/AutoEq/blob/master/results/INDEX.md).

## Persistence and upgrade

Schema v84 introduced `eq_presets` and a singleton `eq_state` row; v85 adds
the persistent per-preset/per-mode workspace snapshot.
Preset identity is stable and separate from its name. General settings saves
cannot overwrite this data. Damaged records are retained for recovery while a
bad current configuration loads disabled/flat with a visible notice.

The v83→84 migration drops legacy experimental EQ gains/enable and loudness
booster columns. It does not translate or preserve them. Affected installations
receive a one-time reset notice; ordinary draft saves do not acknowledge it.
Unrelated settings and precise speed/pitch work survive the migration.

## Validation

Physical-device delivery checks are listed in
[the phone checklist](equalizer-phone-checklist.md).

- `flutter test test/src/features/equalizer` (includes layout, interaction,
  semantics, and graph-painting goldens under `presentation/goldens/`)
- `flutter test test/src/database/migrations/navis_migration_test.dart`
- `./tool/equalizer_native_test.sh` (independent response/PCM and stereo fixtures)
- `./tool/equalizer_diagnostics.sh` (isolated Linux profile, captured signal,
  pitch compatibility, bypass, headroom, crossfade transition, persistence,
  restart, screenshots)
- `tool/android_equalizer_diagnostics.py` exercises an already-running isolated
  Android sidecar with local tone fixtures and its authenticated handshake.
- `./tool/check.sh` runs native fixtures, generation, analysis, and the full suite.

Clone diagnostics exposes authenticated `GET /v1/equalizer` for desired,
applied, persisted, and preset state; `POST /v1/equalizer` uses the production
controller for configure, enable, select, save/update, rename/duplicate/delete,
restore, import, mode selection, Custom selection, discard, retry, temporary
preview/cancel, undo/redo, reset, and reset-notice acknowledgement. Status includes
workspace snapshots, active dirty state, and draft persistence status. Existing
presentation navigation and app-owned screenshots cover `/settings/equalizer`. Mounted graph actions
include selectBand, dragBand/cancelDrag, exact numeric editing, and profileGraph;
status exposes queue occupancy and command/write counters for isolated evidence.
`POST /v1/presentation/dismiss-popup` can dismiss app-owned popup routes without
leaving the underlying page. Mutation endpoints remain forbidden in read-only
certification mode.
