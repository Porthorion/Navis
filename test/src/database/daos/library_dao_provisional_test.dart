import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late Directory tempDirectory;

  setUp(() async {
    database = createTestDatabase();
    tempDirectory = await Directory.systemTemp.createTemp(
      'navis_provisional_library_test_',
    );
    await database.libraryDao.upsertProvisionalArtists(
      <ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'remote-artist',
          name: 'Remote Artist',
          isExternal: const Value(true),
        ),
      ],
    );
    await database.libraryDao.upsertProvisionalAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'remote-album',
        name: 'Remote Album',
        artistId: const Value('remote-artist'),
        artistName: const Value('Remote Artist'),
        isExternal: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'remote-song',
        title: 'Remote Song',
        albumId: const Value('remote-album'),
        albumName: const Value('Remote Album'),
        artistId: const Value('remote-artist'),
        artistName: const Value('Remote Artist'),
        isExternal: const Value(true),
      ),
    ]);
  });

  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  test(
    'provisional parents stay hidden and cached songs remain searchable',
    () async {
      expect(await database.libraryDao.getAllArtists(), isEmpty);
      expect(await database.libraryDao.getAllAlbums(), isEmpty);
      expect(
        await database.libraryDao.searchCachedSongs('Remote Song'),
        isEmpty,
      );

      final audio = File('${tempDirectory.path}/remote-song.mp3');
      await audio.writeAsBytes(<int>[1, 2, 3]);
      await database
          .into(database.cachedTracksTable)
          .insert(
            CachedTracksTableCompanion.insert(
              songId: 'remote-song',
              filePath: audio.path,
              fileSize: 3,
              format: 'mp3',
              lastAccessedAt: DateTime.now(),
              cacheType: CacheType.rolling,
              downloadStatus: DownloadStatus.complete,
            ),
          );

      final cachedSearch = await database.libraryDao.searchCachedSongs(
        'Remote Song',
      );
      expect(cachedSearch.map((song) => song.id), <String>['remote-song']);

      await database.customStatement(
        '''
        INSERT INTO external_lyrics_cache (
          song_id,
          source,
          fetched_at,
          ttl_seconds,
          failure_count
        ) VALUES ('remote-song', 'lrclib', ?, 86400, 0);
        ''',
        <Object?>[DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
      await database.cacheDao.removeCachedTrack('remote-song');
      final collected = await database.songIdentityDao
          .garbageCollectUnreferencedProvisionalMetadata();

      expect(collected.songs, 1);
      expect(collected.albums, 1);
      expect(collected.artists, 1);
      expect(await database.libraryDao.getSongById('remote-song'), isNull);
      final lyrics = await database.customSelect(
        '''
            SELECT COUNT(*) AS count
            FROM external_lyrics_cache
            WHERE song_id = 'remote-song';
            ''',
      ).getSingle();
      expect(lyrics.read<int>('count'), 0);
    },
  );

  test('provisional writes never downgrade a canonical row', () async {
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(id: 'canonical-song', title: 'Canonical'),
    ]);
    await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'canonical-song',
        title: 'Search Stub',
      ),
    ]);

    final row = await database.libraryDao.getSongById('canonical-song');
    expect(row, isNotNull);
    expect(row!.isProvisional, isFalse);
    expect(row.title, 'Canonical');
  });

  test(
    'same-ID canonicalization preserves child and song references',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        "INSERT INTO playlists (id, name) VALUES ('playlist', 'Playlist');",
      );
      await database.customStatement(
        '''
        INSERT INTO playlist_songs (playlist_id, song_id, sort_order)
        VALUES ('playlist', 'remote-song', 0);
        ''',
      );
      await database.customStatement(
        '''
        INSERT INTO play_queue (
          id,
          current_index,
          shuffle_mode,
          repeat_mode,
          position_ms,
          updated_at
        ) VALUES (1, 0, 'off', 'off', 0, ?);
        ''',
        <Object?>[now],
      );
      await database.customStatement(
        '''
        INSERT INTO play_queue_items (queue_id, song_id, sort_order)
        VALUES (1, 'remote-song', 0);
        ''',
      );

      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'remote-artist',
          name: 'Canonical Artist',
        ),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'remote-album',
          name: 'Canonical Album',
          artistId: const Value('remote-artist'),
          artistName: const Value('Canonical Artist'),
        ),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'remote-song',
          title: 'Canonical Song',
          albumId: const Value('remote-album'),
          albumName: const Value('Canonical Album'),
          artistId: const Value('remote-artist'),
          artistName: const Value('Canonical Artist'),
        ),
      ]);

      expect(
        (await database.libraryDao.getArtistById(
          'remote-artist',
        ))?.isProvisional,
        isFalse,
      );
      expect(
        (await database.libraryDao.getArtistById('remote-artist'))?.isExternal,
        isFalse,
      );
      expect(
        (await database.libraryDao.getAlbumById(
          'remote-album',
        ))?.isProvisional,
        isFalse,
      );
      final song = await database.libraryDao.getSongById('remote-song');
      expect(song?.isProvisional, isFalse);
      expect(song?.isExternal, isFalse);
      expect(song?.title, 'Canonical Song');

      for (final table in <String>[
        'playlist_songs',
        'play_queue_items',
      ]) {
        final row = await database
            .customSelect(
              "SELECT COUNT(*) AS count FROM $table "
              "WHERE song_id = 'remote-song';",
            )
            .getSingle();
        expect(row.read<int>('count'), 1, reason: table);
      }
    },
    skip: !sqliteAvailable,
  );
}
