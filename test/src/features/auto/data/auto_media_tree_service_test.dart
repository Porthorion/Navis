import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:navis/src/features/auto/data/auto_media_tree_service.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';

import '../../../../helpers/test_database.dart';

class _FakeSearchApiClient extends SubsonicApiClient {
  _FakeSearchApiClient(this.onSearch)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Future<SearchResult3> Function() onSearch;

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) {
    return onSearch();
  }
}

void main() {
  late NavisDatabase database;
  late AutoMediaTreeService service;

  setUp(() {
    database = createTestDatabase();
    service = AutoMediaTreeService(
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: database.playQueueDao,
      historyDao: database.historyDao,
      readApiClient: () => null,
    );
  });

  tearDown(() async {
    await database.close();
  });

  // ── Root children ─────────────────────────────────────────────────────────

  group('getChildren - root', () {
    test(
      'returns at most 4 root items for car navigation tabs',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        expect(items, hasLength(4));
      },
      skip: !sqliteAvailable,
    );

    test(
      'root items have expected IDs in order',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        final ids = items.map((e) => e.id).toList();
        expect(ids, [
          AutoMediaRoot.liked,
          AutoMediaRoot.recent,
          AutoMediaRoot.playlists,
          AutoMediaRoot.library,
        ]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'root uses concise labels and list presentation hints',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        expect(
          items.map((item) => item.title),
          <String>['Liked', 'Recent', 'Playlists', 'Library'],
        );
        for (final item in items) {
          expect(
            item.extras?[AndroidAutoConstants.contentStyleSupportedKey],
            isTrue,
          );
          expect(
            item.extras?[AndroidAutoConstants.contentStyleBrowsableHintKey],
            AndroidAutoConstants.contentStyleList,
          );
          expect(
            item.extras?[AndroidAutoConstants.contentStylePlayableHintKey],
            AndroidAutoConstants.contentStyleList,
          );
        }
      },
      skip: !sqliteAvailable,
    );

    test(
      'all root items are browsable (not playable)',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        for (final item in items) {
          expect(
            item.playable,
            isFalse,
            reason: '${item.id} should not be playable',
          );
        }
      },
      skip: !sqliteAvailable,
    );

    test(
      'root cache returns same list within TTL',
      () async {
        final first = await service.getChildren(AutoMediaRoot.root);
        final second = await service.getChildren(AutoMediaRoot.root);
        expect(identical(first, second), isTrue);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Library ───────────────────────────────────────────────────────────────

  group('getChildren - library', () {
    test(
      'returns albums and artists when no downloads exist',
      () async {
        final items = await service.getChildren(AutoMediaRoot.library);
        expect(
          items.map((item) => item.id),
          <String>[
            AutoMediaRoot.albums,
            AutoMediaRoot.artists,
          ],
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'uses clear labels and collection-appropriate presentation hints',
      () async {
        final items = await service.getChildren(AutoMediaRoot.library);
        expect(
          items.map((item) => item.title),
          <String>['Albums', 'Artists'],
        );
        expect(
          items.map(
            (item) =>
                item.extras?[AndroidAutoConstants.contentStyleBrowsableHintKey],
          ),
          <int>[
            AndroidAutoConstants.contentStyleGrid,
            AndroidAutoConstants.contentStyleGrid,
          ],
        );
        expect(
          items.every(
            (item) =>
                item.extras?[AndroidAutoConstants
                    .contentStylePlayableHintKey] ==
                AndroidAutoConstants.contentStyleList,
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'puts downloads first when permanent tracks exist',
      () async {
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => null,
          readDownloadedSongIds: () async => const <String>{'s1'},
        );

        final items = await service.getChildren(AutoMediaRoot.library);
        expect(items.first.id, AutoMediaRoot.downloads);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Artists ───────────────────────────────────────────────────────────────

  group('getChildren - artists', () {
    test(
      'returns placeholder when no artists',
      () async {
        final items = await service.getChildren(AutoMediaRoot.artists);
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/${AutoMediaRoot.artists}');
        expect(items.single.title, 'No artists');
        expect(items.single.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns artists from database',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'a1', name: 'Artist One'),
          ArtistsTableCompanion.insert(id: 'a2', name: 'Artist Two'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.artists);
        expect(items, hasLength(2));
        expect(items[0].title, 'Artist One');
        expect(items[1].title, 'Artist Two');
      },
      skip: !sqliteAvailable,
    );

    test(
      'artist items are browsable',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'a1', name: 'Artist One'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.artists);
        expect(items.single.playable, isFalse);
        expect(
          items.single.extras?[AndroidAutoConstants.isBrowsableKey],
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'artist media IDs use artist/{id} format',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'a1', name: 'Artist One'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.artists);
        expect(items.single.id, 'artist/a1');
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Albums ────────────────────────────────────────────────────────────────

  group('getChildren - albums', () {
    test(
      'returns albums from database',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'al1', name: 'Album One'),
          AlbumsTableCompanion.insert(id: 'al2', name: 'Album Two'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.albums);
        expect(items, hasLength(2));
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns placeholder when no albums',
      () async {
        final items = await service.getChildren(AutoMediaRoot.albums);
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/${AutoMediaRoot.albums}');
        expect(items.single.title, 'No albums');
      },
      skip: !sqliteAvailable,
    );

    test(
      'album items are browsable with artist metadata',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'al1',
            name: 'Album One',
            artistName: const Value('The Artist'),
          ),
        ]);

        final items = await service.getChildren(AutoMediaRoot.albums);
        expect(items.single.artist, 'The Artist');
        expect(items.single.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Artist → Albums drill-down ────────────────────────────────────────────

  group('getChildren - artist/{id}', () {
    test(
      'returns albums by artist',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'a1', name: 'Artist One'),
          ArtistsTableCompanion.insert(id: 'a2', name: 'Artist Two'),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'al1',
            name: 'Album A',
            artistId: const Value('a1'),
          ),
          AlbumsTableCompanion.insert(
            id: 'al2',
            name: 'Album B',
            artistId: const Value('a1'),
          ),
          AlbumsTableCompanion.insert(
            id: 'al3',
            name: 'Other Album',
            artistId: const Value('a2'),
          ),
        ]);

        final items = await service.getChildren('artist/a1');
        expect(items, hasLength(2));
        final titles = items.map((e) => e.title).toSet();
        expect(titles, containsAll(['Album A', 'Album B']));
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Album → Songs drill-down ──────────────────────────────────────────────

  group('getChildren - album/{id}', () {
    test(
      'returns songs from album',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'al1', name: 'Album One'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Song 1',
            albumId: const Value('al1'),
          ),
          SongsTableCompanion.insert(
            id: 's2',
            title: 'Song 2',
            albumId: const Value('al1'),
          ),
        ]);

        final items = await service.getChildren('album/al1');
        expect(items, hasLength(2));
        expect(
          AutoMediaId.parse(items[0].id)?.contextType,
          AutoMediaContextType.album,
        );
        expect(AutoMediaId.parse(items[0].id)?.contextId, 'al1');
        expect(AutoMediaId.songIdFrom(items[0].id), 's1');
        expect(AutoMediaId.songIdFrom(items[1].id), 's2');
      },
      skip: !sqliteAvailable,
    );

    test(
      'song items include metadata',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'al1', name: 'Album One'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Song 1',
            albumId: const Value('al1'),
            artistName: const Value('The Artist'),
            albumName: const Value('Album One'),
            duration: const Value(180),
          ),
        ]);

        final items = await service.getChildren('album/al1');
        final song = items.single;
        expect(song.artist, 'The Artist');
        expect(song.album, 'Album One');
        expect(song.duration, const Duration(seconds: 180));
        expect(song.playable, isTrue, reason: 'song items must be playable');
      },
      skip: !sqliteAvailable,
    );

    test(
      'song items include favorite and download status extras',
      () async {
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => null,
          readDownloadedSongIds: database.cacheDao.getPermanentlyCachedSongIds,
        );
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'al1', name: 'Album One'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Song 1',
            albumId: const Value('al1'),
            starred: Value(DateTime(2024)),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 's1',
            filePath: '/tmp/song-1.mp3',
            fileSize: 1,
            format: 'mp3',
            lastAccessedAt: DateTime(2024),
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
          ),
        );

        final items = await service.getChildren('album/al1');
        final extras = items.single.extras;
        expect(extras?[AndroidAutoConstants.isFavoriteKey], isTrue);
        expect(
          extras?[AndroidAutoConstants.downloadStatusKey],
          AndroidAutoConstants.downloadStatusDownloaded,
        );
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Playlists ─────────────────────────────────────────────────────────────

  group('getChildren - playlists', () {
    test(
      'returns playlists from database',
      () async {
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'pl1', name: 'My Playlist'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.playlists);
        expect(items, hasLength(1));
        expect(items.single.title, 'My Playlist');
        expect(items.single.id, 'playlist/pl1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns placeholder when no playlists',
      () async {
        final items = await service.getChildren(AutoMediaRoot.playlists);
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/${AutoMediaRoot.playlists}');
        expect(items.single.title, 'No playlists');
      },
      skip: !sqliteAvailable,
    );

    test(
      'playlist/{id} returns playlist songs',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 's2', title: 'Song 2'),
        ]);
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'pl1', name: 'My Playlist'),
        ]);
        await database.playlistDao.replacePlaylistSongs('pl1', [
          PlaylistSongsTableCompanion.insert(
            playlistId: 'pl1',
            songId: 's1',
            sortOrder: 0,
          ),
          PlaylistSongsTableCompanion.insert(
            playlistId: 'pl1',
            songId: 's2',
            sortOrder: 1,
          ),
        ]);

        final items = await service.getChildren('playlist/pl1');
        expect(items, hasLength(2));
        expect(
          items.map((item) => AutoMediaId.songIdFrom(item.id)),
          containsAllInOrder(<String?>['s1', 's2']),
        );
        for (final item in items) {
          final parsed = AutoMediaId.parse(item.id);
          expect(parsed?.contextType, AutoMediaContextType.playlist);
          expect(parsed?.contextId, 'pl1');
        }
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Liked ─────────────────────────────────────────────────────────────────

  group('getChildren - liked', () {
    test(
      'returns quick-play actions before liked library categories',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Liked Song',
            starred: Value(DateTime(2024)),
          ),
        ]);
        final items = await service.getChildren(AutoMediaRoot.liked);
        expect(
          items.map((item) => item.id),
          <String>[
            AutoMediaRoot.shuffleLiked,
            AutoMediaRoot.instantMix,
            AutoMediaRoot.instantRadio,
            AutoMediaRoot.likedSongs,
            AutoMediaRoot.likedAlbums,
          ],
        );
        expect(items.take(3).every((item) => item.playable == true), isTrue);
        expect(items.skip(3).every((item) => item.playable == false), isTrue);
        expect(
          items
              .take(3)
              .map(
                (item) => item
                    .extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
              ),
          everyElement('Quick Play'),
        );
        expect(
          items
              .skip(3)
              .map(
                (item) => item
                    .extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
              ),
          everyElement('Library'),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'hides Shuffle Liked when no liked songs exist',
      () async {
        final items = await service.getChildren(AutoMediaRoot.liked);
        expect(
          items.map((item) => item.id),
          isNot(contains(AutoMediaRoot.shuffleLiked)),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'liked/songs returns starred songs',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Liked Song',
            starred: Value(DateTime(2024)),
          ),
          SongsTableCompanion.insert(
            id: 's2',
            title: 'Not Liked Song',
          ),
        ]);

        final items = await service.getChildren(AutoMediaRoot.likedSongs);
        expect(items, hasLength(1));
        expect(items.single.title, 'Liked Song');
        expect(items.single.playable, isTrue);
        final parsed = AutoMediaId.parse(items.single.id);
        expect(parsed?.contextType, AutoMediaContextType.liked);
        expect(parsed?.contextId, AutoMediaRoot.likedSongs);
      },
      skip: !sqliteAvailable,
    );

    test(
      'liked/albums returns starred albums',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'al1',
            name: 'Liked Album',
            starred: Value(DateTime(2024)),
          ),
          AlbumsTableCompanion.insert(
            id: 'al2',
            name: 'Not Liked Album',
          ),
        ]);

        final items = await service.getChildren(AutoMediaRoot.likedAlbums);
        expect(items, hasLength(1));
        expect(items.single.title, 'Liked Album');
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Recently Played ───────────────────────────────────────────────────────

  group('getChildren - recent', () {
    test(
      'returns recently played songs',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Song 1'),
        ]);
        await database.historyDao.addPlayHistory('s1');

        final items = await service.getChildren(AutoMediaRoot.recent);
        expect(items, hasLength(1));
        expect(items.single.title, 'Song 1');
        expect(items.single.playable, isTrue);
        final parsed = AutoMediaId.parse(items.single.id);
        expect(parsed?.contextType, AutoMediaContextType.recent);
        expect(parsed?.contextId, AutoMediaRoot.recent);
      },
      skip: !sqliteAvailable,
    );

    test(
      'puts Resume Queue before recently played songs when resumable',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 's2', title: 'Song 2'),
        ]);
        await database.playQueueDao.saveQueue(
          currentIndex: 1,
          songIds: const <String>['s1', 's2'],
        );
        await database.historyDao.addPlayHistory('s1');

        final items = await service.getChildren(AutoMediaRoot.recent);
        expect(items.first.id, AutoMediaRoot.resumeQueue);
        expect(items.first.title, 'Resume Queue');
        expect(items.first.playable, isTrue);
        expect(items[1].title, 'Song 1');
        expect(
          items.first.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Continue Listening',
        );
        expect(
          items[1].extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Recently Played',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'system recent root returns no resumable item when empty',
      () async {
        final items = await service.getChildren(AudioService.recentRootId);
        expect(items, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'system recent root falls back to persisted queue item when history is empty',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 's2', title: 'Song 2'),
        ]);
        await database.playQueueDao.saveQueue(
          currentIndex: 1,
          songIds: const <String>['s1', 's2'],
        );

        final items = await service.getChildren(AudioService.recentRootId);
        expect(items, hasLength(1));
        expect(items.single.id, 'song/s2');
        expect(items.single.title, 'Song 2');
        expect(items.single.playable, isTrue);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Downloads ─────────────────────────────────────────────────────────────

  group('getChildren - downloads', () {
    test(
      'returns only permanently downloaded songs with collection context',
      () async {
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => null,
          readDownloadedSongIds: () async => const <String>{'s2'},
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Streamed'),
          SongsTableCompanion.insert(id: 's2', title: 'Downloaded'),
        ]);

        final items = await service.getChildren(AutoMediaRoot.downloads);
        expect(items, hasLength(1));
        expect(items.single.title, 'Downloaded');
        final parsed = AutoMediaId.parse(items.single.id);
        expect(parsed?.contextType, AutoMediaContextType.downloads);
        expect(parsed?.contextId, AutoMediaRoot.downloads);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Unknown parent ID ────────────────────────────────────────────────────

  group('getChildren - edge cases', () {
    test(
      'returns placeholder for unknown entity parent',
      () async {
        final items = await service.getChildren('unknown/parent');
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/unknown/parent');
        expect(items.single.title, 'No content');
        expect(items.single.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'does not serve stale Android Auto genre browse IDs',
      () async {
        final items = await service.getChildren('library/genres');
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/library/genres');
        expect(items.single.title, 'No content');
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns placeholder for entity that does not exist',
      () async {
        final items = await service.getChildren('album/nonexistent');
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/album/nonexistent');
        expect(items.single.title, 'No songs');
      },
      skip: !sqliteAvailable,
    );
  });

  // ── getMediaItem ──────────────────────────────────────────────────────────

  group('getMediaItem', () {
    test(
      'resolves song by ID',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'My Song',
            artistName: const Value('My Artist'),
          ),
        ]);

        final item = await service.getMediaItem('song/s1');
        expect(item, isNotNull);
        expect(item!.title, 'My Song');
        expect(item.artist, 'My Artist');
      },
      skip: !sqliteAvailable,
    );

    test(
      'resolves album by ID',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'al1', name: 'My Album'),
        ]);

        final item = await service.getMediaItem('album/al1');
        expect(item, isNotNull);
        expect(item!.title, 'My Album');
        expect(item.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'resolves artist by ID',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'a1', name: 'The Artist'),
        ]);

        final item = await service.getMediaItem('artist/a1');
        expect(item, isNotNull);
        expect(item!.title, 'The Artist');
        expect(item.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'does not expose provisional album and artist parents',
      () async {
        await database.libraryDao.upsertProvisionalAlbums([
          AlbumsTableCompanion.insert(
            id: 'provisional-album',
            name: 'Provisional Album',
          ),
        ]);
        await database.libraryDao.upsertProvisionalArtists([
          ArtistsTableCompanion.insert(
            id: 'provisional-artist',
            name: 'Provisional Artist',
          ),
        ]);

        expect(
          await service.getMediaItem('album/provisional-album'),
          isNull,
        );
        expect(
          await service.getMediaItem('artist/provisional-artist'),
          isNull,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'resolves playlist by ID',
      () async {
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'pl1', name: 'My Playlist'),
        ]);

        final item = await service.getMediaItem('playlist/pl1');
        expect(item, isNotNull);
        expect(item!.title, 'My Playlist');
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns null for unknown song ID',
      () async {
        final item = await service.getMediaItem('song/nonexistent');
        expect(item, isNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns null for root media ID',
      () async {
        final item = await service.getMediaItem('root');
        expect(item, isNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns null for malformed media ID',
      () async {
        final item = await service.getMediaItem('');
        expect(item, isNull);
      },
      skip: !sqliteAvailable,
    );
  });

  // ── search ────────────────────────────────────────────────────────────────

  group('getMediaItem', () {
    test(
      'resolves both prefixed and raw song IDs',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Aurora Song'),
        ]);

        final prefixed = await service.getMediaItem('song/song-1');
        final raw = await service.getMediaItem('song-1');

        expect(prefixed, isNotNull);
        expect(prefixed!.id, 'song/song-1');
        expect(raw, isNotNull);
        expect(raw!.id, 'song/song-1');
      },
      skip: !sqliteAvailable,
    );
  });

  group('search', () {
    test(
      'returns empty list for empty query',
      () async {
        final items = await service.search('');
        expect(items, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'returns empty list for whitespace-only query',
      () async {
        final items = await service.search('   ');
        expect(items, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search finds songs by title',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'Bohemian Rhapsody'),
          SongsTableCompanion.insert(id: 's2', title: 'Stairway to Heaven'),
        ]);

        final items = await service.search('Bohemian');
        expect(items, hasLength(1));
        expect(items.single.title, 'Bohemian Rhapsody');
        expect(
          items.single.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Songs',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search finds songs by artist',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'Song 1',
            artistName: const Value('Queen'),
          ),
          SongsTableCompanion.insert(
            id: 's2',
            title: 'Song 2',
            artistName: const Value('Beatles'),
          ),
        ]);

        final items = await service.search('Queen');
        expect(items, hasLength(1));
        expect(items.single.artist, 'Queen');
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search groups songs, playlists, albums, and artists',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Aurora'),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Aurora Live'),
        ]);
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'playlist-1', name: 'Aurora Mix'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Aurora Song'),
        ]);

        final items = await service.search('Aurora');
        expect(
          items.map(
            (item) =>
                item.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          ),
          containsAllInOrder(['Songs', 'Playlists', 'Albums', 'Artists']),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search ranks exact song and playlist matches first',
      () async {
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(
            id: 'playlist-1',
            name: 'Road Trip Extended',
          ),
          PlaylistsTableCompanion.insert(id: 'playlist-2', name: 'Road Trip'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Road Trip Reprise',
          ),
          SongsTableCompanion.insert(id: 'song-2', title: 'Road Trip'),
        ]);

        final items = await service.search('Road Trip');
        expect(items[0].id, 'song/song-2');
        expect(items[1].id, 'song/song-1');
        expect(items[2].id, 'playlist/playlist-2');
        expect(items[3].id, 'playlist/playlist-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'voice artist focus returns only artist results',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Aurora'),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Aurora Live'),
        ]);
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'playlist-1', name: 'Aurora Mix'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Aurora Song'),
        ]);

        final items = await service.search('Aurora', {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusArtist,
        });

        expect(items, hasLength(1));
        expect(items.single.id, 'artist/artist-1');
        expect(
          items.single.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Artists',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'voice song focus returns playable song results',
      () async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Aurora'),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Aurora Live'),
        ]);
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(id: 'playlist-1', name: 'Aurora Mix'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Aurora Song'),
        ]);

        final items = await service.search('Aurora', {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusSong,
        });

        expect(items, hasLength(1));
        expect(items.single.id, 'song/song-1');
        expect(items.single.playable, isTrue);
        expect(
          items.single.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Songs',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search returns a no-results placeholder',
      () async {
        final items = await service.search('missing');
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/search');
        expect(items.single.title, 'No results');
        expect(items.single.playable, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'local search is case insensitive',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's1', title: 'BOHEMIAN RHAPSODY'),
        ]);

        final items = await service.search('bohemian');
        expect(items, hasLength(1));
      },
      skip: !sqliteAvailable,
    );

    test(
      'remote search merges matching local playlists',
      () async {
        await database.playlistDao.upsertPlaylists([
          PlaylistsTableCompanion.insert(
            id: 'playlist-1',
            name: 'Road Trip',
          ),
        ]);
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => _FakeSearchApiClient(
            () async => const SearchResult3(),
          ),
        );

        final items = await service.search('Road');

        expect(items, hasLength(1));
        expect(items.single.id, 'playlist/playlist-1');
        expect(
          items.single.extras?[AndroidAutoConstants.contentStyleGroupTitleKey],
          'Playlists',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'remote search timeout falls back to local results',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Road Song'),
        ]);
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => _FakeSearchApiClient(
            () => Completer<SearchResult3>().future,
          ),
          remoteSearchTimeout: const Duration(milliseconds: 10),
        );

        final items = await service.search('Road');

        expect(items, hasLength(1));
        expect(items.single.id, 'song/song-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'empty remote search falls back to local results',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'song-1', title: 'Road Song'),
        ]);
        service = AutoMediaTreeService(
          libraryDao: database.libraryDao,
          playlistDao: database.playlistDao,
          playQueueDao: database.playQueueDao,
          historyDao: database.historyDao,
          readApiClient: () => _FakeSearchApiClient(
            () async => const SearchResult3(),
          ),
        );

        final items = await service.search('Road');

        expect(items, hasLength(1));
        expect(items.single.id, 'song/song-1');
      },
      skip: !sqliteAvailable,
    );
  });
}
