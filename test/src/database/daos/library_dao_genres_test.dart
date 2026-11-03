import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/utils/genre_key.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  SongsTableCompanion song(
    String id,
    String albumId,
    List<String> genres, {
    bool external = false,
    String? title,
  }) => SongsTableCompanion.insert(
    id: id,
    title: title ?? 'Song $id',
    albumId: Value(albumId),
    artistId: const Value('artist-1'),
    artistName: const Value('Artist'),
    genres: Value(genres),
    isExternal: Value(external),
  );

  Future<void> markDownloaded(String songId) {
    return database.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: songId,
        filePath: '/music/$songId.mp3',
        fileSize: 1,
        format: 'mp3',
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime(2026),
      ),
    );
  }

  // hiphop: s1 s2 s3 s7 (albums 1, 2); rock: s1 s4 s5 (albums 1, 2, 3);
  // jazz: s8 (album 3). s6 is external and must not be indexed.
  Future<void> seed() async {
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
    ]);
    await database.libraryDao.upsertAlbums([
      for (final n in [1, 2, 3])
        AlbumsTableCompanion.insert(
          id: 'album-$n',
          name: 'Album $n',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist'),
          year: Value(2000 + n),
        ),
    ]);
    await database.libraryDao.upsertSongs([
      song('s1', 'album-1', ['Hip Hop', 'Rock']),
      song('s2', 'album-1', ['Hip-Hop']),
      song('s3', 'album-2', ['Hip-Hop']),
      song('s4', 'album-2', ['Rock']),
      song('s5', 'album-3', ['Rock']),
      song('s6', 'album-3', ['Rock'], external: true),
      song('s7', 'album-2', ['hip hop']),
      song('s8', 'album-3', ['Jazz']),
      song('s9', 'album-3', const []),
    ]);
  }

  test('lists genres with song and album counts, merged by key', () async {
    await seed();

    final genres = await database.libraryDao.getGenres();

    expect(genres.map((g) => g.key), ['hiphop', 'rock', 'jazz']);
    final hiphop = genres.first;
    expect(hiphop.songCount, 4);
    expect(hiphop.albumCount, 2);
    expect(genres[1].songCount, 3);
    expect(genres[1].albumCount, 3);
    expect(genres[2].songCount, 1);
    // External rows are not indexed.
    expect(
      await database
          .customSelect(
            "SELECT COUNT(*) AS n FROM song_genre_index WHERE song_id = 's6'",
          )
          .map((row) => row.read<int>('n'))
          .getSingle(),
      0,
    );
  }, skip: !sqliteAvailable);

  test('the display name is the most common spelling', () async {
    await seed();

    final genres = await database.libraryDao.getGenres();

    // Hip-Hop twice, Hip Hop and hip hop once each.
    expect(genres.first.name, 'Hip-Hop');
    expect(genres[1].name, 'Rock');
  }, skip: !sqliteAvailable);

  test('sorts by name, songs and albums', () async {
    await seed();
    Future<List<String>> keys(GenreSortOrder sort) async =>
        (await database.libraryDao.getGenres(sort: sort))
            .map((g) => g.key)
            .toList();

    expect(await keys(GenreSortOrder.name), ['hiphop', 'jazz', 'rock']);
    expect(await keys(GenreSortOrder.songs), ['hiphop', 'rock', 'jazz']);
    expect(await keys(GenreSortOrder.albums), ['rock', 'hiphop', 'jazz']);
  }, skip: !sqliteAvailable);

  test('searches genre names through the merge key', () async {
    await seed();

    expect(
      (await database.libraryDao.getGenres(query: 'hip hop')).map((g) => g.key),
      ['hiphop'],
    );
    expect((await database.libraryDao.searchGenres('RO')).map((g) => g.key), [
      'rock',
    ]);
    expect(await database.libraryDao.searchGenres('---'), isEmpty);
    expect(await database.libraryDao.searchGenres('zzz'), isEmpty);
  }, skip: !sqliteAvailable);

  test('downloaded-only counts only permanently downloaded songs', () async {
    await seed();
    await markDownloaded('s1');
    await markDownloaded('s5');

    final genres = await database.libraryDao.getGenres(downloadedOnly: true);

    expect(genres.map((g) => g.key), unorderedEquals(['hiphop', 'rock']));
    final rock = genres.firstWhere((g) => g.key == 'rock');
    expect((rock.songCount, rock.albumCount), (2, 2));
    final hiphop = genres.firstWhere((g) => g.key == 'hiphop');
    expect((hiphop.songCount, hiphop.albumCount), (1, 1));
    expect(
      await database.libraryDao.searchGenres('jazz', downloadedOnly: true),
      isEmpty,
    );
  }, skip: !sqliteAvailable);

  test('an album belongs to every genre any of its songs has', () async {
    await seed();

    final rock = await database.libraryDao.getAlbumsByGenre('rock');
    final hiphop = await database.libraryDao.getAlbumsByGenre('hiphop');
    final jazz = await database.libraryDao.getAlbumsByGenre('jazz');

    expect(
      rock.map((a) => a.id),
      unorderedEquals(['album-1', 'album-2', 'album-3']),
    );
    expect(hiphop.map((a) => a.id), unorderedEquals(['album-1', 'album-2']));
    expect(jazz.map((a) => a.id), ['album-3']);
    expect(
      (await database.libraryDao.getAlbumsByGenre(
        'rock',
        sort: AlbumSortOrder.newest,
        limit: 2,
      )).map((a) => a.id),
      ['album-3', 'album-2'],
    );
    expect(
      (await database.libraryDao.getAlbumsByGenre(
        'rock',
        sort: AlbumSortOrder.name,
        limit: 2,
        offset: 2,
      )).map((a) => a.id),
      ['album-3'],
    );
  }, skip: !sqliteAvailable);

  test('album and song queries honour downloaded-only', () async {
    await seed();
    await markDownloaded('s4');

    expect(
      (await database.libraryDao.getAlbumsByGenre(
        'rock',
        downloadedOnly: true,
      )).map((a) => a.id),
      ['album-2'],
    );
    expect(
      (await database.libraryDao.getSongsByGenre(
        'rock',
        downloadedOnly: true,
      )).map((s) => s.id),
      ['s4'],
    );
  }, skip: !sqliteAvailable);

  test('songs in a genre sort and page', () async {
    await seed();

    Future<List<String>> ids(
      GenreSongSort sort, {
      int? limit,
      int offset = 0,
    }) async => (await database.libraryDao.getSongsByGenre(
      'hiphop',
      sort: sort,
      limit: limit,
      offset: offset,
    )).map((s) => s.id).toList();

    expect(await ids(GenreSongSort.title), ['s1', 's2', 's3', 's7']);
    expect(await ids(GenreSongSort.title, limit: 2, offset: 1), ['s2', 's3']);
    // Album order follows the library's album order, then track order.
    expect(await ids(GenreSongSort.album), ['s1', 's2', 's3', 's7']);
    expect(await database.libraryDao.getSongsByGenre('jazz'), hasLength(1));
    expect(await database.libraryDao.getSongsByGenre('nope'), isEmpty);
  }, skip: !sqliteAvailable);

  test("a retag replaces the song's index rows", () async {
    await seed();
    await database.libraryDao.getGenres();

    await database.libraryDao.upsertSongs([
      song('s8', 'album-3', ['Blues']),
    ]);
    final genres = await database.libraryDao.getGenres();

    expect(genres.map((g) => g.key), isNot(contains('jazz')));
    expect(genres.map((g) => g.key), contains('blues'));
  }, skip: !sqliteAvailable);

  test('a deleted song leaves the counts', () async {
    await seed();
    await database.libraryDao.getGenres();

    await database.customStatement("DELETE FROM songs WHERE id = 's8'");

    expect(
      (await database.libraryDao.getGenres()).map((g) => g.key),
      isNot(contains('jazz')),
    );
  }, skip: !sqliteAvailable);

  test('getGenre reads one genre by key', () async {
    await seed();

    final rock = await database.libraryDao.getGenre(genreKey('Rock'));

    expect(rock?.songCount, 3);
    expect(await database.libraryDao.getGenre('missing'), isNull);
  }, skip: !sqliteAvailable);
}
