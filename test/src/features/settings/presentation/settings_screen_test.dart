import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';

final _noHighlights = [
  pendingSetupHighlightsProvider.overrideWithValue(const <SetupHighlight>{}),
  appSettingsProvider.overrideWithValue(
    const AsyncData(AppSettingsModel.defaults()),
  ),
];

void main() {
  testWidgets('removed desktop UI toggle is not shown', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noHighlights,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Desktop UI V1'), findsNothing);
  });

  testWidgets('portrait phone settings keep space above the first row', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noHighlights,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.only(top: 12));
  });

  testWidgets('settings layout follows adaptive width parity matrix', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(599, 1000));
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noHighlights,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DesktopFrame), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(tester.takeException(), isNull);

    final transitions = <({Size size, bool desktopWorkspace})>[
      (size: const Size(700, 1000), desktopWorkspace: false),
      (size: const Size(840, 1000), desktopWorkspace: false),
      (size: const Size(1200, 1000), desktopWorkspace: true),
      (size: const Size(900, 420), desktopWorkspace: false),
    ];

    for (final step in transitions) {
      tester.view.physicalSize = step.size;
      await tester.pumpAndSettle();
      expect(find.byType(DesktopFrame), findsNothing);
      expect(
        find.byType(AppBar),
        step.desktopWorkspace || step.size == const Size(599, 1000)
            ? findsNothing
            : findsOneWidget,
      );
      expect(find.text('Listen Together Configuration'), findsNothing);
      if (step.size.width >= 1200) {
        expect(find.text('Desktop Window'), findsOneWidget);
        expect(
          find.text('Desktop workspace controls and app preferences'),
          findsNothing,
        );
        expect(find.text('Keyboard Shortcuts'), findsOneWidget);
        expect(find.text('Connection'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'does not show separate Listen Together or External Services entries',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: _noHighlights,
          child: MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Listen Together Configuration'), findsNothing);
      expect(find.text('Listen Together'), findsNothing);
      expect(find.text('External Services'), findsNothing);
      expect(find.text('Server Information'), findsOneWidget);
      expect(find.text('Configuration'), findsNothing);
      expect(find.text('AudioMuse AI'), findsNothing);
    },
  );

  testWidgets('places quick customization in Other before About', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1200, 1000));
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noHighlights,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Run Quick Customization'), findsOneWidget);
    expect(find.text('Customize Navis'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Run Quick Customization')).dy,
      lessThan(tester.getTopLeft(find.text('About')).dy),
    );
  });

  testWidgets('lists Server Information, then Integrations, under Connection', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noHighlights,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final connection = tester.getTopLeft(find.text('Connection')).dy;
    final serverInformation = tester
        .getTopLeft(find.text('Server Information'))
        .dy;
    final integrations = tester.getTopLeft(find.text('Integrations')).dy;
    final nextGroup = tester
        .getTopLeft(find.text('Device Storage & Cache').first)
        .dy;
    expect(connection, lessThan(serverInformation));
    expect(serverInformation, lessThan(integrations));
    expect(integrations, lessThan(nextGroup));
    // Integrations is its own entry, listed once.
    expect(find.text('Integrations'), findsOneWidget);
    expect(
      find.text('Deezer, Last.fm, ListenBrainz and other online services.'),
      findsOneWidget,
    );
  });

  group('Appearance entry New tag', () {
    Future<void> pump(
      WidgetTester tester,
      Size size,
      Set<SetupHighlight> highlights, {
      String themeMode = 'system',
      bool flatSurfaces = false,
    }) async {
      setAdaptiveTestViewport(tester, size);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pendingSetupHighlightsProvider.overrideWithValue(highlights),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  themeMode: themeMode,
                  flatSurfaces: flatSurfaces,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final sizes = <String, Size>{
      'phone': const Size(390, 1600),
      'tablet': const Size(700, 1600),
      'compact wide landscape': const Size(900, 420),
      'desktop': const Size(1200, 1000),
    };
    for (final entry in sizes.entries) {
      testWidgets('shows on the ${entry.key} layout while pending', (
        tester,
      ) async {
        await pump(tester, entry.value, SetupHighlight.values.toSet());
        await tester.scrollUntilVisible(
          find.text('Appearance'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(NewFeatureTag), findsNWidgets(2));
      });

      testWidgets('is absent on the ${entry.key} layout when none pending', (
        tester,
      ) async {
        await pump(tester, entry.value, const <SetupHighlight>{});
        expect(find.byType(NewFeatureTag), findsNothing);
      });
    }

    testWidgets('Appearance and Quick Customization say "Has new options"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const Size(390, 1600), SetupHighlight.values.toSet());
      await tester.scrollUntilVisible(
        find.text('Run Quick Customization'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      for (final title in <String>['Appearance', 'Run Quick Customization']) {
        final row = find.ancestor(
          of: find.text(title),
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(of: row.first, matching: find.byType(NewFeatureTag)),
          findsOneWidget,
          reason: title,
        );
      }
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Has new options',
        ),
        findsNWidgets(2),
      );
      handle.dispose();
    });

    testWidgets('OLED alone does not tag outside Auto mode', (tester) async {
      await pump(tester, const Size(390, 1600), const <SetupHighlight>{
        SetupHighlight.oledForAuto,
      }, themeMode: 'dark');
      expect(find.byType(NewFeatureTag), findsNothing);
    });

    testWidgets('OLED alone tags in Auto mode', (tester) async {
      await pump(tester, const Size(390, 1600), const <SetupHighlight>{
        SetupHighlight.oledForAuto,
      });
      await tester.scrollUntilVisible(
        find.text('Appearance'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(NewFeatureTag), findsNWidgets(2));
    });

    testWidgets('Flat areas alone do not tag while Flat is off', (
      tester,
    ) async {
      await pump(tester, const Size(390, 1600), const <SetupHighlight>{
        SetupHighlight.flatAreas,
      });
      expect(find.byType(NewFeatureTag), findsNothing);
    });

    testWidgets('Flat areas alone tag while Flat is on', (tester) async {
      await pump(tester, const Size(390, 1600), const <SetupHighlight>{
        SetupHighlight.flatAreas,
      }, flatSurfaces: true);
      await tester.scrollUntilVisible(
        find.text('Appearance'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(NewFeatureTag), findsNWidgets(2));
    });

    testWidgets('OLED does not hide other pending options', (tester) async {
      await pump(tester, const Size(390, 1600), const <SetupHighlight>{
        SetupHighlight.oledForAuto,
        SetupHighlight.flatSurfaces,
      }, themeMode: 'dark');
      await tester.scrollUntilVisible(
        find.text('Appearance'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(NewFeatureTag), findsNWidgets(2));
    });
  });
}
