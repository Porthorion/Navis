---
name: flutter-fix-layout-issues
description: Diagnose and fix Flutter layout errors in Navis — "RenderFlex overflowed", "Vertical viewport was given unbounded height", unbounded TextField width, ParentData misuse. Use whenever an overflow exception, yellow/black stripes, or a layout exception appears in test output or the runtime log.
---

# Fixing Flutter Layout Errors in Navis

## Reproduce first

- **From a widget test failure:** the test log contains the full layout
  exception with the render tree. Capture the viewport the failure occurred at;
  adaptive bugs are width-dependent, so re-check with
  `setAdaptiveTestViewport` (from `test/helpers/adaptive_test_harness.dart`)
  across the buckets the widget responds to — phone (< 600), tablet (600–840+),
  desktop (`kDesktopViewMinimumSize` 800×600, `standardDesktop` >= 1008,
  `ultraWideDesktop` >= 1600).
- **From the running app:** the diagnostics log surfaces the exception; pin
  down the window size from the screenshot via `POST /v1/presentation/screenshot`,
  then write the failing widget test at that size before fixing. Do not debug
  layout by window scraping or OCR — the diagnostics API is the sanctioned
  runtime channel (see `docs/development/development-workflow.md`).
- Write a regression widget test at the failing size; keep it after the fix.

## Error signatures

Flutter's rule: **Constraints go down. Sizes go up. Parent sets position.**

- **"Vertical viewport was given unbounded height"** — a scrollable
  (`ListView`, `GridView`) inside an unconstrained vertical parent
  (`Column`). Wrap it in `Expanded`, or bound it with a `SizedBox` height.
- **"An InputDecorator...cannot have an unbounded width"** — a `TextField` in
  an unconstrained horizontal parent (`Row`). Wrap in `Expanded`/`Flexible`.
- **"RenderFlex overflowed by N pixels"** — a `Row`/`Column` child exceeds the
  allocated space (yellow/black stripes). Wrap the child in `Expanded` (force
  fit), `Flexible`, or let long text wrap; for icon+label rows use
  `Text` with `overflow: TextOverflow.ellipsis` inside `Expanded`.
- **"Incorrect use of ParentData widget"** — `Expanded`/`Flexible` must be
  direct children of `Row`/`Column`/`Flex`; `Positioned` direct children of
  `Stack`. Move, don't wrap.
- **"RenderBox was not laid out"** — a cascading symptom. Ignore it and fix the
  primary violation higher in the stack trace.

## Navis-specific hot spots

Adaptive composition surfaces (`app_shell*.dart`, desktop workspace, Mini
Player, queue/quick-search overlays) switch trees at `AdaptiveContext`
boundaries — an overflow often appears only in one shell mode or
`DesktopLayoutClass` bucket. Prefer fixing within the existing adaptive
resolution (`lib/src/routing/desktop_layout.dart`) over adding new local
`LayoutBuilder` guards that diverge from the shared policy.

## Verify

1. `flutter test test/src/path/to/regression_test.dart`
2. The routing/shell tests: `flutter test test/src/routing/`
3. For visible changes, the runtime loop with a resized window across the
   relevant buckets, then `./tool/check.sh`.
