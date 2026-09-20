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
| Architecture, providers, data flows, routing, platform integration | [architecture.md](architecture.md) |
| Bootstrap, local validation, diagnostics API, runtime evidence | [development-workflow.md](development-workflow.md) |
| Dependency audits, upgrade batches, replacement decisions, and regression gates | [dependency-upgrades.md](dependency-upgrades.md) |
| Quality gates, releases, signing, CI-equivalent workflow | [ci-cd.md](ci-cd.md) and [release-secrets.md](release-secrets.md) |
| Side-by-side/dev builds | [dev-testing-builds.md](dev-testing-builds.md) |
| Android Auto | [android-auto-testing.md](android-auto-testing.md) and [android_auto_real_car_testing.md](android_auto_real_car_testing.md) |
| Linux, macOS, Windows, or multi-host releases | [release-from-linux.md](release-from-linux.md), [release-linux.md](release-linux.md), [release-macos.md](release-macos.md), [release-windows.md](release-windows.md), [multi-os-build-from-mac.md](multi-os-build-from-mac.md) |
| Production symptom recovery | [troubleshooting.md](troubleshooting.md) |
| Active platform-readiness work | [flathub-readiness.md](flathub-readiness.md) or [google-play-readiness.md](google-play-readiness.md) |
| Current sync design, recovery boundaries, and certification evidence | [sync-reliability-recovery-plan.md](sync-reliability-recovery-plan.md), [sync-stability-validation.md](sync-stability-validation.md) |

## Document status

### Active reference

`architecture.md`, `development-workflow.md`, `ci-cd.md`, `dev-testing-builds.md`,
`troubleshooting.md`, the Android Auto guides, release guides, and platform
readiness documents describe maintained workflows or explicit current gaps.

### Plans, audits, and evidence

[Sync Improvement Plan — 1.4.0](../Sync_Improvement_Plan_1-4-0.md) records the
2026-09-19 sync audit, tested defects, live-server measurements, and phased
acceptance criteria. Its [reproduction appendix](audits/sync-1-4-0-reproductions.md)
preserves sanitized characterization fixtures; their passing assertions describe
the audited defects, not the desired post-fix behavior.

[Rapid Playback Navigation Fix Plan](../Rapid_Playback_Navigation_Fix_Plan.md)
records the cross-platform playback burst investigation, repair contracts, and
runtime acceptance matrix. Keep it at the root until all listed validation is
complete.

`DEVELOPMENT_PLAN.md`, `PROGRESS.md`, `design-ux-audit.md`,
`../Remote_Song_Handling_Plan.md`,
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
