---
name: flutter-add-widget-test
description: Implement widget tests for Navis UI with WidgetTester — rendering, taps, text entry, scrolling, adaptive viewports, and provider overrides. Use when validating that a widget renders correct data or responds to interaction, when a UI bug needs a regression test, or when asked "does this have a widget test?".
---

# Writing Widget Tests in Navis

## Placement and runner

Mirror the widget's location: `lib/src/common_widgets/star_button.dart` is
tested in `test/src/common_widgets/star_button_test.dart`. Import
`package:flutter_test/flutter_test.dart` and run:

```bash
flutter test test/src/common_widgets/star_button_test.dart
```

## Build the harness

- Wrap the widget in `MaterialApp(theme: testTheme())` (or mount
  `testNavisApp` from `test/helpers/test_theme.dart`) so Navis theming is
  deterministic.
- Widgets that read providers need `ProviderScope(overrides: [...])`. Override
  at the boundary with the helpers from `test/helpers/` (`withTestDatabase`,
  library sync fakes); never construct a `NavisDatabase` inline — check.sh
  hard-fails on it.
- Adaptive widgets: set the viewport with `setAdaptiveTestViewport` from
  `test/helpers/adaptive_test_harness.dart` and test each form factor the
  widget responds to (phone, tablet, desktop bucket). Harnesses like
  `_StarHarness` in `star_button_test.dart` are the local pattern for stateful
  context.

## Core tools

- **`WidgetTester`** from `testWidgets()` drives pumping and gestures.
- **Finders**: prefer `find.byKey` with the semantic keys widgets already
  expose (e.g. `ValueKey<String>('starButtonFeedbackScale')`), then
  `find.text`, then `find.byType`/`find.byIcon`.
- **Matchers**: `findsOneWidget`, `findsNothing`, `findsNWidgets(n)`.

## Interaction rules

- Static render: one `pumpWidget`, then assert.
- State changes: `await tester.tap(finder)` → `await tester.pump()` → assert.
- Animations/transitions: `pumpAndSettle()` — but if the tree schedules
  continuous frames (spinners, looping animations), use
  `await tester.pump(const Duration(milliseconds: 300))` instead or the test
  times out.
- Text: `enterText(finder, 'text')`; long lists:
  `scrollUntilVisible(finder, 500.0, scrollable: listFinder)`.
- Respect reduced motion where the widget supports it: drive
  `MediaQueryData(disableAnimations: true)` as `star_button_test.dart` does.

## AsyncValue-bearing widgets

All `AsyncValue` states must be reachable and handled: pump through loading,
assert the data state, and force an error state via a throwing override to
assert the error UI. Do not mutate providers during build — the production
rule also holds in tests; drive changes through taps and callbacks.

## Feedback loop

Run the focused file → read the failing matcher's FlutterError → adjust the
widget or assertion → rerun. Visible UI changes additionally need the runtime
loop and a screenshot via `POST /v1/presentation/screenshot` (see
`docs/development/development-workflow.md`); widget tests alone do not certify rendering.
