import 'dart:io';
import 'dart:async';

import 'package:drift/drift.dart' show InsertMode, Value;
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
      service = SessionLifecycleService(
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
      expect(await database.serverDao.getRetainedServer(), isNotNull);
      expect(
        (await database.serverDao.getRetainedServer())?.isAuthenticated,
        isFalse,
      );
      expect(credentials.password, isNull);
      expect((await database.select(database.artistsTable).get()).length, 1);
      expect(
        (await database.select(database.cachedTracksTable).get()).length,
        1,
      );
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
      expect(await database.playQueueDao.watchQueueItems().first, isEmpty);
      expect(await database.select(database.downloadQueueTable).get(), isEmpty);
      expect(await database.scrobbleDao.countEntries(), 0);
      expect(
        await database.listenBrainzFeedbackDao.getDueFeedback(
          now: DateTime.now().add(const Duration(days: 1)),
        ),
        isEmpty,
      );
      expect(
        await database.select(database.librarySyncWorkTable).get(),
        isEmpty,
      );
      expect(cacheFile.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test(
      'server data reset clears typed aliases for every entity kind',
      () async {
        for (final kind in ['song', 'album', 'artist']) {
          await database
              .into(database.entityIdentityAliasTable)
              .insert(
                EntityIdentityAliasTableCompanion.insert(
                  entityType: kind,
                  oldId: 'old',
                  newId: 'new',
                  matchReason: 'metadata',
                  matchedAt: DateTime.now(),
                ),
              );
        }
        await ServerDataResetService(database: database).reset();
        expect(
          await database.select(database.entityIdentityAliasTable).get(),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test('full wipe clears local data and deletes cached files', () async {
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
      expect(await database.select(database.playlistSongsTable).get(), isEmpty);
      expect(await database.select(database.playHistoryTable).get(), isEmpty);
      expect(
        await database.select(database.recentSearchesTable).get(),
        isEmpty,
      );
      expect(await database.select(database.downloadQueueTable).get(), isEmpty);
      expect(await database.select(database.cachedTracksTable).get(), isEmpty);
      expect(await database.playQueueDao.watchQueueItems().first, isEmpty);
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
      expect(
        await database.select(database.appSettingsTable).get(),
        hasLength(1),
      );
      expect(cacheFile.existsSync(), isFalse);
    }, skip: !sqliteAvailable);

    test(
      'full wipe keeps files in the user download folder and Android folders',
      () async {
        final navisFile = File('${tmpDir.path}/track.mp3')
          ..writeAsStringSync('audio');
        final userFolder = Directory('${tmpDir.path}/My Music')..createSync();
        final userFile = File('${userFolder.path}/Artist/Song.flac')
          ..createSync(recursive: true)
          ..writeAsStringSync('mine');
        await _seedAuthenticatedData(database, repository, navisFile.path);
        await database.appSettingsDao.updateCustomDownloadFolderPath(
          userFolder.path,
        );
        await database.appSettingsDao.updateCustomDownloadFolderEnabled(
          enabled: true,
        );
        for (final (songId, path, kind) in <(String, String, String)>[
          ('song-user', userFile.path, 'filesystem'),
          ('song-saf', 'content://tree/music/document/a', 'androidSaf'),
        ]) {
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: songId,
              filePath: path,
              storageKind: Value(kind),
              fileSize: 4,
              format: 'flac',
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime(2026),
            ),
          );
        }

        await service.signOut(wipeLocalData: true);

        expect(navisFile.existsSync(), isFalse);
        expect(userFile.existsSync(), isTrue);
        expect(
          await database.select(database.cachedTracksTable).get(),
          isEmpty,
        );
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

    test(
      'teardown is single-flight and continues after a failed step',
      () async {
        final cacheFile = File('${tmpDir.path}/track.mp3');
        cacheFile.writeAsStringSync('audio');
        await _seedAuthenticatedData(database, repository, cacheFile.path);
        final syncGate = Completer<void>();
        var apiCalls = 0;
        var syncCalls = 0;
        var downloadCalls = 0;
        var playbackCalls = 0;
        var invalidationCalls = 0;
        final transitions = <SessionTransition>[];
        service = SessionLifecycleService(
          serverConfigRepository: repository,
          database: database,
          cancelApiRequests: () async {
            apiCalls += 1;
            throw StateError('contains sensitive server detail');
          },
          cancelSync: () async {
            syncCalls += 1;
            await syncGate.future;
          },
          stopDownloads: () async => downloadCalls += 1,
          resetPlayback: () async => playbackCalls += 1,
          invalidateSessionProviders: () => invalidationCalls += 1,
          onTransition: transitions.add,
        );

        final first = service.signOut(wipeLocalData: false);
        final second = service.signOut(wipeLocalData: false);
        await Future<void>.delayed(Duration.zero);
        expect(apiCalls, 1);
        expect(syncCalls, 1);
        syncGate.complete();
        await Future.wait(<Future<void>>[first, second]);

        expect(downloadCalls, 1);
        expect(playbackCalls, 1);
        expect(invalidationCalls, 1);
        expect(transitions, <SessionTransition>[
          SessionTransition.signingOut,
          SessionTransition.idle,
        ]);
        expect(await database.serverDao.getActiveServer(), isNull);
        expect(credentials.password, isNull);
        expect(await database.playQueueDao.watchQueueItems().first, isEmpty);
      },
      skip: !sqliteAvailable,
    );
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
      .into(database.appSettingsTable)
      .insert(
        AppSettingsTableCompanion.insert(
          id: const Value(1),
          updatedAt: DateTime.now(),
        ),
        mode: InsertMode.insertOrIgnore,
      );
  final server = await database.serverDao.getActiveServer();
  await database.librarySyncDao.enqueueWork(
    serverId: server!.id,
    kind: 'catalogSnapshot',
    priority: 1,
  );

  await database
      .into(database.artistsTable)
      .insert(ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'));
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
  final now = DateTime.now();
  await database.scrobbleDao.enqueue(
    songId: 'song-1',
    provider: 'subsonic',
    submission: true,
    sessionKey: 'session-1',
    createdAt: now,
    nextAttemptAt: now,
    expiresAt: now.add(const Duration(days: 1)),
  );
  await database.listenBrainzFeedbackDao.queueFeedback(
    songId: 'song-1',
    score: 1,
    title: 'Song 1',
    artist: 'Artist 1',
  );
}
