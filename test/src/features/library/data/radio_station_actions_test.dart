import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/local_radio_station_dao.dart';
import 'package:navis/src/features/library/data/radio_station_actions.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;
class _MockLocalStations extends Mock implements LocalRadioStationDao;

void main() {
  group('RadioStationActions', () {
    late NavisDatabase database;
    late ProviderContainer container;
    late _MockApi api;
    late RadioStationActions actions;
    late int serverReads;
    const station = InternetRadioStation(
      id: 'r1',
      name: 'Old',
      streamUrl: 'https://radio.example/old',
    );

    setUp(() {
      database = createTestDatabase();
      api = _MockApi();
      serverReads = 0;
      container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            radioStationsProvider.overrideWith((ref) async {
              serverReads++;
              return [];
            }),
          ],
        ),
      );
      actions = container.read(radioStationActionsProvider);
    });
    tearDown(() async {
      container.dispose();
      await database.close();
    });

    for (final isLocal in [true, false]) {
      for (final url in [
        'ftp://radio.example/stream',
        'file:///tmp/audio',
        'content://media/audio',
        '/relative',
        'https:',
        'https:///',
      ]) {
        test(
          'rejects invalid stream $url local=$isLocal before writing',
          () async {
            await expectLater(
              actions.save(isLocal: isLocal, name: 'Station', streamUrl: url),
              throwsArgumentError,
            );
            expect(
              await database.localRadioStationDao.watchAll().first,
              isEmpty,
            );
            verifyZeroInteractions(api);
          },
        );
        test(
          'rejects invalid homepage $url local=$isLocal before writing',
          () async {
            await expectLater(
              actions.save(
                isLocal: isLocal,
                name: 'Station',
                streamUrl: 'https://radio.example/stream',
                homePageUrl: url,
              ),
              throwsArgumentError,
            );
            verifyZeroInteractions(api);
          },
        );
      }
      test('rejects blank names local=$isLocal', () async {
        await expectLater(
          actions.save(
            isLocal: isLocal,
            name: '  ',
            streamUrl: 'https://radio.example/stream',
          ),
          throwsArgumentError,
        );
        verifyZeroInteractions(api);
      });
    }

    test(
      'local create/update/delete trims fields and leaves server cache alone',
      () async {
        await container.read(radioStationsProvider.future);
        await actions.save(
          isLocal: true,
          name: ' Station ',
          streamUrl: ' http://radio.example/stream ',
          homePageUrl: ' https://radio.example ',
        );
        final row =
            (await database.localRadioStationDao.watchAll().first).single;
        expect(row.id, startsWith('local:'));
        expect(row.name, 'Station');
        expect(row.streamUrl, 'http://radio.example/stream');
        expect(row.homePageUrl, 'https://radio.example');
        final local = InternetRadioStation(
          id: row.id,
          name: row.name,
          streamUrl: row.streamUrl,
          homePageUrl: row.homePageUrl,
        );
        await actions.save(
          existing: local,
          isLocal: true,
          name: 'Renamed',
          streamUrl: local.streamUrl,
          homePageUrl: '  ',
        );
        final updated =
            (await database.localRadioStationDao.watchAll().first).single;
        expect(updated.id, row.id);
        expect(updated.name, 'Renamed');
        expect(updated.homePageUrl, isNull);
        await actions.delete(local, isLocal: true);
        expect(await database.localRadioStationDao.watchAll().first, isEmpty);
        await container.read(radioStationsProvider.future);
        expect(serverReads, 1);
        verifyZeroInteractions(api);
      },
    );

    test(
      'server create/update/delete invalidates the station list after success',
      () async {
        when(
          () => api.createInternetRadioStation(
            name: 'Station',
            streamUrl: 'https://radio.example/stream',
            homepageUrl: 'https://radio.example',
          ),
        ).thenAnswer((_) async {});
        when(
          () => api.updateInternetRadioStation(
            id: 'r1',
            name: 'Renamed',
            streamUrl: 'https://radio.example/new',
            homepageUrl: null,
          ),
        ).thenAnswer((_) async {});
        when(() => api.deleteInternetRadioStation('r1'))
            .thenAnswer((_) async {});
        await container.read(radioStationsProvider.future);
        await actions.save(
          isLocal: false,
          name: ' Station ',
          streamUrl: ' https://radio.example/stream ',
          homePageUrl: ' https://radio.example ',
        );
        await container.read(radioStationsProvider.future);
        expect(serverReads, 2);
        verify(
          () => api.createInternetRadioStation(
            name: 'Station',
            streamUrl: 'https://radio.example/stream',
            homepageUrl: 'https://radio.example',
          ),
        ).called(1);
        await actions.save(
          existing: station,
          isLocal: false,
          name: 'Renamed',
          streamUrl: 'https://radio.example/new',
          homePageUrl: '',
        );
        await container.read(radioStationsProvider.future);
        expect(serverReads, 3);
        verify(
          () => api.updateInternetRadioStation(
            id: 'r1',
            name: 'Renamed',
            streamUrl: 'https://radio.example/new',
            homepageUrl: null,
          ),
        ).called(1);
        await actions.delete(station, isLocal: false);
        await container.read(radioStationsProvider.future);
        expect(serverReads, 4);
        verify(() => api.deleteInternetRadioStation('r1')).called(1);
        expect(await database.localRadioStationDao.watchAll().first, isEmpty);
      },
    );

    test('server failures propagate without invalidating the list', () async {
      final failure = StateError('Permission denied');
      when(
        () => api.createInternetRadioStation(
          name: 'Station',
          streamUrl: station.streamUrl,
          homepageUrl: null,
        ),
      ).thenThrow(failure);
      when(
        () => api.updateInternetRadioStation(
          id: station.id,
          name: 'Station',
          streamUrl: station.streamUrl,
          homepageUrl: null,
        ),
      ).thenThrow(failure);
      when(() => api.deleteInternetRadioStation(station.id)).thenThrow(failure);
      await container.read(radioStationsProvider.future);
      for (final existing in <InternetRadioStation?>[null, station]) {
        await expectLater(
          actions.save(
            existing: existing,
            isLocal: false,
            name: 'Station',
            streamUrl: station.streamUrl,
          ),
          throwsA(same(failure)),
        );
      }
      await expectLater(
        actions.delete(station, isLocal: false),
        throwsA(same(failure)),
      );
      await container.read(radioStationsProvider.future);
      expect(serverReads, 1);
    });

    test('local storage failures propagate', () async {
      final dao = _MockLocalStations();
      final failure = StateError('Storage unavailable');
      when(() => dao.upsert(name: 'Station', streamUrl: station.streamUrl))
          .thenThrow(failure);
      when(() => dao.deleteStation(station.id)).thenThrow(failure);
      var invalidated = false;
      final failingActions = RadioStationActions(
        localStations: dao,
        api: api,
        onServerChanged: () => invalidated = true,
      );
      await expectLater(
        failingActions.save(
          isLocal: true,
          name: 'Station',
          streamUrl: station.streamUrl,
        ),
        throwsA(same(failure)),
      );
      await expectLater(
        failingActions.delete(station, isLocal: true),
        throwsA(same(failure)),
      );
      expect(invalidated, isFalse);
      verifyZeroInteractions(api);
    });

    test('without an API server writes fail but local writes work', () async {
      container.dispose();
      container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [subsonicApiProvider.overrideWithValue(null)],
        ),
      );
      actions = container.read(radioStationActionsProvider);
      await expectLater(
        actions.save(
          isLocal: false,
          name: 'Station',
          streamUrl: station.streamUrl,
        ),
        throwsStateError,
      );
      await expectLater(
        actions.delete(station, isLocal: false),
        throwsStateError,
      );
      await actions.save(
        isLocal: true,
        name: 'Station',
        streamUrl: station.streamUrl,
      );
      expect(
        await database.localRadioStationDao.watchAll().first,
        hasLength(1),
      );
    });
  }, skip: !sqliteAvailable);
}
