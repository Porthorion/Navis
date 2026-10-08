import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

/// Characterization golden for catalog promotion and identity repair.
///
/// A library with user state (likes, a rating, permanent downloads, rolling
/// cache files, a saved queue) is synced, then the server rebuilds its ids:
/// MusicBrainz-matched and unmatched renames, a removed album with
/// downloads, duplicate release identifiers, a removed cached song and a new
/// album. The database state after each of the three following syncs (the
/// first only recommends a repair, the next promotes, the last settles
/// provisional rows) is compared with
/// test/fixtures/sync_golden/rebuild.json, so refactors of promotion,
/// reconciliation, preservation and cache cleanup must keep every outcome.
///
/// Regenerate after an intended behaviour change with
/// `NAVIS_UPDATE_SYNC_GOLDENS=1 flutter test <this file>` and review the diff.
void main() {
  const goldenPath = 'test/fixtures/sync_golden/rebuild.json';

  test('an id rebuild keeps every promotion and repair outcome', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final files = await Directory.systemTemp.createTemp('navis_sync_golden_');
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
    );
    Future<LibrarySyncState> runRepair() async {
      final result = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      // Explicit repairs refresh both companions independently of the catalog.
      await engine.executeSyncPlan(
        syncPlanForTest(
          LibrarySyncPlanKind.targetedHydration,
          target: const LibrarySyncTarget.starred(),
        ),
      );
      await engine.executeSyncPlan(
        syncPlanForTest(
          LibrarySyncPlanKind.targetedHydration,
          target: const LibrarySyncTarget.playlistHeaders(),
        ),
      );
      return result;
    }

    final starred = DateTime.utc(2026, 1, 2);

    Song song(
      String id,
      String title,
      String albumId,
      String artistId,
      int track, {
      String? mbid,
      DateTime? starredAt,
      int? rating,
    }) => Song(
      id: id,
      title: title,
      albumId: albumId,
      artistId: artistId,
      track: track,
      discNumber: 1,
      duration: 200,
      musicBrainzId: mbid,
      starred: starredAt,
      userRating: rating,
    );

    void serve(List<Artist> artists, List<Album> albums) {
      api.artists
        ..clear()
        ..addAll(artists);
      api.fastPathPages
        ..clear()
        ..[0] = albums;
      api.albumDetails
        ..clear()
        ..addAll({for (final album in albums) album.id: album});
    }

    Album album(
      String id,
      String name,
      String artistId,
      List<Song> songs, {
      String? mbid,
      DateTime? starredAt,
    }) => Album(
      id: id,
      name: name,
      artistId: artistId,
      songCount: songs.length,
      musicBrainzId: mbid,
      starred: starredAt,
      songs: songs,
    );

    // --- The library before the rebuild. --------------------------------
    serve(
      <Artist>[
        Artist(
          id: 'ar-mb',
          name: 'Mbid Artist',
          musicBrainzId: 'mb-artist-1',
          starred: starred,
        ),
        const Artist(id: 'ar-plain', name: 'Plain Artist'),
        const Artist(id: 'ar-gone', name: 'Gone Artist'),
      ],
      <Album>[
        album('al-mb', 'Mbid Album', 'ar-mb', <Song>[
          song(
            's-mb-1',
            'Mb One',
            'al-mb',
            'ar-mb',
            1,
            mbid: 'mb-rec-1',
            starredAt: starred,
          ),
          song('s-mb-2', 'Mb Two', 'al-mb', 'ar-mb', 2, mbid: 'mb-rec-2'),
          song('s-mb-3', 'Mb Three', 'al-mb', 'ar-mb', 3, mbid: 'mb-rec-3'),
        ], mbid: 'mb-release-1'),
        album('al-plain', 'Plain Album', 'ar-plain', <Song>[
          song('s-plain-1', 'Plain One', 'al-plain', 'ar-plain', 1),
          song('s-plain-2', 'Plain Two', 'al-plain', 'ar-plain', 2, rating: 4),
          song('s-plain-3', 'Plain Three', 'al-plain', 'ar-plain', 3),
        ], starredAt: starred),
        album('al-gone', 'Gone Album', 'ar-gone', <Song>[
          song('s-gone-1', 'Gone One', 'al-gone', 'ar-gone', 1),
          song('s-gone-2', 'Gone Two', 'al-gone', 'ar-gone', 2),
        ]),
        album('al-dup', 'Dup Album', 'ar-mb', <Song>[
          song('s-dup-1', 'Dup One', 'al-dup', 'ar-mb', 1),
        ], mbid: 'mb-release-dup'),
        album('al-keep', 'Keep Album', 'ar-plain', <Song>[
          song('s-keep-1', 'Keep One', 'al-keep', 'ar-plain', 1),
          song('s-keep-2', 'Keep Two', 'al-keep', 'ar-plain', 2),
        ]),
      ],
    );
    final first = await runRepair();

    // --- User state kept locally. ----------------------------------------
    Future<void> cache(String songId, CacheType type) async {
      final file = File('${files.path}/${type.name}-$songId.mp3')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: songId,
          filePath: file.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: type,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.utc(2026, 1, 3),
        ),
      );
    }

    await cache('s-mb-2', CacheType.permanent);
    await cache('s-gone-1', CacheType.permanent);
    await cache('s-plain-1', CacheType.permanent);
    await cache('s-keep-2', CacheType.rolling);
    await cache('s-gone-2', CacheType.rolling);
    await database.playQueueDao.saveQueue(
      currentIndex: 1,
      songIds: const <String>['s-mb-1', 's-plain-1', 's-gone-2', 's-keep-1'],
    );

    // --- The server rebuilds its ids. -------------------------------------
    serve(
      const <Artist>[
        Artist(id: 'ar-mb2', name: 'Mbid Artist', musicBrainzId: 'mb-artist-1'),
        Artist(id: 'ar-plain', name: 'Plain Artist'),
      ],
      <Album>[
        album('al-mb2', 'Mbid Album', 'ar-mb2', <Song>[
          song('s-mb2-1', 'Mb One', 'al-mb2', 'ar-mb2', 1, mbid: 'mb-rec-1'),
          song('s-mb2-2', 'Mb Two', 'al-mb2', 'ar-mb2', 2, mbid: 'mb-rec-2'),
          song('s-mb2-3', 'Mb Three', 'al-mb2', 'ar-mb2', 3, mbid: 'mb-rec-3'),
        ], mbid: 'mb-release-1'),
        album('al-plain2', 'Plain Album', 'ar-plain', <Song>[
          song('s-plain2-1', 'Plain One', 'al-plain2', 'ar-plain', 1),
          song('s-plain2-2', 'Plain Two', 'al-plain2', 'ar-plain', 2),
          song('s-plain2-3', 'Plain Three', 'al-plain2', 'ar-plain', 3),
        ]),
        album('al-dup-a', 'Dup Album', 'ar-mb2', <Song>[
          song('s-dup-a', 'Dup One', 'al-dup-a', 'ar-mb2', 1),
        ], mbid: 'mb-release-dup'),
        album('al-dup-b', 'Dup Album', 'ar-mb2', <Song>[
          song('s-dup-b', 'Dup One', 'al-dup-b', 'ar-mb2', 1),
        ], mbid: 'mb-release-dup'),
        album('al-keep', 'Keep Album', 'ar-plain', <Song>[
          song('s-keep-1', 'Keep One', 'al-keep', 'ar-plain', 1),
        ]),
        album('al-new', 'New Album', 'ar-plain', <Song>[
          song('s-new-1', 'New One', 'al-new', 'ar-plain', 1),
        ]),
      ],
    );
    final second = await runRepair();
    final afterSecond = await _snapshot(database, files);
    final third = await runRepair();
    final afterThird = await _snapshot(database, files);
    // One more sync settles what the rebuild left provisional.
    final fourth = await runRepair();
    final afterFourth = await _snapshot(database, files);
    // Settling is idempotent, so it is asserted equal rather than stored.
    expect(afterFourth, afterThird);

    final actual = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'runs': <String>[
        for (final run in <LibrarySyncState>[first, second, third, fourth])
          '${run.status.name}/${run.freshness.name}',
      ],
      'afterRebuildSync': afterSecond,
      'afterFollowingSync': afterThird,
    });
    final golden = File(goldenPath);
    if (Platform.environment['NAVIS_UPDATE_SYNC_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync('$actual\n');
    }
    expect(actual, golden.readAsStringSync().trimRight());
  }, skip: !sqliteAvailable);
}

/// The outcome of promotion and repair: every identity, flag, alias,
/// review, cache row, surviving cache file and the saved queue, sorted and
/// without timestamps.
Future<Map<String, Object?>> _snapshot(
  NavisDatabase database,
  Directory files,
) async {
  Future<List<Map<String, Object?>>> rows(String sql) async => [
    for (final row in await database.customSelect(sql).get()) row.data,
  ];
  return <String, Object?>{
    'artists': await rows(
      'SELECT id, name, artist_mbid, is_provisional, '
      'starred IS NOT NULL AS starred FROM artists ORDER BY id',
    ),
    'albums': await rows(
      'SELECT id, name, artist_id, release_mbid, is_provisional, '
      'starred IS NOT NULL AS starred, user_rating FROM albums ORDER BY id',
    ),
    'songs': await rows(
      'SELECT id, title, album_id, artist_id, recording_mbid, is_provisional, '
      'server_deleted_at IS NOT NULL AS server_deleted, '
      'starred IS NOT NULL AS starred, user_rating FROM songs ORDER BY id',
    ),
    'songAliases': await rows(
      'SELECT old_id AS old_song_id, new_id AS canonical_song_id, match_reason '
      "FROM entity_identity_aliases WHERE entity_type = 'song' ORDER BY old_id",
    ),
    'entityAliases': await rows(
      'SELECT entity_type, old_id, new_id, match_reason '
      'FROM entity_identity_aliases ORDER BY entity_type, old_id',
    ),
    'recoveryReviews': await rows(
      'SELECT entity_type, old_id, reason, candidate_json, disposition '
      'FROM library_recovery_review ORDER BY entity_type, old_id',
    ),
    'starActions': await rows(
      'SELECT item_id, item_type, action FROM star_sync_queue '
      'ORDER BY item_id, action',
    ),
    'cachedTracks': [
      for (final row in await rows(
        'SELECT song_id, file_path, cache_type, download_status '
        'FROM cached_tracks ORDER BY song_id',
      ))
        <String, Object?>{
          ...row,
          'file_path': (row['file_path'] as String?)?.split('/').last,
        },
    ],
    'files': [
      for (final entity in files.listSync())
        if (entity is File) entity.path.split('/').last,
    ]..sort(),
    'queue': (await database.playQueueDao.getQueueItems())
        .map((song) => song.id)
        .toList(),
  };
}
