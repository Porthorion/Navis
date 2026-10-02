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
