import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/search_text.dart';

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

  test('search rekeys half-width kana from key-version suffix 1', () async {
    await database.libraryDao.upsertSongs([
      _song('kana', 'ｶﾞｯﾂﾎﾟｰｽﾞ', '嵐', '残響リファレンス'),
    ]);
    await database.customStatement(
      'INSERT INTO song_search_text(song_id, source, search_text, match_title, match_artist, match_album) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'kana',
        'ｶﾞｯﾂﾎﾟｰｽﾞ\u001f嵐\u001f残響リファレンス\u001f1',
        'ｶﾞｯﾂﾎﾟｰｽﾞ|嵐|残響リファレンス',
        'ｶﾞｯﾂﾎﾟｰｽﾞ',
        '嵐',
        '残響リファレンス',
      ],
    );
    expect(await search('ガッツポーズ'), ['kana']);
    expect(normalizeSearchText('カ\u3099ッツホ\u309aース\u3099'), 'ガッツポーズ');
    await database.libraryDao.scheduleSongSearchIndexRefresh();
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
