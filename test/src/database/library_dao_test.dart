import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_database.dart';

void main() {
  group('LibraryDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('id lookups and deletes stay within the SQL variable limit', () async {
      // More ids than SQLite's default bound-variable limit (32766), as when a
      // server rebuild regenerates every album id.
      final ids = [for (var i = 0; i < 40000; i++) 'missing-$i'];
      expect(await database.libraryDao.getAlbumsByIds(ids), isEmpty);
      expect(await database.libraryDao.getArtistsByIds(ids), isEmpty);
      await database.libraryDao.deleteAlbumsByIds(ids);
    }, skip: !sqliteAvailable);

    test(
      'preserving cached rows accepts more stale ids than SQLite binds',
      () async {
        // A server rebuild can make every album and artist stale at once.
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album',
            artistId: const Value('artist-1'),
          ),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Cached',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
          ),
          SongsTableCompanion.insert(
            id: 'song-2',
            title: 'Same album',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: '/nonexistent/song-1.mp3',
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.utc(2026),
          ),
        );
        final stale = [for (var i = 0; i < 40000; i++) 'album-stale-$i'];

        final preserved = await database.libraryDao
            .preserveCachedLegacyRowsAsProvisional(
              staleArtistIds: [
                'artist-1',
                for (var i = 0; i < 40000; i++) 'artist-stale-$i',
              ],
              staleAlbumIds: ['album-1', ...stale],
              protectedSongIds: [
                for (var i = 0; i < 40000; i++) 'song-stale-$i',
              ],
            );

        expect(preserved.songIds, {'song-1', 'song-2'});
        expect(preserved.albumIds, {'album-1'});
        expect(preserved.artistIds, {'artist-1'});
        expect(
          (await database.libraryDao.getSongById('song-2'))!.isProvisional,
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test('metadata upserts never execute primary-key updates', () async {
      // UPDATE OF observes column assignment even when the value is unchanged.
      // Rejecting it guards against expensive foreign-key rechecks while the
      // normal foreign-key constraints still validate metadata relationships.
      for (final table in ['artists', 'albums', 'songs']) {
        await database.customStatement('''
          CREATE TEMP TRIGGER reject_${table}_identity_update
          BEFORE UPDATE OF id ON $table
          BEGIN SELECT RAISE(ABORT, 'metadata must not update identity'); END;
        ''');
      }
      for (final provisional in [false, true]) {
        final prefix = provisional ? 'reference' : 'local';
        for (final revision in [1, 2]) {
          final artist = ArtistsTableCompanion.insert(
            id: '$prefix-artist',
            name: 'Artist $revision',
          );
          final album = AlbumsTableCompanion.insert(
            id: '$prefix-album',
            name: 'Album $revision',
            artistId: Value('$prefix-artist'),
          );
          final song = SongsTableCompanion.insert(
            id: '$prefix-song',
            title: 'Song $revision',
            artistId: Value('$prefix-artist'),
            albumId: Value('$prefix-album'),
          );
          if (provisional) {
            await database.libraryDao.upsertProvisionalArtists([artist]);
            await database.libraryDao.upsertProvisionalAlbums([album]);
            await database.libraryDao.upsertProvisionalSongs([song]);
          } else {
            await database.libraryDao.upsertArtists([artist]);
            await database.libraryDao.upsertAlbums([album]);
            await database.libraryDao.upsertSongs([song]);
          }
        }
        expect(
          (await database.libraryDao.getArtistById('$prefix-artist'))!.name,
          'Artist 2',
        );
        expect(
          (await database.libraryDao.getAlbumById('$prefix-album'))!.name,
          'Album 2',
        );
        final song = (await database.libraryDao.getSongById('$prefix-song'))!;
        expect(song.title, 'Song 2');
        expect(song.isProvisional, provisional);
        expect(song.albumId, '$prefix-album');
        expect(song.artistId, '$prefix-artist');
      }
      await database.libraryDao.reconcileSongsForAlbumsChunk(
        {
          'local-album': [
            SongsTableCompanion.insert(
              id: 'local-song',
              title: 'Verified detail',
              albumId: const Value('local-album'),
              artistId: const Value('local-artist'),
            ),
          ],
        },
        albumMetadata: [
          AlbumsTableCompanion.insert(
            id: 'local-album',
            name: 'Verified album',
          ),
        ],
        markAlbumsHydrated: true,
      );
      expect(
        (await database.libraryDao.getAlbumById('local-album'))!.name,
        'Verified album',
      );
      expect(
        (await database.libraryDao.getSongById('local-song'))!.title,
        'Verified detail',
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    });

    test(
      'outer rollback keeps cache files and deleted membership intact',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis_sync_rollback_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File(p.join(directory.path, 'track.mp3'));
        await file.writeAsBytes([1, 2, 3]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'a', name: 'Album'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's',
            title: 'Song',
            albumId: const Value('a'),
          ),
        ]);
        await database
            .into(database.cachedTracksTable)
            .insert(
              CachedTracksTableCompanion.insert(
                songId: 's',
                filePath: file.path,
                fileSize: 3,
                format: 'mp3',
                lastAccessedAt: DateTime.now(),
                cacheType: CacheType.rolling,
                downloadStatus: DownloadStatus.complete,
              ),
            );
        final deferred = <String>[];
        await expectLater(
          database.transaction(() async {
            await database.libraryDao.reconcileSongsForAlbumsChunk({
              'a': [],
            }, deferredCacheFiles: deferred);
            throw StateError('failure after nested reconciliation');
          }),
          throwsStateError,
        );
        expect(file.existsSync(), isTrue);
        expect(await database.libraryDao.getSongById('s'), isNotNull);
        expect(
          await database.select(database.cachedTracksTable).get(),
          hasLength(1),
        );
        expect(deferred, contains(file.path));
      },
    );

    test('canonical write boundary routes external rows and respects explicit local evidence', () async {
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'external',
          name: 'External',
          isExternal: const Value(true),
        ),
        AlbumsTableCompanion.insert(
          id: 'remote-local',
          name: 'Local',
          isExternal: const Value(false),
        ),
      ]);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'ext-song', title: 'External'),
      ]);
      expect(
        (await database.libraryDao.getAlbumById('external'))!.isProvisional,
        isTrue,
      );
      expect(
        (await database.libraryDao.getAlbumById('external'))!.isExternal,
        isTrue,
      );
      expect(
        (await database.libraryDao.getAlbumById('remote-local'))!.isProvisional,
        isFalse,
      );
      expect(
        (await database.libraryDao.getSongById('ext-song'))!.isExternal,
        isTrue,
      );
      expect(
        (await database.libraryDao.getSongById('ext-song'))!.isProvisional,
        isTrue,
      );
    });

    test('older metadata cannot overwrite a newer unlike or rating after acknowledgement', () async {
      final star = DateTime.utc(2020);
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(id: 'a', name: 'A', starred: Value(star)),
      ]);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's', title: 'S', starred: Value(star)),
      ]);
      final started = DateTime.now();
      await database.libraryDao.updateAlbumStarred('a', null);
      await database.libraryDao.updateAlbumRating('a', 5);
      await database.libraryDao.updateSongStarred('s', null);
      await database.libraryDao.updateSongRating('s', 4);
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'a',
          name: 'Updated',
          starred: Value(star),
          userRating: const Value(1),
        ),
      ], snapshotStartedAt: started);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 's',
          title: 'Updated',
          starred: Value(star),
          userRating: const Value(1),
        ),
      ], snapshotStartedAt: started);
      final album = (await database.libraryDao.getAlbumById('a'))!;
      final song = (await database.libraryDao.getSongById('s'))!;
      expect(album.name, 'Updated');
      expect(album.starred, isNull);
      expect(album.userRating, 5);
      expect(song.title, 'Updated');
      expect(song.starred, isNull);
      expect(song.userRating, 4);
    });

    test('deleteArtistsByIds removes a large stale artist batch', () async {
      await database.libraryDao.upsertArtists(
        List<ArtistsTableCompanion>.generate(
          501,
          (index) => ArtistsTableCompanion.insert(
            id: 'stale-artist-$index',
            name: 'Stale Artist $index',
          ),
          growable: false,
        ),
      );

      await database.libraryDao.deleteArtistsByIds(
        List<String>.generate(501, (index) => 'stale-artist-$index'),
      );

      expect(await database.libraryDao.countArtists(), 0);
    }, skip: !sqliteAvailable);

    test(
      'watchSongsFromLikedAlbums returns liked album tracks in stable order',
      () async {
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'liked-album-newer',
            name: 'Newest Album',
            starred: Value(DateTime(2024, 2, 1)),
          ),
          AlbumsTableCompanion.insert(
            id: 'liked-album-older',
            name: 'Older Album',
            starred: Value(DateTime(2024, 1, 1)),
          ),
          AlbumsTableCompanion.insert(
            id: 'unliked-album',
            name: 'Unliked Album',
          ),
        ]);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'newer-track-2',
            title: 'Track 2',
            albumId: const Value('liked-album-newer'),
            track: const Value(2),
          ),
          SongsTableCompanion.insert(
            id: 'newer-track-1',
            title: 'Track 1',
            albumId: const Value('liked-album-newer'),
            track: const Value(1),
          ),
          SongsTableCompanion.insert(
            id: 'older-track-1',
            title: 'Track 1',
            albumId: const Value('liked-album-older'),
            track: const Value(1),
          ),
          SongsTableCompanion.insert(
            id: 'unliked-track-1',
            title: 'Track 1',
            albumId: const Value('unliked-album'),
            track: const Value(1),
          ),
        ]);

        final songs = await database.libraryDao
            .watchSongsFromLikedAlbums()
            .first;
        expect(songs.map((song) => song.id), <String>[
          'newer-track-1',
          'newer-track-2',
          'older-track-1',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'album detail without created preserves Recently Added server ordering',
      () async {
        final created = DateTime.utc(2026, 8, 10);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-old',
            name: 'Old album',
            serverCreatedAt: Value(created),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-new',
            name: 'New album',
            serverCreatedAt: Value(DateTime.utc(2026, 8, 11)),
          ),
        ]);

        // getAlbum responses from compatible servers may omit `created`.
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(id: 'album-old', name: 'Old album'),
        ]);

        final albums = await database.libraryDao
            .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
            .first;
        expect(albums.map((album) => album.id), <String>[
          'album-new',
          'album-old',
        ]);
        expect(
          (await database.libraryDao.getAlbumById('album-old'))?.serverCreatedAt
              ?.toUtc(),
          created,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'Recently Added keeps newest-feed order when server creation dates tie',
      () async {
        final created = DateTime.utc(2026, 8, 20);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-zulu',
            name: 'Zulu',
            serverCreatedAt: Value(created),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-middle',
            name: 'Middle',
            serverCreatedAt: Value(created),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-alpha',
            name: 'Alpha',
            serverCreatedAt: Value(created),
          ),
        ]);

        await database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
          const <String, int>{
            'album-zulu': 0,
            'album-middle': 1,
            'album-alpha': 2,
          },
        );
        // Detail hydration has no newest-feed rank of its own and must keep
        // the one supplied by the authoritative newest response.
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(id: 'album-zulu', name: 'Zulu'),
        ]);

        final albums = await database.libraryDao
            .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
            .first;

        expect(albums.map((album) => album.id), <String>[
          'album-zulu',
          'album-middle',
          'album-alpha',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'Recently Added replaces stale ranks and never falls back to sync time',
      () async {
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'ranked',
            name: 'Ranked',
            serverCreatedAt: Value(DateTime.utc(2026, 8, 20)),
          ),
          AlbumsTableCompanion.insert(
            id: 'dated',
            name: 'Dated',
            serverCreatedAt: Value(DateTime.utc(2026, 8, 19)),
          ),
          AlbumsTableCompanion.insert(id: 'unknown', name: 'Unknown'),
        ]);
        await database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
          const <String, int>{'ranked': 0, 'unknown': 1},
        );
        await database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
          const <String, int>{'unknown': 0},
        );

        final albums = await database.libraryDao
            .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
            .first;

        expect(albums.map((album) => album.id), <String>[
          'unknown',
          'ranked',
          'dated',
        ]);
        expect(
          (await database.libraryDao.getAlbumById('ranked'))?.recentlyAddedRank,
          isNull,
        );
      },
      skip: !sqliteAvailable,
    );

    test('watchArtistAlbumBuckets keeps primary albums separate from featured appearances', () async {
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ArtistsTableCompanion.insert(id: 'artist-2', name: 'Artist 2'),
      ]);

      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-primary',
          name: 'Primary Album',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          artists: const Value(<ArtistRef>[
            ArtistRef(id: 'artist-1', name: 'Artist 1'),
          ]),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-collab-primary',
          name: 'Collab Album',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          artists: const Value(<ArtistRef>[
            ArtistRef(id: 'artist-1', name: 'Artist 1'),
            ArtistRef(id: 'artist-2', name: 'Artist 2'),
          ]),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-featured-credit',
          name: 'Featured Credit Album',
          artistId: const Value('artist-2'),
          artistName: const Value('Artist 2'),
          artists: const Value(<ArtistRef>[
            ArtistRef(id: 'artist-2', name: 'Artist 2'),
            ArtistRef(id: 'artist-1', name: 'Artist 1'),
          ]),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-featured-song',
          name: 'Featured Song Album',
          artistId: const Value('artist-2'),
          artistName: const Value('Artist 2'),
          artists: const Value(<ArtistRef>[
            ArtistRef(id: 'artist-2', name: 'Artist 2'),
          ]),
        ),
      ]);

      await database.libraryDao.replaceSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-featured-credit',
          title: 'Featured Credit Song',
          albumId: const Value('album-featured-credit'),
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
        ),
        SongsTableCompanion.insert(
          id: 'song-featured-song',
          title: 'Featured Song',
          albumId: const Value('album-featured-song'),
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
        ),
      ]);

      final buckets = await database.libraryDao
          .watchArtistAlbumBuckets('artist-1')
          .firstWhere(
            (value) =>
                value.primaryAlbums.length == 2 &&
                value.featuredInAlbums.length == 2,
          );

      expect(buckets.primaryAlbums.map((album) => album.id), <String>[
        'album-collab-primary',
        'album-primary',
      ]);
      expect(buckets.featuredInAlbums.map((album) => album.id), <String>[
        'album-featured-credit',
        'album-featured-song',
      ]);
    }, skip: !sqliteAvailable);

    test(
      'reconcileSongsForAlbumsChunk replaces targeted album songs atomically',
      () async {
        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
          AlbumsTableCompanion.insert(id: 'album-2', name: 'Album 2'),
        ]);
        await database.libraryDao.replaceSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'old-song-1',
            title: 'Old Song 1',
            albumId: const Value('album-1'),
          ),
          SongsTableCompanion.insert(
            id: 'old-song-2',
            title: 'Old Song 2',
            albumId: const Value('album-2'),
          ),
        ]);

        final chunk = <String, List<SongsTableCompanion>>{
          'album-1': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'new-song-1',
              title: 'New Song 1',
              albumId: const Value('album-1'),
            ),
          ],
          'album-2': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'new-song-2',
              title: 'New Song 2',
              albumId: const Value('album-2'),
            ),
            SongsTableCompanion.insert(
              id: 'new-song-3',
              title: 'New Song 3',
              albumId: const Value('album-2'),
            ),
          ],
        };

        await database.libraryDao.reconcileSongsForAlbumsChunk(chunk);
        await database.libraryDao.reconcileSongsForAlbumsChunk(chunk);

        final songs = await database.select(database.songsTable).get();
        expect(songs.map((song) => song.id).toSet(), {
          'new-song-1',
          'new-song-2',
          'new-song-3',
        });
        expect(songs.where((song) => song.albumId == 'album-1').length, 1);
        expect(songs.where((song) => song.albumId == 'album-2').length, 2);
      },
      skip: !sqliteAvailable,
    );

    test('reconcileSongsForAlbumsChunk preserves complete permanent downloads as local-only', () async {
      final tempDir = Directory.systemTemp.createTempSync('navis_library_dao_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'deleted-song',
          title: 'Downloaded Deleted Song',
          albumId: const Value('album-1'),
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          albumName: const Value('Album 1'),
        ),
      ]);
      final audioFile = File(p.join(tempDir.path, 'deleted-song.mp3'));
      await audioFile.writeAsBytes(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'deleted-song',
          filePath: audioFile.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );

      await database.libraryDao.reconcileSongsForAlbumsChunk(
        const <String, List<SongsTableCompanion>>{'album-1': []},
      );

      final allRows = await database.select(database.songsTable).get();
      expect(allRows, hasLength(1));
      expect(allRows.single.id, 'deleted-song');
      expect(allRows.single.albumId, isNull);
      expect(allRows.single.artistId, isNull);
      expect(allRows.single.serverDeletedAt, isNotNull);
      expect(
        await database.libraryDao.watchSongsByAlbum('album-1').first,
        isEmpty,
      );
      expect(
        await database.libraryDao.watchSongsSorted(SongSortOrder.name).first,
        isEmpty,
      );
      expect(await database.cacheDao.getCachedTrack('deleted-song'), isNotNull);

      await database.libraryDao.reconcileSongsForAlbumsChunk(
        <String, List<SongsTableCompanion>>{
          'album-1': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'deleted-song',
              title: 'Downloaded Deleted Song',
              albumId: const Value('album-1'),
            ),
          ],
        },
      );

      final restored = await database.libraryDao.getSongById('deleted-song');
      expect(restored?.albumId, 'album-1');
      expect(restored?.serverDeletedAt, isNull);
    }, skip: !sqliteAvailable);

    test('reconcileSongsForAlbumsChunk retains owned stale state as confirmed missing', () async {
      final tempDir = Directory.systemTemp.createTempSync('navis_library_dao_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'stale-song',
          title: 'Stale Song',
          albumId: const Value('album-1'),
        ),
      ]);
      final audioFile = File(p.join(tempDir.path, 'stale-song.mp3'));
      await audioFile.writeAsBytes(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'stale-song',
          filePath: audioFile.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );
      await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('stale-song'),
          status: DownloadStatus.queued,
          addedAt: DateTime.now(),
        ),
      );
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'stale-song',
        source: 'test',
        plainLyrics: 'lyrics',
      );
      await database
          .into(database.matchFlowsTable)
          .insert(
            MatchFlowsTableCompanion.insert(
              id: 'flow-1',
              name: 'Flow 1',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
      await database
          .into(database.matchFlowSongsTable)
          .insert(
            MatchFlowSongsTableCompanion.insert(
              flowId: 'flow-1',
              songId: 'stale-song',
              sortOrder: 0,
              addedAt: DateTime.now(),
            ),
          );

      await database.libraryDao.reconcileSongsForAlbumsChunk(
        const <String, List<SongsTableCompanion>>{'album-1': []},
      );

      // Download ownership and match-flow references keep the row alive as
      // confirmed-missing so recovery review can still relink it.
      final retained = await database.libraryDao.getSongById('stale-song');
      expect(retained, isNotNull);
      expect(retained!.serverDeletedAt, isNotNull);
      expect(
        retained.catalogAvailability,
        CatalogAvailability.confirmedMissing.name,
      );
      expect(retained.albumId, isNull);
      expect(await database.cacheDao.getCachedTrack('stale-song'), isNotNull);
      expect(await database.downloadQueueDao.watchQueue().first, isNotEmpty);
      expect(
        await database.libraryDao.getExternalLyricsCache('stale-song'),
        isNotNull,
      );
      expect(
        await database.select(database.matchFlowSongsTable).get(),
        isNotEmpty,
      );
      expect(audioFile.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test('reconcileSongsForAlbumsChunk deletes unowned stale rows', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'navis_library_dao_unowned_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(id: 'album-2', name: 'Album 2'),
      ]);
      final audioFile = File(p.join(tempDir.path, 'plain-song.mp3'));
      await audioFile.writeAsBytes(<int>[1, 2, 3]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'plain-song',
          title: 'Plain Song',
          albumId: const Value('album-2'),
        ),
      ]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'plain-song',
          filePath: audioFile.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );

      final files = await database.libraryDao.reconcileSongsForAlbumsChunk(
        const <String, List<SongsTableCompanion>>{'album-2': []},
      );

      expect(audioFile.existsSync(), isTrue);
      await database.libraryDao.cleanupRemovedCacheFiles(files);
      expect(await database.libraryDao.getSongById('plain-song'), isNull);
      expect(await database.cacheDao.getCachedTrack('plain-song'), isNull);
      expect(audioFile.existsSync(), isFalse);
    }, skip: !sqliteAvailable);

    test('bumpCoverArtRevisions targets only listed entities', () async {
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(id: 'album-1', name: 'Album'),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song',
          albumId: const Value('album-1'),
        ),
        SongsTableCompanion.insert(
          id: 'song-2',
          title: 'Song 2',
          albumId: const Value('album-1'),
        ),
      ]);

      await database.libraryDao.bumpCoverArtRevisions(
        songIds: <String>['song-1'],
        albumIds: <String>['album-1'],
      );

      expect(
        (await database.libraryDao.getSongById('song-1'))!.coverArtRevision,
        1,
      );
      expect(
        (await database.libraryDao.getSongById('song-2'))!.coverArtRevision,
        isNull,
      );
      final album = await database.libraryDao.getAlbumById('album-1');
      expect(album!.coverArtRevision, 1);
    }, skip: !sqliteAvailable);

    test('bulk selection keeps suspected rows and confirmed rows with local copies', () async {
      Future<void> setAvailability(
        String songId, {
        String? availability,
        bool serverDeleted = false,
        DateTime? starred,
      }) async {
        await (database.update(
          database.songsTable,
        )..where((t) => t.id.equals(songId))).write(
          SongsTableCompanion(
            catalogAvailability: Value(availability),
            serverDeletedAt: serverDeleted
                ? Value(DateTime.utc(2026, 9, 6))
                : const Value.absent(),
            starred: starred == null ? const Value.absent() : Value(starred),
          ),
        );
      }

      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-present', title: 'Present'),
        SongsTableCompanion.insert(id: 'song-suspect', title: 'Suspect'),
        SongsTableCompanion.insert(id: 'song-gone', title: 'Gone'),
        SongsTableCompanion.insert(id: 'song-kept', title: 'Kept'),
      ]);
      // A favorite absent from the validated catalog with no local copy:
      // excluded from bulk selection.
      await setAvailability(
        'song-gone',
        availability: 'confirmedMissing',
        serverDeleted: true,
        starred: DateTime.utc(2026, 9, 1),
      );
      // A favorite absent from the catalog but holding a complete local
      // copy stays selectable; offline copies remain playable.
      await setAvailability(
        'song-kept',
        availability: 'confirmedMissing',
        serverDeleted: true,
        starred: DateTime.utc(2026, 9, 1),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-kept',
          filePath: '/tmp/song-kept.audio',
          fileSize: 1024,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );

      final selectable = await database.libraryDao.getAllStarredSongs();
      expect(selectable.map((song) => song.id).toSet(), <String>{'song-kept'});

      // Suspicion is recorded only on rows still reading as present.
      await database.libraryDao.markSongsSuspectedMissing(<String>[
        'song-present',
        'song-gone',
        'missing-id',
      ]);
      expect(
        (await database.libraryDao.getSongById('song-present'))!
            .catalogAvailability,
        'suspectedMissing',
      );
      expect(
        (await database.libraryDao.getSongById('song-gone'))!
            .catalogAvailability,
        'confirmedMissing',
      );
    }, skip: !sqliteAvailable);

    test('markAlbumsSongsHydratedByIds updates only targeted albums', () async {
      await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          songsHydrated: const Value(false),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-2',
          name: 'Album 2',
          songsHydrated: const Value(false),
        ),
      ]);

      await database.libraryDao.markAlbumsSongsHydratedByIds(const <String>[
        'album-1',
      ]);

      final rows = await database.select(database.albumsTable).get();
      final byId = {for (final row in rows) row.id: row};
      expect(byId['album-1']?.songsHydrated, isTrue);
      expect(byId['album-2']?.songsHydrated, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'getSongsByIds chunks requests beyond the SQLite variable limit',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        ]);
        final requestedIds = <String>[
          'song-1',
          ...List<String>.generate(40000, (index) => 'missing-$index'),
        ];

        final songs = await database.libraryDao.getSongsByIds(requestedIds);

        expect(songs.map((song) => song.id), <String>['song-1']);
      },
      skip: !sqliteAvailable,
    );

    test(
      'remote upserts preserve pending local star actions for every entity',
      () async {
        await database.starSyncDao.queueStarAction(
          itemId: 'artist-1',
          itemType: 'artist',
          action: 'star',
        );
        await database.starSyncDao.queueStarAction(
          itemId: 'album-1',
          itemType: 'album',
          action: 'star',
        );
        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'star',
        );

        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album',
            artistId: const Value('artist-1'),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song',
            albumId: const Value('album-1'),
          ),
        ]);

        expect(
          (await database.libraryDao.getArtistById('artist-1'))?.starred,
          isNotNull,
        );
        expect(
          (await database.libraryDao.getAlbumById('album-1'))?.starred,
          isNotNull,
        );
        expect(
          (await database.libraryDao.getSongById('song-1'))?.starred,
          isNotNull,
        );

        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'unstar',
        );
        await database.libraryDao.reconcileSongsForAlbumsChunk(
          <String, List<SongsTableCompanion>>{
            'album-1': <SongsTableCompanion>[
              SongsTableCompanion.insert(
                id: 'song-1',
                title: 'Remote liked song',
                albumId: const Value('album-1'),
                starred: Value(DateTime.now()),
              ),
            ],
          },
        );

        expect(
          (await database.libraryDao.getSongById('song-1'))?.starred,
          isNull,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'watchMostPlayedSongs breaks play-count ties by recency then title',
      () async {
        Future<void> insertSong(String id, String title, int? playCount) async {
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: id,
              title: title,
              playCount: Value(playCount),
            ),
          ]);
        }

        await insertSong('tie-old', 'Alpha', 2);
        await insertSong('tie-new', 'Beta', 2);
        await insertSong('single', 'Alpha', 1);
        await insertSong('never-played', 'Delta', null);
        // upsertSongs intentionally clears deletion evidence on writes, so
        // mark the row deleted directly to exercise the query filter.
        await (database.update(database.songsTable)
              ..where((table) => table.id.equals('deleted')))
            .write(SongsTableCompanion(serverDeletedAt: Value(DateTime.now())));

        await database
            .into(database.playHistoryTable)
            .insert(
              PlayHistoryTableCompanion.insert(
                songId: 'tie-old',
                playedAt: DateTime.utc(2026, 1, 1),
              ),
            );
        await database
            .into(database.playHistoryTable)
            .insert(
              PlayHistoryTableCompanion.insert(
                songId: 'tie-new',
                playedAt: DateTime.utc(2026, 2, 1),
              ),
            );

        final songs = await database.libraryDao
            .watchMostPlayedSongs()
            .map((rows) => rows.map((row) => row.id).toList())
            .first;

        // The newer play wins the tie; the unplayed lower count follows;
        // deleted and unplayed-zero rows never appear.
        expect(songs, <String>['tie-new', 'tie-old', 'single']);
      },
      skip: !sqliteAvailable,
    );

    test(
      'watchMostPlayedSongs deterministic order survives a history-less tie',
      () async {
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'b-title',
            title: 'Beta',
            playCount: const Value(3),
          ),
          SongsTableCompanion.insert(
            id: 'a-title',
            title: 'Alpha',
            playCount: const Value(3),
          ),
        ]);

        final songs = await database.libraryDao
            .watchMostPlayedSongs()
            .map((rows) => rows.map((row) => row.id).toList())
            .first;

        // Without history, the alphabetical title tiebreaker decides.
        expect(songs, <String>['a-title', 'b-title']);
      },
      skip: !sqliteAvailable,
    );

    test(
      'watchPendingHydrationAlbums tracks the metadata backlog live',
      () async {
        Future<int> currentCount() =>
            database.libraryDao.watchPendingHydrationAlbums().first;

        expect(await currentCount(), 0);

        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'album-watch-a', name: 'A'),
          AlbumsTableCompanion.insert(id: 'album-watch-b', name: 'B'),
          AlbumsTableCompanion.insert(id: 'album-provisional', name: 'C'),
        ]);
        // upsertAlbums normalizes rows to the committed catalog, so mark the
        // provisional row directly to exercise the query filter.
        await (database.update(database.albumsTable)
              ..where((table) => table.id.equals('album-provisional')))
            .write(const AlbumsTableCompanion(isProvisional: Value(true)));
        expect(await currentCount(), 2);

        await database.libraryDao.markAlbumSongsHydrated('album-watch-a');
        expect(await currentCount(), 1);
      },
      skip: !sqliteAvailable,
    );
  });
}
