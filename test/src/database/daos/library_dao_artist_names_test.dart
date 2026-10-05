import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  Future<void> artist(
    String id,
    String name, {
    bool isExternal = false,
    bool isProvisional = false,
    int? albumCount,
  }) => database
      .into(database.artistsTable)
      .insert(
        ArtistsTableCompanion.insert(
          id: id,
          name: name,
          isExternal: Value(isExternal),
          isProvisional: Value(isProvisional),
          albumCount: Value(albumCount),
        ),
      );

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  test('findArtistsByNormalizedNames matches normalized names', () async {
    await artist('oor', 'ＯＮＥ　ＯＫ　ＲＯＣＫ');
    await artist('bey', 'Beyoncé');
    await artist('mfs', 'MY FIRST STORY');
    await artist('other', 'Someone Else');

    final found = await database.libraryDao.findArtistsByNormalizedNames([
      'One Ok Rock',
      'Beyonce',
      'My First Story',
      'Coldrain',
      '',
    ]);

    expect(found.map((key, artist) => MapEntry(key, artist.id)), {
      'one ok rock': 'oor',
      'beyonce': 'bey',
      'my first story': 'mfs',
    });
  });

  test(
    'a server artist wins over a remote namesake, then more albums',
    () async {
      await artist('remote', 'Coldrain', isExternal: true, albumCount: 40);
      await artist('few', 'coldrain', albumCount: 2);
      await artist('many', 'COLDRAIN', albumCount: 9);
      await artist('pending', 'Crossfaith', isProvisional: true);

      final found = await database.libraryDao.findArtistsByNormalizedNames([
        'Coldrain',
        'Crossfaith',
      ]);

      expect(found.keys, ['coldrain']);
      expect(found['coldrain']?.id, 'many');
    },
  );
}
