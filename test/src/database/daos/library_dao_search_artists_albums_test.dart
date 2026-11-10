import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<void> artists(List<String> names) =>
      database.libraryDao.upsertArtists([
        for (final (i, name) in names.indexed)
          ArtistsTableCompanion.insert(id: 'a$i-$name', name: name),
      ]);

  Future<void> albums(List<(String, String?, int?)> rows) =>
      database.libraryDao.upsertAlbums([
        for (final (i, r) in rows.indexed)
          AlbumsTableCompanion.insert(
            id: 'b$i-${r.$1}',
            name: r.$1,
            artistName: Value(r.$2),
            year: Value(r.$3),
          ),
      ]);

  Future<List<String>> artistNames(String q, {int limit = 20}) async => [
    for (final a in await database.libraryDao.searchArtistsLocal(
      q,
      limit: limit,
    ))
      a.name,
  ];

  Future<List<String>> albumNames(String q, {int limit = 20}) async => [
    for (final a in await database.libraryDao.searchAlbumsLocal(
      q,
      limit: limit,
    ))
      a.name,
  ];

  test('folds accents in both directions', () async {
    await artists(['Beyoncé', 'Édith Piaf', 'Other']);
    await albums([('Beyoncé', 'Beyoncé', 2013), ('Lemonade', 'Beyoncé', 2016)]);
    expect(await artistNames('beyonce'), ['Beyoncé']);
    expect(await artistNames('Beyoncé'), ['Beyoncé']);
    expect(await artistNames('edith'), ['Édith Piaf']);
    expect(await artistNames('ÉDITH'), ['Édith Piaf']);
    expect(await albumNames('beyonce'), ['Beyoncé', 'Lemonade']);
  });

  test('percent and underscore are literals', () async {
    await artists(['100% Pure', 'Plain', 'a_b', 'axb']);
    await albums([('100% Pure', null, 2000), ('Plain', null, 2001)]);
    expect(await artistNames('100%'), ['100% Pure']);
    expect(await artistNames('%'), ['100% Pure']);
    expect(await artistNames('a_b'), ['a_b']);
    expect(await artistNames('_'), ['a_b']);
    expect(await albumNames('%'), ['100% Pure']);
  });

  test('ranks before limiting', () async {
    // 30 artists containing "the" sort before "The" is not guaranteed, so
    // name them so that the exact match is alphabetically last.
    await artists([for (var i = 0; i < 30; i++) 'A the $i', 'The', 'The Who']);
    final top = await artistNames('the');
    expect(top, hasLength(20));
    expect(top.take(2), ['The', 'The Who']);

    await albums([
      for (var i = 0; i < 30; i++) ('Best of Love $i', null, 2020),
      ('Love', null, 1970),
    ]);
    expect((await albumNames('love')).first, 'Love');
  });

  test('album name matches rank ahead of artist name matches', () async {
    await albums([('Zed', 'Queen', 2020), ('Queen', 'Someone', 1990)]);
    expect(await albumNames('queen'), ['Queen', 'Zed']);
  });

  test('a query that folds to nothing returns no rows', () async {
    await artists(['Alpha', 'Beta']);
    await albums([('Gamma', 'Alpha', 2000)]);
    expect(await artistNames(''), isEmpty);
    expect(await artistNames('   '), isEmpty);
    expect(await albumNames(''), isEmpty);
  });

  test(
    'navis_fold exists on test connections and folds, NULL stays NULL',
    () async {
      final row = await database
          .customSelect(
            "SELECT navis_fold('Édith ÉCOLE') AS a, navis_fold(NULL) AS b",
          )
          .getSingle();
      expect(row.read<String>('a'), 'edith ecole');
      expect(row.data['b'], isNull);
    },
  );
}
