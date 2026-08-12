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

    test(
      'deleteArtistsByIds removes a large stale artist batch',
      () async {
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
      },
      skip: !sqliteAvailable,
    );

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
        expect(
          songs.map((song) => song.id),
          <String>['newer-track-1', 'newer-track-2', 'older-track-1'],
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'watchArtistAlbumBuckets keeps primary albums separate from featured appearances',
      () async {
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

        expect(
          buckets.primaryAlbums.map((album) => album.id),
          <String>['album-collab-primary', 'album-primary'],
        );
        expect(
          buckets.featuredInAlbums.map((album) => album.id),
          <String>['album-featured-credit', 'album-featured-song'],
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'replaceSongsForAlbumsChunk replaces targeted album songs atomically',
      () async {
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
            AlbumsTableCompanion.insert(id: 'album-2', name: 'Album 2'),
          ],
        );
        await database.libraryDao.replaceSongs(
          <SongsTableCompanion>[
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
          ],
        );

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

        await database.libraryDao.replaceSongsForAlbumsChunk(chunk);
        await database.libraryDao.replaceSongsForAlbumsChunk(chunk);

        final songs = await database.select(database.songsTable).get();
        expect(songs.map((song) => song.id).toSet(), {
          'new-song-1',
          'new-song-2',
          'new-song-3',
        });
        expect(
          songs.where((song) => song.albumId == 'album-1').length,
          1,
        );
        expect(
          songs.where((song) => song.albumId == 'album-2').length,
          2,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'reconcileSongsForAlbumsChunk preserves complete permanent downloads as local-only',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'navis_library_dao_',
        );
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
        expect(
          await database.cacheDao.getCachedTrack('deleted-song'),
          isNotNull,
        );

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
      },
      skip: !sqliteAvailable,
    );

    test(
      'reconcileSongsForAlbumsChunk removes non-preserved stale state',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'navis_library_dao_',
        );
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

        expect(await database.libraryDao.getSongById('stale-song'), isNull);
        expect(await database.cacheDao.getCachedTrack('stale-song'), isNull);
        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
        expect(
          await database.libraryDao.getExternalLyricsCache('stale-song'),
          isNull,
        );
        expect(
          await database.select(database.matchFlowSongsTable).get(),
          isEmpty,
        );
        expect(audioFile.existsSync(), isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'markAlbumsSongsHydratedByIds updates only targeted albums',
      () async {
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
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
          ],
        );

        await database.libraryDao.markAlbumsSongsHydratedByIds(
          const <String>['album-1'],
        );

        final rows = await database.select(database.albumsTable).get();
        final byId = {for (final row in rows) row.id: row};
        expect(byId['album-1']?.songsHydrated, isTrue);
        expect(byId['album-2']?.songsHydrated, isFalse);
      },
      skip: !sqliteAvailable,
    );

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
  });
}
