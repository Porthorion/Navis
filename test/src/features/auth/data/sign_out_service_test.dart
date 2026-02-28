import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import '../../../../helpers/test_database.dart';

class _FakeCredentialStore implements SecureCredentialStore {
  String? password;

  @override
  Future<void> clearPassword() async {
    password = null;
  }

  @override
  Future<String?> readPassword() async => password;

  @override
  Future<void> savePassword(String password) async {
    this.password = password;
  }
}

void main() {
  group('SignOutService', () {
    late NavisDatabase database;
    late _FakeCredentialStore credentials;
    late ServerConfigRepository repository;
    late SignOutService service;
    late Directory tmpDir;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      credentials = _FakeCredentialStore();
      repository = ServerConfigRepository(database, credentials: credentials);
      service = SignOutService(
        serverConfigRepository: repository,
        database: database,
      );
      tmpDir = Directory.systemTemp.createTempSync('navis_sign_out_test_');
    });

    tearDown(() async {
      await database.close();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('credentials-only sign out keeps local data', () async {
      final cacheFile = File('${tmpDir.path}/track.mp3');
      cacheFile.writeAsStringSync('audio');
      await _seedAuthenticatedData(database, repository, cacheFile.path);

      await service.signOut(wipeLocalData: false);

      expect(await database.serverDao.getActiveServer(), isNull);
      expect(credentials.password, isNull);
      expect((await database.select(database.artistsTable).get()).length, 1);
      expect(
        (await database.select(database.cachedTracksTable).get()).length,
        1,
      );
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
      expect(cacheFile.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test(
      'full wipe clears local data and deletes cached files',
      () async {
        final cacheFile = File('${tmpDir.path}/track.mp3');
        cacheFile.writeAsStringSync('audio');
        await _seedAuthenticatedData(database, repository, cacheFile.path);

        await service.signOut(wipeLocalData: true);

        expect(await database.serverDao.getActiveServer(), isNull);
        expect(credentials.password, isNull);
        expect(await database.select(database.artistsTable).get(), isEmpty);
        expect(await database.select(database.albumsTable).get(), isEmpty);
        expect(await database.select(database.songsTable).get(), isEmpty);
        expect(await database.select(database.playlistsTable).get(), isEmpty);
        expect(
          await database.select(database.playlistSongsTable).get(),
          isEmpty,
        );
        expect(await database.select(database.playHistoryTable).get(), isEmpty);
        expect(
          await database.select(database.recentSearchesTable).get(),
          isEmpty,
        );
        expect(
          await database.select(database.downloadQueueTable).get(),
          isEmpty,
        );
        expect(
          await database.select(database.cachedTracksTable).get(),
          isEmpty,
        );
        expect(await database.playQueueDao.watchQueueItems().first, isEmpty);
        expect(await database.starSyncDao.getPendingActions(), isEmpty);
        expect(cacheFile.existsSync(), isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('full wipe tolerates missing cached files', () async {
      final missingPath = '${tmpDir.path}/missing-track.mp3';
      await _seedAuthenticatedData(database, repository, missingPath);

      await service.signOut(wipeLocalData: true);

      expect(await database.serverDao.getActiveServer(), isNull);
      expect(credentials.password, isNull);
      expect(await database.select(database.cachedTracksTable).get(), isEmpty);
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
    }, skip: !sqliteAvailable);
  });
}

Future<void> _seedAuthenticatedData(
  NavisDatabase database,
  ServerConfigRepository repository,
  String cacheFilePath,
) async {
  await repository.save(
    const ServerConfigModel(
      name: 'example.com',
      url: 'https://example.com',
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
    ),
  );

  await database
      .into(database.artistsTable)
      .insert(
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      );
  await database
      .into(database.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
        ),
      );
  await database
      .into(database.songsTable)
      .insert(
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          albumId: const Value('album-1'),
          artistId: const Value('artist-1'),
          albumName: const Value('Album 1'),
          artistName: const Value('Artist 1'),
        ),
      );
  await database
      .into(database.genresTable)
      .insert(
        GenresTableCompanion.insert(
          name: 'Rock',
          songCount: const Value(1),
          albumCount: const Value(1),
        ),
      );
  await database
      .into(database.playlistsTable)
      .insert(
        PlaylistsTableCompanion.insert(id: 'playlist-1', name: 'Playlist 1'),
      );
  await database
      .into(database.playlistSongsTable)
      .insert(
        PlaylistSongsTableCompanion.insert(
          playlistId: 'playlist-1',
          songId: 'song-1',
          sortOrder: 0,
        ),
      );
  await database
      .into(database.playHistoryTable)
      .insert(
        PlayHistoryTableCompanion.insert(
          songId: 'song-1',
          playedAt: DateTime.now(),
        ),
      );
  await database
      .into(database.recentSearchesTable)
      .insert(
        RecentSearchesTableCompanion.insert(
          query: 'rock',
          searchedAt: DateTime.now(),
        ),
      );
  await database.cacheDao.upsertCachedTrack(
    CachedTracksTableCompanion.insert(
      songId: 'song-1',
      filePath: cacheFilePath,
      fileSize: 4,
      format: 'mp3',
      bitRate: const Value(320),
      lastAccessedAt: DateTime.now(),
      cacheType: CacheType.rolling,
      downloadStatus: DownloadStatus.complete,
    ),
  );
  await database.downloadQueueDao.enqueue(
    DownloadQueueTableCompanion.insert(
      songId: const Value('song-1'),
      status: DownloadStatus.queued,
      addedAt: DateTime.now(),
    ),
  );
  await database.playQueueDao.saveQueue(songIds: const ['song-1']);
  await database.starSyncDao.queueStarAction(
    itemId: 'song-1',
    itemType: 'song',
    action: 'star',
  );
}
