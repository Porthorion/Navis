# Removed and deprecated functionality

| Capability | Status and date | Previous purpose | Current state / migration | Evidence and notes |
|---|---|---|---|---|
| Listen Together / Voyage | Retired 2026-06-30 | Voyage-backed multi-device rooms with shared queue and playback synchronization. | No active networking, session state, settings UI, or player entry points. Legacy Drift setting columns remain only for migration compatibility and are exposed as disabled/empty values. No replacement is currently committed. | `c541f74f` (`feat: retire listen together`), `08117d4f` (`fix: retire Listen Together for 1.0.7`), changelog 1.0.6–1.0.8. The reason beyond a redesign/retirement decision is not documented conclusively; do not infer one. |
| Forgejo-hosted CI quality gates | Removed 2026-02-19 | Server-side quality gate execution. | Local `./tool/check.sh` and the optional `.githooks/pre-commit` hook provide the documented quality gate. | `PROGRESS.md` records removal due to no Forgejo runner. This is an operational change, not a reduction in required validation. |
| Deferrable library-cache upgrade prompt | Replaced 2026-08-26 | Let users postpone a required library-cache renewal until a later launch. | The authenticated router now sends profiles with an outdated cache contract directly to the mandatory full-screen rebuild, before onboarding. The rebuild preserves permanent downloads and is only acknowledged after a successful catalog promotion. | `cache_system_upgrade_gate.dart` was replaced by `cacheSystemUpgradeRequiredProvider` and `appRouterProvider`; release 1.3.0. |

When a removal is reintroduced, retain this history row and add the new
decision/replacement information rather than erasing the record.
