# I27: foldables (iPhone Duo first, then Android foldables)

Issue [#410](https://github.com/Porthorion/Navis/issues/410). Owner request,
2026-11-09: support the iPhone Duo properly when unfolded, and reuse the work
for other foldables (Galaxy Z Fold, Pixel Fold).

## Evidence (2026-11-09)

- **iPhone Duo simulator** (Xcode 27 / iOS 27.2, `iPhone19,4`, 3x). Measured
  in a runtime pass:
  - **Folded cover:** 466x678 pt, full screen, padding LTRB 0/0/84/34. iOS puts
    its status bar in an **84 pt strip on the right edge**. `displayFeatures`
    is empty.
  - **Unfolded:** 669x951 pt (from the device profile). It can't be measured
    yet: the simulator can't be folded from scripts, because DeviceHub needs
    Accessibility and Screen Recording grants.
- **Widget-test renders** of the full app at 466x678, 669x951 and 951x669
  (local only, `build/foldables-i27/renders/`, gitignored):
  - Fold changes keep the route, the Now Playing sheet, the queue and typed
    search text. **The list scroll offset resets to 0.**
- **Shell modes today** (`resolveAdaptiveShellMode`,
  `lib/src/routing/desktop_layout.dart`):

  | Screen | Layout | Navigation |
  |---|---|---|
  | Folded | `phoneCompact` | bottom navigation |
  | Unfolded portrait | `tabletMedium` | bottom navigation |
  | Unfolded landscape | `tabletExpanded` | rail |

  These are sensible and stay as they are.
- **Android, Pixel 9 Pro Fold emulator** (`Pixel_Fold_I27`, real server,
  before the fix):

  | State | Size | Layout |
  |---|---|---|
  | Unfolded | 851.7x882.9 dp | `tabletExpanded`, rail |
  | Folded | 443x994 dp | `phoneCompact` |

  - Unfolded reports a `fold` feature (`postureFlat`), vertical at x=425.8 dp.
  - A fold keeps the route and playback, but the artists scroll position reset
    from 1200 to 0 (A2).
  - The A1 exception appeared in the real app.
  - The unfolded album page showed only the cover (B1).
  - With a flat posture, grids run across the fold. That is acceptable, so
    there is no hinge handling.

## Defects found

Each one also affects tablets, iPads and rotation, not only foldables.

| # | Defect | Cause | Fix |
|---|---|---|---|
| A1 | Artist letter tracking in grid mode throws `RenderSliverToBoxAdapter is not a subtype of RenderBox?` on every scroll, at any size. The active letter never updates. | **Proven by reading the code.** The section `GlobalKey` is on the `SliverToBoxAdapter` (`library_screen.dart:2323`), so `findRenderObject()` returns a sliver, and the cast at :2380 throws. | Put the key on the box child (the `Padding`). `Scrollable.ensureVisible` at :2549 keeps working with a box context. |
| A2 | The scroll position is lost when the layout class changes (fold or unfold, tablet rotation across 600/840 dp). | **Likely, from reading the code; the first failing test proves it.** `tabletMode` (`library_screen.dart:605`) changes the widget tree, so the scroll view is recreated with offset 0. | `PageStorageKey`s on the library section scroll views (and Home, if the test shows the same thing), so a recreated scroll view restores its offset. No tree restructuring. |
| A3 | Now Playing in a short, wide pane (unfolded landscape: a 633x669 content pane next to the rail) cuts the pause button off and hides the action row. | **From the code (corrected after review).** The split layout needs a content width of at least 790 (`_resolveSplitMetrics`), so the pane gets the compact mode, embedded next to the rail (`wideEmbeddedMode`). Only the non-embedded compact path budgets height for the controls (`NowPlayingPhoneLayout.compute`). The embedded compact path and the standard path size the art as `min(width, height x 0.62 / 0.54)`, with no room reserved for the controls (`now_playing_screen.dart:2222-2244`). | Give the embedded compact and standard paths the same height budget, reusing `NowPlayingPhoneLayout`'s reservations. The phone and split paths don't change. |
| A4 | On the Duo cover, the artist alphabet rail, the mini player's heart button and the Playlists FAB sit under the 84 pt right system strip. Page bodies already avoid it. | Those widgets ignore the right padding. | Respect `MediaQuery.paddingOf(context).right` there. The background still extends edge to edge. |

## Foldable/tablet tuning

Owner decision, 2026-11-09: A1–A4 and B1 all ship in **1.5.2**.

- **B1, album detail:** at 669x951 the cover hero is about 500 pt tall, and no
  songs show above the mini player. In landscape the cover fills the pane.
  Cap the hero height on tablet layouts (about 45% of the viewport height) so
  the first songs are visible. Phone layouts don't change.
- **B2, Now Playing in unfolded portrait:** the artwork is 572 pt, which
  pushes the controls to the bottom edge. The A3 height bound covers this
  too. Verify it at 669x951.
- **Hinge (Android only):** when the Pixel Fold run reports a vertical hinge
  in `displayFeatures`, check that no single control straddles it. Act only if
  the run shows one does.
- **Not changing:** artist avatar size, which is by design in
  `ContentLayout.artists`; list widths in Search, Playlists and Settings,
  which are readable at 669 pt; the shell-mode thresholds.

## Build (Sonnet, from this plan)

- **Reuse:** `resolveAdaptiveContextFor`, `ContentLayout`, the existing Now
  Playing layout modes, and the `testNavisApp` harness. The survey's
  throwaway test, kept locally at
  `build/foldables-i27/zz_foldables_survey_test.dart.txt`, shows how to pump
  the full app at a size and change it.
- **Write the failing tests first:**
  - A1: drag the artists grid, then expect no exception and the active letter
    to change.
  - A2: pump at 466x678, scroll the artists list, change
    `tester.view.physicalSize` to 669x951, and expect the same offset.
  - A3/B2: at 951x669 with the rail and at 669x951, expect the transport and
    the action row to be fully on screen.
  - A4: at 466x678 with right padding 84, expect the rail, heart and FAB to
    sit inside the safe area.
  - B1: at 669x951, expect the first song row to be visible.
- **Edge cases:**
  - The phone layout at 360–430 dp doesn't change. Add a regression test at
    393x852.
  - The desktop shell is untouched.
  - Text scale 1.3.
  - Landscape phones (`compactWideLandscape`).
  - The iPad split view at 507 and 678 pt widths.
- **Branch:** these files are shared by all platforms. A1–A4 go to
  `release/1.5` (a 1.5.2 fix for tablets everywhere) and are then forwarded to
  `dev`. Check the other machine's open PRs first. B1 goes with them (owner,
  2026-11-09).
- **Risk:** low (UI). One Sonnet review, focused tests, then CI.
- **Runtime check:** the Duo simulator in both states once fold control works,
  and the Pixel Fold emulator.

## Outcome

Merged to `release/1.5` on 2026-11-09 as #416 (`5ba4df7b`), after a fresh
Sonnet review with one fix round:
- Positioned lists restore by index, not pixels, so a rail jump survives a
  fold. Genres resets to the top.
- The embedded Now Playing keeps its label and metadata fallback. Only the
  cover size comes from the height budget.
- The Radio button stays out of the right system strip.

Follow-ups, tracked on #410:
- the non-embedded standard Now Playing (iPad portrait) cover still sizes as
  `height x 0.54`;
- phone landscape 844x390 has a 6 px overflow, which predates #416;
- the unfolded check on the real Duo simulator.
