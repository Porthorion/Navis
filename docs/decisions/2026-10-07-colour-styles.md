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
  primary, secondary and tertiary containers in a warm hue (reds through
  olive, `isWarmHue`) at tone 25-50 with chroma above 24 are replaced by the
  same hue at chroma 20 (no brick-red or khaki buttons from saturated
  covers). Cool hues stay as Material builds them, because blues, greens and
  purples read as jewel tones at those tones. A test asserts this.
- Every styled scheme is checked across all styles, modes and a set of seeds
  for contrast, the no-mud rule, khaki-free dark yellows and pure-black OLED
  backgrounds.
- New widgets should read colours from `ColorScheme` roles or `NavisTokens`.
  Hardcoded colours on theme surfaces will not follow the style.

### Album card captions

The cover-tinted fade was first chosen over caption-below, a solid band and a
dark scrim as the album-card caption for everyone (measured on a phone emulator
with 40 jump-scrolls: 0 frames over 33 ms, and the same over-16 ms profile as
the plain fade, cold and warm). Owner decision 2026-10-10 revises this: the
classic page-coloured fade is the default again and the cover-tinted caption
is the opt-in Album Art Colored Shade setting, so the default path samples no
cover colours. Flat text over artwork (a Flat Surfaces area) restores the
caption-below layout, with its height plumbing keyed on the theme's
`flatArtworkText`, because a solid block over the art defeated the point of
Flat; the colored shade has nothing to tint there and is disabled with a note.
The plain fade remains the fallback until a cover's tint is known or when no
cover-art id is available.

### Flat areas

Flat Surfaces keeps its master switch and gains three area switches (Panels
and Shadows, Now Playing, Text Over Artwork), all on by default so existing
Flat users see no change. Turning every area off is valid and has no effect.
Text Over Artwork covers album-card captions and the phone album and weekly
playlist headers, which show the art unobstructed with the title below it.

### Cover tint refresh and local cache coverage

Caption fields and the Home wash retain the sampled artwork revision in the
existing memory LRU and NCF2 persistent store. NCF1 entries load safely as
revision zero. Library revision bumps trigger lazy re-sampling when a caller
shows the cover, with the previous colour retained through decoding and
caption derivation. Refreshes reuse the existing settle/scroll deferral,
two-slot coordinator, worker isolate and frame-budget dispatcher; a bulk sync
never starts a colour re-scan. The canonical artwork revision is used instead
of filesystem metadata so unchanged covers need neither stats nor decodes,
and alternate cached image sizes do not count as artwork changes.

Local-only remote lookup covers album cards/heroes (600 px), showcase playlist
mosaics (480/420 px), and the mini-cover strip (96 px), using the requested
revision's cache keys. A refreshed request waits for those bytes instead of
sampling an old permanent copy as if it were fresh.

### Known limitations

A server-side change must reach Navis's existing artwork revision mechanism
to invalidate a sampled field. URL-only external cards have no Subsonic cover
identity and continue to use the caption fallback. Sampling never downloads
artwork; missing local files use the existing bounded retry path.

### New tags in setup

Updated users see "New" on options introduced by the newest eligible setup
highlight release. The 1.5.0 registry includes eight options: Color Style,
OLED for Auto, Night Schedule, Flat Surfaces, Flat areas, Album Art Colored
Shade, Now Playing Background and Corner Style. The planned version move to 1.5.0 renames this together with the changelog
entry. Density is a renamed existing setting, so it has no highlight or New tag.

Owner addendum (2026-10-09): tags clear per option after that option has been
visible. `SetupHighlightsService.markOptionSeen(SetupHighlight)` records its
stable storage key in the nullable `setup_highlights_seen` JSON array using an
idempotent, atomic targeted write. Setup and Settings read the same pending set;
there is no second clearing rule. A newer highlight release replaces the group.
Highlights expire after the next minor release: 1.4.x highlights remain in 1.5.x,
but disappear at 1.6.0+; a new major also clears older highlights.

Finish in setup or review still acknowledges every option for the release via
`setup_highlights_seen_release`. Skip keeps pending tags for updated users.
Fresh installs suppress tags while onboarding is required; their first Finish or
Skip acknowledges the release. Required-at-entry is captured when setup hydrates.
The Home invitation is hidden when no options remain pending and can also be
dismissed independently via `setup_card_dismissed_release`.

Clearing happens per option: Settings and setup wrap each tagged option in
`HighlightedAppearanceOption`, which calls `markOptionSeen` once at least half
of the option has been visible (hidden options and a closed "More appearance
options" group never count). The Settings home Appearance and Run Quick
Customization rows show "Has new options" while anything visible is pending;
Use OLED When Dark does not count outside Auto mode. The Home card is titled
"New appearance options", and the Integrations notice takes priority over it.

### Corner Style

Corner Style (Rounded, Soft, Square) is a third appearance axis next to color
style and mode: it changes cards, buttons, sheets and panels but not artwork,
which follows Artwork Shape. Soft is deliberately distinct from Rounded (14 px
rounded rectangles instead of pills, larger sheet and dialog radii) so the three
choices read differently at a glance. Square uses 4 px controls.

### Settings regrouping and setup (2026-10-09)

A UX audit regrouped Settings › Appearance into Theme, Color, Shape & Layout
and Now Playing under one shared section heading, moved Dynamic Album Color
under the accent grid it overrides, and moved the former collapsed Cover Art
Shape group's selectors, renamed Artwork Shape, into Shape & Layout.
Owner decision for setup: Theme Mode, Color Style and Accent Color stay visible
and a "More appearance options" group holds the remaining six options, opening
by itself while any of them is still tagged. Night Schedule is locked off while
the Night style is chosen, since the style already is the night look.
