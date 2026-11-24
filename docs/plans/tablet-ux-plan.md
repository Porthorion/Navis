# Tablet and medium-width UX plan (iPad, Android tablets, foldables, medium desktop windows)

Status: investigation and plan only (Opus, 2026-11-24, branch
`t3/ipad-ux-investigation` at 422126b99). Nothing is implemented. Owner
decisions are in section 8.

Owner brief: "a lot of wasted space we could be using properly", and "I don't
like where the mini player is located on the sidebar, it doesn't feel right,
but I could be wrong". Scope (owner, 2026-11-24): every tablet / medium-to-wide
form factor on every platform. Decisions key on pane width and the shared
adaptive code (`lib/src/routing/desktop_layout.dart`,
`lib/src/routing/content_layout.dart`), never on `Platform.isIOS` or device
type.

**Scope rule (owner, 2026-11-24): reorganize, don't redesign.** This plan
only moves and re-gates widgets the app already has (phone, compact-wide
and desktop variants) so they make sense at tablet widths. New visual
designs, new components and restyled screens wait for the 1.6 redesign;
they are listed in section 9 so the ideas are not lost.

## 1. Evidence

Screenshots (main checkout, not committed):

| Path | What |
|---|---|
| `build/appstore-screenshots/ipad-13/01-home.png` | 13" portrait Home, live server |
| `build/appstore-screenshots/ipad-13/02-now-playing.png` | 13" portrait Now Playing in the rail pane, rail mini player still visible |
| `build/appstore-screenshots/ipad-13/03-album.png` | 13" portrait album: full-bleed hero, one column |
| `build/appstore-screenshots/ipad-13/04-library.png` | 13" portrait library grid, rail mini player |
| `build/appstore-screenshots/ipad-13/05-lyrics.png` | 13" full-screen lyrics route (rail hidden) |
| `build/appstore-screenshots/ipad-13/06-equalizer.png`, `08-integrations.png` | 13" portrait EQ and a settings page |
| `build/appstore-screenshots/iphone-6.9/*.png` | Phone set for comparison |
| `build/ipad/run-i46-pro-*/`, `build/ipad/run-i46-mini-*/` | I46 fixture runs, 13" and mini portrait |
| `build/ipad-ux/mini-run/` | This investigation's iPad mini pass, portrait and landscape (section 1.1) |
| `build/ipad-ux/shell-survey.md`, `build/ipad-ux/screens-survey.md` | Code surveys with file:line detail |
| `build/ipad-ux/mockup.html` | Wireframes of the recommended layouts |

### 1.1 Runtime pass (iPad mini)

iPad mini (A20 Pro), iOS 27.2, build of 422126b99, Flash-driven
(agent-device), 2026-11-24. Signed in to `https://sub.porthorion.com` with
the disposable diagnostics account `navis`, the host runtime passes use
(see section 8 note). Evidence and `NOTES.md`:
`build/ipad-ux/mini-run/`. Portrait 756x1158 is the bottom-nav shell;
landscape 1158x756 is the rail shell (288 pt rail, 870 pt pane).

- Portrait: `01-portrait-home.png` ... `14-portrait-lyrics.png` (home,
  albums, album, artists, artist, playlists, playlist, search, settings,
  EQ, downloads, now playing, queue, lyrics).
- Landscape: `21-landscape-nowplaying.png`, `22-landscape-lyrics.png`,
  `23-landscape-queue.png`, `25-landscape-album.png` ... `35-landscape-downloads.png`.
- Rail mini player tap test (landscape, points in 1158x756):

| Target | Result | Shot |
|---|---|---|
| artwork | album page | `40-tap-a-artwork.png` |
| song title | album page (title resolved to its album) | `45-tap-b-title-home.png` |
| blank right of title | Now Playing | `41b-*.png` |
| upper edge of artist line | Now Playing | `42-tap-c-artist.png` |
| artist line | artist page | `46-tap-c-artist-lower.png` |
| empty space right of controls | nothing | `43-tap-d-empty.png` |
| progress bar | seeks only | `44-tap-e-progress.png` |

  The hit zones do not match what the card draws: confirms F2.
- Landscape Now Playing: the lyrics button does nothing (reproduced twice);
  portrait (sheet) opens lyrics. Confirms F1 at runtime.
- Landscape Now Playing (870 pt pane) is a centred phone column with
  wide empty sides (F11). Artist bio runs the full 870 pt (about 105
  characters a line).
- Playlist detail showed "No songs" for about 5 s before its tracks
  rendered (F16).
- Split View and Stage Manager widths cannot be driven by agent-device;
  they are covered by the width matrix in section 2 and the widget tests.
- No overflow lines were seen (`simctl log show`; debug stdout was not
  attached).

## 2. How the shell resolves today

`resolveAdaptiveShellMode` (`desktop_layout.dart:324-388`) and
`resolveAdaptiveContext` (`:390-434`):

- Desktop (`desktopRuntime` = macOS/Windows/Linux, `:244-251`) always gets the
  desktop workspace: sidebar 64/220/260 by navbar style
  (`app_shell.dart:1114-1120`), and `_DesktopPlayerBar` across the bottom
  (`app_shell_desktop_workspace.dart:402-420`). The choice is by platform, at
  every window size from 800x600 (`kDesktopViewMinimumSize`). A desktop
  window never gets the rail or phone shell.
- Touch platforms: shortest side < 600 is a phone. A tablet gets
  `standardRail` at width >= 840 (`kAdaptiveExpandedWidth`), otherwise
  `phoneBottomNav`. Rail width is `(width * 0.25).clamp(270, 360)`
  (`app_shell.dart:1155-1157`).

Now Playing mode by pane: split >= 920, standard >= 760, else compact
(`now_playing_screen.dart:1117-1125`). "After P1.2" is the pane with the
220 pt default rail.

| Window (logical) | Shell | Rail | Pane today | NP today | Pane after P1.2 | NP after |
|---|---|---|---|---|---|---|
| iPad 13" portrait 1032x1376 | rail | 270 | 762 | standard | 812 | standard |
| iPad 13" landscape 1376x1032 | rail | 344 | 1032 | split | 1156 | split |
| iPad 11" portrait 834x1194 (10th gen 820) | bottom nav | – | 834 | sheet | 834 | sheet |
| iPad 11" landscape 1194x834 | rail | 298 | 896 | standard | 974 | split |
| iPad mini portrait 756x1158 (measured) | bottom nav | – | 756 | sheet | 756 | sheet |
| iPad mini landscape 1158x756 (measured) | rail | 288 | 870 | standard | 938 | split |
| Split View 2/3 of 13" landscape ~981 | rail | 270 | ~711 | compact | ~761 | standard |
| Split View 1/2 ~678, Stage Manager 600-839 | bottom nav | – | 600-839 | sheet | same | sheet |
| Slide Over / 1/3 320-375 | phone | – | 320-375 | sheet | same | sheet |
| Pixel Tablet landscape 1280x800 | rail | 320 | 960 | split | 1060 | split |
| Pixel Tablet portrait 800x1280 | bottom nav | – | 800 | sheet | 800 | sheet |
| Pixel Fold inner ~841x701 | rail | 270 | ~571 | compact | ~621 | compact |
| macOS/Windows/Linux window 800-1100 | desktop workspace | 220/260 (64 icons) | 540-880 | desktop overlay | same | same |

P1.2 moves 11" and mini landscape into the split Now Playing, and Split
View 2/3 across the 720 `wideDetail` line (P2.0). Builders and reviewers
should expect those devices to change bucket.

Content screens pick their wide layouts with `useDesktopShell` or
`desktopRuntime`, both platform checks: for example
`album_detail_screen.dart:289,324`, `home_screen.dart:168,241,1164`, the
playlist and artist header branches. A 1032 px iPad pane therefore gets the
phone layout of the album page, while a 900 px macOS window gets the
desktop header row. This is the root of "wasted space".

## 3. Findings

Type: **bug** (wrong behaviour) or **design** (works as built, wastes space or
feels wrong).

| # | Type | Finding | Evidence |
|---|---|---|---|
| F1 | bug | Lyrics toggle on the embedded Now Playing only highlights the button. `showInlineLyrics` requires `!widget.wideEmbeddedMode` (`now_playing_screen.dart:2406-2410`), and the embedded fallback panel (`:2236-2248`) needs `_showWideFullscreenLyrics`, which nothing ever sets to `true` (dead branch). Hits every rail pane in standard/compact mode (pane < 920): 13" portrait, 11" and mini landscape, Split View 2/3, Pixel Fold. The split layout (`:1988`) works, as does Settings > "Fullscreen Mode Lyrics" (route). | code; runtime (1.1, landscape lyrics no-op) |
| F2 | design | Rail mini player hit targets: artwork opens the album (`app_shell_mini_player.dart:312-326`), title resolves the song (`goToTitle`, `:336-365`, which can resolve to nothing), artist opens the artist (`:390-416`), only the card padding opens Now Playing (`InkWell` `:281-288`), about 40-45 % of a 222x120 card. No expand button or swipe (the bottom strip has one `InkWell` and swipe-up, `:856-894`). This is why tapping it "did not open Now Playing". | code; runtime tap table in 1.1 |
| F3 | design | Rail mini player stays visible while Now Playing is open in the rail pane, so two transports show (`02-now-playing.png`). The sheet shells hide the strip (`expandable_player_sheet.dart:334-352`). | screenshot, code |
| F4 | design | Rail mini player is cramped: 44 px art, marquee title at 17 px, controls in a 184 px row, the seek bar outside the card (`:584-668`), all at the bottom of a 270-360 px column that is otherwise empty below the nav. | `04-library.png` |
| F5 | design | The tablet rail is wide: 25 % clamp 270-360, against the desktop sidebar's 220/260 (or 64 icons) for the same items. 13" landscape spends 344 px on six labels. | `app_shell.dart:1155-1157` vs `:1114-1120` |
| F6 | design | Album page on tablets: full-bleed hero `min(width, height*0.45)` (`album_detail_screen.dart:1208-1217`), then one column; on 13" portrait the cover takes about 475 pt of height (measured in `03-album.png`) and the first track sits below the fold's middle. The desktop branch already has a cover-left header row from 900 px (`:707`), gated off by `useDesktopShell`. | `03-album.png` |
| F7 | design | Home is the phone layout stretched: centred 96/104 px logo header (`home_screen.dart:1249-1268`), a hero carousel capped at 300-320 px cover (`:3996-4007`), sections nested in Card margin 12 + inner 12 (`:2230-2256`), shelves 164 px cards; two-column song lists only in compact-wide >= 900 (`:4501,4541`). No max width: the narrow look comes from the centred cover and logo, and the empty lower third on a tall pane. | `01-home.png` |
| F8 | design | Playlist detail has no tablet branch: centred 180 px cover over a full-width list; the cover-left header exists only for desktop (`playlist_detail_screen.dart:260-340`). Artist detail is one column on tablets. Playlists tab is a plain list (`library_tabs.dart:313-330`). | screens survey |
| F9 | design | Lyrics open as a full-screen route on tablets (rail hidden) and have no max line width (`lyrics_display_widget.dart:252,386`), so desktop and 13" landscape lines run very wide. | `05-lyrics.png` |
| F10 | design | Queue on tablets is a 95 %-height full-width sheet (`app_shell_queue_overlay.dart:21`); desktop has a floating panel 320..min(560, 46 % width) (`:387-397`) gated to desktop. | screens survey |
| F11 | design | Now Playing in rail panes of about 760-919 (13" portrait 762, mini landscape 870, 11" landscape 896) misses the 920 px split threshold (`now_playing_screen.dart:1117-1170`, split needs 790x360 content) and uses the vertical standard layout with a gap between cover and title on tall panes. | `02-now-playing.png` |
| F12 | design | Pointer and keyboard: on iPad/Android tablets only Escape works (`enableDesktopCommandShortcuts = desktopRuntime`, `desktop_layout.dart:439-447`). Right-click is wired widely (`adaptive_track_row.dart:571`, `track_list_tile.dart:122`, `home_screen.dart:708`) but menus branch on `isDesktopRuntime` (`song_context_menu.dart:37`, `album_context_menu.dart:78`, `artist_context_menu.dart:28`), so a trackpad right-click opens a bottom sheet. `enableSecondaryClickMenus` and `enableDesktopPointerAffordances` exist and are tested but no UI reads them. Hover Play on cards is desktop-only (`album_card.dart:191`). | shell survey |
| F13 | design | The 600-839 tier (iPad 11"/10th gen/mini portrait, Pixel Tablet portrait, Split View 1/2, many Stage Manager windows) gets the phone bottom-nav shell and phone content layouts on a 600-839 pane. | section 2 |
| F14 | design | Downloads lists are full width with no cap (`downloads_screen.dart:557,791,1474`); EQ wide mode needs tabletExpanded and >= 850 (`eq_screen.dart:284-288`), so 13" portrait leaves the lower third empty (`06-equalizer.png`). Settings caps at 860/980/1040 and is fine. | screens survey |
| F16 | bug (low, verify) | Playlist detail shows its "No songs" empty state for about 5 s before the tracks load, instead of a loading state. Check `playlist_detail_screen.dart` uses `DetailTrackListOutline` / the pending body like album detail (`album_detail_screen.dart:242-287`). Not tablet-specific: tracked as its own issue, not in this plan. | `build/ipad-ux/mini-run/07-portrait-playlist.png`, NOTES.md |
| F17 | design | Album grid titles sit on the cover art; covers that carry their own text (for example "One More Lawn Radio") read as overprinted text (`crop-library-titles.png`). On panes >= 600 the grid has room for titles below the art, or a stronger scrim. Owner taste; listed, not planned. | mini-run crops |
| F15 | needs repro | "Download Album" on iPad appeared to do nothing (Downloaded tab stayed empty). Low confidence (agent may have run out of time). Repro: 13" or mini, live/demo server, album > Download, wait 60 s, check Downloads and `/v1/downloads` via the diagnostics API. Not planned as a bug until reproduced. | screenshot agent |

Already fixed and not re-planned: the 48 px Now Playing cover (I46,
c890749ea, #562).

## 4. Player placement: options

Patterns: Spotify iPad and desktop, and Navis desktop, put a full-width
player bar along the bottom with the sidebar above it. Apple Music on
iPadOS puts a compact player at the bottom of the content area, and the
sidebar runs full height. Both keep the player at the bottom edge, where
the thumb and eye expect it, and keep the sidebar for navigation only.
Navis tablet is the outlier: the player sits in the nav column.

| Option | What | For | Against | Size |
|---|---|---|---|---|
| A. Keep rail mini player, fix it | Whole card opens Now Playing, add an expand chevron and swipe-up; metadata links move to the card's context menu; hide it while Now Playing is open | smallest change | still cramped (F4), still spends a 270+ px column, still unlike desktop | S |
| **B. Bottom strip across the content pane (recommended)** | Reuse `_MiniPlayerStrip` (`app_shell_mini_player.dart:699-1187`, `flattenWideStyle`, `showSkipButtons`, swipe-up expand) as a 64-72 px bar at the bottom of the content pane in `standardRail`; the rail becomes nav only and can narrow; strip hides while Now Playing is open, as in the sheet shells | same widget and behaviour as the phone/medium tablet strip; matches Apple Music; the player stays in one place across 600-1376; frees the rail; small | not identical to the desktop bar (fewer controls) | M |
| C. Desktop player bar on tablets | Extract `_DesktopPlayerBar` (`app_shell_desktop_player_bar.dart`, a `part of app_shell.dart`) and use it in the rail shell | full parity with desktop; volume, EQ, queue, lyrics buttons | medium refactor: part file, `<700` empty branch (`:153-155`), Mini Player window button (`:1091-1095`), height bands tied to desktop; touch volume slider is redundant with hardware buttons | L |
| D. Persistent Now Playing inspector | A 320-360 px right panel (art, transport, queue/lyrics tabs) on very wide windows | uses 13" landscape and big desktop windows well | duplicates Now Playing and the queue; costs content width on every page; nobody asked for it | L |

Recommendation: **B** in P1. It answers the owner's instinct (the player
leaves the sidebar) with existing code and keeps one player position from
phone to 13". C stays open for the 1.6 redesign if the owner wants desktop parity on
13" landscape; D is not planned (YAGNI) until there is a request.

Now Playing itself stays in the content pane (rail visible), as today and as
the desktop overlay does. The owner may prefer a full-window cover (Apple
Music and Spotify cover the sidebar); a full-window Now Playing is listed as a 1.6 idea (section 9).

## 5. Prioritized changes

Risk class follows the Shipping gates in the global rules: `app_shell.dart`
and `now_playing_screen.dart` are hot files, so shell items are risky and go
one at a time; a layout change inside one screen is low risk. Every item
names its tests first; all of them use `setAdaptiveTestViewport` and the
shell matrix in `test/src/routing/desktop_layout_test.dart:63-228`.

**Regression gates for every item:** `test/src/routing/desktop_layout_test.dart`,
`test/src/routing/app_shell_navigation_test.dart` (phone bottom nav `:826`,
700x1000 `:913`, 840x1000 `:934`, desktop workspace `:956+`, 800x600
`:1452,1476`, Mini Player `:1598,3357`, goldens `:2066,4027`),
`test/src/routing/foldable_layouts_test.dart` (I27/I28 viewport matrix
`:125-199`, strip clearance `:989-1290`),
`test/src/routing/bottom_navigation_labels_golden_test.dart`, and the I46
group in `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`.
Phones (< 600 shortest side) and the desktop workspace must not change unless
an item says so.

### P0: bugs (target 1.5.x patch)

**P0.1 Embedded Now Playing lyrics toggle (F1).** Bug, low risk (one
condition in a hot file).
- Change: `now_playing_screen.dart`. Make the toggle show lyrics in the art
  slot in embedded standard/compact mode, as phone and split already do:
  drop `!widget.wideEmbeddedMode &&` from `showInlineLyrics` (`:2406-2410`)
  after checking with `git log -L` why it was added (eb71bde95/822c1aadc era).
  Then delete the dead `_showWideFullscreenLyrics` embedded panel
  (`:2236-2260`) and its resets if nothing sets it, or, if the history shows
  the panel was the intended embedded UI, set it from `onLyricsToggle`
  instead. Pick the one-line inline fix unless history says otherwise.
- Reuse: `PlaybackLyricsContent(maxSize:)`, `_coverArtSwitcherLayoutBuilder`.
- Tests first (fail today): in `now_playing_screen_adaptive_test.dart`, tap
  the lyrics action at `Size(762, 1376)`, `Size(868, 756)`, `Size(711, 1032)`
  embedded and expect `PlaybackLyricsContent`; radio and no-song cases keep
  the cover.
- Edge cases: split layout unchanged; fullscreen-lyrics setting still
  routes; phone sheet unchanged; queue/settings wide panel open then lyrics
  toggled (`:2536-2545`).
- Size: S.

**P0.2 Reproduce Download Album (F15)** with the steps above; plan a fix only
if it reproduces. Size: S (Flash runtime pass).

**P0.3 Now Playing has no close in embedded portrait (#803).**
**Status (2026-11-24): merged in #804.** The collapse button shows whenever Now
Playing is embedded without a sheet, and the standard embedded layout closes on a
swipe down. Runtime: `build/ipad-ux/batch-p12-803/`.

### P1: player placement and rail (target 1.5.x; owner decisions in section 8)

**P1.1 Bottom player strip in the rail shell (option B; F2, F3, F4).**
**Status (2026-11-24): merged in #802.** Runtime: `build/ipad-ux/p1.1/runtime/`.
Risky (hot file `app_shell.dart`, shell geometry).
- Change: in the `standardRail` branch of `app_shell.dart` (rail built at
  `:1835-1872`, content pane `:1876+`, embedded Now Playing `:2087-2146`)
  stop passing `showPlayer` to the rail (`app_shell_navigation_widgets.dart:341-355`)
  and put `_MiniPlayerStrip` at the bottom of the content pane, under the
  page and above the safe-area inset, with `onTap` = the existing
  `playerOverlayStackProvider.expand()` callback (`:1860-1869`). Hide it
  with the existing fade while Now Playing is expanded. Pages get the
  strip height as bottom padding the same way the bottom-nav shell does
  (`kMiniPlayerHeight`, `desktop_layout.dart:308`).
- Delete `_RailMiniPlayer` (`app_shell_mini_player.dart:150-694`) once no
  shell uses it. If the owner picks option A instead, keep it and make the
  whole card one `InkWell`, add a chevron and swipe-up, and move album /
  artist links to its context menu.
- Reuse: `_MiniPlayerStrip` with `flattenWideStyle: true`,
  `showSkipButtons: true`, `enableVerticalExpandGesture: true`; the
  compact-wide strip call at `app_shell.dart:2008-2058` is the template;
  `ExpandablePlayerSheet`'s fade logic for hide-on-expand.
- Tests first: in `app_shell_navigation_test.dart`, at 1032x1376, 1376x1032,
  1194x834, 1133x744, 981x1032: no `railMiniPlayer` key; one
  `_MiniPlayerStrip` inside the content pane's rect (not under the rail);
  tapping its title area opens Now Playing; swipe-up opens Now Playing; it
  is absent while Now Playing is expanded; the last list item of Library is
  not covered (scroll to end, hit-test). Golden refresh for the rail
  goldens.
- Edge cases: radio mode (no skip, radio art); external/remote source
  indicator; RTL (strip under the pane, rail on the right); keyboard open on
  Search (the strip behaves like the bottom-nav shell and rides above the
  keyboard); Split View resize across 840 (rail <-> bottom nav swap keeps one
  strip, no double strip for a frame); Escape closes Now Playing and the
  strip returns. Desktop workspace untouched (`useDesktopShell` path).
- Size: M (one Sonnet phase, about 40 tool calls).

**P1.2 Narrower tablet rail that honours the navbar style (F5).** Risky
(shell geometry), after P1.1.
**Status (2026-11-24): merged in #806.** Desktop keeps the "Desktop Navigation"
heading (Linux golden); tablets title the section "Sidebar". Icons-style tiles
now have tooltips and semantics labels. Runtime: `build/ipad-ux/batch-p12-803/`.
- Change: tablet rail width = the desktop sidebar widths by the existing
  navbar style setting (`'compact'` 220, `'comfortable'` 260 (the provider normalizes any other value to `'compact'`), `'icons'` 64;
  `app_shell.dart:1114-1120`) instead of `0.25 * width` clamp 270-360
  (`:1155-1157`); default 220 on tablets. Expose the existing navbar-style
  setting (`desktopNavbarStyleProvider`,
  `interface_settings_screen.dart:284,654-678`) on tablets; it is
  desktop-only today. Library sub-nav keeps its >= 840 rule
  (`:1158-1161`); in icon style it collapses into the Library destination
  as desktop does.
- Gains: 13" portrait pane 762 -> 812 (220) or 968 (icons); 13" landscape
  1032 -> 1156; Pixel Fold 571 -> 621.
- Tests first: rail width rows in the I28 matrix for each style; 13"
  portrait pane width 812 with default; icon style shows tooltips on
  long-press.
- Edge cases: phone landscape compact-wide rail untouched (`:1151-1154`);
  side-strip phones untouched; text scale 200 % in 220 px (labels ellipsize,
  tile heights from `navis_density_scope.dart`).
- Owner (2026-11-24): the user chooses the style; the tablet default is
  220 px labelled (`'compact'`). If the setting is already stored from a
  desktop install, honour the stored value.
- Size: S-M.

### P2: use the width (target 1.5.x)

**P2.0 One pane-width gate (backbone).** Low-medium risk (many files, no
logic change on desktop).
- Add to `ContentLayout` (`lib/src/routing/content_layout.dart`) one
  predicate on the content pane width, not the window:
  `static bool wideDetail(double paneWidth) => paneWidth >= 720;`
  (720 is the existing `trackMode` medium threshold, `:108-113`, so header
  and track rows switch together). Screens read the pane width from their
  `LayoutBuilder` constraints.
- Classify every gate site (`rg -c "useDesktopShell|desktopRuntime|isDesktopRuntime" lib/src/features`:
  home_screen 22, downloads_screen 6, artist_top_tracks_section 6,
  settings_screen 5, ranked_virtual_playlist_content 5,
  artist_detail_screen 5, playlist_detail_screen 4, album_detail_screen 4,
  now_playing_screen 4, library_tabs 3, themes_settings 3, genre_detail 2,
  library_screen 2, radio_screen 2, queue_track_row 2,
  home_onboarding_warmup 10, interface_settings 2, playback_settings 2,
  desktop_window_settings 2 (settings rows here are platform), and the player data
  layer, which is platform behaviour and stays). Each site is either
  *platform* (window controls, `DesktopFrame` and height bands, download
  folder, keyboard) and stays on `desktopRuntime`, or *layout* (header row vs
  hero, columns, paddings) and moves to `wideDetail`. The builder writes
  this table into the PR description.
- Tests: unit test for `wideDetail` at 719/720; the per-screen tests below.
- Size: S for the predicate; the screens are P2.1-P2.6.

**P2.1 Album and playlist header row on wide panes (F6, F8).** Low risk.
- Change: `album_detail_screen.dart`: when `!compactWideMode &&
  wideDetail(paneWidth)`, use the header row composition (cover left,
  title/meta/actions right, `:704-722`, action bar maxWidth 640). On touch,
  drop `DesktopFrame` and the desktop height bands (cover 240 at 720-959,
  280 from 960). The desktop branch's own `constraints.maxWidth >= 900`
  check (`:707`) stays on desktop: it only places the actions beside or below
  the title, and lowering it would squeeze the 640 action bar next to a ~440
  text column. Desktop panes 720-899 are unchanged.
  Playlist's desktop Row header gets the same single threshold. `playlist_detail_screen.dart`: same with its desktop Row header
  (`:260-330`, cover 200/220). Track rows already switch to medium/wide by
  `trackMode`.
- Reuse: the existing desktop header widgets; `AdaptiveTrackRow`;
  `ContentLayout.padding`.
- Tests first: at `Size(762, 1376)` and `Size(1032, 1032)` touch (no
  desktop runtime): cover's rect is left of the title's rect; first track
  row's top < 420 at 762 wide and < 480 at 1032; at `Size(700, 1000)` the hero layout remains. Desktop:
  new test at a ~760 pane (window ~980 with the 220 sidebar) expects the
  header row; existing desktop header tests stay green.
- Edge cases: missing cover, very long titles (two lines then ellipsis),
  multi-disc headers, remote album (Deezer) without tracks, RTL, text scale
  (trackMode divides width by scale, so the header must use the same
  scaled width).
- Size: M.

**P2.2 Home density (F7).** Low risk.
- Change: `home_screen.dart`: on panes >= 720 (touch), use the compact
  header row (`_HomeActionRowVariant.compactWide`, `:1243`) instead of the
  centred logo block; drop the nested section Card margins on wide panes
  (`:2230-2256`) so shelves run to the pane inset; enable the existing
  two-column song lists (`:4501,4541`) from 720 instead of compact-wide
  only. You Might Like keeps its current carousel (a side-by-side hero is a
  1.6 redesign idea, section 9).
  Check what the desktop Home variant (`desktopMode`, `:1164`, `:1403`)
  already does and reuse it rather than writing a third variant. (The
  `useDesktopShell` branch at `:241-253` is the Home mix playlist page, not
  Home; it gets the P2.1 header treatment.)
- Tests first: at 762x1376 touch, the first shelf's top < 520 (today about
  620 logical); two-column song section present; at 700 wide unchanged.
- Edge cases: offline/empty states, onboarding warm-up
  (`home_onboarding_warmup.dart`), Deezer off (no New Releases), the
  carousel's page dots and swipe.
- Size: M.

**P2.3 Library and artist (F8).** Low risk.
- Playlists tab: `ResponsiveContentSliverGrid` with `ContentLayout.albums`
  on panes >= 600 (cover grid like Albums), list below. Artist top tracks in two columns is new layout (there is no desktop
  branch to re-gate), so it moves to section 9 under the scope rule.
- Tests: grid columns at 762 and 1032; list at 500.
- Size: S-M.

**P2.4 Lyrics width and placement (F9).** Low risk.
**Status (2026-11-24): PR open.** `ContentLayout.readingWidth` (720) caps the
lyric column (centred) and the artist bio (start-aligned); panes up to about
816 are unchanged.
- Cap the lyric column at 720 px, centred, in `lyrics_display_widget.dart`
  (helps desktop too); keep the font scale (`:416-423`). Apply the same
  720 cap to the artist bio text (`artist_detail_screen.dart`).
- After P0.1, the toggle shows lyrics in place on rail panes, so the
  full-screen route is only for the setting.
- Tests: line box width <= 720 at 1376 wide.
- Size: S.

**P2.5 Queue as a side panel on wide windows (F10).** Medium risk.
- Use the desktop floating queue panel (`app_shell_queue_overlay.dart:387-397`)
  on `standardRail` windows, gated by width instead of desktop runtime;
  bottom-nav tablets keep the sheet.
- Tests: queue panel width within 320..560 at 1032x1376; sheet at 834x1194.
- Edge cases: drag-to-reorder with touch inside the panel; Escape and
  tap-outside close it; Now Playing open underneath.
- Size: M.

**P2.6 Downloads and EQ (F14).** Low risk.
- Downloads bodies: cap at 1040 like settings pages; use `trackMode` rows.
- EQ: allow `_wide` on any pane >= 760 (drop the layout-class requirement,
  `eq_screen.dart:284-288`) so 13" portrait gets the presets panel.
- Size: S.

### P3: input and the medium tier (target 1.5.x if time allows, else 1.6)

**P3.1 Pointer affordances by policy, not platform (F12).** Low risk.
- `resolveAdaptiveInputPolicy` (`desktop_layout.dart:436-450`): set
  `enableSecondaryClickMenus` and `enableDesktopPointerAffordances` for
  desktop and every non-phone layout class. Then read the policy (via
  `AdaptiveInputPolicyScope`) in `song_context_menu.dart:37`,
  `album_context_menu.dart:78`, `artist_context_menu.dart:28` and
  `album_card.dart:191` instead of `isDesktopRuntime`. A secondary click
  (trackpad/mouse) opens the anchored menu; long-press keeps the bottom
  sheet. Hover cannot fire without a pointer, so touch is unaffected.
- Tests: update the policy tests (`desktop_layout_test.dart:427-455`);
  secondary tap at 1032x1376 opens the anchored menu; long-press opens the
  sheet; phone unchanged.
- Size: S.

**P3.2 Hardware keyboard shortcuts on tablets (F12).** Low-medium risk.
- Set `enableDesktopCommandShortcuts` for non-phone layout classes too; the
  handler (`app_shell.dart:343-398`, `desktop_commands.dart:126-193,550-597`)
  only sees keys when a hardware keyboard is attached. Map Cmd (iPad) and
  Ctrl (Android/ChromeOS) like desktop does; skip shortcuts that need the
  desktop window (Mini Player, window size).
- Tests: Space toggles playback at 1032x1376 with no text focus; Space in
  the Search field types a space; Cmd+F opens search; phone unchanged.
- Edge cases: bare Space/arrows with a focused text field or slider;
  iPadOS system shortcuts (Cmd+Tab, Cmd+H) must pass through.
- Size: S-M.

**P3.3 The 600-839 tier (F13).** Owner (2026-11-24): a user setting,
default bottom nav. With the default the work is P2's width gate: every
pane >= 720 (Pixel Tablet portrait 800, iPad 11" 834, mini portrait 756;
Split View 2/3 crosses at ~761 after P1.2) gets the wide headers and Home
density with no shell change.
- Setting: "Navigation on medium screens: Bottom tabs (default) / Sidebar",
  in Interface settings next to the navbar style, shown only when the
  window is 600-839 wide or could be (tablets, desktop). Persist it the way
  `desktopNavbarStyleProvider` persists the navbar style. This needs a new `app_settings` column (only `desktopNavbarStyle` exists today, `app_settings_table.dart:372-375`), so a stepwise Drift migration plus a migration-test update: treat P3.3 as a risky migration item.
- With "Sidebar", `resolveAdaptiveShellMode` returns `standardRail` for
  600-839 instead of `phoneBottomNav`; the rail uses the navbar style from
  P1.2 (icons recommended there) and the P1.1 strip. Risky shell item, after
  P1.1 and P1.2, one at a time.
- Tests first: at 834x1194, default shows the bottom nav (unchanged
  goldens); with "Sidebar" shows the rail plus strip and no bottom nav;
  phones < 600 ignore the setting; >= 840 ignores it (rail as today).
- Edge cases: the I27/I28 foldable matrices (fold/unfold crossing 600 and
  840 with the setting on), Split View resizes, text scale 200 %, the phone
  side-strip mode untouched.
- Size: M.

## 6. Where the tablet layout meets desktop

- Shell: desktop keeps its workspace and `_DesktopPlayerBar`. After P1 the
  tablet rail uses the same widths and navbar-style setting, and the player
  sits at the bottom on both, so the two read as one family.
- Content: P2.0 moves layout choices from platform to pane width, so a
  762 px iPad pane and a 762 px desktop pane get the same album, playlist
  and Home layouts. Desktop-only chrome (`DesktopFrame`, height bands,
  window controls) stays on `desktopRuntime`. The desktop album header's
  own 900 px check (action placement) stays on desktop (P2.1); desktop panes
  720-899 are unchanged.
- Input: P3 makes pointer and keyboard follow the policy object, which
  desktop already enables; behaviour on desktop does not change.
- Tests that pin desktop: `app_shell_navigation_test.dart:956+` (workspace),
  `:1086-1450` (sidebar widths/autohide), `:1452-1476` (800x600),
  `:3622` (799x599 gate), desktop album/playlist header tests.

## 7. Target release

- P0.1 (lyrics bug) and P0.2 (repro): 1.5.x patch (1.5.2 if still open,
  else 1.5.3). Low risk, one focused PR.
- P1 and P2: 1.5.x, as one milestone (they reorganize existing widgets;
  the redesign is 1.6, section 9). Order: P2.0 -> P2.1 -> P1.1 ->
  P1.2 -> P2.2 -> P2.3/P2.4/P2.6 -> P2.5. P1.1 and P1.2 are hot-file
  items and go one at a time.
- P3: 1.5.x after P2 if time allows, else 1.6 (P3.1 and P3.2 re-gate
  existing desktop pointer and shortcut code; P3.3 adds a setting and a Drift migration).

Rough total: P0 S; P1 M + S-M; P2 about 3 x M + 3 x S; P3 S + S-M + M. About 8-10
Sonnet phases plus reviews.

Runtime check per PR (diagnostics API screenshots, run by Flash): 13"
portrait/landscape, mini landscape, 11"-size Split View, Pixel Tablet
emulator landscape, macOS window at 900x700 and 1440x900, iPhone portrait.

## 8. Owner decisions

Mockups are on the private design canvas "Navis tablet layouts"
(local copy: `build/ipad-ux/mockup.html`; private link held by the coordinator, not committed). Each board title is
tagged **1.5.x** (a reorganization this plan builds) or **1.6 idea** (a
redesign, section 9). The mockups are drawn rather than captured, so their
styling is approximate; for 1.5.x boards only the arrangement counts, and
the widgets stay as they look today.

Owner decisions (2026-11-24):

1. **Player placement:** B, the existing phone mini-player strip along the
   bottom of the content pane (P1.1). A, C and D are dropped (C and D stay
   as 1.6 ideas).
2. **600-839 tier:** a user setting, default bottom nav (P3.3).
3. **Tablet rail:** a user setting (the existing navbar style), default
   220 px labelled (P1.2).

Now Playing stays in the content pane as it does today (it reaches the
existing split layout once the rail narrows); covering the whole window is a
1.6 idea.

Runtime host (coordinator, 2026-11-24): runtime passes use
`https://sub.porthorion.com` with the disposable diagnostics account `navis`
(password file `build/ios-diagnostics/password.txt`; never print it).
`https://navis.porthorion.com/demo` is the future public demo account for
App Review and is not set up yet, so its login rejection is expected; do not
use it for passes.

## 9. Deferred to the 1.6 redesign

Ideas from the mockups that need new components or new visual design, kept
out of 1.5.x by the scope rule:

- Player as a full-width desktop-style bar (C) or a floating pill (D).
- Artist top tracks in two columns on wide panes (was in P2.3).
- You Might Like as a side-by-side hero with a column of upcoming covers.
- Album landscape with a fixed cover column and a Title / Artist / Time
  track table.
- Now Playing portrait with an Up next / Lyrics / About panel filling the
  space under the controls; Now Playing covering the whole window.
- An 80 px icon rail with labels at 600-839, and a floating player card
  above the bottom nav.
