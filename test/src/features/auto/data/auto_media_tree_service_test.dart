import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:navis/src/features/auto/data/auto_media_tree_service.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late AutoMediaTreeService service;

  setUp(() {
    database = createTestDatabase();
    service = AutoMediaTreeService(
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
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
      'returns 5 root items',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        expect(items, hasLength(5));
      },
      skip: !sqliteAvailable,
    );

    test(
      'root items have expected IDs in order',
      () async {
        final items = await service.getChildren(AutoMediaRoot.root);
        final ids = items.map((e) => e.id).toList();
        expect(ids, [
          AutoMediaRoot.albums,
          AutoMediaRoot.recent,
          AutoMediaRoot.artists,
          AutoMediaRoot.playlists,
          AutoMediaRoot.more,
        ]);
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

  // ── More node ─────────────────────────────────────────────────────────────

  group('getChildren - more', () {
    test(
      'returns 3 secondary categories',
      () async {
        final items = await service.getChildren(AutoMediaRoot.more);
        expect(items, hasLength(3));
      },
      skip: !sqliteAvailable,
    );

    test(
      'more items have expected IDs',
      () async {
        final items = await service.getChildren(AutoMediaRoot.more);
        final ids = items.map((e) => e.id).toList();
        expect(ids, contains(AutoMediaRoot.liked));
        expect(ids, contains(AutoMediaRoot.instantMix));
        expect(ids, contains(AutoMediaRoot.instantRadio));
      },
      skip: !sqliteAvailable,
    );

    test(
      'Instant Radio is playable',
      () async {
        final items = await service.getChildren(AutoMediaRoot.more);
        final instantRadio = items.firstWhere(
          (i) => i.id == AutoMediaRoot.instantRadio,
        );
        expect(instantRadio.playable, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'Instant Mix is playable',
      () async {
        final items = await service.getChildren(AutoMediaRoot.more);
        final instantMix = items.firstWhere(
          (i) => i.id == AutoMediaRoot.instantMix,
        );
        expect(instantMix.playable, isTrue);
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
        expect(items[0].id, 'song/s1');
        expect(items[1].id, 'song/s2');
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
      },
      skip: !sqliteAvailable,
    );
  });

  // ── Liked ─────────────────────────────────────────────────────────────────

  group('getChildren - liked', () {
    test(
      'returns sub-categories',
      () async {
        final items = await service.getChildren(AutoMediaRoot.liked);
        expect(items, hasLength(2));
        expect(items[0].id, AutoMediaRoot.likedSongs);
        expect(items[1].id, AutoMediaRoot.likedAlbums);
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
      },
      skip: !sqliteAvailable,
    );

    test(
      'system recent root returns placeholder when empty',
      () async {
        final items = await service.getChildren(AudioService.recentRootId);
        expect(items, hasLength(1));
        expect(items.single.id, 'empty/${AudioService.recentRootId}');
        expect(items.single.title, 'No recent plays');
        expect(items.single.playable, isFalse);
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
      'local search returns grouped artists, albums, playlists, and songs',
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
          containsAllInOrder(['Artists', 'Albums', 'Playlists', 'Songs']),
        );
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
  });
}
