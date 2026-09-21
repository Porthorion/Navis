# Removed and deprecated functionality

| Capability | Status and date | Previous purpose | Current state / migration | Evidence and notes |
|---|---|---|---|---|
| Listen Together / Voyage | Retired 2026-06-30 | Voyage-backed multi-device rooms with shared queue and playback synchronization. | No active networking, session state, settings UI, or player entry points. Legacy Drift setting columns remain only for migration compatibility and are exposed as disabled/empty values. No replacement is currently committed. | `c541f74f` (`feat: retire listen together`), `08117d4f` (`fix: retire Listen Together for 1.0.7`), changelog 1.0.6–1.0.8. The reason beyond a redesign/retirement decision is not documented conclusively; do not infer one. |
| Forgejo-hosted CI quality gates | Removed 2026-02-19 | Server-side quality gate execution. | Local `./tool/check.sh` and the optional `.githooks/pre-commit` hook provide the documented quality gate. | `PROGRESS.md` records removal due to no Forgejo runner. This is an operational change, not a reduction in required validation. |
| Deferrable library-cache upgrade prompt | Replaced 2026-08-26 | Let users postpone a required library-cache renewal until a later launch. | The authenticated router now sends profiles with an outdated cache contract directly to the mandatory full-screen rebuild, before onboarding. The rebuild preserves permanent downloads and is only acknowledged after a successful catalog promotion. | `cache_system_upgrade_gate.dart` was replaced by `cacheSystemUpgradeRequiredProvider` and `appRouterProvider`; release 1.3.0. |
| Random liked-song Instant Radio | Replaced 2026-09-19 | Home seeded the selected song mix from a random liked song; Android Auto had a separate liked/random-song radio path. | Both now start balanced personal radio with liked, recent, server-recommended, and eligible local tracks. Song-based Server mix and Last.fm Same Vibes remain. | Release 1.4.0; `PersonalRadioNotifier` and `RecommendationService`. |
| Android Auto genre browsing | Removed 2026-09-20 | Android Auto exposed a local `Library → Genres` branch and genre-scoped playback/search. | The Library tree now exposes Downloads, Albums, and Artists. Genre-focused voice input uses the normal text search path; legacy genre browse IDs resolve to no content. Cached genre rows remain only for upgrade compatibility and are no longer fetched by sync. | `AutoMediaTreeService`, `AutoMediaId`, `NavisAudioHandler`, and their regression tests; release 1.4.0. |

When a removal is reintroduced, retain this history row and add the new
decision/replacement information rather than erasing the record.

### 2026-09-19 — Direct favorite/rating network writes

Favorite controls and rating actions no longer send independent API requests or
roll back saved intent on remote errors. Schema v74 and the shared annotation
dispatcher replace that behavior with atomic local updates and a versioned,
retryable outbox. This removes the race between an online request and an older
offline favorite operation, and makes offline ratings deliverable. Local database
failures still surface through the existing action error state. Existing pending
favorites are retained by migration; see `docs/architecture.md`.


## 2026-09-19 — Unique-song playlist membership replaced

Playlist membership previously used `(playlist_id, song_id)` as its key, which
could not represent a repeated track. Schema v76 replaces this with ordered
positions `(playlist_id, sort_order)`. Migration preserves each legacy membership
and normalizes its position; identity remapping preserves every occurrence.
This removes the accidental uniqueness restriction, not playlist functionality.
See `docs/architecture.md` and `Sync_Improvement_Plan_1-4-0.md` (F27).


## 2026-09-21 — Blocking full-screen navigation for ordinary Repair Library

Repair Library previously navigated out of Sync Settings into the full-screen
required-rebuild flow (initial-login style), replacing the visible screen for
the duration of the repair. Ordinary repair now runs non-blocking from Sync
Settings: a controller-owned session keeps the mobile-data grant across
retries and reconnects, a persistent status card shows progress with Retry and
Cancel, and cancellation clears the session consent. The blocking rebuild
screen remains only for flows where no usable catalog exists — initial login,
destructive cache reset, cache upgrade, and playback recovery. See
`docs/architecture.md` (Sync Flow → Repair sessions) and
`Fix_Stale_Cache_Plan.md` (Phase B).
