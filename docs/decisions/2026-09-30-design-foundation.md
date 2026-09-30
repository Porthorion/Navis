# Decision: Shared design foundation (tokens, typography, component themes)

- Date: 2026-09-30
- Status: accepted
- Supersedes: none
- Superseded by: none

## Context

The 2026-09-30 UX/UI audit
([audits/ux-ui-audit-2026-09-30.md](../audits/ux-ui-audit-2026-09-30.md))
found that Navis themed only colour. It had no type scale, no bundled font,
and no component themes. Screens chose their own radii (about 120 literals),
font weights (about 113 overrides) and button treatments. The same
Play/Shuffle/Like/Download actions looked different on each detail page, and
text rendered with a different system font on each platform.

## Decision

- **Tokens.** `lib/src/theme/navis_tokens.dart` owns:
  - the `NavisSpace` spacing scale and the `NavisRadius` radius scale, both
    compile-time constants;
  - the `NavisTokens` ThemeExtension for values that vary by theme. It holds
    frame widths, hover and focus opacity, and surface roles such as the quiet
    warning container.

  `NavisTokens` replaces `DesktopTokens`. Durations remain owned by
  `MotionPolicy`.
- **One theme builder.** `buildLightTheme`, `buildDarkTheme` and
  `buildOledTheme` only choose a `ColorScheme`, then call one private builder
  that defines typography, component themes and extensions. This stops the
  three schemes from drifting apart.
- **Font.** Navis bundles the Inter variable font (SIL OFL 1.1) as
  `assets/fonts/InterVariable.ttf`. `FontWeight` maps onto its `wght` axis, so
  one 880 KB file covers every weight. The licence ships as
  `assets/fonts/OFL.txt` and is registered on the licence page at startup.
  Scripts Inter does not cover, such as Arabic and CJK, use the platform's
  per-glyph fallback. No fallback list is hard-coded.
- **Guard.** `test/src/theme/design_token_guard_test.dart` records per-file
  counts of these literals, outside `lib/src/theme/`:
  - numeric radii;
  - numeric `fontSize` values;
  - `Color(0x…)` literals;
  - palette `Colors.*` other than black, white and transparent.

  The test fails when a file's count goes up. It also fails when a count goes
  down without the baseline being lowered, so each cleanup is locked in.

## Reasoning and alternatives

- **Inter over Figtree.** Inter has tabular figures, which durations and time
  labels need, and it covers Latin, Cyrillic, Greek and Vietnamese. Figtree
  is Latin-only.
- **Variable font over static weights.** A test render confirmed that the
  engine applies `FontWeight` to the variable axis. The variable w700 matches
  static Bold's metrics, and one file replaces four to six static files.
- **No bundled Noto fallback.** A hard-coded fallback list risks choosing the
  wrong Han variant, and it adds megabytes. Revisit only if a runtime
  screenshot shows missing glyphs or unstable line metrics.
- **Before/after preview goldens are not pinned to a frozen theme.** They
  render structural preview states that record a layout decision, not
  historical pixels. Re-rendering them under the current theme keeps them
  meaningful.

## Consequences

- New UI should use `NavisSpace`, `NavisRadius`, `TextTheme` slots,
  `ColorScheme` roles and `NavisTokens`. The guard rejects new literals.
- Theme-layer changes regenerate many goldens at once. Land them one layer at
  a time, and keep the regenerated goldens in their own commit.
- Each build grows by about 0.9 MB for the font.
