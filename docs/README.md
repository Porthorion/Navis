# Navis documentation map

This directory separates current operating documentation from plans, audits,
and historical evidence. Current implementation and tests take precedence if a
document conflicts with code. Do not treat roadmap or audit records as current
product contracts.

## Start by task

| Need | Read |
|---|---|
| Project overview, support, quick start | [../README.md](../README.md) |
| Agent workflow and documentation rules | [agentic-engineering.md](agentic-engineering.md) and [../AGENTS.md](../AGENTS.md) |
| Equalizer, AutoEQ, presets, DSP, and platform limits | [equalizer.md](equalizer.md) |
| Architecture, providers, data flows, routing, platform integration | [architecture.md](architecture.md) |
| Bootstrap, local validation, diagnostics API, runtime evidence | [development-workflow.md](development-workflow.md) |
| Dependency audits, upgrade batches, replacement decisions, and regression gates | [dependency-upgrades.md](dependency-upgrades.md) |
| Quality gates, releases, signing, CI-equivalent workflow | [ci-cd.md](ci-cd.md), [release-secrets.md](release-secrets.md) and [release-r2.md](release-r2.md) (update channel) |
| Side-by-side/dev builds | [dev-testing-builds.md](dev-testing-builds.md) |
| Android Auto | [android-auto-testing.md](android-auto-testing.md) and [android_auto_real_car_testing.md](android_auto_real_car_testing.md) |
| Linux, macOS, Windows, or multi-host releases | [release-from-linux.md](release-from-linux.md), [release-linux.md](release-linux.md), [release-macos.md](release-macos.md), [release-windows.md](release-windows.md), [multi-os-build-from-mac.md](multi-os-build-from-mac.md) |
| Production symptom recovery | [troubleshooting.md](troubleshooting.md) |
| Active platform-readiness work | [flathub-readiness.md](flathub-readiness.md) or [google-play-readiness.md](google-play-readiness.md) |
| Current sync design, recovery boundaries, and certification evidence | [sync-reliability-recovery-plan.md](sync-reliability-recovery-plan.md), [sync-stability-validation.md](sync-stability-validation.md) |

## Document status

### Active reference

`architecture.md`, `development-workflow.md`, `ci-cd.md`, `dev-testing-builds.md`,
`troubleshooting.md`, the Android Auto guides,
release guides, and platform readiness documents describe maintained
workflows or explicit current gaps.

### Plans, audits, and evidence

[Production EQ plan](completed-plans/EQ_System_Plan.md) records the accepted replacement
for experimental EQ, native processing, presets, AutoEQ, and validation.
Implementation and validation are in progress; the plan is not a current
capability claim.

[Speed, pitch and presets](completed-plans/Playback_Speed_Pitch_Presets_Plan.md) records the
accepted controls, persistence, platform boundaries and implementation evidence.

[Responsive Layout Overhaul Plan](completed-plans/Responsive_Layout_Overhaul_Plan.md)
records the completed Android/desktop layout overhaul, accepted decisions,
ordered implementation packages, final validation evidence and external
platform coverage limits. Automotive integration remains separate.

[Responsive layout polish](completed-plans/Responsive_Layout_Polish_Plan.md) records the completed
follow-up desktop album fade, Liked Albums Next tooltip and numeric column
headings, with separate acceptance evidence.

[UX/UI audit — 2026-09-30](audits/ux-ui-audit-2026-09-30.md) records the
1.4.0 desktop/mobile design audit, the product decisions it produced, and the
status of each finding. The resulting token, typography and component-theme
foundation is recorded in
[decisions/2026-09-30-design-foundation.md](decisions/2026-09-30-design-foundation.md).

[Mobile track-layout repair](audits/mobile-track-layout-repair-2026-09-28.md)
records the compact-row regression, its shared correction, caller audit,
geometry coverage, and separate Android/Linux runtime evidence.

[Performance audit](audits/performance-audit-2026-09-30.md) records the
2026-09-30 loading, playback, search, memory and rendering measurements
against a 56k-track library, the changes made, before/after results, the
follow-up after the UX merge, and known limits.

[Windows review follow-up](audits/windows-review-2026-10-01.md) records the
2026-10-01 Windows review changes, their verification and the decisions it
raised. [Dependency audit](audits/dependency-audit-2026-10-01.md) lists
dependencies and build-time binaries that are old, archived or carry
advisories outside pub's version constraints, with a recommendation for each.

[Security audit](audits/security-audit-2026-10-09.md) lists code-level
security findings (path traversal, credential leaks, updater and release
tooling) with evidence and the fix for each.

[Polestar 4 automotive investigation](audits/polestar-4-automotive-investigation-2026-09-28.md)
preserves the direct-install driving lockout report, Android Auto/AAOS findings,
user preferences, and open questions. Automotive work is deferred separately
from ordinary responsive-layout work; this is not an implementation plan or a
claim of native AAOS support.

[Dependency Upgrade Plan](completed-plans/Dependency_Upgrade_Plan.md) tracks the 2026-09-27
dependency audit, implementation batches, compatibility holds, and required
validation, and how the upgrades were brought onto dev on 2026-10-01.

[Sync Improvement Plan — 1.4.0](plans/Sync_Improvement_Plan_1-4-0.md) records the
2026-09-19 sync audit, tested defects, live-server measurements, and phased
acceptance criteria. Its [reproduction appendix](audits/sync-1-4-0-reproductions.md)
preserves sanitized characterization fixtures; their passing assertions describe
the audited defects, not the desired post-fix behavior.

The [Rapid Playback Navigation Fix Plan](completed-plans/Rapid_Playback_Navigation_Fix_Plan.md)
records the cross-platform playback burst investigation, repair contracts,
runtime acceptance matrix and its 2026-10-02 handoff.

`DEVELOPMENT_PLAN.md`, `PROGRESS.md`, `design-ux-audit.md`,
the active plans in `plans/`,
`issue-43-implementation-plan.md`, `android-background-sync-recovery-plan.md`,
`sync-reliability-recovery-plan.md`, `sync-stability-validation.md`, and
`multi-os-release-implementation-progress.md` preserve intent, findings, and
completion evidence. They must be verified against the implementation before
use as a current contract. Do not erase them merely because work progressed.

[Completed implementation plans](completed-plans/README.md) are kept in their
own folder. Move a root plan there only after its implementation and required
in-repository validation are complete; leave plans with open implementation
work or blockers at the root.

### History and decisions

[history/README.md](history/README.md) is the discoverable ledger for material
removed or deprecated functionality. [decisions/README.md](decisions/README.md)
explains how to record future architectural decisions. Git history remains the
authoritative line-level history; these records preserve context that is easy
to lose when a feature disappears.

## Maintenance

A documentation change is part of the implementation change. Follow the
documentation lifecycle and Definition of Done in
[agentic-engineering.md](agentic-engineering.md). Avoid duplicate summaries:
extend the owning document and add a map entry only when it improves discovery.
