import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import '../../helpers/test_database.dart';

void main() {
  group('LibraryDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'replaceSongsForAlbumsChunk replaces targeted album songs atomically',
      () async {
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
            AlbumsTableCompanion.insert(id: 'album-2', name: 'Album 2'),
          ],
        );
        await database.libraryDao.replaceSongs(
          <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'old-song-1',
              title: 'Old Song 1',
              albumId: const Value('album-1'),
            ),
            SongsTableCompanion.insert(
              id: 'old-song-2',
              title: 'Old Song 2',
              albumId: const Value('album-2'),
            ),
          ],
        );

        final chunk = <String, List<SongsTableCompanion>>{
          'album-1': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'new-song-1',
              title: 'New Song 1',
              albumId: const Value('album-1'),
            ),
          ],
          'album-2': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'new-song-2',
              title: 'New Song 2',
              albumId: const Value('album-2'),
            ),
            SongsTableCompanion.insert(
              id: 'new-song-3',
              title: 'New Song 3',
              albumId: const Value('album-2'),
            ),
          ],
        };

        await database.libraryDao.replaceSongsForAlbumsChunk(chunk);
        await database.libraryDao.replaceSongsForAlbumsChunk(chunk);

        final songs = await database.select(database.songsTable).get();
        expect(songs.map((song) => song.id).toSet(), {
          'new-song-1',
          'new-song-2',
          'new-song-3',
        });
        expect(
          songs.where((song) => song.albumId == 'album-1').length,
          1,
        );
        expect(
          songs.where((song) => song.albumId == 'album-2').length,
          2,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'markAlbumsSongsHydratedByIds updates only targeted albums',
      () async {
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              songsHydrated: const Value(false),
            ),
            AlbumsTableCompanion.insert(
              id: 'album-2',
              name: 'Album 2',
              songsHydrated: const Value(false),
            ),
          ],
        );

        await database.libraryDao.markAlbumsSongsHydratedByIds(
          const <String>['album-1'],
        );

        final rows = await database.select(database.albumsTable).get();
        final byId = {for (final row in rows) row.id: row};
        expect(byId['album-1']?.songsHydrated, isTrue);
        expect(byId['album-2']?.songsHydrated, isFalse);
      },
      skip: !sqliteAvailable,
    );
  });
}
