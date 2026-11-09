# I27b: foldables round 2 (iPhone Duo)

Follow-up to [I27](I27_Foldables_Plan.md) (#416, issue #410). The first runtime
pass on the iPhone Duo simulator found seven more defects. Round 2 keeps the
fixes at the shared level instead of per screen.

## Round 2 (I27b)

| # | Defect | Cause | Fix |
|---|---|---|---|
| D1 | Library, Radio, Search and Album detail run under the right system strip (84 pt on the folded cover and in unfolded landscape) | Neither shell branch applied horizontal safe padding; only pages that wrap themselves in `SafeArea` (Home, Settings) were clear, and scroll views do not consume cross-axis padding | One `SafeArea(top: false, bottom: false)` around the page content in the bottom-navigation branch and the standard rail branch of `app_shell.dart`. The player sheet and bottom bar sit outside it and still run edge to edge. Compact wide keeps its `Padding` |
| D2 | Unfolded landscape rail is 354 pt wide instead of 270 | The rail's own `SafeArea` padded its left side by the right status strip | Rail `SafeArea` takes no left or right inset; the Row owns it (D1), so a right-side rail works in RTL too. The 240 minimum rail width is unchanged |
| D3 | The collapsed Now Playing overlay paints into the 34 pt band under the rail pane | It is slid off screen by an `AnimatedSlide`, a paint transform the `Stack` does not clip | `ClipRect` around the overlay |
| D4 | Library tab labels are clipped beside the rail ("Albums") | The fit test used the whole screen width and the sum of the label widths, but a non-scrollable `TabBar` gives every tab an equal share, so the widest label decides | `LayoutBuilder` supplies the page's width; the bar scrolls when `(widest label + padding) * tabs` exceeds it |
| D5 | Search Top Result is cramped: the title wraps ("Lov/e") and the tiles stretch | Tablet Search passes `desktopMode`, which forced the three-across row even in a 509 dp section | The row needs `desktopMode` and a section at least 560 dp wide (`_rowLayoutMinWidth`); narrower uses the hero-over-tiles column |
| D6 | Folded album title runs past the strip; unfolded Play button sits 4 dp from the pane edge | The hero was sized from `MediaQuery` width (466, not the 382 page); the action row used a 4 dp left inset | Hero from a `LayoutBuilder` width; the action row's left inset is 16 off phones, 4 on phones (their row is full) |
| D7 | `markNeedsBuild` during build when folding with Now Playing open | `ExpandablePlayerSheet.initState` added the progress listener before setting an expanded start value, so the parent's notifier fired during build | Set the start value first, then add the listener; the existing post-frame callback reports it |

D5 widths measured in the foldable tests (Top Results section content): Duo
landscape with the strip 509 dp, Duo landscape 593, iPad 1024 666, iPad 1180
797, narrowest desktop window (800) 671, desktop 1280 995. 560 sits 51 dp above
the first and 33 dp below the second.

Visible trade-off of D1: page backgrounds, the album hero and the rail-mode
Now Playing overlay now stop at the status strip (the shell background shows
there). The mini player strip and the bottom bar still run edge to edge.

Tests (`test/src/routing/foldable_layouts_test.dart`, group `I27b`, plus
`test/src/common_widgets/expandable_player_sheet_test.dart` for D7): every
screen at the Duo cover stays left of the strip; the rail is 270 wide in
unfolded landscape with the strip (`_duoLandscapeStrip`, 951x669, padding
0/0/84/34); the overlay is clipped to the pane; tabs are unclipped at six
sizes and at text scale 1.6; Top Results at 509, 593, 666 and 671 dp; album
title, hero and Play inset; folding with Now Playing open does not throw.

Not changed: the compact-wide `Padding` path, round-1 `rightSystemInsetFor`
calls (they return 0 under the shell now), the shell-mode thresholds, the
desktop sidebar widths, and the double inset in compact-wide Now Playing
(`now_playing_screen.dart`, follow-up on #410).

## Review fixes

A fresh review and the Duo runtime pass confirmed D1–D7. Follow-up commit:

- **Play inset in RTL:** the album action row uses
  `EdgeInsetsDirectional.fromSTEB`, so an RTL tablet insets the Play side.
  Test: `library_detail_screens_test.dart`, LTR and RTL.
- **Rail beside a left notch:** the outer `SafeArea` around the Row padded the
  rail too, so the shell background showed left of it. The rail's own
  `SafeArea` now takes its leading side only, and the pane's takes the pane
  side only, so the rail background reaches the screen edge and a right strip
  still adds nothing to the rail (270). RTL swaps the sides. The full app only
  has an English locale, so the RTL shell is not covered by a test.
- **Bar flash:** on entering the bottom-navigation layout the shell seeds
  `_playerSheetProgress` (1 with an open player, 0 otherwise) before the bar's
  reveal mounts, so the bar is off screen on the first frame. Nothing listens
  at that point, so it does not mark anything dirty during build.
- **Alphabet rail gutter:** on the folded cover the rail ended flush with the
  status strip. `SafeArea` removes the inset from `padding` and `viewPadding`,
  so nothing in `MediaQuery` tells a page it sits beside one. The shell now
  provides `ConsumedRightInset` (in `desktop_layout.dart`) around the page area
  and the rail adds the 12 dp page margin as a gap when it is set. Ordinary
  phones and the compact wide shell see no inset and keep the rail where it
  was. The Playlists and Radio buttons (16 dp margin) and the sort control
  already leave more than 12 dp, so they are unchanged (guarded by a test).
- **Tests tightened:** each D1 test now measures a widget that ran under the
  strip on the original code (artist heart buttons and rows, playlist rows,
  album cards, the Liked strip) and fails there; the D4 text scale and D5
  593/666/671 dp cases are labelled regression guards.
