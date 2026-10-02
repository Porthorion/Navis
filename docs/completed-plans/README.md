# Completed implementation plans

This folder contains root-level implementation plans whose in-repository work
has been completed and validated. Any remaining platform or upstream checks are
recorded in the plan's handoff section; plans with unfinished implementation,
open blockers, or required follow-up work remain at the repository root.

## Completed plans

- [Rapid playback navigation](Rapid_Playback_Navigation_Fix_Plan.md) — bounded
  Next/Previous bursts and row selections in the production handler. Regression
  tests, the real-server Linux gate, and Windows VM and Android emulator bursts
  passed on 2026-10-02; iOS, macOS and physical devices are recorded as not
  covered.
- [Gradual speed, pitch and playback presets](Playback_Speed_Pitch_Presets_Plan.md)
  — shared bidirectional rulers, independent pitch, exact entry, local presets
  and persistent adjustments. Full quality gate and isolated Linux/Android
  runtime/restart checks passed; native PCM frequency and inspected screenshots
  are recorded, along with physical-device and other host coverage limits.
- [Responsive Layout Polish](Responsive_Layout_Polish_Plan.md) — the 180 ms
  desktop album fade, scoped Liked Albums tooltip suppression and existing
  numeric-column headings. Focused/full tests and authenticated Linux runtime
  captures, paging and clean restart are complete; other host/device coverage
  limits are explicit. The original responsive overhaul evidence is preserved.
- [Responsive Layout Overhaul Plan](Responsive_Layout_Overhaul_Plan.md) — the
  bounded-grid, compact-preview, adaptive-track-row, recommendation and desktop
  time-label overhaul. Linux and Android emulator runtime evidence, persisted
  settings and clean restarts are complete; physical-device and other host
  coverage limits are explicit. Automotive work remains separate.
- [Instant Mix and Radio Fix Plan](Instant_Mix_and_Radio_Fix_Plan.md) — the
  1.4.0 portable Subsonic mix and personal-radio implementation. Physical DHU
  projection and post-indexing validation remain explicitly documented as
  external follow-up, not unrecorded work.

## Root plans retained

- `Remote_Song_Handling_Plan.md` remains active because cold remote playback
  work and Android runtime validation are still unresolved.
- `Sync_Improvement_Plan_1-4-0.md` remains active because its validation
  section and multiple sync findings still require implementation or evidence.
- `DEVELOPMENT_PLAN.md` and `PROGRESS.md` remain at the root because they are
  live backlog and progress trackers with open tasks, rather than completed
  implementation plans.
