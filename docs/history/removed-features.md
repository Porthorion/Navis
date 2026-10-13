# Removed and deprecated functionality

| Capability | Status and date | Previous purpose | Current state / migration | Evidence and notes |
|---|---|---|---|---|
| Flat You Might Like colour band, panel and wash | Removed 2026-10-11 | With Flat surfaces, You Might Like drew a cover-coloured full-bleed band on phones, a rounded panel on desktop and a flat wash on tablets, with cover-derived caption tints (`_ShowcaseFlatBand`, the flat `_ShowcaseColourWash`, `_flatPanelTheme`, `flat_band_tone.dart`). | Owner decision: it looked out of place. Under Flat the section draws no background and sits on the page background on every layout; captions use the normal on-surface colours. Non-flat keeps the mesh wash. | 1.5.0; `you_might_like_widgets.dart`, `home_screen.dart`. |
| Suffix-only cleanup in user download folders | Removed 2026-10-11 | Treated every `.navis-part` file or SAF document as an interrupted Navis transfer. | Custom filesystem cleanup requires an exact queue-journal path persisted before creation. SAF transfers stage privately, so user SAF trees have no suffix sweep. Unknown files and mismatching finish destinations are preserved. | `download_service.dart`; download queue ownership and replacement regressions; [current storage contract](../architecture.md#cache-flow). |
| Fine-Tune preset library | Removed before shipping, 2026-10-10 | Saved intensity and Light/Dark brightness separately from full appearance Looks. | Looks are the only appearance presets and store the three tuning values directly. Unshipped schema 101 omits the tuning-preset library and selected id; old snapshot reference keys are ignored. | Owner decision: two preset layers were confusing. [Colour-style addendum](../decisions/2026-10-07-colour-styles.md#looks-as-the-only-appearance-presets-and-undo-2026-10-10). |
| Sync executor compatibility adapter | Removed 2026-10-08 | The typed coordinator fell back to legacy engine methods for non-Drift executors. | All coordinator executors implement `SyncPlanExecutor.executeSyncPlan` and cancellation directly. Run history and the durable work queue remain intact. All catalog runs require an admitted plan. The coordinator-facing interface accepts requests only; direct stale/manual/continuation/full-sync entry points and combined auxiliary refreshes are removed. Freshness admission and independent auxiliary scheduling remain coordinator-owned. | `LibrarySyncExecutionPlanAdapter`, `runCompatibilityAudit`, the four legacy engine entry points, `markAuxiliarySyncedAt`, and production-plan test fixtures. |
| Diagnostics-only first-setup controller | Removed 2026-10-08 | Session diagnostics instantiated a parallel setup controller whose cancellation wiped local data. | Session status observes the production initial-login rebuild controller without starting it. Retry/mobile/cancel routes use that mounted controller, whose cancellation keeps local data; inactive actions return conflict. Catalog setup and completion-warning helpers remain shared. | `initial_server_sync_provider.dart`, `required_library_rebuild_provider.dart`, and authentication lifecycle diagnostics. |
| In-memory sync diagnostics event mirror | Removed 2026-10-08 | `/v1/sync/ledger.events` temporarily mirrored requested/started/terminal actions during the typed lifecycle rollout. | Diagnostics readers use terminal `durableRuns` and durable attempt telemetry. Work scheduling and checkpoints remain in `library_sync_work`; run history stays for diagnostics. Playback startup telemetry retains its independent `events` array. | `sync_diagnostics_server.dart`, `sync_diagnostics_action.py`, and target-lane diagnostics. |
| Legacy song identity alias table | Replaced 2026-10-08 | Song aliases were read from `song_identity_aliases` and written to both alias tables. | Schema 94 deduplicates typed aliases, enforces `(entity_type, old_id)`, and drops the legacy table. Reads and data reset now use `entity_identity_aliases`, preserving cross-profile resolution. | `SongIdentityDao`, `from93To94`, and migration regression tests. |
| GPL project distribution | Replaced 2026-10-07, restored 2026-10-13 | Navis releases were distributed under GPL-3.0. | Navis briefly became proprietary freeware (2026-10-07) and returned to GPL-3.0-or-later on 2026-10-13 before 1.5.0 shipped; the source is public at github.com/Porthorion/Navis. The LGPL libmpv builds and the MIT colour table from the proprietary period were kept. | Root `LICENSE`, `README.md`; compliance audit L-1; 1.5.0. |
| GPL colour-naming dependency | Replaced 2026-10-07 | `colornames` guessed names for custom accent colours. | An MIT meodai/color-names table and CIELAB nearest-colour lookup retain named labels. | Compliance audit L-2; `color_namer.dart`; `tool/data/color_names/README.md`; 1.5.0. |
| Prebuilt zhongfly Windows libmpv | Replaced 2026-10-13 | Windows downloaded an LGPL daily build with an upstream fallback and mpv/FFmpeg source capture. | Navis cross-builds the audio-only engine and captures all static dependency sources. Only the per-build R2 URL is used; old published folders remain for previous users. | `tool/libmpv/README.md`, `docs/release-windows.md`; 1.5.0. |
| GPL/system desktop libmpv release dependencies | Replaced 2026-10-07 | Windows shipped the GPL shinchiro build; Linux packages relied on distribution-provided mpv. | Windows and Linux x86_64 bundle pinned LGPL-2.1+ libraries with mirrored sources; Linux development may opt out to system mpv. | `docs/release-windows.md`, `docs/release-linux.md`, `tool/libmpv/README.md`; 1.5.0. |
| Listen Together / Voyage | Retired 2026-06-30 | Voyage-backed multi-device rooms with shared queue and playback synchronization. | No active networking, session state, settings UI, or player entry points. Legacy Drift setting columns remain only for migration compatibility and are exposed as disabled/empty values. No replacement is currently committed. | `c541f74f` (`feat: retire listen together`), `08117d4f` (`fix: retire Listen Together for 1.0.7`), changelog 1.0.6–1.0.8. The reason beyond a redesign/retirement decision is not documented conclusively; do not infer one. |
| Forgejo-hosted CI quality gates | Removed 2026-02-19 | Server-side quality gate execution. | Local `./tool/check.sh` and the optional `.githooks/pre-commit` hook provide the documented quality gate. | `PROGRESS.md` records removal due to no Forgejo runner. This is an operational change, not a reduction in required validation. |
| Deferrable library-cache upgrade prompt | Replaced 2026-08-26 | Let users postpone a required library-cache renewal until a later launch. | The authenticated router now sends profiles with an outdated cache contract directly to the mandatory full-screen rebuild, before onboarding. The rebuild preserves permanent downloads and is only acknowledged after a successful catalog promotion. | `cache_system_upgrade_gate.dart` was replaced by `cacheSystemUpgradeRequiredProvider` and `appRouterProvider`; release 1.3.0. |
| Random liked-song Instant Radio | Replaced 2026-09-19 | Home seeded the selected song mix from a random liked song; Android Auto had a separate liked/random-song radio path. | Both now start balanced personal radio with liked, recent, server-recommended, and eligible local tracks. Song-based Server mix and Last.fm Same Vibes remain. | Release 1.4.0; `PersonalRadioNotifier` and `RecommendationService`. |
| Android Auto genre browsing | Removed 2026-09-20 | Android Auto exposed a local `Library → Genres` branch and genre-scoped playback/search. | The Library tree now exposes Downloads, Albums, and Artists. Genre-focused voice input uses the normal text search path; legacy genre browse IDs resolve to no content. Cached genre rows were later dropped by schema 89 (see the 2026-09-30 row). | `AutoMediaTreeService`, `AutoMediaId`, `NavisAudioHandler`, and their regression tests; release 1.4.0. |
| Post-update "What's New" dialog | Removed 2026-09-30 | `showChangelogDialog` showed a release's non-fix entries in a modal with "Got it" and "View full changelog". | Unused since design-ux-audit D5 (2026-08-14) replaced it with the inline Home card; that card now shows a major release's codename and highlight badges or a one-row patch summary. Its `changelogDialog*` and `whatsNewTitle` strings were removed. | `changelog_dialog.dart` and its test deleted; `ChangelogDiscoveryCard`; release 1.4.0. |
| Genres (all surfaces, storage, and sync) | Removed 2026-09-30 | Albums stored a server `genre`, a `genres` table cached `getGenres`, an unrouted Genre detail screen and providers browsed by genre, a retired genre sync target/stage/timestamp remained, and Android Auto mapped genre voice intents. A genre-only server edit rewrote album rows. | Product decision: genres are not a Navis concept. Schema 89 drops the `genres` table and the `albums.genre`, `library_sync_candidate_albums.genre` and `library_sync_state.last_genres_synced_at` columns, and purges `@genres` work and genre-target run history. Server genre fields are ignored, so genre-only edits no longer trigger album re-sync. Android Auto genre intents are ordinary raw-query searches. No replacement. | `AGENTS.md` rule; `test/src/architecture/no_genre_feature_test.dart`; `navis_migration_test.dart` (v86 step); release 1.4.0. |
| Last.fm authentication and scrobbling client code | Removed 2026-10-05 | `LastFmApiClient` could fetch an auth token, build the authorization URL, exchange it for a session, sign requests with a shared secret, send now-playing updates and scrobble. `RecommendationService.sameVibes` was a second Same Vibes entry point and `AppSettingsDao.updateLastFmScrobblingState` wrote the connection flags. | Last.fm scrobbling and sign-in were retired before 1.5.0, leaving this code with no callers. It is deleted along with its signature helper, session and exception types and their tests and fakes. The API key is only used for read-only recommendation lookups. Same Vibes runs through `SameVibesNotifier`, not `RecommendationService`. The `lastFmScrobblingEnabled` and `lastFmSessionConnected` columns stay as deprecated compatibility columns, and old `lastfm` scrobble-queue rows are still dropped on flush. | 1.5.0; `lastfm_api_client.dart`, `recommendation_service.dart`, `app_settings_dao.dart`. |
| AudioMuse direct client and similar-artist/album sections | Removed 2026-10-07 | `AudioMuseRepository`/`AudioMuseApiClient` fed AI "similar artists" and "You might also like" sections on the artist and album pages, gated by `audioMuseAvailableProvider`. | The gate had been hard-coded to `false` since the AudioMuse Navidrome plugin began answering the standard similarity calls through the server (Smart Queue and Instant Mix use `getSimilarSongs2`), so the client, models, providers, widgets, `audioMuse*` settings fields and strings could never run. Product decision 2026-10-07: a direct AudioMuse client is out of scope. Navis depends entirely on results returned by the Subsonic APIs; a server with the AudioMuse plugin simply returns AudioMuse-powered results through those same standard calls. The three `audio_muse_*` columns stay in the Drift schema for migration compatibility. | `chore/dead-code-removal`; `settings_screen_test.dart` and `app_router_test.dart` still assert there is no AudioMuse settings entry or route. |
| Sleep timer controller | Removed 2026-10-07 | `SleepTimerController` could stop playback after a duration or at end of track with a 30-second volume fade. | Nothing ever started it: there was no UI entry point and no tests, and sign-out only called `cancel()`. Product decision 2026-10-07: a sleep timer suits audiobook apps, not a music player, so Navis will not have one. If it is ever wanted it will be designed from scratch rather than restored from this code. | `chore/dead-code-removal`; `sleep_timer_provider.dart`. |
| Retired Voyage and Listen Together fields in the settings model | Removed 2026-10-07 | `AppSettingsModel`, `AppSettingsDao` and `SettingsRepository` carried `groupListeningEnabled`, the `voyage*` fields and `customVoyageServers`, and rewrote the retired columns to disabled values on every save and reset. | Runtime settings no longer expose them and saves no longer touch the columns. The schema migration that resets the columns on upgrade remains and is still covered by `navis_migration_test.dart` (now through raw SQL). | `chore/dead-code-removal`; compare the 2026-06-30 Listen Together row. |
| Temporary album-card caption variants | Removed 2026-10-08 | Compared the plain fade, caption-below, solid band, dark scrim and cover-tinted fade; hosts reserved extra height for caption-below. | Cover-tinted captions are the design for everyone, with the plain fade retained until tint is known or no cover-art id is available. The selector and extra-height plumbing are deleted; cards stay square. | Experiment `4b258725`, tint `68b5c5e4`; [colour-style decision](../decisions/2026-10-07-colour-styles.md#album-card-captions); release 1.5.0. |

When a removal is reintroduced, retain this history row and add the new
decision/replacement information rather than erasing the record.

## 2026-09-27 — Unversioned Windows SQLite cache fallback

Remote Windows packaging previously accepted any DLL from older local build
caches and patched published sqlite3 hook files to find sibling cached assets.
This could select a binary unrelated to the locked package, and the patched
hook path was obsolete. Packaging now requires the exact locked release DLL,
checks its published SHA-256 locally and again after transfer, and configures
the supported bundled-file hook source. Missing or mismatched assets fail
explicitly. See `tool/remote_build_windows.sh`,
`tool/sqlite3_windows_asset.py`, and `docs/ci-cd.md`.

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
[equalizer.md](../equalizer.md) and the accepted `docs/completed-plans/EQ_System_Plan.md`.

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

## 2026-10-05 — External-service switches moved to Settings › Integrations

Before 1.5.0 the switches for online services were spread across three pages.
Playback had "Use LRCLIB Fallback" and a Server Mix / Last.fm · Same Vibes
switch, each held in the screen's own state and written by its debounced
full-row autosave. Configuration had an "External Services" section with the
Last.fm key card and a ListenBrainz card whose single switch turned
scrobbling on or off. About had "Automatically Check for Updates".

They are replaced by Settings › Integrations (`/settings/integrations`): a
switch per service and per feature, a master "Online services" switch, the
Last.fm key field (keyless builds only) and the ListenBrainz token field.
LRCLIB is `lrclib.lyrics`, the mix mode is `lastfm.sameVibes` (on is Same
Vibes, off is Server Mix), the automatic update check is `updates.automatic`
and the ListenBrainz switch became scrobbling, likes and weekly-playlist
switches. The stored columns did not change, so no migration was needed.
Playback keeps no copy of these switches, so its autosave can no longer revert
a choice made on the new page. Configuration keeps a link row, About keeps
"Check now" (disabled while update checks are off) and a link, and the retired
`/settings/external-services` path now redirects to Integrations. See
[architecture.md](../architecture.md#external-integration-policy).

## 2026-10-09 — Duplicate appearance compatibility APIs removed

The old `artTintedNowPlaying` model/save parameter, provider and DAO writer/watch
are removed. `NowPlayingBackground` and its targeted DAO writer are the single
source; the database column remains unchanged for historical migrations,
including the guarded 92→97 conversion, and active writes no longer mirror it.
The Home density string provider/writer are also removed in favour of typed
`NavisDensity` and `densityProvider`. Appearance consistently uses DAO writers,
so redundant repository wrappers are removed. No user setting or schema column
is removed. `NavisShapeData` replaces the duplicate panel-radius token.
