import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/library/presentation/unavailable_review_screen.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';

final _baseOverrides = [
  pendingSetupHighlightsProvider.overrideWithValue(const <SetupHighlight>{}),
  appSettingsProvider.overrideWithValue(
    const AsyncData(AppSettingsModel.defaults()),
  ),
];

final _noHighlights = [
  pendingUnavailableCountProvider.overrideWith((ref) => Stream.value(0)),
  ..._baseOverrides,
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
        expect(find.text('Desktop'), findsWidgets);
        expect(
          find.text('Window, navigation and keyboard shortcuts.'),
          findsOneWidget,
        );
        expect(
          find.text('Desktop workspace controls and app preferences'),
          findsNothing,
        );
        // Window and shortcuts live on the Desktop page now.
        expect(find.text('Desktop Window'), findsNothing);
        expect(find.text('Keyboard Shortcuts'), findsNothing);
        expect(find.text('Server & Accounts'), findsOneWidget);
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

  testWidgets('lists Themes and Home & Library in Look & Feel, in that order', (
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

    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Looks, colors, shapes and layout.'), findsOneWidget);
    expect(
      find.text('Home sections, library pages and navigation.'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Themes')).dy,
      lessThan(tester.getTopLeft(find.text('Home & Library')).dy),
    );
    expect(find.text('Interface'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Home & Library')).dy,
      lessThan(tester.getTopLeft(find.text('Run Quick Customization')).dy),
    );
  });

  testWidgets('places quick customization in Help & About before About', (
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

    expect(find.text('Help & About'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
    expect(find.text('Run Quick Customization'), findsOneWidget);
    expect(find.text('Customize Navis'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Run Quick Customization')).dy,
      lessThan(tester.getTopLeft(find.text('About')).dy),
    );
  });

  testWidgets(
    'lists Server Information, then Integrations, under Server & Accounts',
    (tester) async {
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

      final connection = tester.getTopLeft(find.text('Server & Accounts')).dy;
      final serverInformation = tester
          .getTopLeft(find.text('Server Information'))
          .dy;
      final integrations = tester.getTopLeft(find.text('Integrations')).dy;
      final nextGroup = tester.getTopLeft(find.text('Playback').first).dy;
      expect(connection, lessThan(serverInformation));
      expect(serverInformation, lessThan(integrations));
      expect(integrations, lessThan(nextGroup));
      // Integrations is its own entry, listed once.
      expect(find.text('Integrations'), findsOneWidget);
      expect(
        find.text('Deezer, Last.fm, ListenBrainz and other online services.'),
        findsOneWidget,
      );
    },
  );

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
            pendingUnavailableCountProvider.overrideWith(
              (ref) => Stream.value(0),
            ),
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
        // Haptics sits between the two tagged entries on phones and tablets.
        await tester.scrollUntilVisible(
          find.text('Run Quick Customization'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        // Themes, Home & Library (Genres), Playback (Loudness) and Quick
        // Customization. The 420 px landscape list is lazy: by the time Quick
        // Customization is in view, the Playback row is no longer built.
        expect(
          find.byType(NewFeatureTag),
          findsNWidgets(entry.key == 'compact wide landscape' ? 3 : 4),
        );
      });

      testWidgets('is absent on the ${entry.key} layout when none pending', (
        tester,
      ) async {
        await pump(tester, entry.value, const <SetupHighlight>{});
        expect(find.byType(NewFeatureTag), findsNothing);
      });
    }

    testWidgets(
      'Themes, Home & Library, Playback and Quick Customization say "Has new options"',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          const Size(390, 1600),
          SetupHighlight.values.toSet(),
        );
        await tester.scrollUntilVisible(
          find.text('Run Quick Customization'),
          200,
          scrollable: find.byType(Scrollable).first,
        );

        for (final title in <String>[
          'Themes',
          'Home & Library',
          'Playback',
          'Run Quick Customization',
        ]) {
          final row = find.ancestor(
            of: find.text(title),
            matching: find.byType(ListTile),
          );
          expect(
            find.descendant(
              of: row.first,
              matching: find.byType(NewFeatureTag),
            ),
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
          findsNWidgets(4),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'the Genres highlight tags Home & Library, not Themes or Quick Customization',
      (tester) async {
        await pump(tester, const Size(390, 1600), const <SetupHighlight>{
          SetupHighlight.genresPage,
        });
        await tester.scrollUntilVisible(
          find.text('Run Quick Customization'),
          200,
          scrollable: find.byType(Scrollable).first,
        );

        Finder tagIn(String title) => find.descendant(
          of: find
              .ancestor(of: find.text(title), matching: find.byType(ListTile))
              .first,
          matching: find.byType(NewFeatureTag),
        );
        expect(tagIn('Home & Library'), findsOneWidget);
        expect(tagIn('Themes'), findsNothing);
        expect(tagIn('Run Quick Customization'), findsNothing);
      },
    );

    testWidgets(
      'the Loudness highlight tags Playback, not Themes or Home & Library',
      (tester) async {
        await pump(tester, const Size(390, 1600), const <SetupHighlight>{
          SetupHighlight.loudnessPresets,
        });
        Finder tagIn(String title) => find.descendant(
          of: find
              .ancestor(of: find.text(title), matching: find.byType(ListTile))
              .first,
          matching: find.byType(NewFeatureTag),
        );
        expect(tagIn('Playback'), findsOneWidget);
        expect(tagIn('Themes'), findsNothing);
        expect(tagIn('Home & Library'), findsNothing);
      },
    );

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
        find.text('Themes'),
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
        find.text('Themes'),
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
        find.text('Themes'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(NewFeatureTag), findsNWidgets(2));
    });
  });

  group('top-level groups', () {
    Future<void> pump(WidgetTester tester, Size size) async {
      setAdaptiveTestViewport(tester, size);
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
    }

    double top(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text).first).dy;

    final sizes = <String, Size>{
      'phone': const Size(390, 2800),
      'tablet': const Size(700, 2800),
      'compact wide landscape': const Size(900, 420),
      'desktop': const Size(1200, 2400),
    };
    for (final entry in sizes.entries) {
      testWidgets('follow the approved order on the ${entry.key} layout', (
        tester,
      ) async {
        await pump(tester, entry.value);
        final desktop = entry.key == 'desktop';
        final order = <String>[
          'Server & Accounts',
          'Server Information',
          'Integrations',
          'Playback',
          'Equalizer',
          'Library & Storage',
          'Sync',
          'Downloads',
          'Storage & Cache',
          'Unavailable Items',
          'Look & Feel',
          'Themes',
          'Home & Library',
          if (desktop) 'Desktop' else 'Haptics',
          'Help & About',
          'Run Quick Customization',
          'About',
        ];
        final compactWide = entry.key == 'compact wide landscape';
        if (compactWide) {
          // A short, wide ListView builds lazily: scroll to the end.
          await tester.scrollUntilVisible(
            find.text('About'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
        }
        if (!compactWide) {
          var previous = -1.0;
          for (final label in order) {
            final y = top(tester, label);
            expect(y, greaterThan(previous), reason: label);
            previous = y;
          }
        }
        expect(find.text('Device Storage & Cache'), findsNothing);
        expect(find.text('Library Synchronization'), findsNothing);
        expect(find.text('Connection'), findsNothing);
      });
    }

    testWidgets('About is the last entry on desktop too', (tester) async {
      await pump(tester, const Size(1200, 2400));
      final about = tester.getTopLeft(find.text('About').last).dy;
      for (final row in tester.widgetList<DesktopListRow>(
        find.byType(DesktopListRow),
      )) {
        final y = tester.getTopLeft(find.byWidget(row)).dy;
        expect(y, lessThanOrEqualTo(about));
      }
      expect(find.text('Desktop Window'), findsNothing);
    });

    testWidgets('Desktop entry is desktop only', (tester) async {
      await pump(tester, const Size(390, 2800));
      expect(
        find.text('Window, navigation and keyboard shortcuts.'),
        findsNothing,
      );
    });

    testWidgets('Unavailable Items is a Library & Storage entry that shows '
        'the waiting count', (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 2800));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._baseOverrides,
            pendingUnavailableCountProvider.overrideWith(
              (ref) => Stream.value(3),
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
      expect(find.text('Unavailable Items'), findsOneWidget);
      expect(find.text('3 items waiting for review'), findsOneWidget);
    });

    testWidgets('Unavailable Items stays listed with nothing waiting', (
      tester,
    ) async {
      await pump(tester, const Size(390, 2800));
      expect(find.text('Unavailable Items'), findsOneWidget);
      expect(find.textContaining('waiting for review'), findsNothing);
    });
  });

  testWidgets('the Haptics entry shows on a phone and a tablet, not on '
      'desktop', (tester) async {
    for (final (size, shown) in [
      (const Size(390, 2400), true),
      (const Size(840, 2400), true),
      (const Size(1200, 1000), false),
    ]) {
      setAdaptiveTestViewport(tester, size);
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
      expect(
        find.text('Vibration for taps and gestures.'),
        shown ? findsOneWidget : findsNothing,
        reason: '$size',
      );
    }
  });
}
