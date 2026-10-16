import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('LocalRadioStationDao', () {
    late NavisDatabase database;
    setUp(() {
      database = createTestDatabase();
    });
    tearDown(() async {
      await database.close();
    });

    test('inserts distinct local UUIDs and sorts names without case', () async {
      final ids = <String>[];
      for (final name in ['beta', 'Zulu', 'alpha']) {
        ids.add(
          await database.localRadioStationDao.upsert(
            name: name,
            streamUrl: 'https://radio.example/stream',
          ),
        );
      }
      expect(ids.toSet(), hasLength(3));
      for (final id in ids) {
        expect(
          id,
          matches(
            RegExp(
              r'^local:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
      }
      expect(
        (await database.localRadioStationDao.watchAll().first).map(
          (row) => row.name,
        ),
        ['alpha', 'beta', 'Zulu'],
      );
    });

    test('updates in place, clears homepage, and deletes', () async {
      final dao = database.localRadioStationDao;
      final id = await dao.upsert(
        name: 'Original',
        streamUrl: 'https://radio.example/old',
        homePageUrl: 'https://radio.example',
      );
      expect(
        (await dao.watchAll().first).single.homePageUrl,
        'https://radio.example',
      );
      expect(
        await dao.upsert(
          id: id,
          name: 'Renamed',
          streamUrl: 'https://radio.example/new',
        ),
        id,
      );
      final row = (await dao.watchAll().first).single;
      expect(row.name, 'Renamed');
      expect(row.streamUrl, 'https://radio.example/new');
      expect(row.homePageUrl, isNull);
      await dao.deleteStation(id);
      expect(await dao.watchAll().first, isEmpty);
    });

    test('watch emits committed inserts, updates and deletes', () async {
      final dao = database.localRadioStationDao;
      final values = dao.watchAll();
      final expectation = expectLater(
        values,
        emitsInOrder([
          isEmpty,
          predicate<List<LocalRadioStationsTableData>>(
            (rows) => rows.single.name == 'First',
          ),
          predicate<List<LocalRadioStationsTableData>>(
            (rows) => rows.single.name == 'Second',
          ),
          isEmpty,
        ]),
      );
      await pumpEventQueue();
      final id = await dao.upsert(
        name: 'First',
        streamUrl: 'https://radio.example/stream',
      );
      await pumpEventQueue();
      await dao.upsert(
        id: id,
        name: 'Second',
        streamUrl: 'https://radio.example/stream',
      );
      await pumpEventQueue();
      await dao.deleteStation(id);
      await expectation;
    });
  }, skip: !sqliteAvailable);
}
