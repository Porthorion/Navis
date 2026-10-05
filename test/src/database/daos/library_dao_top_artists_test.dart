import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<void> artist(
    String id, {
    String? name,
    DateTime? starred,
    bool provisional = false,
    bool external = false,
    int? albumCount,
  }) => database
      .into(database.artistsTable)
      .insert(
        ArtistsTableCompanion.insert(
          id: id,
          name: name ?? id.toUpperCase(),
          starred: Value(starred),
          isProvisional: Value(provisional),
          isExternal: Value(external),
          albumCount: Value(albumCount),
        ),
      );

  Future<void> album(
    String id,
    String artistId, {
    DateTime? starred,
    bool external = false,
    String? availability,
  }) => database
      .into(database.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: id,
          name: id,
          artistId: Value(artistId),
          starred: Value(starred),
          isExternal: Value(external),
          catalogAvailability: Value(availability),
        ),
      );

  Future<void> song(
    String id,
    String artistId,
    int? plays, {
    bool deleted = false,
  }) => database
      .into(database.songsTable)
      .insert(
        SongsTableCompanion.insert(
          id: id,
          title: id,
          artistId: Value(artistId),
          playCount: Value(plays),
          serverDeletedAt: Value(deleted ? DateTime(2026) : null),
        ),
      );

  test('ranks artists by summed plays, liked first among equals', () async {
    final liked = DateTime(2026, 9);
    await artist('a');
    await artist('b', starred: liked);
    await artist('c');
    await artist('d', starred: liked);
    await artist('e');
    await song('a1', 'a', 3);
    await song('a2', 'a', 4);
    await song('b1', 'b', 7);
    await song('c1', 'c', 9);
    // d has no plays but is liked; e has neither.
    await song('e1', 'e', 0);

    final ranked = await database.libraryDao.getTopPlayedArtists();
    expect(ranked.map((artist) => artist.id), <String>['c', 'b', 'a', 'd']);
  });

  test('ignores deleted songs and provisional artists, and limits', () async {
    await artist('a');
    await artist('b');
    await artist('p', provisional: true);
    await song('a1', 'a', 1);
    await song('a2', 'a', 50, deleted: true);
    await song('b1', 'b', 2);
    await song('p1', 'p', 99);

    expect(
      (await database.libraryDao.getTopPlayedArtists()).map((a) => a.id),
      <String>['b', 'a'],
    );
    expect(
      (await database.libraryDao.getTopPlayedArtists(limit: 1))
          .map((a) => a.id),
      <String>['b'],
    );
  });

  group('library artists by weight', () {
    test('ranks by liked albums, then songs, then albums', () async {
      final liked = DateTime(2026, 9);
      await artist('few-songs');
      await artist('many-songs');
      await artist('liked-album');
      await artist('tie-more-albums', albumCount: 9);
      await artist('tie-fewer-albums', albumCount: 2);
      await album('la1', 'liked-album', starred: liked);
      await song('l1', 'liked-album', null);
      await song('f1', 'few-songs', null);
      for (var i = 0; i < 3; i++) {
        await song('m$i', 'many-songs', null);
      }
      for (final id in <String>['tie-more-albums', 'tie-fewer-albums']) {
        await song('${id}1', id, null);
        await song('${id}2', id, null);
      }

      expect(
        (await database.libraryDao.getArtistsByLibraryWeight(limit: 10))
            .map((a) => a.id),
        <String>[
          'liked-album',
          'many-songs',
          'tie-more-albums',
          'tie-fewer-albums',
          'few-songs',
        ],
      );
    });

    test('leaves out placeholders, remote and empty artists', () async {
      await artist('real');
      await artist('unknown', name: '[Unknown Artist]');
      await artist('various', name: 'Various Artists');
      await artist('remote', external: true);
      await artist('p', provisional: true);
      await artist('empty', albumCount: 4);
      await artist('deleted');
      for (final id in <String>['real', 'unknown', 'various', 'remote', 'p']) {
        await song('${id}1', id, null);
      }
      await song('deleted1', 'deleted', null, deleted: true);

      expect(
        (await database.libraryDao.getArtistsByLibraryWeight(limit: 10))
            .map((a) => a.id),
        <String>['real'],
      );
    });

    test('liked remote or missing albums do not count', () async {
      final liked = DateTime(2026, 9);
      await artist('remote-liked');
      await artist('missing-liked');
      await artist('more-songs');
      await album('r1', 'remote-liked', starred: liked, external: true);
      await album(
        'm1',
        'missing-liked',
        starred: liked,
        availability: 'confirmedMissing',
      );
      await song('r-song', 'remote-liked', null);
      await song('m-song', 'missing-liked', null);
      await song('s1', 'more-songs', null);
      await song('s2', 'more-songs', null);

      expect(
        (await database.libraryDao.getArtistsByLibraryWeight(limit: 10))
            .map((a) => a.id),
        <String>['more-songs', 'missing-liked', 'remote-liked'],
      );
    });

    test('skips the given artists and limits', () async {
      for (final id in <String>['a', 'b', 'c']) {
        await artist(id);
        await song('${id}1', id, null);
      }

      expect(
        (await database.libraryDao.getArtistsByLibraryWeight(
          limit: 1,
          excludeIds: <String>{'a'},
        )).map((a) => a.id),
        <String>['b'],
      );
    });
  });
}
