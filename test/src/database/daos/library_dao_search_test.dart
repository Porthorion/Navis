import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/search_text.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() async {
    database = createTestDatabase();
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      _song('queen-1', 'Bohemian Rhapsody', 'Queen', 'A Night at the Opera'),
      _song('queen-2', 'Love of My Life', 'Queen', 'A Night at the Opera'),
      _song('beyonce-1', 'Halo', 'Beyoncé', 'I Am... Sasha Fierce'),
      _song('cafe-1', 'Café del Mar', 'Energy 52', 'Café del Mar'),
      _song('arabic-1', 'حبيبي يا نور العين', 'عمرو دياب', 'نور العين'),
      _song('arabic-2', 'أنا', 'فيروز', null),
      _song('cjk-1', '東京フラッシュ', 'Vaundy', 'strobo'),
      _song('acdc-1', 'Back in Black', 'AC/DC', 'Back in Black'),
    ]);
  });

  tearDown(() => database.close());

  Future<List<String>> search(String query, {int limit = 20}) async =>
      (await database.libraryDao.searchCachedSongs(
        query,
        limit: limit,
      )).map((song) => song.id).toList();

  test('ranks exact and prefix title matches before artist matches', () async {
    expect(await search('bohemian rhapsody'), <String>['queen-1']);
    expect((await search('queen')).toSet(), <String>{'queen-1', 'queen-2'});
    expect((await search('love')).first, 'queen-2');
  });

  test('keeps fuzzy subsequence matching for typos', () async {
    expect(await search('bhmn rhpsdy'), contains('queen-1'));
    expect(await search('rhapsody bohemian'), contains('queen-1'));
  });

  test('folds accents in both directions', () async {
    expect(await search('beyonce'), <String>['beyonce-1']);
    expect(await search('Beyoncé'), <String>['beyonce-1']);
    expect(await search('cafe'), <String>['cafe-1']);
  });

  test('finds Arabic and CJK titles, artists and letter variants', () async {
    expect(await search('عمرو'), <String>['arabic-1']);
    expect(await search('نور'), <String>['arabic-1']);
    // Hamza-on-alef folds to bare alef, as users commonly type it.
    expect(await search('انا'), <String>['arabic-2']);
    expect(await search('東京'), <String>['cjk-1']);
  });

  test('punctuation-only queries match nothing', () async {
    expect(await search('!!!'), isEmpty);
    expect(await search('   '), hasLength(8));
  });

  test('stores the index and refreshes stale rows after edits', () async {
    expect(await search('halo'), <String>['beyonce-1']);
    await database.libraryDao.refreshSongSearchIndex();
    final indexed = await database
        .customSelect('SELECT COUNT(*) AS c FROM song_search_text')
        .getSingle();
    expect(indexed.read<int>('c'), 8);

    // A write path that knows nothing about the index changes the title.
    await database.customStatement(
      "UPDATE songs SET title = 'Crazy in Love' WHERE id = 'beyonce-1'",
    );
    expect(await search('halo'), isEmpty);
    expect(await search('crazy'), <String>['beyonce-1']);

    await database.customStatement("DELETE FROM songs WHERE id = 'acdc-1'");
    await database.libraryDao.refreshSongSearchIndex();
    final remaining = await database
        .customSelect('SELECT COUNT(*) AS c FROM song_search_text')
        .getSingle();
    expect(remaining.read<int>('c'), 7);
  });

  test('rebuilds a stored search key with an older version suffix', () async {
    await database.libraryDao.refreshSongSearchIndex();
    final before = await database
        .customSelect(
          "SELECT source FROM song_search_text WHERE song_id = 'beyonce-1'",
        )
        .getSingle();
    final source = before.read<String>('source');
    final older = '${source.substring(0, source.lastIndexOf('\u001f'))}\u001f1';
    expect(older, isNot(source));
    await database.customStatement(
      "UPDATE song_search_text SET source = ?, match_title = 'obsolete' "
      "WHERE song_id = 'beyonce-1'",
      [older],
    );

    expect(await database.libraryDao.refreshSongSearchIndex(), 1);
    final rebuilt = await database
        .customSelect(
          'SELECT source, match_title FROM song_search_text '
          "WHERE song_id = 'beyonce-1'",
        )
        .getSingle();
    expect(rebuilt.read<String>('source'), source);
    expect(
      rebuilt.read<String>('source'),
      endsWith('\u001f$metadataKeyVersion'),
    );
    expect(rebuilt.read<String>('match_title'), normalizeMetadata('Halo'));
    expect(await search('halo'), ['beyonce-1']);
    expect(await database.libraryDao.refreshSongSearchIndex(), 0);
  });

  test('normalizeSearchText keeps letters from every script', () {
    expect(
      normalizeSearchText('AC/DC — Back in Black!'),
      'ac dc back in black',
    );
    expect(normalizeSearchText('Straße'), 'strasse');
    expect(normalizeSearchText('مَرْحَبًا'), 'مرحبا');
    expect(normalizeSearchText('東京 フラッシュ'), '東京 フラッシュ');
    expect(songSearchSubsequenceGlob('abc'), '*a*b*c*');
  });
}

SongsTableCompanion _song(
  String id,
  String title,
  String artist,
  String? album,
) => SongsTableCompanion.insert(
  id: id,
  title: title,
  artistName: Value(artist),
  albumName: Value(album),
);
