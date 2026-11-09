# Follow-ups F1–F4 (from the I28/I29 runtime passes): implementation plan

Planner: Opus, 2026-11-09. Base: `origin/release/1.5` @ `a72aa135` (has I28 #443 and I29 #445).
Target: one PR on release/1.5 (1.5.2), then forward to dev as usual.
Each cause below was proven on release/1.5 with a failing test, and each fix
made that test pass. The proof patches are in this folder:
- `proof-all.diff`: F1 + F3 + F4 lib changes plus the scratch `ZZ` tests in
  `foldable_layouts_test.dart`. Use it as a reference only. Rewrite it in
  project style; the inline `Builder` one-liners are not formatted.
- `proof-f1-guard.diff`: the F1 Search height guard (second half of F1).
- `proof-all.diff` excludes the F2 lib change and the F1 guard.
- `f2_repro_test.dart`: the F2 repro (fails on release/1.5, passes with the fix below).

Builder: Sonnet, test-first. Machine rules: every flutter command goes through
`lockf ~/.cache/claude-navis-logs/heavy.lock …`, focused `flutter test -j 2` on
the touched test files only, foreground. Never run `./tool/check.sh` or the full
suite locally; full checks run in CI or when the coordinator schedules them.

Known pre-existing failures on clean release/1.5 (not ours; do not "fix"):
`test/src/features/search/search_top_results_test.dart` and
`desktop_search_workspace_preview_golden_test.dart` fail 28 tests on this Mac.

---

## F2: Search throws "Ref used after dispose" while typing (risk: low)

**Cause (proven).** `debouncedSearchProvider` (`lib/src/features/search/presentation/search_controller_provider.dart:132`)
is an `autoDispose` StreamProvider that watches `searchQueryProvider`.
1. The query reads "lov". The 300 ms debounce elapses, and the build starts
   `await _searchLocal(...)` (line 148, a Drift query).
2. The user types "e". The provider rebuilds, and the old build's `Ref` is disposed.
3. `_searchLocal` returns, and the old build calls `ref.watch(showGenresPageProvider)`
   at **line 152**, which throws `UnmountedRefException`.

The runtime log `build/i28-runtime/se-flutter-run.log:2643-2652` shows the same
frame (`search_controller_provider.dart:152:42`). The timer gap is already safe:
`ref.onDispose(timer.cancel)` means the completer never completes. The Deezer
gap already has `if (!ref.mounted) return;` (around line 242). The two DB awaits
have no guard. The same race can hit after `searchGenres` (line 155), before
`ref.watch(subsonicApiProvider)` and `ref.onDispose(cancelToken.cancel)`.
dev does not differ from release/1.5 in this file.

**Fix.** Add `if (!ref.mounted) return;` in two places:
- right after the `localResult = _filterResultByType(rankSearchResult(await _searchLocal(...)))` statement;
- right after the `genres = ... : const <GenreSummary>[];` statement.

This reuses the pattern already in the same function at the Deezer await.
Don't add a cancel token or restructure; the Ref is the only thing used after
those gaps.

**Test first.** Add one test to `test/src/features/search/search_controller_provider_test.dart`
(port `f2_repro_test.dart`):
- `_GatedDb extends NavisDatabase` (in-memory `NativeDatabase.memory()`,
  `closeStreamsSynchronously: true`) overrides `late final LibraryDao libraryDao`
  with `_GatedDao`. `_GatedDao.searchArtistsLocal` awaits a `Completer` gate first.
- Reuse the file's `_createContainer(db, api: null)`, which already sets the
  reachability override and the binding. Run inside `runZonedGuarded`:
  listen to the provider, `submit('lov')`, wait 400 ms, `submit('love')`,
  complete the gate, wait 500 ms.
- Assert that the zone saw no errors. Without the fix it reports
  `UnmountedRefException`; with it, the test and the existing 21 tests pass (verified).

Edge cases: an empty query and offline/collection filters return before the
awaits, so they are unchanged. A newer query's build still emits normally.

---

## F1: Search overflows on short landscape phones with the keyboard up (risk: risky, shell inset)

**Cause (proven, not in Search).** In the compact wide shell with a player
showing, `app_shell.dart:~1835-1846` places the page area (`navigationShell`) in an
`AnimatedPositioned(bottom: isExpanded ? 0 : compactBottomMiniPlayerHeight)`.
On the iPhone SE that height is 90 (`app_shell.dart:1116`:
`(h*0.15).clamp(90,112)+inset`). The shell Scaffold does not resize for the keyboard
in compact wide (`resizeToAvoidBottomInset: !useCompactWideLandscape && …`, line 1576),
so Flutter leaves the **full** `viewInsets.bottom` in the page's MediaQuery.

The page's own Scaffold (Search) then subtracts the whole keyboard height,
although its bottom edge already sits 90 px above the screen bottom. Those
90 px count twice. Device numbers: 375 - 205 keyboard = 170 px of real space,
but the Search body got 79 (Column 51 + 12/16 padding); 170 - 79 = 91, which is
this reserve. The Column needs ~114 px, so it overflows by 62–63 px.

Reproduced in a widget test: SE 667x375, playing, keyboard 205 gives
"RenderFlex overflowed by 62 pixels". With no player the same test passes;
that case is not affected. The phone and desktop Search branches have no
short-height pattern to reuse, and none is needed. Any compact-wide page that
reads viewInsets (text fields in Settings, sheets inside the branch) has the same
double count, so the shell is the right place to fix it.

**Fix (shell, one place).** Wrap `navigationShell` inside that `AnimatedPositioned`
with a MediaQuery whose `viewInsets.bottom` is
`max(0, viewInsets.bottom - reserve)`, where `reserve` is the same value as the
`bottom:` (0 when expanded). Write it as a small private widget in
`app_shell_support_widgets.dart` next to `_BottomNavInsetPadding` /
`SideInsetsConsumed`, for example `_ConsumedBottomInset({required double reserve, child})`.
It reads `MediaQuery.of(context)` and uses `copyWith(viewInsets: …)` (the
`removeViewInsets` API can only zero the inset). Use it once, not inline.

**Second half: a Search height guard (needed, proven).** With only the shell fix,
the **offline** case still overflows: the `_OfflineSearchBanner` adds ~32 px.
SE, keyboard 205: 4 px at x1.0, playing or idle, and 12 px at x1.3. This is true
of any short window, so in the `tabletMode` branch of `search_screen.dart` (~313)
wrap the Column in a `LayoutBuilder`:

`showFilters = hasQuery && constraints.maxHeight >= 200`

When it is false, drop the 10 px gap, `_SearchFilterChips` and
`_OfflineSearchBanner`; the search bar and results stay. This follows the
codebase's maxHeight-threshold pattern (`now_playing_screen.dart:2197`,
`app_shell_mini_player.dart:688`). Name the constant, with a comment: header
~150 px plus a minimum results area.

Without the keyboard, SE landscape has ~257 px, so the chips still show. With
the shell fix and the guard, SE offline and online, playing and idle, at x1.0
and x1.3, all pass (verified). The other foldable and search_screen tests are
green, except the I29 test updated under F3.

The phone and desktop branches are out of scope. Desktop has no soft keyboard;
the phone branch is portrait-tall.

**Test first.** Add to `test/src/routing/foldable_layouts_test.dart`, in a new
group or next to the I28 compact-wide tests:
`_pumpApp(tester, _phoneSE, playback: _playing/null, textScale: 1/1.3, extraOverrides: _searchOverrides())`,
`_go(search)`, `submit('love')`, settle. Then
`tester.view.viewInsets = FakeViewPadding(bottom: 205*3)` with
`addTearDown(tester.view.resetViewInsets)`, pump, settle 10.
Assert `takeException()` is null and the `TextField` is found. Playing at
x1.0 fails before the fix (62 px overflow).
Add an **offline** variant (`searchIsOfflineProvider.overrideWithValue(true)`)
for the guard: it fails with only the shell fix (4/12 px). Also assert the chips
are visible again after `resetViewInsets`.

Edge cases:
- The reserve animates over 280 ms. The inset steps once (no per-frame
  rebuild needed); the page settles with it.
- While expanded the reserve is 0, so the full player behaviour is unchanged.
- Car displays (`compactMiniPlayerBottomInset` > 0): the reserve already
  includes it, so subtracting it is correct.
- No keyboard: max(0, 0 - r) = 0, no change.
- Dialogs and sheets on the root navigator sit outside `navigationShell` and
  are unaffected.

Risk: shell MediaQuery change, so it is classed risky. Keep the change minimal.
The review should cover compact-wide pages with text fields.

---

## F3: Duo folded cover keyboard: mini player runs over the side-strip pill, keyboard clips it (risk: low)

**Cause (proven).** In `sideStripNav` the shell does resize for the keyboard (it is
not compact wide), as every bottom-nav shell does. The body Stack shrinks to the
keyboard top, and the mini player sheet in that Stack rides above the keyboard.
On phones the `NavigationBar` is `Scaffold.bottomNavigationBar`; the Scaffold
keeps it at the screen bottom, where the keyboard **covers it**.

The I29 pill instead is a `Positioned(top: viewPadding.top + 168)` child of the
same body Stack (`app_shell.dart:~2187-2225`), 216 px tall, so it ends at
384 pt. Duo keyboard ≈ 303 pt (screenshot 18), so the keyboard top is ≈ 375 and
the mini player band covers ≈ 311–375. The pill overlaps both.

Widget repro: `_duoFolded` with keyboard 303 puts the last pill tile's bottom at
380, past the mini player top (311, playing) and past the keyboard top (375,
idle). It fails in both cases.

**Rule: hide the pill while the shrunk body can't hold pill + mini player.**
This matches the bottom bar: on phones the keyboard covers the bar and the mini
player rides above it. Here the pill goes away while typing and comes back when
the keyboard closes. The other option, keeping the pill and moving the mini
player under the keyboard, would need a non-resizing shell, which brings back
the F1 double count. It also differs from every other bottom-nav shell, and it
is more code.

**Fix.** Turn the pill's `Positioned(...)` into
`Positioned.fill(child: LayoutBuilder(...))`. `constraints.maxHeight` is the body
height, already shrunk by the keyboard. Read the height there, not
`MediaQuery.viewInsets`: the shell Scaffold strips the insets from its body,
and reading them at shell level would rebuild the whole shell on every keyboard
frame. Return `SizedBox.shrink()` when

`viewPadding.top + kSideStripStatusReserve + kSideStripPillHeight > maxHeight - (showPlayer ? ExpandablePlayerSheet.miniPlayerHeight : 0)`.

Otherwise `Align(topRight/topLeft by stripOnRight)` → `Padding(top: pillTop)` →
`SizedBox(width: sideStripInset)` → the existing `FocusTraversalOrder` / `_BottomNavReveal`
/ pill subtree, unchanged. Don't duplicate the pill. `Align` only hit-tests its
child, so the fill area doesn't eat taps (the I29 tap tests check this).

Optional, only if the builder finds it trivial: wrap it in the existing
`_BottomNavReveal`-style fade. A plain hide is fine, because the keyboard
animation crosses the threshold at the moment of overlap.

**Tests.**
- New, in the `foldable_layouts_test.dart` I29 group: `_duoFolded`, playing and
  idle, `_go(search)`. First assert `compactRailNavTile-3` is present. Then set
  `view.padding = FakeViewPadding(right: 84*3)` and `viewInsets bottom 303*3`.
  Assert no exception and that the pill tiles are gone (or, if present, end at or
  above `678 - 303 - (playing ? 64 : 0)`). Both cases fail before the fix.
- **Update the existing** I29 test `the keyboard keeps the pill just at the fit (viewPadding decides)`.
  It used pill presence under a 250 keyboard to show the mode didn't flip; the
  pill is now hidden there by design. Keep its intent: assert
  `find.byType(NavigationBar)` findsNothing for the pill row (mode kept) and
  `tile(0)` findsNothing under the keyboard. After closing the keyboard
  (`resetViewInsets`, restore padding), `tile(0)` findsOne again. With this
  plan's patch applied, all other `foldable_layouts_test.dart` tests pass
  (148/149, verified).

Edge cases: no player, landscape strip (the pill is portrait only), a hardware
keyboard with a small inset bar (the pill stays when it fits; that is why this
is geometric, not `viewInsets > 0`), and the player sheet expanding (the existing
`_BottomNavReveal` is unchanged).

---

## F4: Duo unfold on Library > Artists (grid): rail highlights the wrong letter (risk: low)

**Findings.** The artist **grid** (`_buildArtistsGrid`, `library_screen.dart:~2343`)
is a `CustomScrollView` with `_artistsGridScrollController` +
`PageStorageKey('library-artists-grid')`. It keeps its **pixel offset** across a
layout change. That is the deliberate contract: I28/I29 test
`library $name keeps its offset across a fold` asserts it for the albums,
artists grid, liked and playlists grids. Folded is 3 columns and unfolded
(951x669) is 5, so the same offset shows later artists ("Wi…"). Refolding
restores the same pixels, so "M" again. This content shift is the shared
behaviour of every grid tab and predates I29 (rotation or window resize does the
same). Not changed here.

The real defect is the rail. `_onArtistsGridScrolled` (around line 2398) picks
the last section header with `box.localToGlobal(Offset.zero).dy <= 140`: a
**global screen y with a hardcoded 140**. On the Duo the grid viewport starts at
y≈184 under the Library header, tabs, banner and filters, so the highlight lags
behind the top of the grid. It runs only as a ScrollController listener, so a
relayout without a scroll (fold/unfold, column count, banner dismissed) never
recomputes it. That is how "Wi…" ended up shown under "M".

Widget repro: `_duoFolded`, grid, drag 4x300. The rail says **J** while the top
card is **N**, already wrong without any unfold. The list mode
(`_onArtistsViewportChanged`) already derives the letter from the actual first
visible item and is fine.

**Fix (two lines of logic).**
1. Measure relative to the grid's viewport:
   `box.localToGlobal(Offset.zero, ancestor: _artistsGridScrollController.position.context.notificationContext?.findRenderObject())`.
   A section is active when its header top is `<= 48`: under one grid row, so at
   most a partial row of the previous section shows above it. 0 would pick the
   previous letter while the next header sits 34 px down with only padding above it.
   Name the constant, with a one-line comment.
2. Recompute on layout changes: wrap the `CustomScrollView` in
   `NotificationListener<ScrollMetricsNotification>(onNotification: (_) { _onArtistsGridScrolled(); return false; })`.
   It is dispatched post-frame, so `setState` is safe. This also fixes the last
   value after a drag settles.

Verified: rail and top card agree (N/N) folded and after resize to `_duoLandscapeStrip`.

**Test.** Add to the `A1 artist letter tracking` group in `foldable_layouts_test.dart`.
Seed **enough artists that 3→5 columns moves the content by at least one
letter**; the current `_seed` doesn't, so add ~10 artists per letter A–Z via
`ArtistsTableCompanion` for this test. Then: `_duoFolded`, grid, `_go(artists)`,
drag to mid-list, and assert active letter == `topCardLetter()` (the first
hit-testable `ArtistCard` whose bottom is >40 px below the grid top; take the
initial of `artist.name`, mapping non-letters to '#'). Then `_resize(_duoLandscapeStrip)`
and assert the same equality. Also confirm that the existing
`scrolling the artist grid moves the active letter`,
`tapping a letter on the rail still scrolls the grid there` and
`keeps its offset across a fold` still pass.

Edge cases: empty sections, only '#', rail scrubbing (the guard
`_isArtistRailScrubbing` stays first), a section key not mounted (skip as today),
and RTL (vertical only).

---

## One PR?

Yes, all four go in one PR on release/1.5 (`fix:` squash title, e.g.
"fix(layout): keyboard and fold follow-ups from I28/I29 runtime"). Files:
- `search_controller_provider.dart` (F2)
- `app_shell.dart` (F1 at ~1840, F3 at ~2190; separate blocks, one builder, so no conflict)
- `app_shell_support_widgets.dart` (F1 helper)
- `library_screen.dart` (F4)
- tests: `search_controller_provider_test.dart`, `foldable_layouts_test.dart`

dev differs from release/1.5 in `app_shell.dart` only in macOS hunks (imports,
~744, ~1445, ~2288), away from both blocks, so the forward merge should be clean.

Reviews (global rules): F1 is a shell-inset change, so a fresh Sonnet `high`
review plus runtime checks. The others are low risk.

Runtime checks for the PR:
- SE landscape, playing, Search with keyboard: no overflow in the log.
- Duo cover, Search with keyboard: no pill under the mini player; the pill
  returns on dismiss.
- Duo unfold on Artists grid: rail matches the top row.
- Typing "love" fast: no Unhandled Exception.

No owner question. The rules follow existing bottom-bar behaviour and the
existing offset contract.
