# Release icons

Optional icons for major releases, shown centred in the changelog banner and
on the Home "What's New" card. Reference one from
`lib/src/features/changelog/changelog_data.dart`:

```dart
ChangelogVersion(
  version: '1.4.0',
  codename: 'Navi',
  iconAsset: 'assets/changelog/navi.svg',
  ...
)
```

- SVG or PNG. Square artwork with transparent padding works best; it is drawn
  at about 56% of a 40–76 dp circle.
- A release without an icon, or whose file fails to load, shows a sparkles
  icon instead.
- `test/src/features/changelog/changelog_data_test.dart` fails if a referenced
  file does not exist.
