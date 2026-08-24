import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

const _station = InternetRadioStation(
  id: 'ambient-station',
  name: 'Ambient Radio',
  streamUrl: 'https://example.com/ambient',
);

Future<void> _pumpRadio(
  WidgetTester tester, {
  required List<InternetRadioStation> stations,
  required String query,
  required VoidCallback? onClearTypeFilter,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        radioStationsProvider.overrideWith((ref) async => stations),
        currentRadioStationIdProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RadioTabContent(
            typeFilterQuery: query,
            onClearTypeFilter: onClearTypeFilter,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'filtered Radio empty state explains the filter and restores stations',
    (tester) async {
      var query = 'lofi';
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => ProviderScope(
            overrides: [
              radioStationsProvider.overrideWith(
                (ref) async => const <InternetRadioStation>[_station],
              ),
              currentRadioStationIdProvider.overrideWithValue(null),
            ],
            child: MaterialApp(
              theme: testTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: RadioTabContent(
                  typeFilterQuery: query,
                  onClearTypeFilter: () => setState(() => query = ''),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Stations Match \u201clofi\u201d'), findsOneWidget);
      expect(
        find.text('Try a different filter, or show all stations.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('radioClearTypeFilterAction')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('radioClearTypeFilterAction')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ambient Radio'), findsOneWidget);
      expect(find.text('No Stations Match \u201clofi\u201d'), findsNothing);
    },
  );

  testWidgets('an actually empty Radio library keeps its original guidance', (
    tester,
  ) async {
    await _pumpRadio(
      tester,
      stations: const <InternetRadioStation>[],
      query: 'lofi',
      onClearTypeFilter: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text('No Radio Stations Found'), findsOneWidget);
    expect(
      find.text('Add internet radio stations on your server to see them here.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('radioClearTypeFilterAction')),
      findsNothing,
    );
  });

  testWidgets('filtered Radio empty state has a stable mobile composition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpRadio(
      tester,
      stations: const <InternetRadioStation>[_station],
      query: 'lofi',
      onClearTypeFilter: () {},
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/radio_filtered_empty_after.png'),
    );
  });
}
