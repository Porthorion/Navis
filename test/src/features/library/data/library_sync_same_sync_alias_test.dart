import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/test_database.dart';

void main() {
  test(
    'a rebuilt album keeps its download under the new song id after the '
    'promoting sync',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final files = await Directory.systemTemp.createTemp('navis_late_alias_');
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
      final api = FakeLibrarySyncApi();
      final engine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: repository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
        isolateThreshold: 1000,
      );
      void serve(String albumId, String songId) {
        final album = Album(
          id: albumId,
          name: 'Album',
          artistId: 'artist',
          songCount: 1,
          songs: <Song>[
            Song(
              id: songId,
              title: 'Track',
              albumId: albumId,
              artistId: 'artist',
              track: 1,
              musicBrainzId: 'recording',
            ),
          ],
        );
        api.artists
          ..clear()
          ..add(const Artist(id: 'artist', name: 'Artist'));
        api.fastPathPages
          ..clear()
          ..[0] = <Album>[album];
        api.albumDetails
          ..clear()
          ..[albumId] = album;
      }

      serve('old-album', 'old-song');
      expect(
        (await engine.forceFullSync()).status,
        LibrarySyncStatus.succeeded,
      );
      final download = File('${files.path}/old-song.mp3')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'old-song',
          filePath: download.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.utc(2026),
        ),
      );

      // The server rebuilds its ids. The promoting sync keeps the download
      // of the removed album as a provisional row and, in the same sync,
      // links it to the new id by its recording MBID.
      serve('new-album', 'new-song');
      var promoted = false;
      for (var run = 0; run < 3 && !promoted; run++) {
        await engine.forceFullSync();
        promoted = await database.libraryDao.getSongById('new-song') != null;
      }
      expect(promoted, isTrue);

      final aliases = await database.songIdentityDao.getAliases();
      expect(
        aliases.map((alias) => (alias.oldSongId, alias.canonicalSongId)),
        <(String, String)>[('old-song', 'new-song')],
      );
      expect(await database.libraryDao.getSongById('old-song'), isNull);
      final cached = await database.cacheDao.getCachedTrack('new-song');
      expect(cached?.filePath, download.path);
      expect(cached?.cacheType, CacheType.permanent);
      expect(download.existsSync(), isTrue);
    },
    skip: !sqliteAvailable,
  );
}
