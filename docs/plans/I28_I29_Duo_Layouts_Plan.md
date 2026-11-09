# I28 / I29 plan: short-landscape compact shell, side-strip navigation

Base: `origin/release/1.5` (includes PR #431 as `9be1c045`, which adds the shell
`SafeArea`, `ConsumedRightInset`, `SideInsetsConsumed`). Target: `release/1.5`
(1.5.2), shared Dart. **Order: I28 first, I29 planned against I28 merged.**
Both edit `resolveAdaptiveShellMode` and `app_shell.dart` (hot files), so one
at a time, one PR each. Line numbers are at `9be1c045`.

**Owner constraint (2026-11-09): reuse, don't rebuild.** No new screens or
parallel layouts for one device; extend the existing shell modes and layouts.
Reviewers reject duplicated layout code or device-specific branches.

Owner refs: `owner-refs/...2a4424f5...jpg` (idea 1: landscape cover, art
left, title/seek/transport/volume right, icons bottom) and
`owner-refs/...37c36dac...jpg` (idea 3: portrait cover, status icons at the top
of the right strip, a vertical nav pill in the strip, floating mini player).

---

## I28: short landscape windows use the compact wide shell

### What exists (reuse, don't rebuild)

- `AdaptiveShellMode.compactWideLandscape` (`lib/src/routing/desktop_layout.dart:62`)
  with its full shell branch in `app_shell.dart:1666-1899`: the compact icon rail
  (`_CompactIconRail`, `app_shell_navigation_widgets.dart:17`), the compact mini
  player strip (`_MiniPlayerStrip(compactWideLandscapeMode: true)`,
  `app_shell_mini_player.dart:861`), the in-pane `ExpandablePlayerSheet` and the car
  Now Playing (`NowPlayingScreen(compactWideLandscapeMode: true)`,
  `now_playing_screen.dart:1877-2130`: art left, track info, info pills, seek,
  transport, action row right). This is the layout in the owner's image.
- Compact-wide variants of pages already exist: Home (`home_screen.dart:1154`),
  Settings (`settings_screen.dart:45`), Search (`search_screen.dart:213`),
  Album detail (`album_detail_screen.dart:273, home 332`), navigation fades
  (`navigation_service.dart:63`).
- The rail-height test in `resolveAdaptiveShellMode` (`desktop_layout.dart:308-324`):
  `estimatedRailHeight = height - safePadding.vertical - 44 < 436` means "too short
  for the standard rail", i.e. `height - safe.vertical < 480`.

So the only thing missing is the routing: today a phone-shaped landscape window
gets compact wide only when `width >= 840` (`desktop_layout.dart:304`); below
that it falls to `phoneBottomNav`.

### Rule (size and insets only)

Phone form factor (`shortestSide < 600`), landscape, not desktop:

| rail fits (`h - safe.vertical >= 480`) | width | mode |
|---|---|---|
| no (short) | `>= 600` (`kAdaptiveMediumWidth`) | `compactWideLandscape` (**new for 600-839**) |
| no (short) | `< 600` | `phoneBottomNav` (squarish split windows) |
| yes | `>= 840` | `standardRail` (unchanged) |
| yes | `< 840` | `phoneBottomNav` (unchanged) |

Sketch for `resolveAdaptiveShellMode` (replace `desktop_layout.dart:304-326`):

```dart
if (!isLandscape) return AdaptiveShellMode.phoneBottomNav;
// ...existing constants and estimatedRailHeight...
if (estimatedRailHeight < minPhoneRailHeight) {
  return width >= kAdaptiveMediumWidth
      ? AdaptiveShellMode.compactWideLandscape
      : AdaptiveShellMode.phoneBottomNav;
}
return adaptiveClass == AdaptiveLayoutClass.tabletExpanded
    ? AdaptiveShellMode.standardRail
    : AdaptiveShellMode.phoneBottomNav;
```

Worked sizes (padding as the device reports it):

| Window | Today | After |
|---|---|---|
| 844x390, 932x430, 852x393, 926x428 (iPhones) | compact wide | compact wide (same branch, `width >= 840` short) |
| 667x375 (SE), 812x375 (X/11 Pro/mini), 780x360, 740x360, 800x360 (Android) | bottom nav | **compact wide** |
| Duo cover rotated ≈678x466, strip on a long edge (84 top or bottom) | bottom nav | **compact wide** (`466-84-34 < 480`); also with no strip (`466 < 480`) |
| Pixel Fold folded landscape ≈797x411 | bottom nav | **compact wide** |
| Galaxy Z Fold cover landscape ≈882x344 / 917x373 | compact wide | compact wide |
| Pixel Fold unfolded (≈841x701 / 701x841), Duo unfolded, iPads | tablet rules | unchanged (shortest side ≥ 600, early return at :295) |
| Phone portrait, Duo folded portrait | bottom nav | unchanged |
| Split/freeform phone window 560x400 | bottom nav | bottom nav (width < 600) |
| 700x520 freeform | bottom nav | bottom nav (rail fits, < 840) |
| Desktop (any) | standardRail | unchanged (early return :284) |
| AAOS head unit ≈800x480 dp | bottom nav | bottom nav with zero insets (`480-44 = 436`, not `< 436`); compact wide only if the head reports a vertical inset (e.g. a 24 dp status bar). Not changed here. |

**Keyboard stability:** `padding.bottom` drops to 0 while the keyboard is open,
which raises `estimatedRailHeight`. With the width gate gone a window near the
480 boundary could flip mode while typing in Search. Fix: the shell call site
`app_shell.dart:994` passes `safePadding: mediaViewPadding` (already computed at
:985; `viewPadding` ignores the keyboard). `viewPadding >= padding`, so existing
sizes can only move towards compact wide, and none sit at the boundary
(844x390: 390-21=369, far below 480). `resolveAdaptiveContextFor`'s unscoped
fallback (`:424`) gets `mediaQuery.viewPadding` too, for the same answer.

### What is new (exact list)

1. `desktop_layout.dart:304-326`: the rule above (about 8 lines).
2. `app_shell.dart:994` and `desktop_layout.dart:424`: `viewPadding` instead of `padding`.
3. **Car Now Playing at short heights** (`now_playing_screen.dart:1877-2030`). The test
   at `foldable_layouts_test.dart:705-716` clears a 6 px overflow that already
   happens at 844x390; at 667x375 and 812x375 it is worse. Scoped to
   `resolveAdaptiveContextFor(context).useCompactWideLandscape` (so the desktop
   mini player, which also passes `compactWideLandscapeMode: true` at
   `app_shell_desktop_mini_player.dart:69`, is untouched):
   - below `constraints.maxHeight < 400` drop `_NowPlayingInfoPanel` (the format pills)
     and its spacer. This is a deliberate fix at 844x390 too; say so in the PR.
   - If the overflow remains at 667x375 at text scale 1.3, put the info column in a
     `SingleChildScrollView` (no clipping, last resort). The builder measures first.
4. **Double side inset in car Now Playing** (the documented #410 follow-up, I27b
   "Not changed"): the compact-wide shell pads its Row by `mediaPadding.left/right`
   (`app_shell.dart:1667-1676`) without removing it from `MediaQuery`, and
   `compactPadding` (`now_playing_screen.dart:1882-1890`) adds it again. On 812x375
   (44 pt notch) that is 88 pt lost. Under `useCompactWideLandscape` take left/right
   as `20` / `12` without `mediaPadding`; keep top/bottom. Desktop mini player keeps
   its current padding (zero insets there anyway).
5. **Volume:** owner answered Q1 (2026-11-09): **no in-app slider**. Nothing to build.

Not new: the rail, mini player, sheet, queue panel, compact pages, back handling.

### Failing tests first

`test/src/routing/desktop_layout_test.dart` (unit, next to :63-130):
- matrix over the "Worked sizes" table with realistic padding: 667x375 (0),
  812x375 (44/44, bottom 21), 780x360 (left 48 Android 3-button), 678x466 strip
  bottom (0/0/0/84+34) and strip top (84 top, 34 bottom), 797x411 → compact wide;
  560x400, 700x520, 375x667, 466x678 (0/0/84/34) → phone bottom nav; 844x390,
  932x430, 900x420 → compact wide; 900x620, 1280x720, 1366x955 → standard rail.
- keyboard: 678x466 with `viewPadding.bottom 34` resolves the same whether
  `padding.bottom` is 34 or 0 (assert via `resolveAdaptiveContextFor` under a
  `MediaQuery` with `viewInsets.bottom 200`).

`test/src/routing/foldable_layouts_test.dart`, new group `I28` (reuse `_pumpApp`,
`_resize`, `_openNowPlaying`, `_expectNowPlayingControlsFit`, `_testApp`; add
viewports `_phoneSE` 667x375, `_phoneMini` 812x375 0/44/0/44 bottom 21,
`_duoCoverLandscapeBottomStrip` 678x466 0/0/0/118, `_duoCoverLandscapeTopStrip`
678x466 top 84 bottom 34, `_phoneLandscapeLarge` 932x430 59/59 bottom 21):
1. at 667x375, 812x375, 678x466 (both strips): `compactRailNavTile-0..3` present,
   no `NavigationBar`.
2. Now Playing open: **no exception** (replace the `tester.takeException()` at
   :712-714 with `expect(tester.takeException(), isNull)`), `Icons.pause` and
   `Icons.queue_music_outlined` inside the safe rect, at 844x390, 932x430, 812x375,
   667x375, 678x466 both strips, and 667x375 at text scale 1.3.
3. Double inset: at 812x375 the car Now Playing art's left edge is
   `rail.right + 20` (not `+ 64`).
4. Each tab (home, library albums/artists, search, settings) and an album detail at
   667x375 and 678x466 (both strips) and at text scale 1.3: no exception; nothing
   tappable under the strip (top strip: the first tappable widget's top `>= 84`;
   bottom strip: mini player skip button bottom `<= 466 - 118`). The bottom-strip
   case likely fails: the compact mini player has fixed 10 pt padding
   (`app_shell_mini_player.dart:862`) and the content `SafeArea` drops the bottom with
   the player (`app_shell.dart:1777-1796`). Fix if it fails: give the compact mini
   strip `bottom: MediaQuery.viewPaddingOf(context).bottom` inside its own
   `SizedBox` height (height grows by the inset). Same applies to iPhone landscape
   home-indicator 21 pt today; measure, don't assume.
5. Rotation/fold with state: 375x667 ↔ 667x375 and 466x678 ↔ 678x466, with Now
   Playing open and with the queue open: no exception (D7 class), player stays
   expanded, current tab and Library section kept, page scroll offset kept (reuse the
   A2 pattern). Expected and documented: the bottom-nav and compact-wide branches
   mount different `NowPlayingScreen` instances, so inline lyrics / panel state reset
   on rotation, and compact wide closes the queue overlay on entry
   (`app_shell.dart:1214-1221`) and offers it as the in-pane panel.
6. Regression guards (must already pass): existing `A4 compact wide landscape phone
   keeps its single inset` (`:779-791`), desktop mini player tests/goldens
   (`test/src/routing/app_shell_navigation_test.dart` mini player cases,
   `goldens/desktop_*`), `now_playing_screen_adaptive_test.dart`,
   `library_detail_screens_test.dart` compact-wide cases.

### Edge cases

- Phones portrait: unchanged. Landscape with the notch on either side: compact wide
  pads both sides (`app_shell.dart:1667`) so the rail clears a left notch and the pane
  a right one; the double inset in Now Playing is removed (item 4).
- iPad, Duo/Pixel Fold unfolded, desktop: unchanged by construction (early returns).
- Pixel Fold folded landscape and Galaxy covers: compact wide, test via the unit matrix.
- RTL: compact wide uses a plain `Row` (rail first) and symmetric padding; unchanged.
- Large text: compact pages and car Now Playing at 1.3 covered by tests 2 and 4.
- Keyboard: no mode flip (viewPadding); compact wide keeps
  `resizeToAvoidBottomInset: false` (`app_shell.dart:1565`), so Search results sit
  under the keyboard as on 844x390 phones today. Not changed here.
- Car-bar inset proxy (`effectiveCarBottomInset`, `app_shell.dart:990`) uses
  `viewPadding.top` when the bottom is 0: an Android phone in landscape with a 24 pt
  status bar and no bottom inset gets 24 pt extra below the rail, as 915x412 phones
  already do. Not changed.

### Risk

Risky (shell-mode routing for every phone in landscape, fold/rotation transitions,
player sheet). Sonnet `high` build from this plan; fresh Sonnet `high` review.

### Runtime checks for the PR

1. iPhone SE (3rd gen) simulator 667x375: Home, Library, Search, Settings, album
   detail, Now Playing open/close, queue panel, rotate both ways with playback
   (`agent-device` rotate, `POST /v1/presentation/screenshot` each state).
2. iPhone 16 (852x393): screenshots before/after match except the info pills row
   in car Now Playing (the deliberate fix).
3. iPhone Duo folded, rotated cover: record the `MediaQuery` padding the simulator
   reports (log it once from `AppShell` in a throwaway patch, or read
   `/v1/presentation/screenshot` + `agent-device snapshot`); confirm compact wide and
   that the mini player and pages clear the strip.
4. Android emulator phone landscape (e.g. Pixel 8a 3-button nav) if available.

---

## I29: navigation pill in the side status strip (Duo cover portrait)

### Step 0: prove the OS delivers taps in the strip (before any build)

The strip is the iOS status bar on the Duo cover; iOS may route touches there to
the status bar (Flutter turns status-bar taps into scroll-to-top) instead of the app.

1. Uncommitted patch: wrap the app root (e.g. the `builder` in `lib/src/app.dart`)
   in `Listener(onPointerDown: (e) => AppLogger.debug('[I29_PROBE] down ${e.position}'), behavior: HitTestBehavior.translucent, child: ...)`.
2. Duo simulator, folded cover, app on Home with a scrolled page. Using the
   `agent-device` command from `device_open` (OS-level taps; **not**
   `/v1/presentation/tab`, which injects Flutter pointers and proves nothing),
   check first whether `tap` takes points or pixels (screenshots are 3x,
   1398x2034). Tap strip x≈424 pt at y = 90 (camera), 130 (clock), 160 (just below
   the reserve), 300, 500, 620; plus one content tap (200, 300) as the control.
3. `grep I29_PROBE build/foldables-i27/run/main-navis.log` (or the run's log).
   Record which taps arrived and whether a strip tap scrolled the page to the top.
   Write the result into this file before building. Discard the patch.

Measured status area (from `duo-final/folded-home.png`, 3x): camera ends ≈65 pt,
clock ≈80-98 pt, the wifi glyph ends ≈151 pt. **Reserve: 168 pt from the top of
the strip** (`kSideStripStatusReserve`, a calibration constant; adjust from step 0).

**Fallback** (taps do not arrive below the reserve): the pill goes in the page
area beside the strip: same pill, `Positioned(right: inset)`, and the page
`SafeArea` gets `minimum: EdgeInsets.only(right: inset + 60)` (with
`ConsumedRightInset` set to that value). Content is then 322 pt wide instead of
382 but 80 pt taller. If this happens, ask the owner (Q2) whether that trade is
worth it or whether the cover keeps the bottom bar; don't build it unasked.

### Rule (size and insets only)

`AdaptiveShellMode.sideStripNav` (new enum value) when all hold:
- not desktop, and the result would otherwise be `phoneBottomNav`;
- portrait (`width <= height`); in landscape a wide side inset is a notch or an
  Android 3-button bar and those windows are compact wide after I28 anyway;
- `stripInset = max(padding.left, padding.right) >= 48` (44 pt target + 2 pt each
  side). Ordinary phones in portrait have 0 side insets; Android gesture/3-button
  bars are at the bottom in portrait;
- `height - padding.bottom >= kSideStripStatusReserve + pillHeight + miniPlayerHeight + 16`
  (168 + 216 + 64 + 16 = 464; the folded Duo has 644).

**Side: the physical side with the inset**, not the text direction: the strip is
hardware, an RTL locale does not move it. (The app is English-only, so RTL is
covered by a composition test, as I27b did.)

Use `viewPadding` for the inset test as in I28 (keyboard-stable).

### Design (stay in the bottom-nav branch)

`sideStripNav` has `useRailNavigation == false`, so `bottomNavLayout`
(`app_shell.dart:1025`) and `hasBottomNav` (`:1522`) stay true and everything in
that branch is reused unchanged: the I27b `SafeArea` + `ConsumedRightInset`
(`:2015-2050`, so the alphabet rail keeps its 12 pt gutter), the full-width mini
player with `rightSystemInsetFor` (`app_shell_mini_player.dart:977`, still 84 here),
the `ExpandablePlayerSheet` and Now Playing (its own `SafeArea` clears the strip),
the queue overlay, back handling, the bar-flash seeding (`:1026-1033`).

New:
1. `desktop_layout.dart:62`: add `sideStripNav`; rule in `resolveAdaptiveShellMode`
   (phone branch, before returning `phoneBottomNav`); constants
   `kSideStripMinInset = 48`, `kSideStripStatusReserve = 168` next to :264-267.
   `AdaptiveContext` needs no new field (shell compares `adaptiveShellMode`).
   No `switch` over the enum exists in lib (grep); test helpers construct
   `AdaptiveContext` with explicit modes and are unaffected.
2. `app_shell.dart:2228`: `bottomNavigationBar: null` also for `sideStripNav`.
   `_BottomNavInsetScope(enabled: hasBottomNav)` then reports the system bottom
   (34) instead of bar + 34, so the page area and the sheet stop above the home
   indicator, and content gains the bar's 80 pt. Update the `_BottomNavInset` doc
   comment (`app_shell_support_widgets.dart:217`, "height of the bar") to "bar, or
   the system bottom inset when there is no bar".
3. `app_shell.dart` Stack, after the `_SlideUpPlayerTransition` (`:2068-2174`) and
   before the queue overlay (`:2175`): the pill, only in `sideStripNav`:
   `Positioned(top: viewPadding.top + kSideStripStatusReserve, right|left: 0,
   width: stripInset)`, child `_BottomNavReveal(progress: _playerSheetProgress,
   enabled: showPlayer, ...)` (reused: it fades/hides and ignores pointers while
   Now Playing opens), then `Center` → `Material` pill (`surfaceContainerHigh`,
   `StadiumBorder`), `SizedBox(width: min(56, stripInset - 8), height: 4 * 52 + 8)`,
   `Padding(vertical: 4)`, `_CompactIconRail(destinations: railDestinations,
   selectedIndex, onDestinationSelected)`. Reusing `_CompactIconRail` keeps the
   tooltips, semantics and the keys `compactRailNavTile-$i` that
   `DiagnosticsPresentationController.tapNavigationDestination`
   (`diagnostics_presentation_controller.dart:1120-1128`) already finds, so
   `/v1/presentation/tab` works with no change. Focus order: wrap in
   `FocusTraversalOrder(order: NumericFocusOrder(30))` like the sheet.
4. Mini player: keep the existing strip (simpler than a floating card; the pill sits
   high in the strip so they never meet). No change.

Not new: Now Playing, queue, alphabet rail, page insets, back navigation.

### Failing tests first

`desktop_layout_test.dart` (this flips I28's `466x678 (0/0/84/34) → phone bottom nav` row; update it): 466x678 0/0/84/34 → `sideStripNav`; 466x678 with
left 84 → `sideStripNav`; 466x678 with right 47 → `phoneBottomNav`; 393x852
(top 59, bottom 34) → `phoneBottomNav`; 375x667 → `phoneBottomNav`; 466x440 with
right 84 (too short) → `phoneBottomNav`; 669x951 (Duo unfolded) → `phoneBottomNav`;
951x669 strip → `standardRail`; 678x466 strip → `compactWideLandscape` (I28);
desktop 466x678 with right 84 → `standardRail`; keyboard open (padding.bottom 0,
viewPadding 34) → same result.

`foldable_layouts_test.dart`, group `I29` (viewport `_duoFolded` exists at :121):
1. no `NavigationBar`; four `compactRailNavTile-*`; each tile rect inside
   `x ∈ [382, 466]`, `top >= 168`, height `>= 44`, width `>= 44`.
2. tapping each tile switches the branch (go_router location); re-tapping Home scrolls
   to top (existing `homeScrollToTopRequestProvider` path).
3. geometry with playback: mini player strip bottom `== 678 - 34`; the page's
   scrollable bottom `<= 678 - 34 - 64`; with no playback, page bottom `== 644`.
4. Now Playing open: pill is hidden and not hittable (`IgnorePointer`); after collapse
   it returns. Queue overlay covers it.
5. alphabet rail still left of the strip with the 12 pt gap (existing A4/I27b tests
   keep passing; rerun in this mode).
6. fold/unfold: `_duoFolded` → `_duoPortrait` → `_duoLandscapeStrip` → `_duoFolded`
   with Library artists scrolled and Now Playing closed, then with it open: no
   exception, the selected tab and scroll offset kept (A2 pattern), the bottom bar
   appears unfolded with no one-frame flash over an open player (existing seeding).
7. left strip (`padding.left 84`): pill at `x ∈ [0, 84]`.
8. RTL composition test (pieces, as in I27b): right strip in RTL keeps the pill on the
   right.
9. Guards: `_phone`, `_phoneLandscape`, `_ipadSplitNarrow` keep `NavigationBar` or
   their rail.

### Edge cases

- Ordinary phones portrait/landscape (notch either side): no side inset ≥ 48 in
  portrait → bottom nav; landscape → I28 rules. Android 3-button nav in landscape
  (48 dp side bar) is landscape → excluded.
- iPad (all, including Slide Over/split): no side insets → unchanged.
- Desktop: early return → unchanged.
- Pixel Fold folded/unfolded: no side insets → unchanged.
- Duo: folded portrait → pill; folded rotated → compact wide (I28); unfolded
  portrait → bottom nav; unfolded landscape with strip → standard rail (I27b).
- RTL: physical side, see above.
- Large text: icons only; labels via tooltip/semantics; no layout change.
- Status-bar tap → scroll-to-top may fire on a strip tap (step 0 checks it). If it
  does, it is harmless for Home/Library but note it in the PR.
- VoiceOver: tiles are buttons with labels and `selected` (from `_CompactIconRail`).
- Back: iOS has no system back; edge-swipe back is on the left (content side);
  unchanged.
- Fold transitions: `StatefulNavigationShell` keeps its branch state across the
  branch swap (same as rotation today); covered by test 6.

### Risk

Risky (shell, input inside a system-owned region, platform uncertainty).
Sonnet `high` build after step 0 is recorded; fresh Sonnet `high` review.

### Runtime checks for the PR

1. Step 0 result recorded above.
2. Duo folded: tap each pill icon with `agent-device` (OS input), confirm the tab
   changes via screenshot; open/close Now Playing, queue; Library artists alphabet
   rail; Search with the keyboard up (pill stays, no mode flip).
3. Fold ↔ unfold with playback and with Now Playing open, screenshots per state.
4. iPhone 16 portrait/landscape: unchanged screenshots (bottom bar / compact wide).

---

## Owner questions

- **Q1 (I28), answered 2026-11-09:** no in-app volume slider.
- **Q2 (I29, only if step 0 fails):** pill inside the page beside the strip
  (content 60 pt narrower, 80 pt taller) or keep the bottom bar on the cover?
