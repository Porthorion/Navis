import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';

import '../../../../helpers/test_database.dart';

Future<void> _scanSongs(NavisDatabase database, List<String> ids) =>
    database.libraryDao.upsertSongs([
      for (final id in ids) SongsTableCompanion.insert(id: id, title: id),
    ]);

void main() {
  late NavisDatabase database;
  late LibraryCacheResetService reset;

  setUp(() {
    database = createTestDatabase();
    reset = LibraryCacheResetService(database: database);
  });
  tearDown(() => database.close());

  Future<void> saveQueue() async {
    await _scanSongs(database, ['a', 'b', 'c']);
    await database.playQueueDao.saveQueue(
      songIds: ['a', 'b', 'a', 'c'],
      currentIndex: 2,
      shuffleMode: ShuffleMode.all,
      repeatMode: RepeatMode.one,
      positionMs: 12345,
      originalOrder: [2, 0, 3, 1],
    );
  }

  CacheSystemUpgradeService upgrade(Future<bool> Function() scan) =>
      CacheSystemUpgradeService(
        database: database,
        cacheResetService: reset,
        triggerFullLibraryScan: scan,
        currentEpoch: () async => 1005,
        hasCommittedCatalog: () async => true,
      );

  group('saved queue across library reset', () {
    test(
      'upgrade rescan retains duplicate occurrences and all state',
      () async {
        await saveQueue();
        await upgrade(() async {
          expect(await database.playQueueDao.getQueueItems(), isEmpty);
          expect(await database.playQueueDao.getQueueState(), isNull);
          await _scanSongs(database, ['a', 'b', 'c']);
          return true;
        }).resetAndMarkCurrent();

        final entries = await database.playQueueDao.getQueueEntries();
        expect(entries.map((entry) => entry.song.id), ['a', 'b', 'a', 'c']);
        expect(entries.map((entry) => entry.originalOrder), [2, 0, 3, 1]);
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 2);
        expect(state.shuffleMode, ShuffleMode.all);
        expect(state.repeatMode, RepeatMode.one);
        expect(state.positionMs, 12345);
      },
    );

    test('missing songs are dropped and current occurrence follows', () async {
      await saveQueue();
      final snapshot = await reset.reset();
      await _scanSongs(database, ['a', 'c']);
      await snapshot!.restore();

      final entries = await database.playQueueDao.getQueueEntries();
      expect(entries.map((entry) => entry.song.id), ['a', 'a', 'c']);
      expect(entries.map((entry) => entry.originalOrder), [2, 3, 1]);
      expect((await database.playQueueDao.getQueueState())!.currentIndex, 1);
    });

    test(
      'removed current song clamps index and preserves legacy ranks',
      () async {
        await saveQueue();
        await database.playQueueDao.saveQueue(
          songIds: ['a', 'b', 'c'],
          currentIndex: 2,
        );
        final snapshot = await reset.reset();
        await _scanSongs(database, ['a', 'b']);
        await snapshot!.restore();

        expect((await database.playQueueDao.getQueueState())!.currentIndex, 1);
        expect(
          (await database.playQueueDao.getQueueEntries()).map(
            (entry) => entry.originalOrder,
          ),
          [null, null],
        );
      },
    );

    for (final throws in [false, true]) {
      test('failed scan leaves queue cleared: throws=$throws', () async {
        await saveQueue();
        await expectLater(
          upgrade(() async {
            await _scanSongs(database, ['a', 'b', 'c']);
            if (throws) throw StateError('scan failed');
            return false;
          }).resetAndMarkCurrent(),
          throwsStateError,
        );
        expect(await database.playQueueDao.getQueueItems(), isEmpty);
        expect(await database.playQueueDao.getQueueState(), isNull);
        expect(await database.cacheSystemStateDao.getVersion(), isNull);
      });
    }

    test(
      'successful scan with no surviving songs leaves queue cleared',
      () async {
        await saveQueue();
        await upgrade(() async {
          await _scanSongs(database, ['new']);
          return true;
        }).resetAndMarkCurrent();
        expect(await database.playQueueDao.getQueueItems(), isEmpty);
        expect(await database.playQueueDao.getQueueState(), isNull);
      },
    );

    test('a newly saved live queue takes precedence over snapshot', () async {
      await saveQueue();
      final snapshot = await reset.reset();
      await _scanSongs(database, ['a', 'b', 'c']);
      await database.playQueueDao.saveQueue(songIds: ['c'], currentIndex: 0);
      await snapshot!.restore();
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ['c'],
      );
      expect((await database.playQueueDao.getQueueState())!.currentIndex, 0);
    });

    test(
      'live state-only persistence retains newer position and index',
      () async {
        await saveQueue();
        final snapshot = await reset.reset();
        await database.playQueueDao.savePlaybackState(
          currentIndex: 3,
          positionMs: 54321,
        );
        await _scanSongs(database, ['a', 'c']);
        await snapshot!.restore();
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 2);
        expect(state.positionMs, 54321);
      },
    );
  }, skip: !sqliteAvailable);
}
