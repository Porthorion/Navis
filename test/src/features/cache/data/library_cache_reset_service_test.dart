import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import '../../../../helpers/test_database.dart';

void main() {
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
          .insert(
            ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
          );
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
