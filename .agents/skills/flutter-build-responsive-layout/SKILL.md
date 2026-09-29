---
name: flutter-build-responsive-layout
description: Build adaptive Navis UI that works across phone, tablet, desktop, and resizable windows using the repo's AdaptiveContext system. Use whenever adding or changing layout that must adapt to window size, shell mode, rail/bottom-nav composition, or form factors — even if the user just says "make it responsive" or "fix the desktop layout".
---

# Building Adaptive Layouts in Navis

## Use the existing adaptive system first

Navis already has a shared adaptive resolution layer in
`lib/src/routing/desktop_layout.dart`. Do not invent ad-hoc breakpoints or
`MediaQuery` switches in leaf widgets.

- **`AdaptiveContext`** is resolved once at shell level and exposed to
  descendants via `AdaptiveContextScope.maybeOf(context)`. Leaf widgets consume
  it; they do not re-derive runtime or form factor from `Platform` or
  `MediaQuery`.
- **`AdaptiveLayoutClass`** (phoneCompact < 600, tabletMedium >= 600,
  tabletExpanded >= 840) classifies non-desktop widths.
- **`DesktopLayoutClass`** (compactDesktop < 1008, standardDesktop >= 1008,
  ultraWideDesktop >= 1600) classifies desktop widths.
- **`AdaptiveShellMode`** (`phoneBottomNav`, `standardRail`,
  `compactWideLandscape`) is resolved by
  `resolveAdaptiveShellMode(...)`; call it via `AdaptiveContext`, never
  re-implement its aspect-ratio and rail-height heuristics.
- **`kDesktopViewMinimumSize`** (800×600) gates the full desktop workspace;
  **`kDesktopMiniPlayerMinimumSize`** (560×360) gates the Mini Player. An
  undersized desktop window transitions to the Mini Player — desktop runtimes
  deliberately never inherit the phone/tablet shells.

If a new adaptive decision is genuinely shared, extend `AdaptiveContext` or its
resolver functions so every shell stays deterministic. See
`docs/architecture.md` (adaptive layout section) before composing shells.

## Space measurement rules

Determine the available window space, never the device type:

- Use `MediaQuery.sizeOf(context)` for app-window size and `LayoutBuilder`
  constraints for parent-scoped decisions.
- Do not use `MediaQuery.orientationOf` or `OrientationBuilder` near the top of
  the tree to switch layouts — window size is the contract.
- Do not branch on hardware ("phone" vs "desktop box"). Navis runs in resizable
  desktop windows, split screen, and picture-in-picture. The only sanctioned
  runtime check is the central `isDesktopRuntime` helper, consumed through
  `AdaptiveContext.desktopRuntime`.
- Do not lock orientation; foldables letterbox.

## Widget sizing and constraints

Core rule: **Constraints go down. Sizes go up. Parent sets position.**

- Use `Expanded` to fill remaining space inside `Row`/`Column`; use `Flexible`
  with a `flex` factor for proportional sibling sizing.
- Constrain content that must not stretch on large screens: wrap in
  `Center(ConstrainedBox(constraints: BoxConstraints(maxWidth: ...)))`.
- Prefer `ListView.builder` / `GridView.builder` for large or unbounded lists.
  `SliverGridDelegateWithMaxCrossAxisExtent` adapts column count to window
  width.

## Validate

- Widget tests: set deterministic viewports with `setAdaptiveTestViewport` from
  `test/helpers/adaptive_test_harness.dart` and cover the widths your change
  responds to (at minimum one phone, one tablet, one desktop bucket).
- Layout transitions: `flutter test test/src/routing/desktop_layout_test.dart`
  (and the shell/golden tests under `test/src/routing/`) — regenerate goldens
  only when the rendered change is intended.
- Visible changes need the runtime loop: launch the isolated profile, resize
  the window across the relevant buckets, and inspect the app-owned PNG from
  `POST /v1/presentation/screenshot`. Fix any overflow before handoff (see the
  `flutter-fix-layout-issues` skill).
