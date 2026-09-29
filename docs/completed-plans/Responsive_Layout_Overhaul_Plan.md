# Navis responsive layout overhaul

Date: 2026-09-28  
Status: completed implementation and in-repository validation; archived 2026-09-28  
Baseline: `646275b8c09a4ca41c446aae4ab32397d0be83dc` plus existing local work.

## Goal and accepted decisions

More space reveals more content and useful metadata. Preserve dark surfaces,
blue accents, artwork overlays, navigation, playback markers, and the persistent
player. This is the accepted specification and implementation evidence ledger.

| Area | Decision |
|---|---|
| Wide windows | More columns and richer metadata, bounded artwork |
| Artwork | Preserve overlaid title/artist labels |
| Full grids | Auto / Small / Medium / Large artwork sizing |
| Liked | Artists → Albums → Songs, compact on mobile and desktop |
| Previews | Two horizontal screenfuls plus See all |
| Tracks | Artist, album, duration; shared responsive browsing rows |
| Headers | Full collections only; labels, not sorting controls |
| You Might Like | One prominent feature, preserve ListenBrainz discovery |
| Auto-advance | Appearance preference, off by default |
| Desktop player | Always-visible elapsed/total time |
| Radio | Compact responsive station cards |
| Persistence | Local preferences, no cross-device synchronization |

Included: Home/Liked/Albums/Artists/Radio; full liked-album and artist-detail
grids; browsing song rows in albums/playlists/search/artist/genre/recommendation/
downloads; migration/localization; diagnostics; tests/goldens/runtime/restart;
documentation/release notes. Excluded: Polestar/AAOS/Android Auto, queue redesign,
Mini Player/full Now Playing redesign, playback/sync semantics, sortable or
resizable columns, new metadata services. The
[Polestar record](../audits/polestar-4-automotive-investigation-2026-09-28.md)
remains separate.

### Why this direction

The eight supplied screenshots show two different failures: full grids keep
nearly the same column count while covers grow, and other sections keep a
small fixed sample while their surrounding pane grows. Track rows expand but
retain a compact metadata arrangement, leaving a large distance between the
song and its controls. Fixing only a breakpoint or one page would preserve
these inconsistencies elsewhere.

| Question | Accepted answer and reason |
|---|---|
| Should a larger screen scale everything up? | Keep bounded artwork and readable controls, then reveal more content. Large covers are a deliberate preference, not the automatic result of window width. |
| Should Liked become songs first or use separate tabs? | Keep Artists → Albums → Songs. Single-row shelves make songs reachable within about one swipe while preserving discovery and the existing navigation flow. |
| Should labels move below the cover? | Preserve overlays and their gradient. Their character is an accepted product decision; larger text increases caption space rather than removing the treatment. |
| Should every wide row become a dense table? | Use compact, medium and wide modes based on the actual pane and text scale. Artist, album and duration become separate columns only when they fit. |
| Should density have a fixed number of columns? | Persist artwork size. The same preference works across window sizes because the column count is a result of available space. |
| Should preferences synchronize between installations? | Keep existing local persistence. Platform-appropriate presentation does not introduce account synchronization. |
| Should recommendation cycling remain automatic? | Touch users opt in; default off. The timer must respect interaction, visibility, lifecycle and reduced motion. Desktop remains manual. |
| Should this pass fix the car's driving lockout? | No. That is a separate automotive integration question. Responsive Flutter layout does not establish AAOS driving eligibility. |

Use logical pixels and the current content pane, not physical display
resolution. Device pixel ratio changes rendering density; it does not justify
choosing a desktop composition. A tablet with a narrow split window can have
less usable space than a phone in landscape. Sidebar, safe areas, filters,
padding and player clearance are consumed before resolving content geometry.
Text scaling is another input: a physically wide pane can require a compact
row when accessibility text is enlarged.

### How to read and follow the packages

This document preserves the accepted implementation sequence and its completed
evidence. Current implementation and active architecture documentation remain
authoritative. A follow-up agent should inspect the relevant code and tests
before changing it; do not replay completed migrations or regenerate new
behavior merely because a package below uses imperative language.

For each package: inspect its owner and callers, implement its smallest complete
change, run the focused gate, inspect visual output when applicable, then record
the result before advancing. A failing focused gate is a reason to diagnose
that package, not to broaden the redesign or weaken the assertion. Schema and
generated code must move together. A shared component's tests do not replace
tests of a playlist occurrence, filtered playback index or specialized action.

## Baseline and engineering constraints

Preserve existing tooltip/diagnostics/documentation/tooling work. Initial patch,
status, and file hashes are under `build/responsive-layout/baseline/`.
Follow [agent policy](../agentic-engineering.md) and
[runtime workflow](../development-workflow.md). Use existing AdaptiveContext,
input policy, pane constraints, provider DI, DAO/repository and playback markers.
No provider mutation during build, broad-settings router refresh, duplicate
queue owner, source-priority changes, unrelated resets or publishing. Generated
source must be regenerated. Evidence is actual results, never planned commands.

Verified causes: five/six-column ceilings; six-item recent-liked limit;
limit-before-download-filter; fixed-grid Liked preview; generic expanding song
row; action widgets hiding duration; scroll-only pagination; growing Home hero;
116px player hiding times through <=120px condition; 4.2s carousel interval;
full-width radio rows/raw URLs; blanket tablet collection width constraints.

## 1. Shared geometry policy

Pure immutable policy beside adaptive infrastructure: actual usable pane width,
size preference, text scaler as needed → columns/extent/gap/occupied width,
artist tile height, shelf capacity, track mode, radio geometry. No provider or
database work. Keep shell breakpoints and desktop/Mini Player transitions.

| Album size | Pane <600 min/max | Pane >=600 min/max |
|---|---:|---:|
| Small | 120/152 | 152/184 |
| Medium or Auto | 148/184 | 180/220 |
| Large | 172/216 | 220/268 |

Gap G=8 below600, otherwise12. Usable width W, min M, max X:

```text
columns=max(1,floor((W+G)/(M+G)))
extent=min(X,(W-(columns-1)*G)/columns)
occupiedWidth=columns*extent+(columns-1)*G
```

One fitting card below minimum. No column ceiling or item-count-dependent sizes.
Center occupied grid if bounded cards leave remainder; sparse last row leading
aligned. No horizontal scroll in full grids. Auto examples (logical pixels):
328→2×160;1040→5×198;2000→10×189;3400→17×189.

| Artist size | Pane <600 min/max | Pane >=600 min/max |
|---|---:|---:|
| Small | 104/128 | 120/152 |
| Medium or Auto | 120/152 | 144/176 |
| Large | 144/176 | 176/216 |

Same formula. Artist height=artwork+gap+measured two-line label; preserve shape.
Full album overlays two title lines/one artist; shelf overlays one each. Caption
heights accommodate text scale; never disable scaling/shrink typography. Touch
targets >=48×48; preserve focus/tooltips/semantics/remote indicators.

Gate: pure geometry tests for narrow/ultrawide/all presets/sparse/text-scaled.

## A. Settings and migration

Typed GridArtworkSize enum auto/small/medium/large, persisted gridArtworkSize
text default auto; homeRecommendationsAutoAdvance bool default false. Append
stepwise schema migration (baseline80→81; if schema advances, append next).
Keep legacy albumGridDensity column but stop active reads. Migrate once:
null→Auto;1/2→Large;3→Medium;4/5→Small;invalid→Auto. Unknown new string→Auto.
No repeated legacy remap. New/upgraded users default auto-advance off.

Appearance "Artwork size" with Auto/Small/Medium/Large; description "Controls
artwork size in album and artist grids. Columns adjust to the available space."
Full grids only, not Liked previews/Home Density. Non-desktop Home appearance:
"Automatically advance recommendations"; "Move through You Might Like
automatically. You can always swipe manually." Desktop remains manual.

Update defaults/copyWith/DAO update-reset/repository/model/providers/onboarding
and complete settings drafts (especially Playback Settings). Independent saves
retain new preferences. Generate Drift/localization through repository workflow.
Gate: fresh defaults, populated migration each mapping, unrelated fields,
round-trip, independent settings saves, clean restart persistence.

## B. Grids, width, sorting, and pagination

Apply album policy to Albums/full Liked Albums/artist-detail albums; artist
policy to Artists/similar artists. Similar artist preview remains two rows,
resolved columns×2. Collage geometry unchanged. Remove blanket tablet width
limits for Home/library collections, retain readable prose/forms/detail hero
art bounds. Collection padding12 below600/24 otherwise; resolve after padding.
Preserve rail/safe area/player clearance. Sort dropdown max280, filters leading,
existing narrow/large-text stacking.

Page size60/order/filter unchanged. Check after loaded page/resize/scroll/reset.
Load if more results, no pending equivalent, extentAfter<viewportHeight,
including underfilled first page. Post-layout updates, one pending expansion,
continue to buffer/exhaustion. Stop on error/no new items, retain stale data.
Resize doesn't reset count or jump top; existing sort/filter resets stay.
Don't add paging to fully loaded filtered collections.
Gate: bounded covers/more columns, underfilled60 auto-load, no duplicate loops,
sorting/filters/actions/navigation preserved.

## C. Preview data and Liked shelves

Recent-liked DAO nullable unlimited limit; existing membership and timestamp
descending/null last/name/id order. Shared full ordered source (already loaded
for counts)→downloaded/type filters→count→preview. Existing downloaded-content
authority; consolidate full subscriptions/no parallel cache.
Capacity=max(1,ceil((W+G)/(C+G)));limit=capacity×2. Apply Liked albums/artists and
Home Recently Liked. Recompute only capacity boundaries, no server requests;
stable identity/scroll, clamp if necessary.

Sequence: Artists heading/See all, one shelf; Albums heading/See all, one shelf;
Songs heading plus Play/Shuffle, songs. Preserve exact filtered playback set.
See all for nonempty collection opens existing route. One vertical page with
horizontal shelves.

| Liked metric | Pane <600 | Pane >=600 |
|---|---:|---:|
| Album extent | 128 | 148 |
| Artist art | 56 | 64 |
| Artist tile width | 80 | 88 |
| Gap | 8 | 12 |

Artist height has scaled two-line labels. Not controlled by full-grid setting.
390×844 scale1: first song starts within440px of scroll-content origin excluding
shell/sync banner; <=440 vertical scroll reveals songs. Accessibility readability
over height budget. Gate: no wrapping/orphan row, eligible download after old6,
count/filter agreement, playback unchanged.

## D. Shared adaptive track rows

AdaptiveTrackRow/Header accept metadata/art-number/playback identity/remote/
badge/callbacks/actions/occurrence key. No queue construction or metadata fetch.
TrackListTile delegates; song DesktopListRow callers migrate; generic rows stay.
EffectiveWidth=availableWidth/max(1,textScaler.scale(14)/14).

| Width | Row |
|---|---|
| <720 | Art/number, title+artist/album subtitle, duration, actions |
| 720–959 | Title+album subtitle, Artist, Duration, Actions |
| >=960 | Title, Artist, Album, Duration, Actions |

Full separated-column lists get matching headings; compact/short previews none.
No sorting. After art/duration/actions/gaps, metadata45/25/30 wide,65/35 medium.
Measure duration against0:00:00; right-align/tabular; once and always visible.
Min height64, scaled growth. Unknown duration--:--; missing metadata omitted
compact/dash separate. DesktopSongActions receives resolved mode rather than
whole-window width: compact/medium More; wide Like/Download/More. Preserve
mobile controls/overflow, remote restrictions, supplied specialized menus.

Convert Home/Liked/album disc/playlist filtered+reorderable/search API songs/
artist rank+resolution/genre/recommendation/downloaded playable rows (quality,
size, missing lookup). Keep transfer progress and queue specialized. Preserve
duplicate playlist occurrences, ordering, queue preferences, playback markers.
Rows don't watch playback position. Gate: caller audit, headers aligned,
duration/actions/selection/remote/duplicate remove-reorder-play verified.

## E. Home shelves and hero

Home extents Compact138/152 and Comfortable150/164 (<600/>=600). Explicit
square sizing for local/server cards; remove compact-card conflict. Recently
Liked uses C; other existing sample limits/semantics unchanged. Real fewer items
leave space, never stretch/repeat/fabricate.
Shared shelf touch/trackpad and overflow-only desktop arrows; recalc after
resize/count, roughly one page with overlap, reduced motion, stable scroll/lazy.

Desktop You Might Like pane>=640: artwork left/tracks right; Comfortable
clamp(width*.29,330,360), Compact clamp(width*.26,300,330); cover<=height/40%width.
Shared compact-action preview rows/no headings; row count from height; full
album/playlist navigation. Below640 existing card-style260/240, desktop manual,
selected stable identity across modes. Mobile preserve phone228/208,
tabletMedium244/224, tabletExpanded258/236 plus text safety. Keep ListenBrainz
art/title/availability/detail. Gate: bounded prominence, metadata, no reflow
selection change, all recommendations reachable.

## F. Carousel lifecycle

Off: no timer/manual works/refresh retains identity. On: cancellable one-shot8s,
manual interaction delays10s from last interaction. Eligible only preference,
>1item,resumed,active Home,>=half hero visible,no covering route/player/modal,
no gesture,no reduced motion. Shell/route/viewport signals, no router rebuild
or global polling. Removed item nearest valid index; empty cancels; off cancels
immediately. Reduced motion suppresses without rewriting. Dispose timers/
listeners, no background catch-up. Gate: fake-time conditions and persistence.

## G. Desktop playback times

Preserve metadata/center/actions+volume and local NavisTooltip changes. Always
elapsed/total (unknown--:--). Prefer elapsed—seek—total; if labels plus>=120seek
don't fit, seek above end-aligned labels. Measured scaled widths; normal116
height, grow only for accessibility need; no height-based hide. Drag preview,
existing release seek; m:ss/hour format; Live radio/placeholders. Minimum800×600
without lost controls. Gate: inline/stacked/min/textscale/hour/unknown/drag/live,
transport/volume/focus intact. No Mini Player redesign.

## H. Radio cards

Pane<600 one full-width; otherwise min280/max360/gap12 bounded columns/lazy,
server order. Icon/name two lines/optional host/Play-Stop/non-color playing state.
Never raw query/credential URLs. Min height96/scaled growth. Existing start-stop,
refresh/filter/loading/error/empty/navigation visibility. No new metadata service
or artwork. Gate:1/3/20 fixtures/resize/selection/start-stop/filter.

## Validation specification

Synthetic fixtures empty/one/six/two shelf pages/>=240albums/long multilingual/
hour duration/missing metadata/playlist duplicates/local+remote/download after6/
missing lookup/radio1-3-20/loading-partial-error-refresh. Provider DI/test helpers.
Logical viewports320×568,360×800,390×844,844×390,700×1200,1200×900,800×600,
887×900,1366×900,1920×1080,2560×1440,3440×1440. Representative scale1/1.3/2,
DPR1/2,boundaries,sidebar/constrained panes,light/dark. Pure broad geometry plus
focused widget/golden/runtime subsets, not every permutation.

Goldens small/wide grids; mobile/desktop Liked; row3modes/header; wide hero;
inline/stacked times; radio; selected scale2. Inspect images; don't approve
clipping. Tests cover filters before limit/order/paging-error-no-progress,
occurrence actions/reorder/markers, settings mapping/round-trip/timers, player
times/seek/live, radio. Preserve regression contracts except explicit supersession.

Runtime isolated authenticated API: health→navigate/resize/filter/scroll/actions
→provider/persisted/status evidence→POST screenshot→open PNG→logs→clean restart
repeat. Linux plus isolated Android touch/orientation/carousel/device screenshots
are required for this pass. Record unavailable additional hosts as explicit
coverage limits; they do not substitute for those required gates. No
AT-SPI/OCR/window/accessibility substitution. Reuse presentation/window/
library-filter/scroll/indicator endpoints.
If needed narrow clone-only appearance get/set via production DAO, redacted
geometry/mode/carousel status, Home scroll/manual controls via production owners.
Retain clone authorization, no tokens/titles/URLs in summary.

Focused tests per package, generation after schema/localization. Final make gen,
flutter analyze --no-fatal-infos, ./tool/check.sh, desktop-layout/indicator
diagnostics, screenshots and restart. Static gates don't replace runtime.
Update architecture/workflow+CI for changed tooling/changelog+release notes/
removed-features ledger for fixed-column semantics. No automotive claims.

## Execution and evidence ledger

| Order | Package | Status | Evidence |
|---:|---|---|---|
| 0 | Baseline/plan/before evidence | Captured, known runtime issue | baseline patch/hashes and inspected Home PNGs; shutdown channel error exists before this change |
| 1 | Geometry | Complete | 6 policy tests; 6 grid/shelf widget tests |
| 2 | A Settings/migration | Complete | 41 migration, 2 persistence, and 12 Appearance tests pass; schema/generated source 81; Linux/Android restart persistence |
| 3 | B Grids/pagination | Complete | lazy grids; underfilled-page and error-stop regressions; inspected Linux wide/minimum and Android portrait/landscape/tablet output |
| 4 | C Liked/previews | Complete | download filtering beyond item six, recent order/membership, hidden Artists See all fallback; 58 data/library/router checks pass |
| 5 | D Rows/caller conversion | Complete | 66 caller checks; 8 shared row checks and three inspected mode goldens; duplicate playlist occurrence play/remove/reorder regressions; Linux/Android row inspection |
| 6 | E Home | Complete | bounded desktop hero and narrow pane mode, reachable preview tracks, selected-ID retention across resize/data refresh, matching bounded loading skeleton; both runtime matrices |
| 7 | F Carousel | Complete | manual default, 8s opt-in, 10s interaction pause, reduced motion, visibility, Home/modal/quick-search/player/lifecycle gates; Android off/on timing and persisted settings |
| 8 | G Desktop times | Complete | 5 progress checks, seek-preview/release integration, 74 desktop shell checks; inspected enlarged-text, minimum-window and playback runtime renderings |
| 9 | H Radio | Complete | bounded lazy cards, safe host, playing text, play/stop identity; 5 radio checks; inspected wide scale-2 golden and both runtime matrices |
| 10 | Docs/full checks/runtime/restart | Complete | final full gate: 1,682 passed, one existing skip; 81 inspected runtime PNGs across Linux/Android, persistence and clean restarts; documentation and generated-artifact review |

Each package records actual changes, tests, inspected images, limitations,
justified deviations. Advance after its gate. Audit every explicit requirement
against current evidence; no completed claim with missing caller/migration/
runtime/restart evidence. The plan was archived only after these gates passed.

### Checkpoint evidence and resolved blockers

- Before-change Home and Stage-C Liked captures remain under
  `build/presentation-diagnostics/20260928T072522Z-clone/` and
  `20260928T074122Z-clone/`. Both initially failed clean shutdown because an
  automatic-check completion wrote after Drift closed. They are historical
  captures, not final certification.
- The controller cancellation barrier now drains its automatic-check owner
  (including the durable deadline write) and pending timer-arm tasks, and
  suppresses rearming after cancellation. Its 26 controller regressions pass.
  This narrowly required runtime fix preserves sync admission and data semantics.
- `20260928T084151Z-clone/` now passes initial/restarted Linux capture and clean
  shutdown with empty error logs. Both PNGs were opened: bounded Albums and
  elapsed/total player labels render correctly. Its route is `/library`, which
  defaults to Albums; the label `responsive-liked` does not certify Liked.
- The `responsive-layout` presentation scenario explicitly visits Home,
  Albums, Liked, Artists and Radio at 800×600 and 2560×1280 on both launches,
  exercises Liked scrolling, filter results, artwork preferences and restart
  persistence. It temporarily enables normally hidden Artists/Radio through
  targeted production settings updates inside the clone only.
- `GET/POST /v1/presentation/appearance` is authenticated and clone-only. It
  accepts only artwork size, auto-advance and Artists/Radio visibility with
  strict value types, delegates writes to the production settings DAO, and
  returns only those bounded non-secret preferences. Contract tests verify
  invalid input, persistence, unauthorized and primary-certification rejection.
- Row modes include measured hour durations (`00:00:00`); narrow or enlarged
  text moves actions beneath metadata. Playback times move below the seek bar
  when necessary; exceptionally long labels can occupy separate end-aligned
  lines. The player grows for scaled labels without changing transport sizes.
- The full liked-artist destination `/library/liked-artists` is a justified
  addition: See all must work when the general Artists page is intentionally
  hidden. It uses the same liked source/download filter and never enables a
  hidden page as a side effect.
- All implementation packages and required in-repository acceptance gates are
  complete. Final results, external platform coverage limits and artifact
  locations are recorded below. Historical failed captures remain historical;
  they are not silently reclassified as successful validation.

### Converted caller audit

Convert each family completely, then run its nearest existing tests. A shared
widget does not prove the specialized callbacks are preserved. Check off each
entry only after its behavior, header alignment, remote state, and resize
scenario have evidence.

- [x] `common_widgets/track_list_tile.dart`: delegate rendering, preserve
  art/number markers, touch/secondary menus, badges, padding/gap overrides,
  selected state and playback semantics. The indicator tests now inspect the
  adaptive row and rendered selection color rather than a removed ListTile.
- [x] `library_screen.dart` Liked rows: one delegate for mobile/desktop,
  explicit duration, pane-based desktop actions, headers for full collections.
  The existing liked-song/album playback union, duplicate removal, and download
  filter remain covered by the focused tests.
- [x] `album_detail_screen.dart`: add correctly padded headers with 32px
  leading slots. Keep disc headings and filtered playback indices; use the
  existing row delegate rather than building a second table implementation.
- [x] `playlist_detail_screen.dart`: headers for both filtered and reorderable
  variants, same 32px leading slot. Keep the playlist occurrence index and key
  `${playlistId}-${song.id}-${index}` semantics; duplicate songs may represent
  distinct occurrences. More must still remove the intended occurrence.
- [x] `search_screen.dart`: convert only song DesktopListRow/ListTile paths;
  preserve API result identity and existing play-resolution callbacks. Album,
  artist and other generic result rows remain generic. Preserve local/remote
  restrictions and loading markers, with no duplicate duration in actions.
- [x] `home_screen.dart` song lists: use the shared row without a full-list
  heading. Preserve each section's sampling and playback queue. Convert local
  and ListenBrainz hero previews, including ranked/available remote tracks.
- [x] `artist_top_tracks_section.dart` and its full playlist: preserve rank,
  resolution/loading/unavailable states and play callbacks. Add a header only
  to the full separated-column collection.
- [x] `genre_detail_screen.dart` and recommendation detail lists: retain their
  own queue construction/filter rules while replacing row presentation.
- [x] `downloads_screen.dart`: convert only playable library rows. Retain
  format/quality/filesize, missing-song recovery and deletion controls. Transfer
  progress/error rows remain specialized.
- [x] Audit all remaining `DesktopListRow(` and `TrackListTile(` callers. For
  every song row, record whether it is a full collection, preview, or exempt
  queue/transfer surface. Do not convert non-song rows or silently omit a caller.
- [x] Audit supplied actions and header widths: desktop slots are 48px in
  compact/medium modes and 144px in wide mode. Reserve the same space for remote
  rows. Touch lists with two existing actions need their actual matching slots.
  Duration belongs to the row; converted action widgets must not repeat it.
- [x] Verify long hour durations, scaled text, keyboard focus, selected/loading
  markers, specialized menu callbacks, and playlist duplicates before closing D.

After D, finish E/F/G/H in their numbered order. Add narrow authenticated
controls only when the existing app API cannot exercise a required scenario;
include API contract tests and redaction rules in the same change. A missing
runtime control does not authorize bypassing production providers or editing
the cloned database as the action under test.

Exempt callers: Search artist/album generic DesktopListRows; settings rows;
queue occurrence/reconciliation controls; download transfer progress/error
ListTiles; Match Flow search remains a specialized picker (its TrackListTile
inherits responsive metadata, without a full-collection heading). Downloads
playable library rows are converted; transfer rows keep their progress contract.

### Additional fixes required by runtime validation

- The earlier full-gate run passed 1,681 tests and one existing skip. It was
  superseded by the final post-window-fix run: 1,682 passed and one existing
  skip. Both are retained as evidence; only the final run certifies the final
  implementation.
- The Linux window adapter can retain a maximized horizontal axis while its
  full-maximize flag is false. Diagnostic resize now explicitly clears native
  maximize state before applying bounds, allowing configure events to settle.
  This changes the clone resize helper only; ordinary window lifecycle remains
  unchanged. Its 17 window-controller tests pass. The scenario records each
  bounded resize attempt and still requires exact observed bounds.
- Android clone bootstrap must have its scoped artifact directory prepared by
  the existing native bridge before Drift opens it. Shell-created external
  directories are not valid substitutes under Android scoped storage. The
  profile-sidecar-only bootstrap now prepares that directory and verifies
  sidecar identity first; no Android permissions or Automotive registrations
  changed. Fresh startup and clean shutdown through its API succeeded.
- Android uses a separate `.responsive` profile sidecar and a local Subsonic
  fixture with twelve albums and three radio stations. The ordinary database
  and real-server credentials are not used for fixture authentication. The
  first portrait/landscape captures were obscured by the existing battery
  optimization prompt and are explicitly not visual acceptance. Repeated
  captures exempt only this disposable sidecar from battery optimization.

## Implementation ownership and follow-up guide

Paths in this table are relative to the repository root. Each package owns
presentation or narrowly identified infrastructure; it does not acquire queue,
source selection or server synchronization ownership.

| Package | Implementation owners | Closest focused evidence |
|---|---|---|
| Geometry | `lib/src/routing/content_layout.dart`, `common_widgets/responsive_content_grid.dart` | `test/src/routing/content_layout_test.dart`, `test/src/common_widgets/responsive_content_grid_test.dart` |
| A | `database/tables/app_settings_table.dart`, `database/daos/app_settings_dao.dart`, `database/navis_database.dart`, settings model/repository/Appearance, provider composition | migration suite, `responsive_settings_test.dart`, Appearance tests |
| B | Library screens/tabs/support widgets and scroll provider; artist-detail sections | Library and detail-screen tests, geometry regressions, runtime grids |
| C | `database/daos/library_dao.dart`, recent-liked provider, `common_widgets/content_shelf.dart`, Library/Home, liked-artist route | `recent_liked_albums_test.dart`, Library tests, hidden-page routing tests |
| D | `common_widgets/adaptive_track_row.dart`, `track_list_tile.dart`, `desktop_song_actions.dart`, every checked caller above | row tests and three mode goldens; specialized caller tests; `playlist_responsive_occurrences_test.dart` |
| E | Home screen/support widgets and shared shelves | Home resize/refresh/reachability tests; Linux Home screenshots |
| F | `features/home/presentation/recommendation_auto_advance.dart`, Home viewport/lifecycle owner, `routing/home_activity_scope.dart`, AppShell activity signal | timer fake-time tests, Home/shell tests, Android off/on timing |
| G | `common_widgets/desktop_playback_progress.dart`, `routing/app_shell_desktop_player_bar.dart` | progress tests, shell seek regression/goldens, desktop-layout runtime |
| H | `features/library/presentation/radio_screen.dart`, geometry policy | Radio tests/golden, Linux and Android station-card captures |
| Acceptance infrastructure | presentation scenario and authenticated controller/server; clone resize helper; Android sidecar bootstrap; sync cancellation barrier | endpoint/controller/window tests, final quality gate, isolated runtime reports |

Unless a path starts with `test/` or `lib/`, implementation entries above live
under `lib/src/`. The caller checklist is deliberately explicit: a future row
change must preserve every caller's original occurrence identity and action.

If a future regression appears, diagnose in this order:

1. **Artwork becomes oversized:** inspect the local usable width, preset,
   resolved extent and column count. Verify the caller applies bounded geometry
   instead of a fixed-count grid or an Expanded square. Changing the global
   shell breakpoint is not a substitute for measuring the collection pane.
2. **Wide shelf has empty space:** compare the eligible collection count with
   the two-screenful capacity and the preview count. Filter before limiting.
   A genuinely small collection should leave space; never repeat items or
   fetch unrelated items to fill it.
3. **Track metadata or controls clip:** inspect effective width at the current
   text scale, duration measurement and supplied action width. Header and row
   must resolve the same geometry. Preserve accessibility scaling; switch mode
   or stack controls instead of shrinking text.
4. **Songs move too far down Liked:** inspect each shelf's fixed artwork,
   measured caption, heading and gaps. Do not apply full-grid presets to these
   previews. Check the first-song position at the phone fixture, then enlarged
   text separately; readable enlarged text takes priority over the height target.
5. **A large grid stops after its first page:** check post-layout extent and
   loading/error/exhaustion guards. A zero scroll extent still needs a buffer
   check. Test no-progress responses to prevent an infinite load loop.
6. **Recommendations move unexpectedly:** check preference, desktop/manual
   mode, timer eligibility and the last interaction deadline. There must be one
   owner and one cancellable timer. Route/lifecycle changes must not accumulate
   callbacks or trigger background catch-up.
7. **Player time disappears:** measure labels and seek space. Times move below
   the bar, or onto separate aligned lines for extreme text, and the player
   grows as needed. Do not restore a height-based visibility condition.
8. **A runtime test appears successful but shows login or a modal:** reject
   that capture. Assert the actual route, inspect the PNG and repeat the real
   action through its production owner. Metadata alone is not visual evidence.

## Final acceptance results

The final quality gate ran after the last Dart change, including the clone
window-resize repair. `./tool/check.sh` completed formatting, generation,
analysis, migrations, critical reliability tests and the full suite:
**1,682 passed, one existing skip**. Analyzer output had no errors or warnings;
existing informational findings remain. All 41 migration tests passed. The
authoritative local log is
`build/responsive-layout/check-final-after-window-fix.txt`.

| Runtime acceptance | Result and inspected evidence |
|---|---|
| Linux responsive matrix | `build/presentation-diagnostics/20260928T090733Z-clone/`: passed; all 30 PNGs opened. Home, Albums, Liked, Artists and Radio at 800×600 and 2560×1280; Liked scroll, download/type filtering, Small/Large artwork, saved settings and clean restart. |
| Android touch/orientation | `build/responsive-layout/android-final/`: passed; all 22 PNGs opened. 360×800 portrait and 844×390 landscape at DPR 3, plus 1200×900 tablet at DPR 2 after restart. All five pages and scrolled Liked songs inspected. |
| Desktop window/player contracts | `build/presentation-diagnostics/20260928T092134Z-clone/`: passed; all 23 PNGs opened across initial and restarted runs. Standard, short, compact and minimum Desktop View; existing below-minimum gates, Mini Player sizes, recovery and transitions. Ordinary player times remain visible. |
| Playback markers | `build/playback-indicator-diagnostics/20260928T092326Z-clone/`: passed; all six queue PNGs opened. Current versus inactive, paused-current persistence, marker movement after a song change, then repeat after clean restart. |

The 81 runtime PNGs are separate from the inspected component and shell goldens.
Broad geometry tests cover more viewport and text-scale cases than the live
matrix; this does not claim every viewport/scale/theme/DPR combination was
executed on a running app. The live wide Linux size is 2560×1280 because the
available desktop work area must accommodate the window.

Android used a disposable `.responsive` profile sidecar and deterministic local
fixture: twelve albums, six explicitly starred albums, one artist and three
stations. Its one-pixel black covers verify geometry and overlays; real artwork
was inspected in the Linux clone. The manual carousel did not change over
twelve seconds; the enabled carousel changed to the next item after nine
seconds. Small artwork, disabled auto-advance and page visibility preferences
survived restart. Clone credentials are intentionally in memory, so fixture
authentication was reconnected after restart before taking acceptance captures.

Runtime reports include screenshot hashes/dimensions, actual routes, log review
and successful shutdown/restart evidence. Logs contain no hard-failure patterns.
The playback-indicator run records six known media-kit file-cache warnings and
zero corresponding playback-load failures; these are not hidden as clean logs.
Initial captures obscured by a battery prompt or login were excluded and
replaced with route-verified acceptance evidence. Earlier failed runs remain
available for diagnosis, not certification.

Generated Drift/localization output and intentional changed goldens were
reviewed. Test-failure images were removed without resetting pre-existing work.
Active architecture, diagnostics workflow/CI guidance, both release-note
sources and the fixed-column removal ledger were updated. Documentation links
were adjusted when this completed plan moved out of the repository root.

## Handoff and coverage limits

All accepted in-repository work is complete; no implementation package or
required local gate remains open. The working tree contains the change for
review and also retains the user's pre-existing work. No commit, pull request,
release or deployment was requested or created. Local runtime databases,
tokens, fixture scripts, APKs and captures stay under ignored `build/` paths.

The Android test sidecar was uninstalled, emulator size/density and temporary
battery exemption were restored, and the task's fixture/emulator were stopped.
The ordinary app database was never used as a destructive test target.

Physical Android, iOS, Windows and macOS runtime checks were not executed in
this environment. Shared Flutter geometry and automated regressions provide
coverage, but they do not certify native behavior on those targets. Check them
on suitable hosts before making a cross-platform release claim. This is an
external coverage limit, not an unfinished responsive implementation package.

Automotive installation, driving lockout, native AAOS browsing and projection
theming remain deferred in the separate Polestar record. No Android Auto media
service registration, native automotive category or driving policy was changed
by this overhaul.
