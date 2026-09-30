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
| Windows/macOS media-kit | UI disabled pending platform-specific validation |
| Default Apple backend and web | UI disabled; processing is unavailable |

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

Downloading a selection obtains its `ParametricEQ.txt` export.

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
