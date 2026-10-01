# Production EQ for Navis

Status: implementation complete; automated, Linux, and Android emulator validation passed. Physical-device release checks remain below. Accepted 2026-09-28.

## Summary

Replace the experimental EQ with a dedicated, production-quality Equalizer
page. Android is the primary target; add desktop support through the existing
media-kit backend where validation succeeds.

The first release includes Simple, 10-band, and Advanced parametric editing;
live adjustments; saved presets; AutoEQ search and import; and automatic
headroom. Device-based switching remains a separate follow-up.

Remove the old EQ and loudness-booster settings without approximation or
preservation. Start the replacement disabled with a flat curve, and explain the
reset once to previously affected users.

## Experience and preset behavior

### Navigation and layout

- Add `/settings/equalizer`, accessible directly from Settings, from Playback's
  normal settings section, and from Now Playing's actions.
- Remove the experimental EQ controls. Retire the separate loudness booster in
  favor of EQ preamp and headroom controls.
- Use Navis's existing theme and adaptive layout system. Wide layouts place
  the preset library beside the editor; compact layouts use a preset picker
  above a single scrolling editor.
- Keep enable/bypass, selected preset, mode, and application status visible
  near the top. Unsupported backends show a disabled entry with an accurate
  explanation.
- On phones, use comfortably sized slider rows with numeric input rather than
  squeezing ten narrow controls across the screen. Desktop can show a
  horizontal band bank, with the same accessible numeric controls.

### Editing modes

| Mode | Controls |
|---|---|
| Simple | Five fixed bands: 63, 250, 1,000, 4,000 and 16,000 Hz; gain and preamp |
| 10-band | Ten octave-spaced bands, starting at 31.25 Hz; gain and preamp |
| Advanced | Up to 32 filters; frequency, gain, Q, type, individual enable, add/remove and preamp |

- Use peaking filters for fixed-band modes: Q 0.67 for Simple and square root
  of 2 for 10-band.
- Advanced supports peaking, low/high shelves, low/high pass, and notch filters.
- Show the calculated frequency response, including effective preamp. This
  represents configured filters, not a measured headphone response.
- Provide live preview, undo/redo within the editing session, individual-band
  reset, and reset-to-flat.
- Use numeric controls with validation; never silently clamp imported values.
  Initial supported ranges are 20–20,000 Hz, ±24 dB filter gain, Q 0.1–20,
  and −60 to +24 dB preamp. Backend/sample-rate restrictions remain explicit.

### Preset rules

- Store editing mode and exact filter parameters with every preset. Selecting
  a preset restores its mode.
- Opening fixed bands in Advanced retains their exact filters. Moving to
  another fixed-band mode starts a separate flat draft; it never approximates
  or overwrites the original.
- Manual edits become a persistent **Custom** draft. Named presets change only
  through **Update** or **Save as new**.
- Support create, rename, duplicate, delete with Undo, import, and export.
  Deleting the active preset preserves its sound as Custom.
- Ship immutable Flat, Bass boost, and Vocal clarity presets. Editing them
  creates Custom.
- Keep names unique ignoring case; duplicates receive an editable suggested
  name rather than overwriting.
- Selecting a preset preserves the master enable/bypass state. Import offers
  **Save** and **Save and enable** explicitly.
- Presets are local to the installation and survive account changes and
  ordinary playback-settings resets. Export uses versioned Navis JSON for
  complete round trips.

## Audio architecture and state

### Android

- Vendor the currently resolved just_audio and platform-interface versions
  with a narrow, documented EQ extension. Keep Media3, audio_service, queue
  handling, source resolution, and Android Auto integration.
- Add an app-owned Media3 PCM processor to every playback deck, including the
  crossfade deck. Install it at player creation with a bypass path so EQ can
  be enabled during playback without restarting the player.
- Process audio natively, using higher-precision filter calculations, reusable
  buffers, per-channel state, and short transitions between configurations.
  Flutter/Dart owns editing, validation, presets, graph calculations, and
  control state.
- Place EQ after speed/pitch processing. Preserve existing speed/pitch duration
  accounting.
- Keep processing in decoded PCM; prevent offload or passthrough from bypassing
  EQ. The current Media3 integration uses 16-bit PCM at this boundary, so the
  feature must not claim bit-perfect high-resolution output.

Reference: [Media3 processing contract](https://raw.githubusercontent.com/androidx/media/1.4.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/audio/DefaultAudioSink.java).

### Desktop

- Extend the existing vendored media-kit adapter using mpv/FFmpeg audio filters.
  The preliminary Linux filter-loading check passed; this is feasibility
  evidence, not application validation.
- Give the adapter one owner for the complete speed/pitch/EQ filter chain.
  Replace current calls that overwrite the chain when speed or pitch changes.
- Preserve EQ frequencies in audible-output Hz when pitch changes; include
  any required sample-rate compensation in the adapter.
- Verify applied properties and propagate failures. Desktop availability
  depends on the registered backend and required filter support, including
  macOS's fallback backend.
- Enable desktop support per validated target. Desktop shortcomings must not
  delay a completed Android release.

Reference: [mpv audio filters](https://mpv.io/manual/master/#audio-filters).

### Interfaces and lifecycle

- Add immutable `EqConfiguration`, `EqFilter`, `EqPreset`, `EqCapabilities`,
  and `EqApplicationState` types.
- Extend `NavisPlaybackHandler` with capability reporting, configuration
  application, and observable desired/applied state. Add a typed platform
  bridge; widgets never access native player identifiers.
- Use a long-lived Riverpod EQ controller and dedicated repository methods.
  Coalesce rapid input, serialize native application and persistence, and
  reject stale completions.
- Apply configurations to both decks before they become audible; restore them
  after player recreation, recovery, and deck swaps.
- On rejected edits, restore the last confirmed configuration and show the
  failure. If processing becomes unavailable, keep playback working with an
  explicit bypass status and retain the user's desired preset.
- General settings saves omit EQ-owned fields, preventing stale settings
  screens from overwriting live edits.

### Gain behavior

- Enable automatic headroom by default. Calculate attenuation from the
  combined filter response and authored preamp, including overlapping boosts.
- Show authored preamp and additional protective attenuation separately;
  imported values remain intact.
- Advanced users can disable automatic headroom with a visible clipping-risk
  indicator.
- Preserve ReplayGain, user volume, mute, ducking, and crossfade behavior. Do
  not add a limiter or compressor in this release; automatic headroom reduces
  overload risk without promising protection against every transient.
- Recalculate processing for sample-rate changes. If a complete profile cannot
  be represented, report the limitation and bypass it rather than silently
  dropping filters.

## AutoEQ, persistence, and migration

### AutoEQ discovery and import

- Provide in-app headphone search using AutoEQ's official recommended-results
  list and full index. Show measurement source and target information where
  supplied; retain distinct headphone variants.
- Bundle a versioned search index, allow explicit refresh, and download a
  selected profile on demand. Save imported profiles completely locally so
  playback never depends on network access.
- Preserve attribution, source location, revision, original text, preamp,
  filter order, and exact numeric values. Saved profiles never change
  automatically when upstream updates.
- Accept parametric and fixed-band text through file selection or explicit
  paste. Support documented `PK`, `LSC`, and `HSC` forms and enabled/disabled
  flags.
- Parametric imports open in Advanced. Fixed-band imports retain their original
  layout and values; ten parametric filters must not be mistaken for a
  standard 10-band preset.
- Preview name, source, curve, preamp, and filters before saving. Importing
  alone does not alter playback.
- Reject malformed, oversized, unsupported, or out-of-range input with useful
  errors. Never execute directives or pass raw text into backend commands.
- Dense `GraphicEQ` curves and convolution WAVs are out of scope. Explain how
  to obtain a supported parametric export instead.

References: [recommended results](https://github.com/jaakkopasanen/AutoEq/blob/master/results/README.md),
[full index](https://github.com/jaakkopasanen/AutoEq/blob/master/results/INDEX.md),
[format fixtures](https://github.com/jaakkopasanen/AutoEq/blob/master/tests/test_autoeq.py).

### Storage and upgrade

- Add dedicated Drift persistence for presets and singleton current EQ state,
  with versioned payloads and transactional updates.
- Use the next migration after the current working-tree schema; regenerate
  tracked output and extend populated-database migration tests.
- Delete legacy EQ gains, enable state, and loudness-booster settings from the
  current schema and runtime interfaces. Historical migrations remain intact.
- Do not generate a legacy approximation. Preserve unrelated settings,
  existing speed/pitch work, and other uncommitted changes.
- Playback-settings reset disables EQ and resets the working curve while
  retaining named presets.

### Later device switching

Keep stable preset IDs suitable for future device associations, but add no
discovery permissions or inactive device UI now. The follow-up uses the actual
output route, explicit user assignment, and manual fallback for ambiguous
identities. Connected-device lists alone do not establish which device is
playing audio.

Reference: [audio_session device APIs](https://pub.dev/documentation/audio_session/latest/audio_session/AudioSession-class.html).

## Delivery and acceptance

Implement in order: native processing and capabilities; controller/storage/
migration; responsive editor and presets; AutoEQ discovery/import; desktop
integration; release validation.

- DSP: verify responses against independent fixtures, including AutoEQ
  shelves/Q, overlapping boosts, bypass, rapid changes, sample-rate changes,
  and finite output. Target agreement within 0.1 dB for supported references.
- Playback: test enable-after-startup, both crossfade decks, gapless,
  speed/pitch, seek, skip, recovery, background, interruptions, and restart.
  EQ changes never reset position or queue identity.
- State/storage: test out-of-order work, engine/persistence failures, preset
  lifecycle, stale settings saves, account changes, corrupt data, and populated
  legacy upgrades.
- Import/search: test fixed versus parametric interpretation, exact round
  trips, unsupported formats, duplicate names, cancellation, offline use,
  unavailable files, and stale searches.
- UI: test phone, tablet, compact/wide desktop; large text, keyboard controls,
  screen-reader semantics, long names, and unavailable/error states.
- Runtime: validate a real Android device and Linux isolated profile through
  authenticated diagnostics. Add EQ control/status diagnostics and inspect
  app-owned screenshots. Windows/macOS require separate native/runtime
  evidence before being marked supported.
- Quality/docs: run focused native/Dart/widget/migration checks, generation,
  analysis, and `./tool/check.sh`. Update architecture, platform support,
  workflow/CI docs, changelog, release notes, and removal history.

Promotion out of Experimental requires verified audible processing and
persistence, not merely functioning controls.

## Implementation evidence

- [x] Accepted plan saved as a Markdown artifact.
- [x] Native Android processor and typed bridge, including PCM bank transitions.
- [x] Linux filter-chain integration; Windows/macOS stay explicitly unavailable.
- [x] Domain models, DSP calculations, AutoEQ parser, and independent references.
- [x] Dedicated Drift persistence, populated v83→84 migration, and legacy removal.
- [x] Riverpod controller, stale-edit handling, failure retries, and both decks.
- [x] Responsive EQ editor and preset management with exact numeric editing.
- [x] Official offline catalogue, search, import preview, provenance, and export.
- [x] Authenticated diagnostics and inspected mobile/desktop screenshots.
- [x] Final gate and complete change audit.

Evidence collected on 2026-09-28/29:

- 43 focused EQ tests pass, covering independent response fixtures, exact
  AutoEQ parametric/fixed-band exports, official download filenames, corrupt
  storage, preset lifecycle, engine rejection, persistence retry, adaptive
  layouts, AutoEQ discovery with 2× text and a mobile keyboard, and native
  chain verification that rejects stale coefficients and failed bypass.
- Native JVM tests verify 44.1/48/96 kHz filters, AutoEQ shelves/Q, overlap
  headroom, PCM tone response, stereo isolation, bypass, and validation limits.
- Android debug and isolated x64 profile APK builds succeed. The Android 37
  emulator sidecar verifies actual native 44.1 kHz EQ application, headroom,
  rapid edits, speed/pitch, seek/skip, pause/resume, track transition, background
  progress, preset storage, and exact identity/configuration after restart.
  Its app-owned EQ capture is inspected at
  `build/eq-android-validation/final-evidence/eq-mobile.png`.
- Linux captures verify −11.9983 dB for the requested 12 dB cut, −0.4985 dB
  net gain with automatic headroom for a 12 dB boost, +0.0011 dB bypass,
  and −12.0000 dB with pitch shifted one octave. The crossfade's completed
  incoming deck retains the cut; a clean restart retains configuration and
  preset identity. Compact 800×600 and wide 1280×1000 app-owned captures are
  inspected. Evidence: `build/equalizer-diagnostics/20260928T203506Z/`.
- `./tool/check.sh` passes native fixtures, formatting, generation, analysis,
  migrations, critical reliability checks, and 1,808 tests with one existing
  skip. The final run includes the dialog, preset history, and native chain
  regressions. Analyzer information-level findings remain permitted by the
  repository gate; there are no analyzer errors or warnings.

### Remaining release validation and later work

Physical Android listening, Bluetooth/OEM route behavior, audio interruptions,
and device latency remain unverified here. Emulator tests do not substitute for
those checks. Windows EQ is enabled and verified on the Windows 11 VM with the
pinned libmpv (`docs/audits/windows-review-2026-10-01.md`); macOS still
requires native runtime evidence before enabling EQ. Device discovery and automatic preset association remain the explicitly
optional follow-up; stable preset IDs are ready for it. Convolution and dense
GraphicEQ support remain outside the accepted first release.

The working tree contains substantial unrelated playback and layout work.
Implementation extends that state without resetting or replacing it.

## 2026-09-29 graph-first revision

The accepted follow-up replaces band cards/modal editing and the duplicated
pinned graph with a large interactive graph, selected-band controls, inline
numeric Done/Cancel, and a collapsible/adaptive preset library. It retains the
v85 persistent draft model and the existing native filters and AutoEQ format.
Authored frequency/gain handles remain independent of headroom. Graph gestures
are identity-bound, checkpoint at most every 250 ms, and form one Undo step;
audio previews and checkpoint writes have bounded pending queues. Existing
Advanced drafts can be resumed or preserved while creating a separate preset
from the current fixed curve. Runtime evidence for this revision is recorded
below after the final checks.

Graph-first delivery evidence collected on 2026-09-29:

- 74 focused EQ/presentation tests pass, including graph geometry, fixed-mode
  restrictions, ambiguity selection, cancellation, untouched precision, exact
  preamp output preview, Advanced draft protection, coalescing, delayed storage,
  failed writes, and AutoEQ parametric/fixed export round trips.
- `./tool/check.sh` passes generation, native fixtures, analysis, migration,
  reliability checks, and 1,883 tests with one existing skip. Final log:
  `build/eq-graph-check.log`.
- Linux diagnostics pass calculated/captured response, native bypass and
  headroom, speed/pitch, playback transitions, inline preview/cancel, graph
  drag/Undo/cancel, stored drafts, and clean restart. App-owned wide/compact,
  numeric-preview, and 32-band screenshots were inspected. Evidence:
  `build/equalizer-diagnostics/20260929T101253Z/`.
- The Linux 32-filter/180-update profile captured 192 rendered frames; build
  and raster p95 were 13.821 ms and 8.059 ms. It issued 71 preview commands and
  18 checkpoint/final writes, with no queued work remaining afterward.
- The isolated Android profile package verifies the native bridge, live exact
  preview/cancellation, graph editing, bypass/headroom, background playback,
  and exact configuration/preset/workspace recovery after a clean restart.
  Inspected screenshots and JSON are in `build/eq-graph-android/evidence/`.
  Its 32-band profile captured 190 frames with build/raster p95 6.871/23.580 ms;
  emulator raster timing does not establish physical-phone smoothness. An
  optional repeat without concurrent builds was interrupted when the emulator
  disconnected, after the required runtime and restart evidence were saved.
- The signed development APK is `build/eq-graph-delivery/Navis-Dev-EQ.apk`.
  Package metadata verifies `com.navis.app.navis.dev` and the Navis Dev label;
  APK signature verification succeeds. Physical installation/listening remain
  deferred. The focused checklist is `docs/equalizer-phone-checklist.md`.
