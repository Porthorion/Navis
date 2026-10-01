import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('new profiles are already on the current cache system', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final service = CacheSystemUpgradeService(
      database: database,
      cacheResetService: LibraryCacheResetService(database: database),
      triggerFullLibraryScan: () async => true,
    );

    expect(await service.needsReset(), isFalse);
  }, skip: !sqliteAvailable);

  test('previous cache contract requires a renewal', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.cacheSystemStateDao.markVersion(
      CacheSystemUpgradeService.currentVersion - 1,
    );
    final service = CacheSystemUpgradeService(
      database: database,
      cacheResetService: LibraryCacheResetService(database: database),
      triggerFullLibraryScan: () async => true,
    );

    expect(await service.needsReset(), isTrue);
  }, skip: !sqliteAvailable);

  test('legacy profiles remain pending until reset completes', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customStatement('DELETE FROM cache_system_state;');
    final service = CacheSystemUpgradeService(
      database: database,
      cacheResetService: LibraryCacheResetService(database: database),
      triggerFullLibraryScan: () async => true,
    );

    expect(await service.needsReset(), isTrue);
    await service.resetAndMarkCurrent();
    expect(await service.needsReset(), isFalse);
  }, skip: !sqliteAvailable);

  test(
    'renewal routing state refreshes after the cache version is acknowledged',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(database.close);
      addTearDown(container.dispose);
      await database.cacheSystemStateDao.markVersion(
        CacheSystemUpgradeService.currentVersion - 1,
      );

      expect(
        await container.read(cacheSystemUpgradeNeededProvider.future),
        isTrue,
      );

      await database.cacheSystemStateDao.markVersion(
        CacheSystemUpgradeService.currentVersion,
      );

      expect(
        await container.refresh(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'legacy profiles stay pending when the post-reset full scan fails',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customStatement('DELETE FROM cache_system_state;');
      var scanCalls = 0;
      final service = CacheSystemUpgradeService(
        database: database,
        cacheResetService: LibraryCacheResetService(database: database),
        triggerFullLibraryScan: () async {
          scanCalls += 1;
          return false;
        },
      );

      await expectLater(service.resetAndMarkCurrent(), throwsStateError);
      expect(scanCalls, 1);
      expect(await service.needsReset(), isTrue);
    },
    skip: !sqliteAvailable,
  );

  test(
    'reset removes recoverable cache and metadata but keeps downloads',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'navis_cache_reset_',
      );
      addTearDown(() async {
        await database.close();
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      });

      final rollingPath = '${directory.path}/rolling.mp3';
      final downloadPath = '${directory.path}/download.mp3';
      await File(rollingPath).writeAsString('rolling');
      await File('$rollingPath.part').writeAsString('part');
      await File(downloadPath).writeAsString('download');
      var clearCoverArtCalls = 0;

      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'));
      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album',
              artistId: const Value('artist-1'),
            ),
          );
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song',
              albumId: const Value('album-1'),
              artistId: const Value('artist-1'),
            ),
          );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-1',
          filePath: rollingPath,
          fileSize: 7,
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'download-1',
          filePath: downloadPath,
          fileSize: 8,
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
        ),
      );

      await LibraryCacheResetService(
        database: database,
        clearCoverArt: () async => clearCoverArtCalls += 1,
      ).reset();

      expect(File(rollingPath).existsSync(), isFalse);
      expect(File('$rollingPath.part').existsSync(), isFalse);
      expect(File(downloadPath).existsSync(), isTrue);
      expect(await database.cacheDao.getCachedTracks(), hasLength(1));
      expect(
        (await database.cacheDao.getCachedTracks()).single.songId,
        'download-1',
      );
      expect(await database.select(database.songsTable).get(), isEmpty);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      expect(await database.select(database.artistsTable).get(), isEmpty);
      expect(clearCoverArtCalls, 1);
    },
    skip: !sqliteAvailable,
  );
}
