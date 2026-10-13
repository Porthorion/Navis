# Navis documentation map

This directory separates current operating documentation from plans, audits,
and historical evidence. Current implementation and tests take precedence if a
document conflicts with code. Do not treat roadmap or audit records as current
product contracts.

## Start by task

| Need | Read |
|---|---|
| Project overview, support, quick start | [../README.md](../README.md) |
| Platform status, media integrations, tech stack | [development/technical-overview.md](development/technical-overview.md) |
| Online services, scrobbling and what each one sends | [features/integrations.md](features/integrations.md) |
| Agent workflow and documentation rules | [development/agentic-engineering.md](development/agentic-engineering.md) and [../AGENTS.md](../AGENTS.md) |
| Architecture, providers, data flows, routing, platform integration | [architecture.md](architecture.md) |
| Bootstrap, local validation, diagnostics API, runtime evidence | [development/development-workflow.md](development/development-workflow.md) |
| Dependency audits, upgrade batches, replacement decisions, regression gates | [development/dependency-upgrades.md](development/dependency-upgrades.md) |
| Quality gates, releases, signing, CI-equivalent workflow | [development/ci-cd.md](development/ci-cd.md), [release/release-secrets.md](release/release-secrets.md) and [release/release-r2.md](release/release-r2.md) (update channel) |
| Side-by-side/dev builds | [development/dev-testing-builds.md](development/dev-testing-builds.md) |
| Production symptom recovery | [development/troubleshooting.md](development/troubleshooting.md) |
| Linux, macOS, Windows, or multi-host releases | [release/release-from-linux.md](release/release-from-linux.md), [release/release-linux.md](release/release-linux.md), [release/release-macos.md](release/release-macos.md), [release/release-windows.md](release/release-windows.md), [release/multi-os-build-from-mac.md](release/multi-os-build-from-mac.md) |
| Android Auto | [platforms/android-auto-testing.md](platforms/android-auto-testing.md) and [platforms/android-auto-real-car-testing.md](platforms/android-auto-real-car-testing.md) |
| Platform certification and readiness | [platforms/android-certification-checklist.md](platforms/android-certification-checklist.md), [platforms/flathub-readiness.md](platforms/flathub-readiness.md), [platforms/google-play-readiness.md](platforms/google-play-readiness.md) and [platforms/macos-testing-playbook.md](platforms/macos-testing-playbook.md) |
| Equalizer, AutoEQ, presets, DSP, and platform limits | [features/equalizer.md](features/equalizer.md) and [features/equalizer-phone-checklist.md](features/equalizer-phone-checklist.md) |
| Current sync design, recovery boundaries, and certification evidence | [features/sync-reliability-recovery-plan.md](features/sync-reliability-recovery-plan.md), [features/sync-stability-validation.md](features/sync-stability-validation.md) and [features/android-background-sync-recovery-plan.md](features/android-background-sync-recovery-plan.md) |
| Project backlog and progress evidence | [project/development-plan.md](project/development-plan.md) and [project/progress.md](project/progress.md) |

## Document status

### Active reference

`architecture.md` and the guides under `development/`, `release/`, `platforms/`
and `features/` describe maintained workflows or explicit current gaps.
Android background sync remains an active rollout, rollback and deferred-device
certification reference. Project trackers preserve intent and evidence rather
than defining implementation authority.

### Active plans

New implementation plans go in `plans/`. Keep plans here while implementation,
required validation or acceptance is open:

- [Stale-cache recovery](plans/Fix_Stale_Cache_Plan.md) and its
  [execution plan](plans/Fix_Stale_Cache_Execution_Plan.md) — Android certification
  and release-acceptance evidence remain open.
- [Remote song handling](plans/Remote_Song_Handling_Plan.md) — cold remote
  playback and Android runtime validation remain unresolved.
- [Sync audit remediation](plans/Sync_Audit_Remediation_Plan.md) — consolidated
  runtime certification and operator/device acceptance remain open.
- [Sync improvement — 1.4.0](plans/Sync_Improvement_Plan_1-4-0.md) — broader
  platform, audible-playback and soak acceptance remain open; the
  [reproduction appendix](audits/sync-1-4-0-reproductions.md) preserves sanitized
  characterization fixtures, not post-fix behavior contracts.

Move a plan to [history/completed-plans/](history/completed-plans/README.md) only
when its implementation and required in-repository validation are complete.
Record accepted external coverage limits in its handoff.

### Audits and evidence

Dated reports live in `audits/`:

- [Dependency inventory — 2026-09-27](audits/dependency-upgrades-2026-09-27.md)
  and [dependency audit — 2026-10-01](audits/dependency-audit-2026-10-01.md).
- [Mobile track-layout repair — 2026-09-28](audits/mobile-track-layout-repair-2026-09-28.md)
  and [Polestar 4 automotive investigation — 2026-09-28](audits/polestar-4-automotive-investigation-2026-09-28.md).
- [UX/UI audit — 2026-09-30](audits/ux-ui-audit-2026-09-30.md),
  [performance audit — 2026-09-30](audits/performance-audit-2026-09-30.md),
  [design, UX and motion audit — snapshot 2026-10-01](audits/design-ux-audit-2026-10-01.md)
  and [Windows review — 2026-10-01](audits/windows-review-2026-10-01.md).
- [Compliance audit — 2026-10-07](audits/compliance-audit-2026-10-07.md),
  [security audit — 2026-10-09](audits/security-audit-2026-10-09.md)
  and [Linux packages — 2026-10-13](audits/linux-packages-2026-10-13.md).

The dependency inventory is the retained readable snapshot. Its raw JSON/TXT
and empty evidence files were removed during the documentation reorganization;
prior raw evidence remains available in Git history.

### History and decisions

[history/README.md](history/README.md) indexes removed features, completed
plans, superseded execution records and design specifications.
[decisions/README.md](decisions/README.md) indexes architectural decisions and
explains how to record new ones. Git history remains the authoritative
line-level history; these records preserve context that is easy to lose when
a feature disappears.

## Maintenance

A documentation change is part of the implementation change. Follow the
documentation lifecycle and Definition of Done in
[development/agentic-engineering.md](development/agentic-engineering.md).
Avoid duplicate summaries: extend the owning document and add a map entry only
when it improves discovery.

## Assets

`assets/readme/` holds the README logo, hero and screenshot images. Keep each image under 400 KB and export it from the marketing kit rather than re-capturing it.
