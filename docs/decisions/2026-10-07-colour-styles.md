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
classic page-coloured fade is the default again, and the shade is opt-in in
two tiers. Revised again the same day: the default is the see-through artwork
scrim behind white text, which keeps the whole cover visible; Album Art Shade
switches to a solid page-colour shade (darkened in dark themes) with the same
shape as the colour shade; its sub-option Use Cover Color tints that shade from
the cover. The default and Shade tiers sample no cover colours. Album
titles are never more than one line: a longer one scrolls (a calm marquee that
pauses at both ends and stops off screen or under reduced motion), which also
keeps the shade and the caption-below height uniform. Flat text over artwork (a
Flat Surfaces area) restores the caption-below layout, with its height
plumbing keyed on the theme's `flatArtworkText`, because a solid block over the
art defeated the point of Flat; the shade has nothing to draw on there and both
switches are disabled with a note. The Home Recently added / Frequent cards
used a hard-coded dark scrim from before the page fade; they now share the same
label, so their default is the page fade like the other Home carousels and the
dark scrim is the Album Art Shade tier.
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
OLED for Auto, Night Schedule, Flat Surfaces, Flat areas, Album Art
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

### Pastel revision and style separation (2026-10-10)

Owner feedback after phone testing: Pastel sometimes read harsh, at times
harsher than Immersive, and the three styles did not differ enough to justify
being separate. Diagnosis over the seed matrix (white, grey, yellow, orange,
red, magenta, blue, green, brown, neon pink, dark navy; light, dark, OLED):

- Pastel passed the seed's chroma through (28-44 at tone 82 in dark, light ink
  at chroma 48 at tone 42, containers up to 28), so a neon or yellow seed gave
  dark accents of chroma 44 and light ink of 48.
- Immersive's dark accents are gamut-limited at tone 82 (red 26, blue 34,
  brown 26), so for those seeds Pastel and Immersive produced the same
  accent; elsewhere Pastel was within a few chroma points of it.
- Artwork-adapted colours capped at chroma 30 (light) and 16 (dark) for
  Pastel against Immersive's 40 and 32, with light washes at tone 84.

Decision:

- Pastel takes only the seed's hue. Accent chroma is 16-24 (20 for the default
  white), dark and OLED accents at tone 86, light ink at tone 47, light fills
  at tone 89-91 and chroma 15, dark containers at tone 30 and chroma 12,
  surfaces at chroma 6-7, a soft rose error and a pastel mint success.
  Artwork colours cap at chroma 13 (light, tone 88-94) and 12 (dark, tone
  26-34). Flat bands, Use Cover Color captions and the Now Playing tint inherit
  the cap because they derive from `adaptArtColor`.
- The Home wash veil over Pastel's softer cover colours is lowered (light 0.6
  subtle / 0.42, dark 0.64 / 0.46) so the wash stays visible but gentle.
- Immersive's accent chroma floor rises from 32 to 36 and its dark accents
  move to tone 77, so it stays rich where Pastel went light; Night is
  unchanged.
- Ordering rule, enforced by `navis_style_schemes_test.dart` for every seed,
  mode and style: Pastel's maximum chroma over the key roles is at most 60% of
  Immersive's (measured worst case 58%) and under 85% of Night's; Pastel's
  adapted artwork colours are under 60% of Immersive's; Night keeps hue 15-95
  and a blue channel below red; Neutral is unchanged.
- Alternatives rejected: a global chroma multiplier (it would also have
  softened Immersive's and Night's accents, which are intended to be rich or
  warm) and lowering only the seed chroma clamp (it does not fix the light
  ink, containers or artwork colours).

### Colour and Brightness tuning (2026-10-10)

Owner decision: add two independent integer adjustments, −5…+5, to every
style and theme mode. Color controls vividness (chroma × 0.5…1.5); Brightness
controls depth (positive is deeper). An HCT post-pass keeps zero/zero
bit-identical, preserves errors and text colours and bounds mid-tone chroma.
Pure-black OLED surfaces stay black. Extreme contrast tests reduced Light's
+5 shift from −7 to −4.5 tones; Light −5 remains +4, Dark ±5 remains ∓6,
and OLED containers use at most ∓3 (floor 2). OLED's target chroma ceiling is
1.5 so RGB quantisation keeps measured chroma below 3. The mud guard covers
only the roles the muddy-band rule covers (fills, surfaces, and dark-mode
primary/secondary) and never lowers a role below the style's own chroma, so
every step is monotonic and Brightness alone never changes the accents. Pure
black/white roles remain unchanged, including Neutral's white primary for a
saturated yellow seed.

The initial branch proposal stored one brightness value; the v2 addendum below
redefines the unshipped schema 101 with separate Light and Dark values.
A nullable Riverpod preview temporarily overrides persisted tuning during
dragging. Existing theme-cache, caption memo and dedupe keys, and worker
messages carry both axes; artwork tone windows/chroma caps follow tuning,
while the existing scrim recipes and OLED Now Playing cap remain in place.

### Fine-Tune Colors controls (2026-10-10)

The two tuning axes are one option, Fine-Tune Colors, under Color Style in
Settings › Appearance and under "More appearance options" in setup, with its
own New tag. Each axis is the Speed and Pitch ruler in whole-step mode rather
than a new slider: the scale is eleven stepped swatches of what that step
really produces (the live primary for Color; `surface`, or
`surfaceContainerHigh` in OLED, for Brightness), computed from the previewed
theme's inputs so they hold still while the app recolours. A smooth gradient
was rejected because the setting is eleven discrete steps and a gradient would
imply values between them. The rulers dispatch a preview per whole step and
save on release; Reset (shown only while a value is not Default) returns both.
The ruler stops growing at 480 dp so its steppers stay beside the strip on wide
pages. Dark and OLED Pastel accents sit at the gamut ceiling for some hues, so
the Vivid half of the Color scale can show little change there; the strip
reports the real result rather than exaggerating it.

### Fine-Tune Colors v2 and Looks (2026-10-10)

Owner decision: keep intensity shared, separate Light brightness from
Dark/OLED brightness, and move the rulers into a panel in the subsequent UI
pass. `ColorTuning` resolves into the unchanged rendering adjustment; theme,
worker and caption caches keep their existing resolved keys. Schema 101 was
never shipped and is redefined, rather than adding schema 102.

There are two independent preset libraries using the existing playback JSON
TEXT and targeted-writer pattern. Tuning presets contain only intensity and
Light/Dark brightness, with a derived Default. Looks capture the complete
appearance, including tuning values and its optional preset id; content and
navigation organization (Home Sections, Page Visibility, Desktop Navbar)
stays independent. The capture also includes language, custom accent swatches,
Home recommendation auto-advance and the legacy grid-column setting found in
Appearance. The full field contract lives in `docs/architecture.md`.

Applying a Look writes supplied columns in one transaction. Missing, unknown
or invalid fields preserve current values, so partial snapshots survive
schema evolution. A still-existing tuning reference uses its current values;
a deleted reference falls back to captured values. Look selection compares
current values against saved snapshots while ignoring reference metadata.
Reset keeps both libraries. Shared name validation preserves playback rules
and reserves Default for appearance presets. Settings' tuning swatches read
the effective scheduled style; setup remains an explicit draft preview.

### Fine-Tune Colors panel, Light/Dark brightness and Looks UI (2026-10-10)

Owner decisions, implemented over the v2 persistence:

- The two rulers leave the Appearance page for a panel, as Speed and Pitch
  did: one row (title, New tag, summary, chevron) opens the shared
  `showQuickPanel` shell (popover on desktop, sheet on touch). The inline
  rulers made the Color section long and gave presets no room. The rulers,
  band and haptics are unchanged; they moved, they were not rebuilt.
- Brightness is edited per mode through a compact Light | Dark switch under
  the ruler instead of two more rulers or one value that silently meant "the
  mode you happen to be in". Dark covers OLED. The strip shows the selected
  mode's real surfaces, and a caption says where the change shows when that is
  not the mode on screen, because dragging it would otherwise appear to do
  nothing. Intensity stays one shared ruler.
- Tuning presets and Looks reuse `PresetPicker`, the Speed and Pitch picker,
  so naming, Custom, Update, Rename and Delete behave identically. Custom is
  derived by value: it appears the moment the values match no preset.
- Setup keeps the row and the panel but not the preset picker, and has no
  Looks: both write settings immediately, whereas setup edits a draft that
  Finish saves (and Skip discards). Presets and Looks are managed in Settings.
- Looks sit above Theme because they act on everything below them.

### Looks as the only appearance presets and Undo (2026-10-10)

Owner decision superseding the v2 preset-library proposal above: fold
Fine-Tune presets into Looks. Two preset layers made it unclear whether a
saved choice controlled only tuning or the full appearance. Looks now store
intensity and both brightness values directly, with no preset references;
Fine-Tune remains preview/clear/commit controls. The unshipped schema 101
retains the three tuning columns and Look library/selected id only.
Old snapshot JSON silently ignores `tuningPresetId` and uses captured values.

Applying a Look returns the full pre-apply snapshot for Undo. Restoring it
uses the same transactional DAO path, including automatic accent and legacy
grid-size nulls. Selection remains derived by value, so Undo returns Custom
or the previous matching Look without storing a second selection history.
