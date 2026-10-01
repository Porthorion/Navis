import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/library_sync_candidate_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/library_catalog_diff_analyzer.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('identical candidate is classified without catalog writes', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _seedMatchingCatalog(database, songCount: 3);

    final stats = await LibraryCatalogDiffAnalyzer(
      database,
      initialPageSize: 2,
      minimumPageSize: 1,
    ).analyze(serverId: 1, generation: 2);

    expect(stats.changedCount, 0);
    expect(stats.unchangedCount, 5);
    final songs = await database.librarySyncCandidateDao.getSongs(
      serverId: 1,
      generation: 2,
    );
    expect(
      songs.map((song) => song.applyState),
      everyElement(LibraryCandidateApplyState.unchanged),
    );
    expect((await database.libraryDao.getSongById('song-0'))?.title, 'Song 0');
  });

  test('only changed rows are classified for promotion', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _seedMatchingCatalog(database, songCount: 3);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      _song('song-1', title: 'Old title'),
    ]);

    final stats = await LibraryCatalogDiffAnalyzer(database)
        .analyze(serverId: 1, generation: 2);

    expect(stats.songChangedCount, 1);
    expect(stats.songUnchangedCount, 2);
    final changed = await database.librarySyncCandidateDao.getChangedSongsPage(
      serverId: 1,
      generation: 2,
      afterId: '',
      limit: 10,
    );
    expect(changed.map((song) => song.id), <String>['song-1']);
  });

  test('local star and rating fields do not trigger catalog writes', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _seedMatchingCatalog(database, songCount: 1);
    final starred = DateTime.utc(2026, 1, 1);
    await database.libraryDao.updateArtistStarred('artist-1', starred);
    await database.libraryDao.updateAlbumStarred('album-1', starred);
    await database.libraryDao.updateAlbumRating('album-1', 4);
    await database.libraryDao.updateSongStarred('song-0', starred);
    await database.libraryDao.updateSongRating('song-0', 5);

    final stats = await LibraryCatalogDiffAnalyzer(database)
        .analyze(serverId: 1, generation: 2);

    expect(stats.changedCount, 0);
    expect(stats.unchangedCount, 3);
  });

  test(
    'candidate without created preserves an existing server creation date',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _seedMatchingCatalog(database, songCount: 1);
      final created = DateTime.utc(2026, 8, 10);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist'),
          songCount: const Value(1),
          songsHydrated: const Value(true),
          serverCreatedAt: Value(created),
        ),
      ]);

      final stats = await LibraryCatalogDiffAnalyzer(database)
          .analyze(serverId: 1, generation: 2);

      expect(stats.albumChangedCount, 0);
      expect(stats.albumUnchangedCount, 1);
    },
  );

  test('large candidates stay within the configured page bound', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _seedMatchingCatalog(database, songCount: 1200);

    final stats = await LibraryCatalogDiffAnalyzer(
      database,
      initialPageSize: 128,
      minimumPageSize: 64,
    ).analyze(serverId: 1, generation: 2);

    expect(stats.maximumPageSize, lessThanOrEqualTo(128));
    expect(stats.songChangedCount, 0);
    expect(stats.songUnchangedCount, 1200);
  });

  test(
    'default analysis pages remain below the live diagnostic bound',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _seedMatchingCatalog(database, songCount: 1200);

      final stats = await LibraryCatalogDiffAnalyzer(database)
          .analyze(serverId: 1, generation: 2);

      expect(stats.maximumPageSize, lessThanOrEqualTo(384));
      expect(stats.songUnchangedCount, 1200);
    },
  );

  test('analysis resumes previously classified candidate rows', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _seedMatchingCatalog(database, songCount: 3);
    await database.librarySyncCandidateDao.classifySongs(
      serverId: 1,
      generation: 2,
      changedIds: const <String>[],
      unchangedIds: const <String>['song-0'],
    );

    final stats = await LibraryCatalogDiffAnalyzer(database)
        .analyze(serverId: 1, generation: 2);

    expect(stats.songUnchangedCount, 2);
    final counts = await database.librarySyncCandidateDao.getApplyCounts(
      serverId: 1,
      generation: 2,
    );
    expect(counts.unchanged, 3);
    expect(counts.unclassified, 0);
  });
}

Future<void> _seedMatchingCatalog(
  NavisDatabase database, {
  required int songCount,
}) async {
  final artist = ArtistsTableCompanion.insert(
    id: 'artist-1',
    name: 'Artist',
    albumCount: const Value(1),
  );
  final album = AlbumsTableCompanion.insert(
    id: 'album-1',
    name: 'Album',
    artistId: const Value('artist-1'),
    artistName: const Value('Artist'),
    songCount: Value(songCount),
    songsHydrated: const Value(true),
  );
  final songs = <SongsTableCompanion>[
    for (var index = 0; index < songCount; index++) _song('song-$index'),
  ];
  await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[artist]);
  await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
    album,
  ], preserveHydrationState: false);
  await database.libraryDao.upsertSongs(songs);
  await database.librarySyncCandidateDao.replaceArtists(
    serverId: 1,
    generation: 2,
    artists: <ArtistsTableCompanion>[artist],
  );
  await database.librarySyncCandidateDao.upsertAlbums(
    serverId: 1,
    generation: 2,
    albums: <AlbumsTableCompanion>[album],
  );
  await database.librarySyncCandidateDao.replaceSongsForAlbums(
    serverId: 1,
    generation: 2,
    songsByAlbum: <String, List<SongsTableCompanion>>{'album-1': songs},
  );
}

SongsTableCompanion _song(String id, {String? title}) {
  final index = int.parse(id.substring('song-'.length));
  return SongsTableCompanion.insert(
    id: id,
    title: title ?? 'Song $index',
    albumId: const Value('album-1'),
    artistId: const Value('artist-1'),
    artistName: const Value('Artist'),
    albumName: const Value('Album'),
    track: Value(index + 1),
    duration: const Value(180),
  );
}
