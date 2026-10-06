import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

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
  String? activeId,
  NavisPlaybackHandler? handler,
  double scale = 1,
  AppNoticeController? notices,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        radioStationsProvider.overrideWith((ref) async => stations),
        currentRadioStationIdProvider.overrideWithValue(activeId),
        audioHandlerProvider.overrideWithValue(handler),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: AppNoticeScope(
            notifier: notices,
            child: Scaffold(
              body: RadioTabContent(
                typeFilterQuery: query,
                onClearTypeFilter: onClearTypeFilter,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _RadioHandler implements NavisPlaybackHandler {
  String? startedUrl;
  String? startedId;
  int stops = 0;
  final loads = <String, Completer<void>>{};
  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    startedId = stationId;
    startedUrl = streamUrl;
    await loads[stationId]?.future;
  }

  @override
  Future<void> stopRadio() async => stops++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const nextStation = InternetRadioStation(
    id: 'next',
    name: 'Next Station',
    streamUrl: 'https://example.invalid/next',
  );

  for (final lateFailure in [false, true]) {
    testWidgets(
      lateFailure
          ? 'superseded station failure cannot show a toast'
          : 'successful station switch dismisses the previous radio failure',
      (tester) async {
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        final handler = _RadioHandler();
        final first = Completer<void>();
        final second = Completer<void>();
        handler.loads[_station.id] = first;
        handler.loads[nextStation.id] = second;
        await _pumpRadio(
          tester,
          stations: const [_station, nextStation],
          query: '',
          onClearTypeFilter: null,
          handler: handler,
          notices: notices,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('radioStation-ambient-station')),
        );
        await tester.pump();
        if (!lateFailure) {
          first.completeError(StateError('failed'));
          await tester.pump();
          expect(notices.notice?.message, 'Could not play this radio station.');
        }
        await tester.tap(find.byKey(const ValueKey('radioStation-next')));
        await tester.pump();
        second.complete();
        await tester.pump();
        if (lateFailure) {
          first.completeError(StateError('old failure'));
          await tester.pump();
        }
        expect(notices.notice, isNull);
      },
    );
  }

  for (final newerNotice in [false, true]) {
    testWidgets(
      'successful radio load preserves ${newerNotice ? 'newer' : 'unrelated'} errors',
      (tester) async {
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        notices.show(
          message: newerNotice
              ? 'Could not play this radio station.'
              : 'Library refresh failed',
          level: AppNoticeLevel.error,
        );
        final handler = _RadioHandler();
        final load = Completer<void>();
        handler.loads[_station.id] = load;
        await _pumpRadio(
          tester,
          stations: const [_station],
          query: '',
          onClearTypeFilter: null,
          handler: handler,
          notices: notices,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('radioStation-ambient-station')),
        );
        await tester.pump();
        if (newerNotice) {
          notices.show(
            message: 'Could not play this radio station.',
            level: AppNoticeLevel.error,
          );
        }
        final noticeId = notices.notice!.id;
        load.complete();
        await tester.pump();
        expect(notices.notice?.id, noticeId);
      },
    );
  }

  testWidgets('radio cards resize lazily and display only the safe host', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final stations = List.generate(
      20,
      (i) => InternetRadioStation(
        id: 'station-$i',
        name: 'Station $i with a long multilingual name محطة',
        streamUrl: 'https://user:password@example.com/radio?token=private',
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await _pumpRadio(
      tester,
      stations: stations,
      query: '',
      onClearTypeFilter: null,
      scale: 2,
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('radioStation-station-0'));
    expect(tester.getSize(first).width, 366);
    expect(find.text('example.com'), findsWidgets);
    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('token='), findsNothing);
    expect(find.byKey(const ValueKey('radioStation-station-19')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpAndSettle();
    expect(tester.getSize(first).width, lessThanOrEqualTo(360));
    final second = find.byKey(const ValueKey('radioStation-station-1'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/radio_cards_wide_scaled.png'),
    );
  });

  testWidgets(
    'radio card play and stop preserve stream identity and show playing text',
    (tester) async {
      final handler = _RadioHandler();
      await _pumpRadio(
        tester,
        stations: const [_station],
        query: '',
        onClearTypeFilter: null,
        handler: handler,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(handler.startedId, _station.id);
      expect(handler.startedUrl, _station.streamUrl);
      await _pumpRadio(
        tester,
        stations: const [_station],
        query: '',
        onClearTypeFilter: null,
        handler: handler,
        activeId: _station.id,
      );
      await tester.pumpAndSettle();
      expect(find.text('Now Playing'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop radio'));
      await tester.pump();
      expect(handler.stops, 1);
      expect(tester.takeException(), isNull);
    },
  );

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
              localizationsDelegates: navisLocalizationsDelegates,
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
