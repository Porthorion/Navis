import 'dart:async';

import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/daos/local_radio_station_dao.dart';
import 'package:navis/src/features/library/data/radio_station_actions.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

import '../../../../helpers/test_theme.dart';

const _station = InternetRadioStation(
  id: 'ambient-station',
  name: 'Ambient Radio',
  streamUrl: 'https://example.com/ambient',
);

class _MockApi extends Mock implements SubsonicApiClient;
class _MockLocalStations extends Mock implements LocalRadioStationDao;

Future<void> _pumpRadio(
  WidgetTester tester, {
  required List<InternetRadioStation> stations,
  List<InternetRadioStation> local = const [],
  bool admin = false,
  bool serverFails = false,
  Future<List<InternetRadioStation>>? serverLoad,
  RadioStationActions? actions,
  required String query,
  required VoidCallback? onClearTypeFilter,
  String? activeId,
  NavisPlaybackHandler? handler,
  double scale = 1,
  AppNoticeController? notices,
  Size size = Size.zero,
  Stream<List<InternetRadioStation>>? localStream,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        radioStationsProvider.overrideWith((ref) async {
          if (serverLoad != null) return await serverLoad;
          if (serverFails) throw StateError('offline');
          return stations;
        }),
        localRadioStationsProvider.overrideWith(
          (ref) => localStream ?? Stream.value(local),
        ),
        serverUserIsAdminProvider.overrideWith((ref) async => admin),
        if (actions != null)
          radioStationActionsProvider.overrideWithValue(actions),
        currentRadioStationIdProvider.overrideWithValue(activeId),
        audioHandlerProvider.overrideWithValue(handler),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
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
  Exception? error;
  final loads = <String, Completer<void>>{};
  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    if (error != null) throw error!;
    startedId = stationId;
    startedUrl = streamUrl;
    await loads[stationId]?.future;
  }

  @override
  Future<void> stopRadio() async => stops++;
  // The playback provider subscribes to the snapshot stream up front.
  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();
  @override
  Stream<PlaybackSnapshot> get snapshotStream => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('handler-owned radio failure does not show a second notice', (
    tester,
  ) async {
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    final handler = _RadioHandler()
      ..error = const RadioPlaybackUnavailableException();
    await _pumpRadio(
      tester,
      stations: const [_station],
      query: '',
      onClearTypeFilter: null,
      handler: handler,
      notices: notices,
    );
    await tester.pumpAndSettle();
    // The shell has already shown the handler's radioStreamErrorStream notice.
    notices.show(message: 'Station unavailable', level: AppNoticeLevel.error);
    final noticeId = notices.notice!.id;
    var additionalNotices = 0;
    notices.addListener(() => additionalNotices++);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(notices.notice!.id, noticeId);
    expect(additionalNotices, 0);
  });

  testWidgets('blocked radio explains the online services switch', (
    tester,
  ) async {
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    final handler = _RadioHandler()
      ..error = const RadioPlaybackBlockedException();
    await _pumpRadio(
      tester,
      stations: const [_station],
      query: '',
      onClearTypeFilter: null,
      handler: handler,
      notices: notices,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(
      notices.notice?.message,
      'Online services are off. Turn them on in Integrations to play stations outside your server.',
    );
  });

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
              localRadioStationsProvider.overrideWith(
                (ref) => Stream.value(const <InternetRadioStation>[]),
              ),
              serverUserIsAdminProvider.overrideWith((ref) async => false),
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
      find.text(
        'Add a station to this device, or add internet radio stations on your server.',
      ),
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

  group('search field', () {
    const device = InternetRadioStation(
      id: 'local:1',
      name: 'Basement FM',
      streamUrl: 'https://basement.example/live',
    );
    const jazz = InternetRadioStation(
      id: 'jazz',
      name: 'Basement Jazz',
      streamUrl: 'https://jazz.example/live',
    );

    Future<void> pump(
      WidgetTester tester, {
      List<InternetRadioStation> server = const [_station, jazz],
      List<InternetRadioStation> local = const [device],
      Size size = Size.zero,
      String query = '',
      Stream<List<InternetRadioStation>>? localStream,
    }) async {
      await _pumpRadio(
        tester,
        stations: server,
        local: local,
        query: query,
        onClearTypeFilter: null,
        size: size,
        localStream: localStream,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('touch layouts show the field when stations exist', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Search stations...'), findsOneWidget);
    });

    testWidgets('touch layouts hide the field when there are no stations', (
      tester,
    ) async {
      await pump(tester, server: const [], local: const []);
      expect(find.text('No Radio Stations Found'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('typing filters device and server sections', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'BASE');
      await tester.pumpAndSettle();
      expect(find.text('Basement FM'), findsOneWidget);
      expect(find.text('Basement Jazz'), findsOneWidget);
      expect(find.text('Ambient Radio'), findsNothing);
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('On your server'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'jazz');
      await tester.pumpAndSettle();
      expect(find.text('Basement Jazz'), findsOneWidget);
      expect(find.text('Basement FM'), findsNothing);
      expect(find.text('On this device'), findsNothing);
    });

    testWidgets('no matches shows the empty state and Show All clears it', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No Stations Match \u201czzz\u201d'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('radioClearTypeFilterAction')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(find.text('Ambient Radio'), findsOneWidget);
      expect(find.text('Basement FM'), findsOneWidget);
    });

    testWidgets('a stale filter is cleared when the stations disappear', (
      tester,
    ) async {
      final stations = StreamController<List<InternetRadioStation>>();
      addTearDown(stations.close);
      await pump(tester, server: const [], localStream: stations.stream);
      stations.add(const [device]);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      stations.add(const []);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);

      stations.add(const [device]);
      await tester.pumpAndSettle();
      expect(find.text('Basement FM'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('a whitespace-only query shows every station', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      expect(find.text('Ambient Radio'), findsOneWidget);
      expect(find.text('Basement FM'), findsOneWidget);
      expect(find.textContaining('No Stations Match'), findsNothing);
    });

    testWidgets('the field and query survive a server refresh', (tester) async {
      var loads = 0;
      final refresh = Completer<List<InternetRadioStation>>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            radioStationsProvider.overrideWith(
              (ref) async => ++loads == 1 ? const [_station] : refresh.future,
            ),
            localRadioStationsProvider.overrideWith(
              (ref) => Stream.value(const <InternetRadioStation>[]),
            ),
            serverUserIsAdminProvider.overrideWith((ref) async => false),
            currentRadioStationIdProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: RadioTabContent()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'amb');
      await tester.pumpAndSettle();

      ProviderScope.containerOf(tester.element(find.byType(RadioTabContent)))
          .invalidate(radioStationsProvider);
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'amb',
      );

      refresh.complete(const [_station]);
      await tester.pumpAndSettle();
      expect(find.text('Ambient Radio'), findsOneWidget);
    });

    testWidgets('desktop keeps type-to-filter and has no field', (
      tester,
    ) async {
      await pump(tester, size: const Size(1366, 900), query: 'jazz');
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Basement Jazz'), findsOneWidget);
      expect(find.text('Basement FM'), findsNothing);
      expect(find.text('Ambient Radio'), findsNothing);
    });
  });

  group('device stations and admin editing', () {
    const device = InternetRadioStation(
      id: 'local:1',
      name: 'Basement FM',
      streamUrl: 'https://basement.example/live',
      homePageUrl: 'https://basement.example',
    );
    late _MockApi api;
    late _MockLocalStations dao;
    late RadioStationActions actions;
    var serverChanges = 0;

    setUp(() {
      api = _MockApi();
      dao = _MockLocalStations();
      serverChanges = 0;
      actions = RadioStationActions(
        localStations: dao,
        api: api,
        onServerChanged: () => serverChanges++,
      );
      when(
        () => dao.upsert(
          id: any(named: 'id'),
          name: any(named: 'name'),
          streamUrl: any(named: 'streamUrl'),
          homePageUrl: any(named: 'homePageUrl'),
        ),
      ).thenAnswer((_) async => 'local:new');
      when(() => dao.deleteStation(any())).thenAnswer((_) async {});
      when(
        () => api.createInternetRadioStation(
          name: any(named: 'name'),
          streamUrl: any(named: 'streamUrl'),
          homepageUrl: any(named: 'homepageUrl'),
        ),
      ).thenAnswer((_) async {});
      when(() => api.deleteInternetRadioStation(any()))
          .thenAnswer((_) async {});
    });

    Future<void> pump(
      WidgetTester tester, {
      List<InternetRadioStation> server = const [_station],
      List<InternetRadioStation> local = const [device],
      bool admin = false,
      bool serverFails = false,
      String query = '',
      AppNoticeController? notices,
    }) async {
      await _pumpRadio(
        tester,
        stations: server,
        local: local,
        admin: admin,
        serverFails: serverFails,
        actions: actions,
        query: query,
        onClearTypeFilter: null,
        notices: notices,
      );
      await tester.pumpAndSettle();
    }

    Future<void> longPress(WidgetTester tester, String id) async {
      await tester.longPress(find.byKey(ValueKey('radioStation-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester, String key, String text) async {
      await tester.enterText(find.byKey(ValueKey(key)), text);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('radioEditorSave')));
      await tester.pumpAndSettle();
    }

    testWidgets('device stations get their own headed section', (tester) async {
      await pump(tester);
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('On your server'), findsOneWidget);
      expect(find.text('Basement FM'), findsOneWidget);
      expect(find.text('Ambient Radio'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('On this device')).dy,
        lessThan(tester.getTopLeft(find.text('Basement FM')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Basement FM')).dy,
        lessThan(tester.getTopLeft(find.text('On your server')).dy),
      );
    });

    testWidgets('no device stations keeps the plain layout without headers', (
      tester,
    ) async {
      await pump(tester, local: const []);
      expect(find.text('Ambient Radio'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
      expect(find.text('On your server'), findsNothing);
    });

    testWidgets('the type filter applies to both sections', (tester) async {
      await pump(tester, query: 'base');
      expect(find.text('Basement FM'), findsOneWidget);
      expect(find.text('Ambient Radio'), findsNothing);
      expect(find.text('On your server'), findsNothing);
    });

    testWidgets('filtered device stations stay empty while server loads', (
      tester,
    ) async {
      final serverLoad = Completer<List<InternetRadioStation>>();
      var cleared = false;
      await _pumpRadio(
        tester,
        stations: const [],
        local: const [device],
        serverLoad: serverLoad.future,
        query: 'lofi',
        onClearTypeFilter: () => cleared = true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No Stations Match “lofi”'), findsOneWidget);
      expect(find.byType(ShimmerListPage), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('radioClearTypeFilterAction')),
      );
      expect(cleared, isTrue);
      serverLoad.complete(const []);
      await tester.pumpAndSettle();
    });

    testWidgets('a server error keeps device stations and shows a retry row', (
      tester,
    ) async {
      await pump(tester, serverFails: true);
      expect(find.text('Basement FM'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('radio-server-load-error')),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a server error without device stations stays full page', (
      tester,
    ) async {
      await pump(tester, serverFails: true, local: const []);
      expect(find.text('Could Not Load Radio Stations'), findsOneWidget);
      expect(find.byKey(const ValueKey('radioAddFab')), findsOneWidget);
    });

    testWidgets('long-press on a device station offers Edit and Delete', (
      tester,
    ) async {
      await pump(tester);
      await longPress(tester, device.id);
      expect(find.text('Edit station'), findsOneWidget);
      expect(find.text('Delete station'), findsOneWidget);
    });

    testWidgets('long-press on a server station needs admin rights', (
      tester,
    ) async {
      await pump(tester);
      await longPress(tester, _station.id);
      expect(find.text('Edit station'), findsNothing);
      expect(find.text('Delete station'), findsNothing);
    });

    testWidgets('admins can edit and delete server stations', (tester) async {
      await pump(tester, admin: true);
      await longPress(tester, _station.id);
      expect(find.text('Edit station'), findsOneWidget);
      expect(find.text('Delete station'), findsOneWidget);
    });

    testWidgets('the Save to server switch appears for admins when adding', (
      tester,
    ) async {
      await pump(tester, admin: true);
      await tester.tap(find.byKey(const ValueKey('radioAddFab')));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('radioEditorSaveToServer')),
      );
      expect(tile.value, isFalse);
      expect(find.textContaining('Visible to every user'), findsOneWidget);
    });

    for (final serverFails in [false, true]) {
      testWidgets(
        serverFails
            ? 'admins get no switch while the server list is unavailable'
            : 'non-admins get no switch',
        (tester) async {
          await pump(tester, admin: serverFails, serverFails: serverFails);
          await tester.tap(find.byKey(const ValueKey('radioAddFab')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('radioEditorSave')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('radioEditorSaveToServer')),
            findsNothing,
          );
        },
      );
    }

    testWidgets('editing never offers the switch and prefills the fields', (
      tester,
    ) async {
      await pump(tester, admin: true);
      await longPress(tester, device.id);
      await tester.tap(find.text('Edit station'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('radioEditorSaveToServer')),
        findsNothing,
      );
      expect(find.text('Basement FM'), findsWidgets);
      await fill(tester, 'radioEditorName', 'Basement FM 2');
      await save(tester);
      verify(
        () => dao.upsert(
          id: 'local:1',
          name: 'Basement FM 2',
          streamUrl: device.streamUrl,
          homePageUrl: device.homePageUrl,
        ),
      ).called(1);
      expect(find.byKey(const ValueKey('radioEditorSave')), findsNothing);
    });

    for (final url in ['ftp://radio.example/stream', 'file:///tmp/audio']) {
      testWidgets('the editor rejects $url inline', (tester) async {
        await pump(tester);
        await tester.tap(find.byKey(const ValueKey('radioAddFab')));
        await tester.pumpAndSettle();
        await fill(tester, 'radioEditorName', 'Bad');
        await fill(tester, 'radioEditorStreamUrl', url);
        await save(tester);
        expect(
          find.text('Enter a full address starting with http:// or https://.'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('radioEditorSave')), findsOneWidget);
        verifyNever(
          () => dao.upsert(
            id: any(named: 'id'),
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homePageUrl: any(named: 'homePageUrl'),
          ),
        );
      });
    }

    testWidgets('the editor asks for a name', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('radioAddFab')));
      await tester.pumpAndSettle();
      await fill(tester, 'radioEditorStreamUrl', 'https://radio.example/s');
      await save(tester);
      expect(find.text('Enter a name for this station.'), findsOneWidget);
    });

    testWidgets('adding saves to this device by default', (tester) async {
      await pump(tester, admin: true);
      await tester.tap(find.byKey(const ValueKey('radioAddFab')));
      await tester.pumpAndSettle();
      await fill(tester, 'radioEditorName', ' Night Owl ');
      await fill(tester, 'radioEditorStreamUrl', 'https://owl.example/live');
      await save(tester);
      verify(
        () => dao.upsert(
          id: null,
          name: 'Night Owl',
          streamUrl: 'https://owl.example/live',
          homePageUrl: null,
        ),
      ).called(1);
      verifyZeroInteractions(api);
    });

    testWidgets('an admin can save a new station to the server', (
      tester,
    ) async {
      await pump(tester, admin: true);
      await tester.tap(find.byKey(const ValueKey('radioAddFab')));
      await tester.pumpAndSettle();
      await fill(tester, 'radioEditorName', 'Shared');
      await fill(tester, 'radioEditorStreamUrl', 'https://shared.example/s');
      await tester.tap(find.byKey(const ValueKey('radioEditorSaveToServer')));
      await tester.pump();
      await save(tester);
      verify(
        () => api.createInternetRadioStation(
          name: 'Shared',
          streamUrl: 'https://shared.example/s',
          homepageUrl: null,
        ),
      ).called(1);
      expect(serverChanges, 1);
      verifyZeroInteractions(dao);
    });

    testWidgets('a failed save shows an inline error and preserves input', (
      tester,
    ) async {
      var attempts = 0;
      final retry = Completer<String>();
      when(
        () => dao.upsert(
          id: any(named: 'id'),
          name: any(named: 'name'),
          streamUrl: any(named: 'streamUrl'),
          homePageUrl: any(named: 'homePageUrl'),
        ),
      ).thenAnswer((_) async {
        if (++attempts == 2) return await retry.future;
        throw StateError('disk');
      });
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('radioAddFab')));
      await tester.pumpAndSettle();
      await fill(tester, 'radioEditorName', 'Night Owl');
      await fill(tester, 'radioEditorStreamUrl', 'https://owl.example/live');
      await fill(tester, 'radioEditorHomepage', 'https://owl.example');
      await save(tester);
      final error = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Could not save this station. Try again.'),
      );
      expect(error, findsOneWidget);
      expect(find.byKey(const ValueKey('radioEditorSave')), findsOneWidget);
      for (final entry in {
        'radioEditorName': 'Night Owl',
        'radioEditorStreamUrl': 'https://owl.example/live',
        'radioEditorHomepage': 'https://owl.example',
      }.entries) {
        expect(
          tester
              .widget<TextField>(find.byKey(ValueKey(entry.key)))
              .controller!
              .text,
          entry.value,
        );
      }
      await save(tester);
      expect(error, findsNothing);
      retry.completeError(StateError('disk again'));
      await tester.pumpAndSettle();
      expect(error, findsOneWidget);
      for (final key in [
        'radioEditorName',
        'radioEditorStreamUrl',
        'radioEditorHomepage',
      ]) {
        final text = tester
            .widget<TextField>(find.byKey(ValueKey(key)))
            .controller!
            .text;
        await fill(tester, key, '${text}2');
        await tester.pump();
        expect(error, findsNothing);
        await save(tester);
        expect(error, findsOneWidget);
      }
    });

    testWidgets('the delete dialog describes a device station', (tester) async {
      await pump(tester);
      await longPress(tester, device.id);
      await tester.tap(find.text('Delete station'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Station?'), findsOneWidget);
      expect(find.text('Basement FM'), findsWidgets);
      expect(find.text(device.streamUrl), findsOneWidget);
      expect(find.text(device.homePageUrl!), findsOneWidget);
      expect(find.text('Saved on this device only.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      verify(() => dao.deleteStation('local:1')).called(1);
      expect(find.text('Delete Station?'), findsNothing);
    });

    testWidgets('an admin delete warns that everyone loses the station', (
      tester,
    ) async {
      await pump(tester, admin: true);
      await longPress(tester, _station.id);
      await tester.tap(find.text('Delete station'));
      await tester.pumpAndSettle();
      expect(
        find.text('This removes the station from the server for everyone.'),
        findsOneWidget,
      );
      expect(find.text(_station.streamUrl), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      verify(() => api.deleteInternetRadioStation('ambient-station')).called(1);
      expect(serverChanges, 1);
    });

    testWidgets('cancelling the delete dialog changes nothing', (tester) async {
      await pump(tester);
      await longPress(tester, device.id);
      await tester.tap(find.text('Delete station'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => dao.deleteStation(any()));
    });

    testWidgets('a failed delete shows an error notice', (tester) async {
      final notices = AppNoticeController();
      addTearDown(notices.dispose);
      when(() => dao.deleteStation(any())).thenThrow(StateError('disk'));
      await pump(tester, notices: notices);
      await longPress(tester, device.id);
      await tester.tap(find.text('Delete station'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        notices.notice?.message,
        'Could not delete this station. Try again.',
      );
    });

    testWidgets(
      'with no stations anywhere, the empty state offers Add station',
      (tester) async {
        await pump(tester, server: const [], local: const []);
        expect(find.text('No Radio Stations Found'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('radioEmptyAddAction')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('radioEditorSave')), findsOneWidget);
      },
    );
  });
}
