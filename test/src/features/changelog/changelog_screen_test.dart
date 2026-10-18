import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_cover.dart';
import 'package:navis/src/features/changelog/presentation/changelog_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF6750A4);

final _overrides = [coverArtShapeProvider.overrideWithValue('rounded')];

List<ChangelogEntry> _entries(ChangelogEntryType type, int count, String p) =>
    <ChangelogEntry>[
      for (var i = 1; i <= count; i++) ChangelogEntry('$p $i', type: type),
    ];

final List<ChangelogVersion> _versions = <ChangelogVersion>[
  ChangelogVersion(
    version: '9.9.1',
    released: '2026-09-29',
    entries: <ChangelogEntry>[
      ..._entries(ChangelogEntryType.fix, 2, 'Patch fix'),
    ],
  ),
  ChangelogVersion(
    version: '9.9.0',
    released: '2026-09-20',
    codename: 'Aurora',
    summary: 'A release summary.',
    entries: <ChangelogEntry>[
      ..._entries(ChangelogEntryType.newFeature, 2, 'New thing'),
      ..._entries(ChangelogEntryType.improvement, 3, 'Better thing'),
      ..._entries(ChangelogEntryType.fix, 8, 'Fixed thing'),
    ],
    highlights: const <ChangelogHighlight>[
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.equalizer,
        title: 'Equalizer',
        body: 'Shape the sound',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.speed,
        title: 'Speed and pitch',
        body: 'Precise control',
      ),
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.headphones,
        title: 'AutoEQ',
        body: 'Headphone Profiles',
      ),
    ],
    specialThanks: const <String>['To a tester.'],
  ),
  ChangelogVersion(
    version: '9.8.3',
    released: '2026-09-01',
    entries: <ChangelogEntry>[
      ..._entries(ChangelogEntryType.fix, 1, 'Older fix'),
    ],
  ),
  ChangelogVersion(
    version: '9.8.0',
    released: '2026-08-20',
    entries: <ChangelogEntry>[
      ..._entries(ChangelogEntryType.newFeature, 1, 'Older feature'),
    ],
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  String? initialVersion,
  Size size = const Size(390, 844),
  bool desktop = false,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  Widget screen = ChangelogScreen(
    versions: _versions,
    initialVersion: initialVersion,
  );
  if (desktop) {
    screen = AdaptiveContextScope(
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: size,
        safePadding: EdgeInsets.zero,
      ),
      child: screen,
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides,
      child: MaterialApp(
        theme: brightness == Brightness.light
            ? buildLightTheme(_seed)
            : buildDarkTheme(_seed),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a major release opens like an album', (tester) async {
    await _pump(tester, initialVersion: '9.9.0');

    expect(
      find.byKey(const ValueKey<String>('changelogReleaseHeader-9.9.0')),
      findsOneWidget,
    );
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('Navis 9.9'), findsOneWidget);
    expect(find.text('Sep 20, 2026 • 13 changes'), findsOneWidget);
    expect(find.text('Equalizer'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('changelogTypographicCover')),
      findsWidgets,
    );
    await expectLater(
      find.byType(ChangelogScreen),
      matchesGoldenFile('goldens/changelog_major_phone_light.png'),
    );
  });

  testWidgets('the newest patch shows its header and its major', (
    tester,
  ) async {
    await _pump(tester, brightness: Brightness.dark);

    expect(find.text('Navis 9.9.1'), findsOneWidget);
    expect(find.text('Part of Navis 9.9 “Aurora”'), findsOneWidget);
    expect(find.text('Earlier Releases'), findsOneWidget);
    await expectLater(
      find.byType(ChangelogScreen),
      matchesGoldenFile('goldens/changelog_patch_phone_dark.png'),
    );
  });

  testWidgets('a patch links to its major release', (tester) async {
    await _pump(tester, size: const Size(390, 3000));

    await tester.tap(
      find.byKey(const ValueKey<String>('changelogParentMajor')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('changelogReleaseHeader-9.9.0')),
      findsOneWidget,
    );
    expect(find.text('Releases'), findsOneWidget);
  });

  testWidgets('fixes collapse past five and expand on request', (tester) async {
    await _pump(tester, initialVersion: '9.9.0', size: const Size(390, 3000));

    expect(find.text('Fixed thing 5'), findsOneWidget);
    expect(find.text('Fixed thing 6'), findsNothing);
    expect(find.text('Show 3 more fixes'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('changelogToggleFixes')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fixed thing 8'), findsOneWidget);
    expect(find.text('Show Fewer Fixes'), findsOneWidget);
  });

  testWidgets('type tabs show one kind of change at a time', (tester) async {
    await _pump(tester, initialVersion: '9.9.0', size: const Size(390, 3000));

    await tester.tap(find.widgetWithText(Tab, 'New'));
    await tester.pumpAndSettle();
    expect(find.text('New thing 1'), findsOneWidget);
    expect(find.text('Better thing 1'), findsNothing);
    expect(find.text('Fixed thing 1'), findsNothing);

    // The tab bar scrolls; bring the last tab into view first.
    final fixedTab = find.widgetWithText(Tab, 'Fixed');
    await tester.ensureVisible(fixedTab);
    await tester.pumpAndSettle();
    await tester.tap(fixedTab);
    await tester.pumpAndSettle();
    // A filtered view is never collapsed.
    expect(find.text('Fixed thing 8'), findsOneWidget);
    expect(find.text('New thing 1'), findsNothing);
  });

  testWidgets('tapping an earlier release shows it', (tester) async {
    await _pump(tester, size: const Size(390, 3000));

    expect(find.text('Older fix 1'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('changelogReleaseRow-9.8.3')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('changelogReleaseHeader-9.8.3')),
      findsOneWidget,
    );
    expect(find.text('Older fix 1'), findsOneWidget);
  });

  testWidgets('desktop lists releases beside the selected one', (tester) async {
    await _pump(
      tester,
      size: const Size(1280, 800),
      desktop: true,
      brightness: Brightness.dark,
    );

    expect(
      find.byKey(const ValueKey<String>('changelogVersionRail')),
      findsOneWidget,
    );
    expect(find.text('Navis 9.9.1'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('changelogVersionRail')),
        matching: find.byKey(
          const ValueKey<String>('changelogReleaseRow-9.9.0'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('changelogReleaseHeader-9.9.0')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(ChangelogScreen),
      matchesGoldenFile('goldens/changelog_major_desktop_dark.png'),
    );
  });

  testWidgets('a release icon is painted in the accent colours of the theme', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 520);
    addTearDown(tester.view.reset);

    final light = buildLightTheme(_seed);
    final dark = buildDarkTheme(_seed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: MaterialApp(
          home: Column(
            children: <Widget>[
              _IconCoverSample(theme: light),
              _IconCoverSample(theme: dark),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('changelogTypographicCover')),
      findsNothing,
    );
    final pictures = tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .toList();
    expect(pictures, hasLength(6));
    for (final (index, picture) in pictures.indexed) {
      final scheme = (index < 3 ? light : dark).colorScheme;
      expect(
        picture.colorFilter,
        ColorFilter.mode(scheme.onPrimary, BlendMode.srcIn),
      );
    }
    await expectLater(
      find.byType(Column).first,
      matchesGoldenFile('goldens/changelog_icon_cover_light_dark.png'),
    );
  });

  testWidgets('a missing release icon falls back to the typographic cover', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: const MaterialApp(
          home: Scaffold(
            body: ChangelogReleaseCover(
              version: ChangelogVersion(
                version: '9.9.0',
                entries: <ChangelogEntry>[],
                iconAsset: 'assets/changelog/does-not-exist.png',
              ),
              size: 112,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('changelogTypographicCover')),
      findsOneWidget,
    );
    expect(find.text('9.9'), findsOneWidget);
  });
}

/// The bundled 1.4 icon at the header, list and Home card sizes.
class _IconCoverSample extends StatelessWidget {
  const new({required this.theme});

  final ThemeData theme;

  static const _version = ChangelogVersion(
    version: '9.9.0',
    entries: <ChangelogEntry>[],
    iconAsset: 'assets/changelog/navi.svg',
  );

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 24,
            children: <Widget>[
              ChangelogReleaseCover(version: _version, size: 208),
              ChangelogReleaseCover(version: _version, size: 112),
              ChangelogReleaseCover(version: _version, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}
