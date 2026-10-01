import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpAppearance(
    WidgetTester tester, {
    int? colorSeed,
    List<int> customPresets = const <int>[],
    bool dynamicAlbumColorEnabled = false,
    AdaptiveContext? adaptiveContext,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    final database = createTestDatabase();
    await tester.runAsync(database.appSettingsDao.getSettings);
    final settings = const AppSettingsModel.defaults().copyWith(
      colorSchemeSeed: colorSeed,
      dynamicAlbumColorEnabled: dynamicAlbumColorEnabled,
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
          customColorPresetsProvider.overrideWithValue(
            AsyncData(customPresets),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: testTheme(buildLightTheme(defaultColorSchemeSeedColor)),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: adaptiveContext == null
              ? const AppearanceSettingsScreen()
              : AdaptiveContextScope(
                  adaptiveContext: adaptiveContext,
                  child: const AppearanceSettingsScreen(),
                ),
        ),
      ),
    );
    if (adaptiveContext == null) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return container;
  }

  AnimatedContainer chip(WidgetTester tester, String key) {
    return tester.widget<AnimatedContainer>(
      find.byKey(ValueKey<String>('colorChip-$key')),
    );
  }

  BoxDecoration chipDecoration(WidgetTester tester, String key) {
    return chip(tester, key).decoration! as BoxDecoration;
  }

  testWidgets('theme selector stays horizontal on a phone-width surface', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ThemeModeSelector(currentMode: 'system', onChanged: (_) {}),
        ),
      ),
    );

    final selector = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(selector.direction, Axis.horizontal);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('OLED'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses white for implicit default', (tester) async {
    await pumpAppearance(tester);

    final defaultDecoration = chipDecoration(tester, 'default');
    expect(
      (defaultDecoration.border! as Border).top.width,
      3,
    );

    final orangeValue = Colors.orange.toARGB32();
    final orangeKey = 'preset-$orangeValue';
    final orangeDecoration = chipDecoration(tester, orangeKey);
    expect((orangeDecoration.border! as Border).top.width, 1);
  });

  testWidgets('uses default chip for explicit saved white', (tester) async {
    await pumpAppearance(
      tester,
      colorSeed: defaultColorSchemeSeedColor.toARGB32(),
    );

    final defaultDecoration = chipDecoration(tester, 'default');
    expect((defaultDecoration.border! as Border).top.width, 3);
  });

  testWidgets('keeps explicit orange distinct from default', (tester) async {
    final orangeValue = Colors.orange.toARGB32();
    final orangeKey = 'preset-$orangeValue';

    await pumpAppearance(tester, colorSeed: orangeValue);
    await tester.pumpAndSettle();

    final explicitDefaultDecoration = chipDecoration(tester, 'default');
    final explicitOrangeDecoration = chipDecoration(tester, orangeKey);
    expect((explicitDefaultDecoration.border! as Border).top.width, 1);
    expect((explicitOrangeDecoration.border! as Border).top.width, 3);
  });

  testWidgets('default white chip has a visible contrast treatment', (
    tester,
  ) async {
    final whiteValue = Colors.white.toARGB32();
    await pumpAppearance(tester, colorSeed: whiteValue);

    final decoration = chipDecoration(tester, 'default');
    expect((decoration.border! as Border).top.width, 3);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('colorChip-default')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not render a separate white preset chip', (tester) async {
    await pumpAppearance(tester);

    expect(
      find.byKey(
        ValueKey<String>(
          'colorChip-preset-${defaultColorSchemeSeedColor.toARGB32()}',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('custom colors merge into gradient order and show named badge', (
    tester,
  ) async {
    final customWarm = const Color(0xFFFFB000).toARGB32();
    final customGrey = const Color(0xFF777777).toARGB32();
    final customCoral = const Color(0xFFFF7F50).toARGB32();
    await pumpAppearance(
      tester,
      customPresets: <int>[
        customWarm,
        Colors.orange.toARGB32(),
        defaultColorSchemeSeedColor.toARGB32(),
        customCoral,
        customGrey,
        customGrey,
      ],
    );

    final orangeFinder = find.byKey(
      ValueKey<String>('colorChip-preset-${Colors.orange.toARGB32()}'),
    );
    final customWarmFinder = find.byKey(
      ValueKey<String>('colorChip-custom-$customWarm'),
    );
    final amberFinder = find.byKey(
      ValueKey<String>('colorChip-preset-${Colors.amber.toARGB32()}'),
    );

    expect(customWarmFinder, findsOneWidget);
    expect(
      find.byKey(
        ValueKey<String>(
          'customColorBadge-custom-$customWarm',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey<String>(
          'customColorBadge-custom-${Colors.orange.toARGB32()}',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        ValueKey<String>(
          'customColorBadge-custom-${defaultColorSchemeSeedColor.toARGB32()}',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('colorChip-custom-$customGrey')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        lookupAppLocalizations(
          const Locale('en'),
        ).appearanceColorCustomSemantics('Custom: Coral'),
      ),
      findsOneWidget,
    );

    final orangeX = tester.getTopLeft(orangeFinder).dx;
    final customX = tester.getTopLeft(customWarmFinder).dx;
    final amberX = tester.getTopLeft(amberFinder).dx;
    expect(orangeX, lessThan(customX));
    expect(customX, lessThan(amberX));
  });

  testWidgets('saving exact default white stores null seed and no preset', (
    tester,
  ) async {
    final container = await pumpAppearance(
      tester,
      colorSeed: Colors.orange.toARGB32(),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.enterText(
      find.widgetWithText(TextField, l10n.appearanceColorPickerHexLabel),
      'FFFFFF',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.appearanceColorPickerSave));
    await tester.pumpAndSettle();

    final database = container.read(navisDatabaseProvider);
    final settings = await database.appSettingsDao.getSettings();
    expect(settings?.colorSchemeSeed, isNull);
    expect(settings?.customColorPresets, isNull);
  });

  testWidgets('dynamic album color explains selected color fallback', (
    tester,
  ) async {
    await pumpAppearance(tester, dynamicAlbumColorEnabled: true);

    final l10n = lookupAppLocalizations(const Locale('en'));

    expect(
      find.text(l10n.appearanceDynamicAlbumColorEnabledSub),
      findsOneWidget,
    );
    expect(
      find.text(l10n.appearanceColorSchemeDynamicSub),
      findsOneWidget,
    );
  });

  testWidgets('artwork choices wrap and save on a phone with large text', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(320, 800));
    final container = await pumpAppearance(
      tester,
      textScaler: const TextScaler.linear(2),
    );
    // Shape previews animate continuously; wait only for finite transitions.
    final small = find.widgetWithText(ChoiceChip, 'Small');
    await tester.scrollUntilVisible(
      small,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(small);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final row = (await tester.runAsync(
      () => container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .watchSettings()
          .firstWhere((row) => row?.gridArtworkSize == 'small')
          .timeout(const Duration(seconds: 2)),
    ))!;
    expect(row.gridArtworkSize, 'small');
    expect(row.homeRecommendationsAutoAdvance, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile Home offers an automatic recommendation preference off by default',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await pumpAppearance(tester);
      final home = find.text('Home Sections');
      await tester.scrollUntilVisible(
        home,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final control = find.widgetWithText(
        SwitchListTile,
        'Automatically advance recommendations',
      );
      await tester.scrollUntilVisible(
        control,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<SwitchListTile>(control).value, isFalse);
      await tester.tap(control);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final row = (await tester.runAsync(
        () => container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .watchSettings()
            .firstWhere((row) => row?.homeRecommendationsAutoAdvance == true)
            .timeout(const Duration(seconds: 2)),
      ))!;
      expect(row.homeRecommendationsAutoAdvance, isTrue);
      expect(row.gridArtworkSize, 'auto');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop appearance uses a focused settings workspace', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    await pumpAppearance(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: const Size(1280, 800),
        safePadding: EdgeInsets.zero,
      ),
    );

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    await expectLater(
      find.byType(AppearanceSettingsScreen),
      matchesGoldenFile('goldens/appearance_settings_desktop_workspace.png'),
    );
  });
}
