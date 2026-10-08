# Decision: Colour styles as a second theme axis

- Date: 2026-10-07
- Status: accepted
- Supersedes: none
- Superseded by: none

## Context

The owner asked for a Pastel option that works with Light, Dark and OLED and
softens both accents and backgrounds, and invited further styles.

Before this change, every theme came from `ColorScheme.fromSeed`. With a
saturated seed, often a cover colour from Dynamic Album Color, the dark
`fidelity` scheme put containers at about tone 30 with high chroma. An
orange-red cover produced a brick-red mini-player button and navigation
indicator, and a yellow cover produced an olive Home wash.

## Decision

- Add a colour style setting (`neutral`, `pastel`, `immersive`, `night`)
  that is independent of the theme mode. Neutral is the original look.
- Build styled schemes from hand-chosen HCT tones and chromas per role,
  rather than from Material's `DynamicScheme` tone table, so that the
  "no mud" rule can hold: no container or surface at tone 25–50 with chroma
  above 24.
- Apply the style to Navis-drawn fields derived from artwork (Home cover
  wash, Now Playing tint) but never to the artwork, or to text over it.
- Choose styles in Appearance and onboarding with preview tiles painted from
  each style's real scheme.

## Reasoning and alternatives

- **Vivid** was rejected because the dark `fidelity` scheme is already vivid.
- **Monochrome** was rejected because the default white seed already gives a
  monochrome scheme.
- **A plain Pastel switch** was rejected because it could not grow to
  further styles without replacing the control.
- **A dropdown** was rejected in favour of preview tiles, which show the
  result before a style is chosen.
- **Immersive** and **Night** were kept because they are distinct needs:
  backgrounds that follow the playing record, and warm low-blue colours for
  evening listening. The owner chose both.
- **`DynamicScheme` with custom palettes** was rejected because its fixed
  tone table recreates the tone-30 containers the no-mud rule forbids.

## Consequences

- Neutral stays identical to the original schemes, except that dark and OLED
  primary, secondary and tertiary containers at tone 25-50 with chroma above
  24 are replaced by the same hue at chroma 20 (no brick-red buttons from
  saturated covers). A test asserts this.
- Every styled scheme is checked across all styles, modes and a set of seeds
  for contrast, the no-mud rule, khaki-free dark yellows and pure-black OLED
  backgrounds.
- New widgets should read colours from `ColorScheme` roles or `NavisTokens`.
  Hardcoded colours on theme surfaces will not follow the style.
