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

## Fixed album grid column density (2026-09-28)

The former Grid Density preference set a fixed column count and Auto stopped
at five columns. Wide panes therefore enlarged artwork rather than showing
more content. Artwork size replaces the active layout meaning with bounded
card sizes and a column count derived from the pane. Schema 81 preserves the
legacy column and migrates its preference once (1/2 → Large, 3 → Medium,
4/5 → Small, null/invalid → Auto). Compact Liked and Home previews use their
own shelf geometry. See the [responsive layout plan](../completed-plans/Responsive_Layout_Overhaul_Plan.md)
and [adaptive architecture](../architecture.md#collection-pane-geometry).

## 2026-09-28 — Stepped speed controls and queue-clear reset replaced

The 0.25× slider stops and generic 0.5×–2× clamp are replaced by shared Speed &
Pitch rulers, exact decimal input and local named presets. Actual backend limits
remain centralized in capabilities. Clearing a queue no longer resets playback
speed; both adjustments persist until changed or None is selected. This is an
explicit product decision recorded in `Playback_Speed_Pitch_Presets_Plan.md`.

## 2026-09-28 — Percentage speed presentation replaced

Speed readouts now use two-decimal multipliers and 0.10 buttons, with fine
hundredth rulers and a saved pitch-lock mode. The diagnostics percentage API
remains compatible, and legacy precise values/presets keep their exact sound
until edited. Both controls expose actual supported bounds; None restores
1×, zero pitch and lock off.

## 2026-09-29 — Speed & Pitch dropdown and disabled pitch controls replaced

The preset dropdown is replaced by preset chips, the ±0.10/±1 text buttons by
hold-to-repeat icon steppers, and the always-visible "Available range" line by
range text shown only at a limit. On backends without pitch, the pitch ruler
and lock are hidden rather than shown disabled. "Lock Pitch to Speed" is now
labelled "Pitch follows speed" and the None preset "Normal"; stored ids and
values are unchanged, so no migration is needed. New presets cannot be named
Normal; an existing preset with that name still loads.

## 2026-09-29 — Preset chips and Manage presets replaced by dropdowns

Speed & Pitch presets and the mini Equalizer now pick presets from a dropdown
instead of chip rows, which grew unwieldy with many presets or AutoEQ profiles.
The separate Save as new, Update and Manage presets controls (and its preset
picker dialog) became a ⋮ actions menu that acts on the current or originating
preset; deleting now asks for confirmation. Stored presets are unchanged.

## 2026-09-29 — Player EQ button no longer opens the full page

The player Equalizer button (and the desktop Mini Player menu entry) now opens a
compact equalizer panel instead of navigating straight to
`/settings/equalizer`; the full page is one tap away through Open Equalizer or
the graph. The Now Playing settings sheet replaces its Equalizer row with an
inline card on supported backends. On desktop, the Equalizer page's back arrow
now returns to where the page was opened rather than always to the Settings
root.

## Experimental equalizer and loudness booster (2026-09-29)

The old Playback Experimental controls and their current-schema fields have
been removed. They used Android system effects with limited, device-dependent
bands. Schema v84 discards the old values without approximation or recovery and
starts the replacement disabled/flat, with a one-time notice for affected users.
The dedicated Equalizer page, native filters, authored preamp, and automatic
headroom replace them; historical migration steps remain. See
[equalizer.md](../equalizer.md) and the accepted `EQ_System_Plan.md`.

## 2026-09-29 — Equalizer band-card editing replaced

The scrolling per-band cards, modal band editor, and duplicate mini graph that
pinned after scrolling are replaced by the large interactive graph and selected
band controls. Exact input previews inline with Done/Cancel. Existing saved
presets, v85 draft workspaces, AutoEQ provenance, and native processing retain
their contracts; this presentation change requires no migration. See
[equalizer.md](../equalizer.md).

## 2026-09-29 — Equalizer band dropdown and duplicate controls replaced

The graph-first page previously selected bands with a dropdown, repeated the
selected band's summary inside the graph, placed the Q slider under the plot,
and showed preamp both in the graph toolbar and in the band controls. A band chip
strip, three value tiles, an inspector Q control, and one preamp control per
layout replace them; the mode dropdown became a segmented control, and draft
status moved beside the preset name. Saved presets, drafts, AutoEQ provenance,
diagnostics actions, and audio behaviour are unchanged; no migration is needed.
See [equalizer.md](../equalizer.md#editing-workspace).
