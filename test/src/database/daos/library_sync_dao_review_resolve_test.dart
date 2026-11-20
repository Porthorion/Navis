import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase db;

  setUp(() async {
    db = createTestDatabase();
    for (final url in ['https://a.test', 'https://b.test']) {
      await db
          .into(db.serverConfigTable)
          .insert(
            ServerConfigTableCompanion.insert(
              url: url,
              username: 'me',
              apiVersion: '1.16.1',
            ),
          );
    }
  });
  tearDown(() => db.close());

  Future<void> song(
    String id, {
    bool liked = false,
    bool external = false,
    int? generation,
    bool tombstoned = false,
  }) async {
    await db.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: id,
        title: id,
        starred: liked ? Value(DateTime(2026)) : const Value.absent(),
        isExternal: Value(external),
      ),
    ]);
    await db.customStatement(
      'UPDATE songs SET catalog_generation = ${generation ?? 'NULL'}, '
      'server_deleted_at = ${tombstoned ? 1769904000 : 'NULL'} '
      "WHERE id = '$id'",
    );
  }

  Future<void> review(
    String id, {
    int server = 1,
    String reason = 'missingFromCatalog',
    String type = 'song',
  }) => db.librarySyncDao.recordRecoveryReview(
    serverId: server,
    entityType: type,
    oldId: id,
    reason: reason,
  );

  Future<Map<String, String>> rows() async => {
    for (final r in await db.select(db.libraryRecoveryReviewTable).get())
      '${r.serverId}:${r.oldId}': r.disposition,
  };

  Future<int> pass({int server = 1}) => db.librarySyncDao
      .autoResolveRecoveryReview(serverId: server, generation: 5, owner: 'me');

  test(
    'live id resolves, disappearing again lists again, replay is idempotent',
    () async {
      await song('s', liked: true, generation: 5);
      await review('s');
      expect(await pass(), 1);
      expect(await rows(), isEmpty);
      expect(await pass(), 0);
      await song('s', liked: true, tombstoned: true);
      await review('s');
      expect(await pass(), 0);
      expect(await rows(), {'1:s': 'pending'});
    },
  );

  test('ambiguous survives the live rule; dispositions untouched', () async {
    await song('amb', liked: true, generation: 5);
    await review('amb', reason: 'ambiguousMatch');
    for (final d in ['keptForLater', 'removedFromLiked', 'relinked']) {
      await song(d, generation: 5);
      await review(d);
      final row = (await db.select(db.libraryRecoveryReviewTable).get())
          .firstWhere((r) => r.oldId == d);
      await db.librarySyncDao.setRecoveryReviewDisposition(
        id: row.id,
        disposition: d,
      );
    }
    await pass();
    final r = await rows();
    expect(r['1:amb'], 'pending');
    expect(r['1:keptForLater'], 'keptForLater');
    expect(r['1:removedFromLiked'], 'removedFromLiked');
    expect(r['1:relinked'], 'relinked');
  });

  test('same oldId on two servers: only that server resolves', () async {
    await song('s', liked: true, generation: 5);
    await review('s');
    await review('s', server: 2);
    await pass();
    expect(await rows(), {'2:s': 'pending'});
  });

  test('alias, missing row and no user-chosen reference resolve', () async {
    await song('aliased', liked: true, tombstoned: true);
    await review('aliased');
    await db.customStatement(
      "INSERT INTO entity_identity_aliases (entity_type, old_id, new_id, "
      "match_reason, matched_at) VALUES ('song','aliased','n','x',0)",
    );
    await review('ghost');
    await song('plain', tombstoned: true);
    await review('plain');
    await song('chosen', liked: true, tombstoned: true);
    await review('chosen');
    await pass();
    expect(await rows(), {'1:chosen': 'pending'});
  });

  test(
    'user-chosen: external, history-only, other-user and local playlists',
    () async {
      await song('ext-1', liked: true, external: true);
      await song('hist');
      await song('theirs');
      await song('mine');
      await db.playlistDao.upsertPlaylists([
        PlaylistsTableCompanion.insert(
          id: 'p1',
          name: 'x',
          owner: const Value('other'),
        ),
        PlaylistsTableCompanion.insert(
          id: 'p2',
          name: 'y',
          isLocal: const Value(true),
        ),
      ]);
      await db.playlistDao.replacePlaylistSongs('p1', [
        PlaylistSongsTableCompanion.insert(
          playlistId: 'p1',
          songId: 'theirs',
          sortOrder: 0,
        ),
      ]);
      await db.playlistDao.replacePlaylistSongs('p2', [
        PlaylistSongsTableCompanion.insert(
          playlistId: 'p2',
          songId: 'mine',
          sortOrder: 0,
        ),
      ]);
      final chosen = await db.librarySyncDao.userChosenSongIds([
        'ext-1',
        'hist',
        'theirs',
        'mine',
      ], owner: 'me');
      expect(chosen, {'mine'});
      await song('ext-1', liked: true);
      expect(
        await db.librarySyncDao.userChosenSongIds(['ext-1'], owner: 'me'),
        isEmpty,
      );
      await song('flipped', liked: true);
      expect(
        await db.librarySyncDao.userChosenSongIds(['flipped'], owner: 'me'),
        {'flipped'},
      );
    },
  );

  test('a remap deletes its review row', () async {
    await song('old', liked: true, tombstoned: true);
    await song('new', generation: 5);
    await review('old');
    await db.songIdentityDao.remapSongIdentity(
      oldSongId: 'old',
      canonicalSongId: 'new',
      matchReason: 't',
    );
    expect(await rows(), isEmpty);
  });
}
