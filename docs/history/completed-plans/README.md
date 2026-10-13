# Completed implementation plans

This folder contains implementation plans whose in-repository work
has been completed and validated. Any remaining platform or upstream checks are
recorded in the plan's handoff section; plans with unfinished implementation,
open blockers, or required follow-up work remain in `docs/plans/`.

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

- [Production EQ](EQ_System_Plan.md) — the dedicated Equalizer page and native
  parametric EQ. Automated, Linux and Android emulator validation passed
  (accepted 2026-09-28); physical-device release checks are listed in the plan.
- [Dependency upgrades](Dependency_Upgrade_Plan.md) — the 2026-09-27 dependency
  upgrade, merged into dev on 2026-10-01. Apple, physical Android arm64 and full
  head-unit projection remain recorded as unverified. Moved from the root on
  2026-10-12.

- [Personal Radio pool memory](2026-10-12-radio-pool-memory.md) — shipped in
  merge `299d4f34` on 2026-10-12; retained as implementation evidence.

## Plans retained elsewhere

- Active plans live in `docs/plans/` (moved from the root on 2026-10-13).
- `Remote_Song_Handling_Plan.md` remains active because cold remote playback
  work and Android runtime validation are still unresolved.
- `Sync_Improvement_Plan_1-4-0.md` remains active because its validation
  section and multiple sync findings still require implementation or evidence.
- `docs/project/development-plan.md` and `docs/project/progress.md` live in
  `docs/project/` because they are live backlog and progress trackers with open tasks, rather than completed
  implementation plans.
- `Fix_Stale_Cache_Plan.md` and `Fix_Stale_Cache_Execution_Plan.md` remain
  until the execution plan's open acceptance boxes are checked.
- `Sync_Audit_Remediation_Plan.md` remains active (status: in progress).
