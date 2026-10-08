import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

void main() {
  test(
    'a promotion that rolls back keeps the cache files its remaps released',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final files = await Directory.systemTemp.createTemp('navis_rollback_');
      addTearDown(() => files.delete(recursive: true));
      final repository = ServerConfigRepository(
        database,
        credentials: FakeSyncCredentialStore(),
      );
      await repository.save(
        ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );

      // A cached song of an old album, and a rolling copy already cached
      // under the id the server now uses for the same recording: the remap
      // keeps the download and releases the rolling file.
      await database.libraryDao.upsertProvisionalArtists([
        ArtistsTableCompanion.insert(id: 'artist', name: 'Artist'),
      ]);
      await database.libraryDao.upsertProvisionalAlbums([
        AlbumsTableCompanion.insert(
          id: 'old-album',
          name: 'Album',
          artistId: const Value('artist'),
          releaseMbid: const Value('release'),
        ),
      ]);
      await database.libraryDao.upsertProvisionalSongs([
        SongsTableCompanion.insert(
          id: 'old-song',
          title: 'Track',
          albumId: const Value('old-album'),
          artistId: const Value('artist'),
          recordingMbid: const Value('recording'),
        ),
      ]);
      Future<File> cache(String songId, CacheType type) async {
        final file = File('${files.path}/$songId.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: songId,
            filePath: file.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: type,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.utc(2026),
          ),
        );
        return file;
      }

      final download = await cache('old-song', CacheType.permanent);
      final rolling = await cache('new-song', CacheType.rolling);

      final api = FakeLibrarySyncApi();
      api.artists.add(const Artist(id: 'artist', name: 'Artist'));
      const album = Album(
        id: 'new-album',
        name: 'Album',
        artistId: 'artist',
        songCount: 1,
        musicBrainzId: 'release',
        songs: <Song>[
          Song(
            id: 'new-song',
            title: 'Track',
            albumId: 'new-album',
            artistId: 'artist',
            musicBrainzId: 'recording',
          ),
        ],
      );
      api.fastPathPages[0] = const <Album>[album];
      api.albumDetails[album.id] = album;

      // The album alias comes after the song remap in the same promotion;
      // failing it rolls the whole promotion back.
      await database.customStatement('''
        CREATE TEMP TRIGGER fail_album_alias
        AFTER INSERT ON entity_identity_aliases
        WHEN NEW.entity_type = 'album'
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
      ''');

      final engine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: repository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
      );
      final result = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(result.status, isNot(LibrarySyncStatus.succeeded));
      expect(await database.songIdentityDao.getAliases(), isEmpty);
      final rolledBack = await database.cacheDao.getCachedTrack('new-song');
      expect(rolledBack?.filePath, rolling.path);
      expect(rolling.existsSync(), isTrue);
      expect(download.existsSync(), isTrue);
    },
    skip: !sqliteAvailable,
  );
}
