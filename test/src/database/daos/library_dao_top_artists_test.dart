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
    DateTime? starred,
    bool provisional = false,
  }) => database
      .into(database.artistsTable)
      .insert(
        ArtistsTableCompanion.insert(
          id: id,
          name: id.toUpperCase(),
          starred: Value(starred),
          isProvisional: Value(provisional),
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
}
