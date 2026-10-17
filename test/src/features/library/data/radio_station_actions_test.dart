import 'dart:async';

import 'package:navis/src/api/subsonic_error.dart';
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

    group('moving a device station to the server', () {
      Future<InternetRadioStation> addDevice() async {
        final id = await database.localRadioStationDao.upsert(
          name: 'Dev',
          streamUrl: 'https://radio.example/dev',
          homePageUrl: 'https://radio.example',
        );
        return InternetRadioStation(
          id: id,
          name: 'Dev',
          streamUrl: 'https://radio.example/dev',
          homePageUrl: 'https://radio.example',
        );
      }

      setUp(() {
        var reads = 0;
        when(() => api.getInternetRadioStations()).thenAnswer(
          (_) async => [
            if (reads++ > 0)
              const InternetRadioStation(
                id: 'new',
                name: 'Dev 2',
                streamUrl: 'https://radio.example/dev',
              ),
          ],
        );
      });

      test(
        'radio commit then timeout resolves on retry without duplicate',
        () async {
          final device = await addDevice();
          var committed = false;
          var failRead = true;
          when(() => api.getInternetRadioStations()).thenAnswer((_) async {
            if (committed && failRead) {
              failRead = false;
              throw const SubsonicConnectionException('offline');
            }
            return [
              if (committed)
                const InternetRadioStation(
                  id: 'new',
                  name: 'Dev',
                  streamUrl: 'https://radio.example/dev',
                ),
            ];
          });
          when(
            () => api.createInternetRadioStation(
              name: any(named: 'name'),
              streamUrl: any(named: 'streamUrl'),
              homepageUrl: any(named: 'homepageUrl'),
            ),
          ).thenAnswer((_) async {
            committed = true;
            throw const SubsonicConnectionException('timeout');
          });
          Future<void> save() => actions.save(
            existing: device,
            isLocal: true,
            moveToServer: true,
            name: 'Dev',
            streamUrl: device.streamUrl,
          );
          await expectLater(
            save(),
            throwsA(isA<SubsonicConnectionException>()),
          );
          await save();
          expect(await database.localRadioStationDao.watchAll().first, isEmpty);
          verify(
            () => api.createInternetRadioStation(
              name: any(named: 'name'),
              streamUrl: any(named: 'streamUrl'),
              homepageUrl: any(named: 'homepageUrl'),
            ),
          ).called(1);
        },
      );

      for (final field in ['name', 'stream', 'homepage']) {
        test(
          'radio move preserves device $field edited during create',
          () async {
            final device = await addDevice();
            when(
              () => api.createInternetRadioStation(
                name: any(named: 'name'),
                streamUrl: any(named: 'streamUrl'),
                homepageUrl: any(named: 'homepageUrl'),
              ),
            ).thenAnswer((_) async {
              await database.localRadioStationDao.upsert(
                id: device.id,
                name: field == 'name' ? 'Edited' : device.name,
                streamUrl: field == 'stream'
                    ? 'https://radio.example/new'
                    : device.streamUrl,
                homePageUrl: field == 'homepage' ? null : device.homePageUrl,
              );
            });
            final result = await actions.save(
              existing: device,
              isLocal: true,
              moveToServer: true,
              name: 'Dev 2',
              streamUrl: device.streamUrl,
              homePageUrl: device.homePageUrl,
            );
            expect(result.deviceCopyKept, isTrue);
            expect(
              await database.localRadioStationDao.watchAll().first,
              hasLength(1),
            );
          },
        );
      }

      test('ambiguous radio create keeps device copy on retry', () async {
        final device = await addDevice();
        var reads = 0;
        when(() => api.getInternetRadioStations()).thenAnswer(
          (_) async => [
            const InternetRadioStation(
              id: 'old',
              name: 'Dev',
              streamUrl: 'https://radio.example/dev',
            ),
            if (reads++ > 0) ...const [
              InternetRadioStation(
                id: 'x',
                name: 'Dev',
                streamUrl: 'https://radio.example/dev',
              ),
              InternetRadioStation(
                id: 'y',
                name: 'Dev',
                streamUrl: 'https://radio.example/dev',
              ),
            ],
          ],
        );
        when(
          () => api.createInternetRadioStation(
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homepageUrl: any(named: 'homepageUrl'),
          ),
        ).thenAnswer((_) async {});
        Future<void> save() => actions.save(
          existing: device,
          isLocal: true,
          moveToServer: true,
          name: 'Dev',
          streamUrl: device.streamUrl,
        );
        await expectLater(save(), throwsStateError);
        await expectLater(save(), throwsStateError);
        expect(
          (await database.localRadioStationDao.watchAll().first).single.id,
          device.id,
        );
        verify(
          () => api.createInternetRadioStation(
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homepageUrl: any(named: 'homepageUrl'),
          ),
        ).called(1);
      });

      test('radio double submit makes one create', () async {
        final device = await addDevice();
        final started = Completer<void>();
        final gate = Completer<void>();
        when(
          () => api.createInternetRadioStation(
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homepageUrl: any(named: 'homepageUrl'),
          ),
        ).thenAnswer((_) {
          if (!started.isCompleted) started.complete();
          return gate.future;
        });
        Future<void> save() => actions.save(
          existing: device,
          isLocal: true,
          moveToServer: true,
          name: 'Dev 2',
          streamUrl: device.streamUrl,
        );
        final first = save();
        await started.future;
        final second = save();
        gate.complete();
        await Future.wait([first, second]);
        verify(
          () => api.createInternetRadioStation(
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homepageUrl: any(named: 'homepageUrl'),
          ),
        ).called(1);
      });

      test('creates the server station, then deletes the device row', () async {
        final device = await addDevice();
        when(
          () => api.createInternetRadioStation(
            name: 'Dev 2',
            streamUrl: device.streamUrl,
            homepageUrl: 'https://radio.example',
          ),
        ).thenAnswer((_) async {});
        await container.read(radioStationsProvider.future);

        await actions.save(
          existing: device,
          isLocal: true,
          moveToServer: true,
          name: 'Dev 2',
          streamUrl: device.streamUrl,
          homePageUrl: device.homePageUrl,
        );

        expect(await database.localRadioStationDao.watchAll().first, isEmpty);
        verify(
          () => api.createInternetRadioStation(
            name: 'Dev 2',
            streamUrl: device.streamUrl,
            homepageUrl: 'https://radio.example',
          ),
        ).called(1);
        await container.read(radioStationsProvider.future);
        expect(serverReads, 2);
      });

      test('keeps the device station when the server create fails', () async {
        final device = await addDevice();
        final failure = StateError('Permission denied');
        when(
          () => api.createInternetRadioStation(
            name: any(named: 'name'),
            streamUrl: any(named: 'streamUrl'),
            homepageUrl: any(named: 'homepageUrl'),
          ),
        ).thenThrow(failure);

        await expectLater(
          actions.save(
            existing: device,
            isLocal: true,
            moveToServer: true,
            name: 'Dev',
            streamUrl: device.streamUrl,
          ),
          throwsA(same(failure)),
        );

        expect(
          (await database.localRadioStationDao.watchAll().first).single.id,
          device.id,
        );
      });
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
