import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

void main() {
  late NavisDatabase db;
  final counter = _StatementCounter();

  setUp(() async {
    db = NavisDatabase(
      DatabaseConnection(
        NativeDatabase.memory(setup: registerSearchFoldFunction)
            .interceptWith(counter),
        closeStreamsSynchronously: true,
      ),
    );
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

  Future<void> entity(String type, String id, {int? generation}) async {
    if (type == 'album') {
      await db.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(id: id, name: id),
      ]);
    } else {
      await db.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: id, name: id),
      ]);
    }
    await db.customStatement(
      'UPDATE ${type}s SET catalog_generation = ${generation ?? 'NULL'}, '
      "is_provisional = 0 WHERE id = '$id'",
    );
  }

  test(
    'remapAlbumIdentity and remapArtistIdentity delete their rows',
    () async {
      for (final type in ['album', 'artist']) {
        await entity(type, 'old-$type');
        await entity(type, 'new-$type', generation: 5);
        await review('old-$type', type: type, reason: 'ambiguousMatch');
      }
      await db.songIdentityDao.remapAlbumIdentity(
        oldAlbumId: 'old-album',
        canonicalAlbumId: 'new-album',
        matchReason: 't',
      );
      expect(await rows(), {'1:old-artist': 'pending'});
      await db.songIdentityDao.remapArtistIdentity(
        oldArtistId: 'old-artist',
        canonicalArtistId: 'new-artist',
        matchReason: 't',
      );
      expect(await rows(), isEmpty);
    },
  );

  test(
    'ambiguous album and artist rows resolve when the old id is live',
    () async {
      for (final type in ['album', 'artist']) {
        await entity(type, 'live-$type', generation: 5);
        await review('live-$type', type: type, reason: 'ambiguousMatch');
        await review('conf-$type', type: type, reason: 'conflictingMbid');
        await entity(type, 'conf-$type', generation: 5);
      }
      await song('amb-song', liked: true, generation: 5);
      await review('amb-song', reason: 'ambiguousMatch');
      await pass();
      expect(await rows(), {'1:amb-song': 'pending'});
    },
  );

  test('own-playlist rule mirrors isOwnPlaylist', () async {
    Future<void> inPlaylist(
      String songId,
      String playlistId, {
      String? owner,
      bool readOnly = false,
      String? comment,
    }) async {
      await song(songId);
      await db.playlistDao.upsertPlaylists([
        PlaylistsTableCompanion.insert(
          id: playlistId,
          name: playlistId,
          owner: Value(owner),
          readOnly: Value(readOnly),
          comment: Value(comment),
        ),
      ]);
      await db.playlistDao.replacePlaylistSongs(playlistId, [
        PlaylistSongsTableCompanion.insert(
          playlistId: playlistId,
          songId: songId,
          sortOrder: 0,
        ),
      ]);
    }

    await inPlaylist('case', 'p-case', owner: 'ME');
    await inPlaylist('nullOwner', 'p-null');
    await inPlaylist(
      'auto',
      'p-auto',
      owner: 'me',
      comment: "Auto-imported from 'x.m3u'",
    );
    await inPlaylist('ro', 'p-ro', owner: 'me', readOnly: true);
    await inPlaylist('other', 'p-other', owner: 'someone');
    expect(
      await db.librarySyncDao.userChosenSongIds([
        'case',
        'nullOwner',
        'auto',
        'ro',
        'other',
        'ghost',
      ], owner: 'Me'),
      {'case', 'nullOwner'},
    );
  });

  test('legacy remote- ids are never user-chosen', () async {
    await song('remote-1', liked: true);
    expect(
      await db.librarySyncDao.userChosenSongIds(['remote-1'], owner: 'me'),
      isEmpty,
    );
  });

  test('20k pending rows resolve in a handful of queries', () async {
    const n = 20000;
    await db.batch((b) {
      for (var i = 0; i < n; i++) {
        b.insert(
          db.songsTable,
          SongsTableCompanion.insert(id: 's$i', title: 's$i'),
        );
        b.insert(
          db.libraryRecoveryReviewTable,
          LibraryRecoveryReviewTableCompanion.insert(
            serverId: 1,
            entityType: 'song',
            oldId: 's$i',
            reason: 'missingFromCatalog',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
      }
    });
    counter.count = 0;
    final removed = await db.librarySyncDao.autoResolveRecoveryReview(
      serverId: 1,
      generation: 5,
      owner: 'me',
    );
    expect(removed, n);
    // Chunks of 500: a few dozen statements, never one per row.
    expect(counter.count, lessThan(400));
    counter.count = 0;
    final ids = [for (var i = 0; i < n; i++) 's$i'];
    await db.librarySyncDao.userChosenSongIds(ids, owner: 'me');
    expect(counter.count, lessThan(100));
  });
}

class _StatementCounter extends QueryInterceptor {
  int count = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    count++;
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    count++;
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    count++;
    return super.runUpdate(executor, statement, args);
  }
}
