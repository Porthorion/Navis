import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  test(
    'unlimited recent liked albums preserve membership and stable order',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final stamp = DateTime(2026, 9, 20);
      await database.libraryDao.upsertAlbums([
        for (var i = 0; i < 12; i++)
          AlbumsTableCompanion.insert(
            id: 'album-$i',
            name: 'Album ${i.toString().padLeft(2, '0')}',
            starred: Value(stamp.subtract(Duration(days: i ~/ 2))),
          ),
        AlbumsTableCompanion.insert(
          id: 'song-liked-only',
          name: 'Song liked only',
        ),
      ]);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'liked-song',
          title: 'Liked song',
          albumId: const Value('song-liked-only'),
          starred: Value(stamp),
        ),
      ]);
      final full = await database.libraryDao
          .watchRecentlyLikedAlbums(limit: null)
          .first;
      final preview = await database.libraryDao
          .watchRecentlyLikedAlbums()
          .first;
      expect(full.map((album) => album.id), [
        for (var i = 0; i < 12; i++) 'album-$i',
      ]);
      expect(
        preview.map((album) => album.id),
        full.take(6).map((album) => album.id),
      );
      // Local filtering must have access to matches beyond the former six-item slice.
      expect(
        full.where((album) => album.id == 'album-10').single.id,
        'album-10',
      );
      expect(full.any((album) => album.id == 'song-liked-only'), isFalse);
    },
  );
}
