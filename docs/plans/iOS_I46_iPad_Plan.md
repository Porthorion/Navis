# I46 iPad compatibility (1.5.2)

Status: planned (Opus, 2026-11-10, dev at 394647387). One Sonnet phase.
Risk: low (UI layout). Gates: build, focused tests, one Sonnet review, CI.

Evidence: portrait simulator passes with app-owned screenshots, zero
overflow/exception lines in the logs.

- iPad Pro 13 (1032x1376): `build/ipad/run-20261110T183919Z/`
- iPad mini (756x1158): `build/ipad/run-20261110T184535Z/`

## 1. Now Playing cover collapses to 48 px on the iPad Pro (bug, fix)

### Proven cause

1. Shell branch. `resolveAdaptiveShellMode`
   (`lib/src/routing/desktop_layout.dart:326-333`): shortest side 1032 >= 600
   is a tablet, and width 1032 >= `kAdaptiveExpandedWidth` (840) gives
   `standardRail`. The rail is `(1032*0.25).clamp(270, 360)` = 270
   (`lib/src/routing/app_shell.dart:1123-1129`). The rail branch hosts Now
   Playing as `NowPlayingScreen(wideEmbeddedMode: true)`
   (`app_shell.dart:2014-2016`), in a 762 px pane. The iPad mini is 756 wide,
   below 840, so it gets `phoneBottomNav` and the full-width sheet
   (`app_shell.dart:2200`).
2. Layout mode. `_resolveLayoutMode` (`now_playing_screen.dart:1068-1076`):
   762 >= 760 is `standard`. `phoneLayout` is null because the pane is
   embedded and not compact (`now_playing_screen.dart:2238-2249`).
3. Unsized cover. The standard path places the art as
   `SizedBox(height: artRegionHeight, child: Center(child: artOrLyrics))`
   (`now_playing_screen.dart:2563-2581`). `artOrLyrics` contains
   `buildCurrentArt(artMaxSize)` (`now_playing_screen.dart:1742-1753`), and that
   ignores its size argument for song covers: it returns `_CoverArt`, which
   builds `CoverArtImage(size: kCoverArtStandardSize)` with no width or height
   (`now_playing_metadata_panel.dart:16-26`). `size` is only the decode size
   (600, `cover_art_cache_manager.dart:34`). Under `Center`'s loose constraints
   the `Image`/`OctoImage` (`cover_art_image.dart:574-580`, `656-660`) paints
   at the image's intrinsic size. The fixture cover is a 48 px PNG
   (`tool/auth_lifecycle_fixture_server.py:49`, `_cover_png(size=48)`), so the
   cover is 48 px. The phone path is the only one that wraps the art in
   `SizedBox.square(dimension: artSize)` (`now_playing_screen.dart:2348-2353`,
   `2551-2555`). That is why the mini fills its width.
4. History. `_CoverArt` has never used its size: the old `maxSize` branch
   built the same widget (`git log -L` on `_CoverArt`, 15e1da2ba, removed in
   4b177b03f).

### Scope: a shared-widget bug that iPads expose

All three non-phone layouts pass the unsized `buildCurrentArt`:
standard/compact embedded (`:2348`), split (`:2660-2671`, also ignores
`splitCoverArtMaxSize`) and compact-wide (`:1934-1938`). Real servers mostly
hide the bug, because a 600 px decoded cover is larger than most slots, so
the slot constrains it. It shows when the slot is larger than the cover
(iPad 13 portrait slot ~734 px: even a real 600 px cover is undersized) or
when the server returns small covers.

- macOS/Windows/Linux desktop workspace: not affected. The desktop shell
  never hosts `NowPlayingScreen` (`app_shell.dart:1709-1710` builds a
  `SizedBox.shrink`; the workspace has its own player bar). The desktop Mini
  Player hosts it in compact-wide mode
  (`app_shell_desktop_mini_player.dart:67-70`), so it has the same latent
  bug, masked by its 180-380 px slot.
- Android tablets and phone landscape are affected by the same code. Not
  iOS-only.

### iPad sizes and the branch each one hits (portrait, landscape)

| Device (logical) | Shell | Now Playing host width | Mode | Cover today |
|---|---|---|---|---|
| 13" 1032x1376 | standardRail (270) | 762 embedded | standard | unsized (bug) |
| 13" 1376x1032 | standardRail (344) | 1032 embedded | split | unsized (bug) |
| 11" 834x1194 (and 10th gen 820) | phoneBottomNav | 834 sheet | standard, not embedded | unsized (bug) |
| 11" 1194x834 | standardRail (298) | 895 embedded | standard | unsized (bug) |
| mini 756x1158 / 744x1133 | phoneBottomNav | 756 sheet | compact, phone layout | OK |
| mini 1158x756 / 1133x744 | standardRail (~290) | ~868 embedded | standard | unsized (bug) |
| Split View 2/3 of 13" landscape ~981x1032 | standardRail (270) | ~711 embedded | compact, embedded (no phone layout) | unsized (bug) |
| Split View 1/2 ~678x1024, 1/3 or Slide Over 320-375 | phoneBottomNav | sheet | compact, phone layout | OK |

### Fix (one place, every caller)

In `buildCurrentArt` (`now_playing_screen.dart:1742`), size the song cover to
the largest square that fits both the given maximum and the slot:

```dart
Widget squareArt(double maxSize, Widget child) => ConstrainedBox(
  constraints: BoxConstraints.loose(Size.square(maxSize)),
  child: AspectRatio(aspectRatio: 1, child: child),
);
```

Wrap both `_CoverArt` branches. `_RadioCoverArt` already sizes itself. Use
`AspectRatio` with a loose cap, not `SizedBox.square(maxSize)`: in the
standard path `artRegionHeight` can be smaller than `artMaxSize`
(`:2304-2329`), and a fixed square would come out non-square. The phone path's
outer `SizedBox.square` stays as it is; it is tight, so the inner wrapper does
nothing there. In split, the cap is `splitCoverArtMaxSize` (170-340), which
also fixes split ignoring its own cap. Do not change `CoverArtImage` or
`_CoverArt`'s public shape; other callers rely on intrinsic/filled sizing.

## 2. "Could Not Load This Album" (wrong script id, not an app bug)

The fixture has exactly one album, id `fixture-album`
(`tool/auth_lifecycle_fixture_server.py:84`; `ALL_ALBUMS = [ALBUM]` at `:113`,
and the downloads scenario keeps the id at `:194-197`). `getAlbum` answers any
other id with Subsonic error 70 "Album not found" (`:580-586`). The app shows
its correct error state. `fixture-album-1` only exists in a Dart unit test
(`test/src/features/player/integration/auth_to_playback_test.dart:115`).

Script fix (untracked `build/ipad/run_ipad.sh`, `screens()` route list):

```bash
sed -i '' 's#/library/albums/fixture-album-1#/library/albums/fixture-album#' build/ipad/run_ipad.sh
```

Also fix `build/ipad/analyze_ipad.py:25-26`. The screenshot records carry
`logicalWidth`, `logicalHeight` and `artifact`, not `width`, `height` and
`path`, which is why every line printed `SHOT None: NonexNone portrait`:

```python
w, h = s.get("logicalWidth"), s.get("logicalHeight")
print(f"SHOT {s.get('artifact')}: {w}x{h} {'landscape' if (w or 0) > (h or 0) else 'portrait'}")
```

## 3. Other screenshots (13" and mini portrait): nothing blocking

Checked: home, library, search, settings, playback, appearance, equalizer,
about, server, queue.

- No overflow, clipping or cramped rows. Content panes are 762 px (13") and
  756 px (mini). Settings pages cap at 1040
  (`playback_settings_screen.dart:156-157`,
  `appearance_settings_screen.dart:214-215`), the same as a desktop window.
  Search caps by layout class (`search_screen.dart:305`, `378`). Line lengths
  are fine in portrait. In 13" landscape the settings pane is about 1032 wide:
  switch rows span the pane, the same as macOS at 1300 px. Accepted, no
  change.
- Touch targets: rail tiles are 64 px tall and library sub-tiles 44 px
  (`app_shell_navigation_widgets.dart:259-266`). The rail mini player's
  buttons are at least 46x46 (`app_shell_mini_player.dart:273-276`). All are
  at least 44 pt (Apple HIG). Desktop-only 32 px buttons (history arrows,
  auto-hide lock) are not built on tablets.
- 13" portrait Now Playing has a large empty area. That is the collapsed
  cover from item 1, not separate spacing.
- Album detail is unverified on iPad until the item 2 re-run.
  `album_detail_screen.dart:647` switches to two columns from a 900 px pane,
  which 13" landscape (1032) will hit.

## 4. Landscape, orientation and multitasking config

- `ios/Runner/Info.plist:81-87`: `UISupportedInterfaceOrientations~ipad`
  lists all four orientations, and `UIRequiresFullScreen` is absent.
  `lib/main.dart:503-507` allows all four. iPadOS therefore enables Split
  View, Slide Over and Stage Manager, so windows from 320 px wide up to full
  screen will happen. `UIApplicationSupportsMultipleScenes` is false
  (`Info.plist:42-43`), so there is one window; that is fine. No plist change
  is needed. Keep multitasking (an audio app benefits).
- Every iPad size resolves through `resolveAdaptiveShellMode` with no
  iPad-specific branch. The table above lists what each size hits. A narrow
  Split View window (shortest side < 600) is a phone (`phoneBottomNav`),
  which the phone layout handles. A tall window 600-839 wide is a medium
  tablet with the bottom bar.
- Landscape (and Split View 2/3) only adds the item 1 bug (split, standard
  and embedded-compact panes). The fix covers it.

## Builder phase (one Sonnet brief, about 40 tool calls)

Reuse: `setAdaptiveTestViewport`, `_pumpNowPlaying` and `_songPlayback` in
`test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`
(`:94-140`, `:360-398`); the I28 matrix in
`test/src/routing/desktop_layout_test.dart:65-115`; and the stored-cover
override pattern from `test/src/common_widgets/cover_art_image_test.dart:261-286`
(`subsonicApiProvider` null plus `permanentArtworkStoreProvider` serving a
PNG file).

### Tests first (must fail on dev before the fix)

In `now_playing_screen_adaptive_test.dart`, add a group "I46 tablet cover
fills a square slot", one test per case, with
`(name, viewport, wideEmbeddedMode)`:

- 13" portrait rail pane `Size(762, 1376)`, embedded (standard)
- 13" landscape rail pane `Size(1032, 1032)`, embedded (split)
- mini landscape rail pane `Size(868, 756)`, embedded (standard, compact height)
- 11" portrait sheet `Size(834, 1194)`, not embedded (standard)
- Split View 2/3 pane `Size(711, 1032)`, embedded (compact, no phone layout)
- Slide Over `Size(320, 1032)`, not embedded (phone layout; regression guard,
  passes today)
- compact-wide `Size(560, 360)`, `compactWideLandscapeMode: true` (desktop
  Mini Player)

Assert on the `CoverArtImage` with `shape == ArtworkShapeRole.nowPlaying`:
its `RenderBox` is square (`width` closeTo `height`, 0.5) and at least 0.9 of
the slot's shorter side, where the slot is the art region the layout computes.
Simpler bound: at least 160 px in every case. Today the placeholder fills
`Center`'s loose box, so it is non-square in standard and split, and the
square assertion fails.

Plus one real-image test at `Size(762, 1376)` embedded. Serve the song's
cover from a stored 48x48 PNG through the `permanentArtworkStoreProvider`
override with the API null. Expect the painted cover to be larger than 300
px, not 48. This test reproduces the screenshot symptom.

Characterization (passes today, pins the shell choice): add rows to the I28
matrix in `desktop_layout_test.dart`:
`(1032,1376) rail`, `(1376,1032) rail`, `(1024,1366) rail`,
`(834,1194) bottomNav`, `(1194,834) rail`, `(820,1180) bottomNav`,
`(756,1158) bottomNav`, `(1158,756) rail`, `(744,1133) bottomNav`,
`(1133,744) rail`, `(981,1032) rail`, `(678,1024) bottomNav`,
`(507,1032) bottomNav`, `(320,1376) bottomNav`. Use `EdgeInsets.zero`;
iPads have no side insets.

### Change

`buildCurrentArt` in `now_playing_screen.dart` only (item 1 fix). Then
re-measure the existing tests at `:360-398` (`embedded compact/standard/focus
player cover`). If the expected heights move, update the numbers and say in
the commit body that the cover is now square-capped. Keep the assertion that
the tablet cover is not taller than the desktop one in those cases.

### Edge cases

- `artRegionHeight` < `artMaxSize` (short panes such as `Size(840, 400)`, the
  focus player): the cover must stay square, within the region.
- Inline lyrics toggled: `PlaybackLyricsContent(maxSize:)` is unchanged.
- Radio (`_RadioCoverArt`) and no-cover placeholder: the placeholder must be
  square too. The wrapper applies to the null-id `_CoverArt` branch as well.
- Swipe and tap on the art: the gesture area shrinks from the full region to
  the cover. Check that the swipe test (`:1489`) still passes. A tap on the
  empty region no longer toggles play, and the phone path already behaves
  that way.
- Song-change `AnimatedSwitcher` (`_coverArtSwitcherLayoutBuilder`, a Stack
  centred): the outgoing and incoming covers are the same size, so there is
  no jump.
- Art Shape circle: the circle needs a square box, which the wrapper now
  guarantees.
- Text scale 2.0 at `Size(868, 756)`: no overflow (run the existing
  text-scale tests).

### Docs and changelog

- Add a 1.5.2 entry in `lib/src/features/changelog/changelog_data.dart`
  (`:201`), with no `platforms` restriction (Android tablets are affected
  too). Example: "The Now Playing cover fills its space on tablets, in
  landscape and in split-screen windows."
- Add a line in `docs/project/progress.md` at PR time. No architecture doc
  change.

### Validation

1. `flutter test test/src/features/player/presentation/now_playing_screen_adaptive_test.dart test/src/routing/desktop_layout_test.dart`
2. `./tool/check.sh` (under the heavy lock).
3. Runtime: re-run `build/ipad/run_ipad.sh` on the iPad Pro 13 and mini with
   the item 2 fixes. Expect a full-size cover in
   `…-portrait-nowplaying.png`, the album page with the Lifecycle Album
   tracks, and real `SHOT` sizes in `analysis.txt`. Landscape stays covered by
   the widget tests: Xcode 27 has no Simulator.app, so rotation cannot be
   scripted.

## Open questions (owner)

1. Should 11" and 10th-gen iPads in portrait (834/820 wide, just under the
   840 rail breakpoint) keep the bottom bar, as Android 800 dp tablets do, or
   get the side rail? Default: keep the bottom bar. Changing the breakpoint
   is a separate design item.
2. Is the desktop Mini Player's compact-wide cover now sized to its slot (up
   to 380 px), with no visible change for normal 600 px covers? This is
   expected, so no owner action is needed unless they object.
