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

- SVG or PNG. It is drawn inside a square cover (48–208 dp) with about 18%
  padding on each side, on a neutral surface, following the user's cover
  shape setting.
- A release without one, or whose file fails to load, gets a typographic
  cover instead: its version ("1.4") set large on the accent colour.
- `test/src/features/changelog/changelog_data_test.dart` fails if a referenced
  file does not exist.
