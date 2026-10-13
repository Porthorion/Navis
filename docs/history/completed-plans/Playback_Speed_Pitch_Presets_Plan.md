# Gradual speed, pitch, and playback presets

Date: 2026-09-28. Status: completed in-repository; external host/device coverage limits below.

## Accepted behavior

Replace the stepped playback-speed controls throughout Navis with one shared
Speed & Pitch panel. Speed is a signed percentage adjustment (0% = 1×,
+25% = 1.25×); pitch is signed semitones (0 = unchanged, +12 = one octave).
The controls are independent. Horizontal rulers scroll beneath a fixed marker
in both directions, with decimal ticks, exact numeric entry, ±1 buttons,
individual resets, and a combined reset. Precision is 0.01 percentage point
and 0.01 semitone. Preserve Navis styling and responsive behavior, and support
touch, pointer, focused wheel/trackpad, keyboard and semantic adjustments.

Keep adjustments across tracks, new queues, clearing queues and app restarts.
User presets are local and contain a name and both values. None is an immutable
built-in preset that applies zero adjustments. Offer Save as new, Update,
Rename and Delete everywhere the panel appears. Editing controls yields Custom
and never silently modifies a preset; retain the originating preset as an
explicit update target. Deleting an active preset leaves the sound as Custom.
Names must be nonempty and unique ignoring case, with None reserved. Initially
provide only None. A playback-settings reset selects None but retains presets.

Pitch is available on Android and the desktop media-kit backend. iOS and
unsupported fallback backends show pitch unavailable and disable application of
nonzero-pitch presets while preserving their visibility and management.
No arbitrary global slider limits: enforce positive finite factors, numeric
representability and documented backend constraints, explain rejected input,
and never silently clamp or claim an unapplied preset is active.

## Implementation packages

- [x] Persist pitch, presets and selected identity through a stepwise Drift
  migration; preserve existing speed exactly. Derive None in code. Use targeted
  writes so unrelated settings autosaves cannot overwrite adjustments/presets.
- [x] Add a shared Riverpod controller whose lifetime exceeds the panel. Apply
  immediately, serialize/coalesce changes, persist after a short delay, flush
  on interaction completion/dismissal and retain pending writes after navigation.
  Handle application and persistence errors explicitly.
- [x] Extend the handler/runtime contract with paired application and backend
  capabilities, retaining the existing speed wrapper. Convert percentage with
  `1 + percent / 100` and semitones with `2^(semitones / 12)`.
- [x] Apply both values to active/crossfade decks across creation, replacement,
  recovery and swaps. Remove UI quantization, generic speed clamp, and
  queue-clear speed resets. Keep source priority and queue identity intact.
- [x] Build the reusable panel and replace every existing speed entry point,
  including Settings and wide Now Playing layouts; update playback summaries.
- [x] Add authenticated clone-only diagnostics through the production controller
  for observation, adjustment and preset scenarios.
- [x] Update localization, architecture/platform capability documentation,
  changelog, release notes and history of replaced behavior.

## Validation and acceptance

- [x] Logic: conversion accuracy, fractional and negative adjustments, backend
  boundaries, nonfinite/invalid values, unsupported pitch and pair independence.
- [x] Persistence: populated-schema upgrade, exact old speed preservation,
  preset CRUD, immutable None, selected identity and unrelated settings writes.
- [x] Concurrency/lifecycle: rapid drag and preset selection, close before save,
  failures, queue clear, crossfade, recreation/recovery and clean restart.
- [x] Widgets: synchronized entry points, exact input, buttons/resets, Custom,
  management, unavailable/loading/error states, keyboard/semantics and enlarged
  text at phone/tablet/desktop widths.
- [x] Isolated Linux runtime: authenticated diagnostics, app-owned screenshots
  opened and inspected, independent audible speed/pitch and position progression,
  persistence and restart. Exercise available affected platform builds/devices;
  report unavailable coverage honestly.
- [x] Regenerate tracked source, run focused tests and analyzer, complete
  `./tool/check.sh`, review the diff and repeat acceptance after clean restart.

## Boundaries and evidence

No preset synchronization, per-track assignment, linked controls or new iOS
audio engine. Preserve pre-existing dirty work. The installed Android Media3
1.4.1 audio sink constrains speed and pitch factors to 0.1–8. Desktop media-kit
uses mpv speed for pitch and scaletempo scale for speed/pitch compensation;
validate that pair rather than imposing an unrelated UI range.

References: [Android sink](https://github.com/androidx/media/blob/1.4.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/audio/DefaultAudioSink.java),
[mpv scaletempo](https://github.com/mpv-player/mpv/blob/v0.40.0/audio/filter/af_scaletempo.c).

## Implementation evidence

The final `./tool/check.sh` run passed formatting, generated-source refresh,
analysis, 42 migration tests, critical reliability checks and the full suite:
1,726 tests passed, with one existing skip. Analysis reported no errors or
warnings; the existing informational lint backlog remains. The complete task
diff was reviewed and `git diff --check` passed. Existing unrelated workspace
changes were preserved. Bootstrap and focused tests completed before the full
quality gate.

Focused coverage includes three conversion/capability/serialization tests, nine
controller tests and eleven panel widget tests, plus targeted storage, migration,
paired-handler and authenticated API regressions. These cover coalescing, native
rollback, retryable persistence, dismissal before debounce, immutable None,
CRUD and explicit update, long names, unsupported pitch, exact input rejection,
keyboard, focused scrolling, semantics and 2× text at 390/768/1280 pixel widths.
A named zero-adjustment preset keeps its selected identity after reload. Engine
publication preserves an already restored preset without a transient Custom
label or redundant application.

Linux final acceptance passed in
`build/playback-adjustment-diagnostics/20260928T120254Z/`. It used an isolated
SQLite backup and synthetic 440 Hz WAV, with scrobbling disabled in the clone.
Both decks accepted +27.35% speed and −2.37 semitones, and retained them through
queue clearing, a track transition/deck swap and clean restart. Changing only
speed to +45.12% kept the measured pitch near 384 Hz (expected 383.71 Hz), with
nonzero captured PCM. Native position advanced. Preset save/select/delete and
None reset passed; deleting the active preset retained the sound as Custom.
The app-owned Settings, Mini Player/Now Playing and restarted Settings PNGs
were opened and visually inspected. Controls fit; the smaller sheet scrolls to
its lower actions. The primary database, downloads and ordinary output route
were not modified.

Android sideload debug and isolated profile builds passed. The final native
phone smoke used the `Navis_Dependency_Upgrade` Android 37 emulator, a separate
`.adjustments` profile package, fresh database and deterministic loopback
Subsonic fixture; no real-server credentials or primary database were used.
Evidence is in `build/playback-adjustment-diagnostics/android/`. Native speed
and pitch factors matched the fractional values, changing speed preserved pitch,
position advanced from 42 ms to 3,866 ms, queue clear retained the pair, and
preset identity/values survived a clean restart. Restored values were verified
before reconnecting the fixture account for the final Settings screenshot.
Deleting the active preset retained sound; None reset both values. Settings,
Now Playing and restarted Settings app-owned PNGs were opened and inspected at
448×997 logical pixels, DPR 3. No Flutter/runtime exceptions were found in the
inspected sidecar process log. The temporary sidecar, battery exemption, forwarded
ports, fixture service and task-started emulator were removed/stopped.

Physical Android hardware, Windows and macOS runtime/audio checks were not
executed on this Linux host. Android emulator acceptance confirms native
parameters, playback progression and UI behavior; PCM frequency verification
was performed on Linux. iOS/default Apple pitch remains explicitly unavailable,
with disabled pitch application and visible/manageable presets; no new Apple
audio engine was added. Android Auto projection and cross-host native packaging
were not changed by this task.
