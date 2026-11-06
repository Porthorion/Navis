import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('StarSyncDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'queueStarAction keeps only the latest pending action per item',
      () async {
        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'star',
        );
        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'unstar',
        );

        final pending = await database.starSyncDao.getPendingActions();

        expect(pending, hasLength(1));
        expect(pending.single.itemId, 'song-1');
        expect(pending.single.itemType, 'song');
        expect(pending.single.action, 'unstar');
      },
      skip: !sqliteAvailable,
    );

    group('remote copies (ext- ids)', () {
      Future<void> seed() async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'lib-1', title: 'So it goes'),
          SongsTableCompanion.insert(
            id: 'ext-deezer-song-9',
            title: 'So It Goes',
          ),
        ]);
      }

      test('a remote copy is refused: no star, no queue', () async {
        await seed();

        final liked = await database.starSyncDao.toggleSongStarred(
          'ext-deezer-song-9',
        );

        expect(liked, isNull);
        expect(
          await database.libraryDao.getSongStarred('ext-deezer-song-9'),
          isNull,
        );
        expect(await database.starSyncDao.getPendingActions(), isEmpty);
      }, skip: !sqliteAvailable);

      test('a relinked remote copy is still not redirected', () async {
        await seed();
        await database.songIdentityDao.remapSongIdentity(
          oldSongId: 'ext-deezer-song-9',
          canonicalSongId: 'lib-1',
          matchReason: 'metadata',
        );

        expect(
          await database.starSyncDao.toggleSongStarred('ext-deezer-song-9'),
          isNull,
        );
        expect(await database.libraryDao.getSongStarred('lib-1'), isNull);
        expect(await database.starSyncDao.getPendingActions(), isEmpty);
      }, skip: !sqliteAvailable);

      test('a library song toggles as before', () async {
        await seed();

        expect(await database.starSyncDao.toggleSongStarred('lib-1'), isTrue);
        expect(await database.starSyncDao.toggleSongStarred('lib-1'), isFalse);
      }, skip: !sqliteAvailable);

      test(
        'dropRemoteSongLikes clears remote likes locally, nothing queued',
        () async {
          await seed();
          await database.libraryDao.setEntityStarred(
            'song',
            'ext-deezer-song-9',
            DateTime(2026),
          );
          await database.libraryDao.setEntityStarred(
            'song',
            'lib-1',
            DateTime(2026),
          );
          await database.starSyncDao.queueStarAction(
            itemId: 'ext-deezer-song-9',
            itemType: 'song',
            action: 'star',
          );

          expect(await database.starSyncDao.dropRemoteSongLikes(), 1);

          expect(
            await database.libraryDao.getSongStarred('ext-deezer-song-9'),
            isNull,
          );
          expect(await database.libraryDao.getSongStarred('lib-1'), isNotNull);
          expect(await database.starSyncDao.getPendingActions(), isEmpty);
        },
        skip: !sqliteAvailable,
      );

      Future<void> remap() => database.songIdentityDao.remapSongIdentity(
        oldSongId: 'ext-deezer-song-9',
        canonicalSongId: 'lib-1',
        matchReason: 'metadata',
      );

      Future<void> likeExt({required bool sent}) async {
        await database.libraryDao.setEntityStarred(
          'song',
          'ext-deezer-song-9',
          DateTime(2026),
        );
        if (!sent) {
          await database.starSyncDao.queueStarAction(
            itemId: 'ext-deezer-song-9',
            itemType: 'song',
            action: 'star',
          );
        }
      }

      test(
        'an unsent remote like moves to the library song on relink',
        () async {
          await seed();
          await likeExt(sent: false);

          await remap();

          expect(await database.libraryDao.getSongStarred('lib-1'), isNotNull);
          final pending = await database.starSyncDao.getPendingActions();
          expect(pending.map((p) => (p.itemId, p.action)), [('lib-1', 'star')]);
        },
        skip: !sqliteAvailable,
      );

      test(
        'a sent remote like carries nothing onto the library song',
        () async {
          await seed();
          await likeExt(sent: true);

          await remap();

          expect(await database.libraryDao.getSongStarred('lib-1'), isNull);
          expect(await database.starSyncDao.getPendingActions(), isEmpty);
        },
        skip: !sqliteAvailable,
      );

      test('a pending unlike of the library song survives a relink', () async {
        await seed();
        await database.starSyncDao.setStarred(
          itemId: 'lib-1',
          itemType: 'song',
          liked: false,
        );
        await likeExt(sent: true);

        await remap();

        expect(await database.libraryDao.getSongStarred('lib-1'), isNull);
        final pending = await database.starSyncDao.getPendingActions();
        expect(pending.map((p) => (p.itemId, p.action)), [('lib-1', 'unstar')]);
      }, skip: !sqliteAvailable);

      test('an unsent remote like does not replace a pending unlike', () async {
        await seed();
        await database.starSyncDao.setStarred(
          itemId: 'lib-1',
          itemType: 'song',
          liked: false,
        );
        await likeExt(sent: false);

        await remap();

        expect(await database.libraryDao.getSongStarred('lib-1'), isNull);
        final pending = await database.starSyncDao.getPendingActions();
        expect(pending.map((p) => (p.itemId, p.action)), [('lib-1', 'unstar')]);
      }, skip: !sqliteAvailable);
    });
  });
}
