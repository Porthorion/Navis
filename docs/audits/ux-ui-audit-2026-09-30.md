# UX/UI audit — 2026-09-30

This audit covers the desktop and mobile clients before the 1.4.0 release. It
extends [design-ux-audit.md](../design-ux-audit.md) and does not replace it.
The motion, Hero and navigation findings recorded there remain current.

The implementation decision is recorded in
[decisions/2026-09-30-design-foundation.md](../decisions/2026-09-30-design-foundation.md).

## Evidence

- About 30 app-owned screenshots from existing diagnostics runs (presentation,
  responsive layout, equalizer, playback adjustment, artist playback and
  mobile-layout repair). They span 360–2560 px on phone, landscape, tablet,
  desktop and Mini Player.
- Component goldens under `test/`.
- Source review of the theme, shared widgets, the mobile shell and player, and
  the desktop shell and player bar.

## Verdict

Navis is functional and mostly coherent. These parts are strong and are kept
unchanged:

- the motion policy and reduced-motion handling;
- the adaptive shell and collapsing sidebar;
- the desktop player-bar layout;
- the Speed & Pitch and Equalizer quick panels;
- queue reordering and swiping;
- context menus, shortcuts and tooltips;
- the mobile player-sheet gestures.

What was missing is a design-system foundation. The theme defined colour
only: there was no type scale, no bundled font and no component themes. That
left about 120 radius literals, about 113 font-weight overrides, several
private section-header implementations, and three or four different
treatments for the same detail-page actions.

## Product decisions

- Scope is the foundation plus targeted fixes. There are no large layout
  rethinks.
- One font family, Inter, is bundled for every platform.
- A desktop Now Playing page is deferred to a later release, because the
  persistent player bar already covers playback.
- The large centred mobile Home logo stays. It doubles as the pull-to-refresh
  and sync indicator.

## Findings

Status is updated as each slice lands.

| # | Area | Finding | Status |
|---|---|---|---|
| 1 | All | No type scale or bundled font; titles use weights ad hoc | Fixed: bundled Inter plus a tuned Material 3 scale (P2) |
| 2 | All | No component themes; buttons, chips, inputs, cards and sheets use defaults or local overrides | Fixed: soft outlined buttons, stadium chips, flat cards, 12 px menus and inputs (P3) |
| 3 | Detail pages | Inconsistent action bars (Filled/Tonal/Outlined mix, custom Rate pill, red hearts, duplicated More, Download without run spacing) | Fixed: shared `EntityActionBar` (filled Play, tonal Shuffle, outlined secondary actions). The artist page keeps its phone "More" (an earlier approved reachability decision), now as an outlined secondary action |
| 4 | Album | Unlabelled track count, "-" for a missing year, count changes with filters, permanent Filters label, redundant "Album" title, Album column repeated on every row | Fixed: "2026 • 16 songs • 52 min" summary; a single Filter button with a badge; loaded albums drop the app-bar title; album tracks hide the Album column |
| 5 | Library | Sync-failure banner is the loudest element on screen; message is hard-coded English | Fixed: a quiet, dismissible warning with the localized headline "Last sync failed". The engine's detail text stays as secondary copy until the sync state gains a typed failure kind |
| 6 | All | Missing-artwork placeholder is a 20 px icon at every tile size | Fixed: icon scales with the tile over a subtle gradient |
| 7 | Desktop | No maximum content width; tables stretch at 2560 px | Fixed: `DesktopFrame` centres content at 1720 px on very wide windows |
| 8 | Desktop | No Shuffle in the player bar; title and artist both use the accent colour; Instant Mix test key named `desktopPlayerPreviousButton` | Key renamed and the artist link quieted. Product decision: Shuffle moved into the queue header on every platform. Instant Mix takes its transport slot on phones too, so Play stays centred. A badge on the Queue button shows when shuffle is on |
| 9 | Desktop Home | You Might Like arrow covers the track list's "…" column | Fixed: arrows sit beside the cover strip on wide layouts |
| 10 | Desktop | No hover affordance on album cards; row actions always shown at full emphasis; 76 px artist rows | Hover Play on album cards. Row actions stay quiet until hover or focus; liked and downloaded state stays at full emphasis. Artist rows are now flat, and on desktop they are about 64 px instead of 76 px |
| 11 | Speed popover | "2×" chip wraps alone onto a second row | Fixed: compact chips in narrow panels |
| 12 | Now Playing (phone) | Metadata pager has no affordance; several fields in the accent colour | Fixed: page dots; only the title uses the accent |
| 13 | Search (phone) | Unstyled field; clear tooltip reused "Clear" from recent searches | Fixed: filled search bar with a search icon; "Clear search" tooltip |
| 14 | Settings (phone) | No title; group headings hidden | Group headings added. No title by design: phone tab roots rely on the selected bottom-navigation label |
| 15 | Library (phone) | Tabs clip "Radio" at 360 dp | Not a defect: the partly visible last tab is the scroll affordance for scrollable tabs |
| 16 | Home (landscape) | Hero carousel card cropped at 390 px height | Not a defect: the card continues below the fold in the scrolling page |
| 17 | Copy | "1 albums" | Fixed: ICU plural |
| 18 | Copy | Liked Artists title glued from two strings | Fixed: dedicated key |
| 19 | Copy | Hard-coded "Rate" | Fixed: `ratingActionLabel` |
| 20 | Copy | Onboarding text hard-coded in English | Fixed: localized, reusing Settings keys where the text matched |

## Implementation order

Each phase is described in the implementation plan:

- **P0:** copy fixes and independent fixes.
- **P1:** foundation with no visual change (tokens, unified theme builder,
  font asset, guard test).
- **P2:** typography.
- **P3:** component themes.
- **P4:** shared section header, action bar, like, rating and metadata
  widgets.
- **P5:** targeted UX fixes.
- **P6:** ratchet migration of the remaining literals.

## Ratchet migration (P6) outcome

The guard's counts, before → after:

| Pattern | Before | After |
|---|---|---|
| Radius literals | 112 | 24 |
| `fontSize` literals | 15 | 10 |
| `Color(0x…)` literals | 29 | 23 |
| Palette `Colors.*` | 15 | 9 |

Most swaps map to an identical token value. The only visible adjustments are:

- control and panel radii of 10, 14 or 18 rounded to the nearest token;
- two 11 px subtitles moved to `labelSmall`;
- validation and download checkmarks now use the `NavisTokens.success` role.

These remain deliberately literal:

- artwork thumbnails and hairline radii;
- hero display sizes;
- the smart-queue and brand colours;
- the amber partial-download badge, which sits on a fixed scrim;
- the equalizer painters.

## You Might Like redesign

Follow-up decisions:
- **Phones:** a focused cover flow.
- **Desktop:** light alignment only.
- **No reshuffle button.**

The phone cards used to crop square covers to about 300×228 and printed
titles over darkened art. They now show uncropped covers with the details and
the recommendation reason below, a Play button on the focused cover, and a
colour wash. Desktop gained the reason line and Play/Shuffle. See
`docs/architecture.md` → *Home: You Might Like*.
