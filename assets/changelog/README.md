# Release covers

Optional cover art for major releases. It is shown like album art beside the
release's name in the changelog, in the release list, and on the Home
"What's New" card. Reference one from
`lib/src/features/changelog/changelog_data.dart`:

```dart
ChangelogVersion(
  version: '1.4.0',
  codename: 'Navi',
  iconAsset: 'assets/changelog/navi.svg',
  ...
)
```

- SVG or PNG, as a single-colour glyph on a transparent background. Only its
  shape is used: Navis paints it in the theme's on-accent colour on an
  accent-coloured square, like the typographic cover. One file therefore suits
  light and dark themes and every accent colour; do not ship separate light
  and dark versions, and do not rely on the file's own colours.
- It is drawn inside a square cover (48–208 dp) with about 12% padding on
  each side, following the user's cover shape setting. Crop the artwork to a
  square around its bounding box so it sits centred.
- A release without one, or whose file fails to load, gets a typographic
  cover instead: its version ("1.4") set large on the accent colour.
- `test/src/features/changelog/changelog_data_test.dart` fails if a referenced
  file does not exist.

## Provenance

- `navi.svg` (1.4 "Navi"): original artwork drawn for Navis by Porthorion in
  2026, replacing an earlier glyph traced from third-party fan art. A glowing
  orb in a halo with two pairs of wings and a sparkle trail; hand-written SVG,
  no external source.
- `chromatic.svg` (1.5 "Chromatic"): original artwork drawn for Navis in 2026,
  inspired by Path of Exile's Chromatic Orb (a bismuth crystal) but not traced
  from it. Three stacked isometric blocks with terraced faces; the three colours
  are three opacities (1, 0.62, 0.34, faces shaded), which survive the cover's
  single-colour filter. Generated geometry, no external source.
