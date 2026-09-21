import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late Directory tempDirectory;

  setUp(() async {
    database = createTestDatabase();
    tempDirectory = await Directory.systemTemp.createTemp(
      'navis_song_identity_test_',
    );
    await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(id: 'artist', name: 'Artist'),
    ]);
    await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'album',
        name: 'Album',
        artistId: const Value('artist'),
      ),
    ]);
    await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'remote-song',
        title: 'Track',
        albumId: const Value('album'),
        artistId: const Value('artist'),
        recordingMbid: const Value('recording-mbid'),
      ),
    ]);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'server-song',
        title: 'Track',
        albumId: const Value('album'),
        artistId: const Value('artist'),
        recordingMbid: const Value('recording-mbid'),
      ),
    ]);
  });

  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  test(
    'notifies playback before deleting a provisional identity',
    () async {
      var callbackObservedProvisionalRow = false;
      final canonical = await database.libraryDao.getSongById('server-song');

      final summary = await SongIdentityReconciler(
        database.songIdentityDao,
        onBeforeRemap: (aliases) async {
          expect(aliases, <String, String>{
            'remote-song': 'server-song',
          });
          callbackObservedProvisionalRow =
              await database.libraryDao.getSongById('remote-song') != null;
        },
        readActiveSongId: () => 'remote-song',
      ).reconcileCanonicalSongs(<SongsTableData>[canonical!]);

      expect(callbackObservedProvisionalRow, isTrue);
      expect(summary.aliases, hasLength(1));
      expect(await database.libraryDao.getSongById('remote-song'), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'aborts identity deletion when playback handoff fails',
    () async {
      final canonical = await database.libraryDao.getSongById('server-song');

      await expectLater(
        SongIdentityReconciler(
          database.songIdentityDao,
          onBeforeRemap: (_) => Future<void>.error(
            StateError('playback handoff failed'),
          ),
        ).reconcileCanonicalSongs(<SongsTableData>[canonical!]),
        throwsStateError,
      );

      expect(
        await database.libraryDao.getSongById('remote-song'),
        isNotNull,
      );
      expect(await database.songIdentityDao.getAliases(), isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test(
    'transactionally remaps every persisted song reference',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        "INSERT INTO playlists (id, name) VALUES ('playlist', 'Playlist');",
      );
      await database.customStatement(
        '''
      INSERT INTO playlist_songs (playlist_id, song_id, sort_order)
      VALUES ('playlist', 'remote-song', 0);
      ''',
      );
      await database.customStatement(
        '''
      INSERT INTO play_queue (
        id,
        current_index,
        shuffle_mode,
        repeat_mode,
        position_ms,
        updated_at
      ) VALUES (1, 0, 'off', 'off', 0, ?);
      ''',
        <Object?>[now],
      );
      await database.customStatement(
        '''
      INSERT INTO play_queue_items (queue_id, song_id, sort_order)
      VALUES (1, 'remote-song', 0);
      ''',
      );
      await database.customStatement(
        'INSERT INTO play_history (song_id, played_at) VALUES (?, ?);',
        <Object?>['remote-song', now],
      );
      await database.customStatement(
        '''
      INSERT INTO match_flows (id, name, enabled, created_at, updated_at)
      VALUES ('flow', 'Flow', 1, ?, ?);
      ''',
        <Object?>[now, now],
      );
      await database.customStatement(
        '''
      INSERT INTO match_flow_songs (flow_id, song_id, sort_order, added_at)
      VALUES ('flow', 'remote-song', 0, ?);
      ''',
        <Object?>[now],
      );
      await database.customStatement(
        '''
      INSERT INTO download_queue (
        song_id,
        status,
        progress,
        added_at,
        priority,
        retry_count
      ) VALUES ('remote-song', 'queued', 0, ?, 0, 0);
      ''',
        <Object?>[now],
      );
      await database.customStatement(
        '''
      INSERT INTO external_lyrics_cache (
        song_id,
        source,
        fetched_at,
        ttl_seconds,
        failure_count
      ) VALUES ('remote-song', 'lrclib', ?, 86400, 0);
      ''',
        <Object?>[now],
      );
      await database.customStatement(
        '''
      INSERT INTO scrobble_queue (
        song_id,
        provider,
        submission,
        created_at,
        next_attempt_at,
        attempts,
        expires_at,
        session_key
      ) VALUES (
        'remote-song',
        'subsonic',
        1,
        ?,
        ?,
        0,
        ?,
        'session'
      );
      ''',
        <Object?>[now, now, now + 3600],
      );
      await database.customStatement(
        '''
      INSERT INTO listenbrainz_feedback_queue (
        song_id,
        score,
        title,
        artist,
        attempts,
        queued_at,
        next_attempt_at
      ) VALUES ('remote-song', 1, 'Track', 'Artist', 0, ?, ?);
      ''',
        <Object?>[now, now],
      );
      await database.customStatement(
        '''
      INSERT INTO star_sync_queue (item_id, item_type, action, queued_at)
      VALUES ('remote-song', 'song', 'star', ?);
      ''',
        <Object?>[now],
      );

      final cacheFile = File('${tempDirectory.path}/remote.audio')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'remote-song',
          filePath: cacheFile.path,
          fileSize: cacheFile.lengthSync(),
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
        ),
      );

      final result = await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'exactMetadata',
      );

      expect(result.alias.oldSongId, 'remote-song');
      expect(
        await database.libraryDao.getSongById('remote-song'),
        isNull,
      );
      expect(
        (await database.libraryDao.getSongById('server-song'))?.isProvisional,
        isFalse,
      );
      expect(
        (await database.cacheDao.getCachedTrack('server-song'))?.filePath,
        cacheFile.path,
      );
      expect(await cacheFile.exists(), isTrue);

      for (final table in <String>[
        'download_queue',
        'play_queue_items',
        'play_history',
        'playlist_songs',
        'match_flow_songs',
        'external_lyrics_cache',
        'scrobble_queue',
        'listenbrainz_feedback_queue',
      ]) {
        expect(await _count(database, table, 'remote-song'), 0, reason: table);
        expect(await _count(database, table, 'server-song'), 1, reason: table);
      }
      final starRows = await database
          .customSelect(
            "SELECT item_id FROM star_sync_queue WHERE item_type = 'song';",
          )
          .get();
      expect(starRows.single.read<String>('item_id'), 'server-song');
      expect(
        await database.songIdentityDao.resolveCanonicalId('remote-song'),
        'server-song',
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'cache collision keeps a valid permanent canonical entry',
    () async {
      final remoteFile = File('${tempDirectory.path}/remote.audio')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final permanentFile = File('${tempDirectory.path}/permanent.audio')
        ..writeAsBytesSync(<int>[4, 5, 6, 7]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'remote-song',
          filePath: remoteFile.path,
          fileSize: remoteFile.lengthSync(),
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'server-song',
          filePath: permanentFile.path,
          fileSize: permanentFile.lengthSync(),
          format: 'flac',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
        ),
      );

      await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );

      final retained = await database.cacheDao.getCachedTrack('server-song');
      expect(retained?.cacheType, CacheType.permanent);
      expect(retained?.filePath, permanentFile.path);
      expect(await permanentFile.exists(), isTrue);
      expect(await remoteFile.exists(), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'active provisional cache survives a canonical cache collision',
    () async {
      final remoteFile = File('${tempDirectory.path}/active-remote.audio')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final permanentFile = File('${tempDirectory.path}/active-permanent.audio')
        ..writeAsBytesSync(<int>[4, 5, 6, 7]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'remote-song',
          filePath: remoteFile.path,
          fileSize: remoteFile.lengthSync(),
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'server-song',
          filePath: permanentFile.path,
          fileSize: permanentFile.lengthSync(),
          format: 'flac',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
        ),
      );

      await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
        retainOldCacheFile: true,
      );

      expect(await remoteFile.exists(), isTrue);
      expect(
        (await database.cacheDao.getCachedTrack('server-song'))?.filePath,
        permanentFile.path,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'carries a like forward and queues server restoration when the replacement lacks it',
    () async {
      final likedAt = DateTime.utc(2026, 8, 1, 12);
      await database.customStatement(
        'UPDATE songs SET starred = ? WHERE id = ?;',
        <Object?>[likedAt.millisecondsSinceEpoch ~/ 1000, 'remote-song'],
      );

      final result = await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );

      expect(result.restoredLike, isTrue);
      final merged = await database.libraryDao.getSongById('server-song');
      expect(merged!.starred!.isAtSameMomentAs(likedAt), isTrue);
      final starRows = await database
          .customSelect(
            "SELECT action FROM star_sync_queue WHERE item_type = 'song' "
            "AND item_id = 'server-song';",
          )
          .get();
      expect(starRows, hasLength(1));
      expect(starRows.single.read<String>('action'), 'star');
      expect(
        await database.songIdentityDao.resolveCanonicalId('remote-song'),
        'server-song',
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'keeps an explicit canonical like and does not queue a duplicate star',
    () async {
      final canonicalLikedAt = DateTime.utc(2026, 8, 15, 8);
      final oldLikedAt = DateTime.utc(2026, 8, 1, 12);
      await database.customStatement(
        'UPDATE songs SET starred = ? WHERE id = ?;',
        <Object?>[oldLikedAt.millisecondsSinceEpoch ~/ 1000, 'remote-song'],
      );
      await database.customStatement(
        'UPDATE songs SET starred = ? WHERE id = ?;',
        <Object?>[
          canonicalLikedAt.millisecondsSinceEpoch ~/ 1000,
          'server-song',
        ],
      );

      final result = await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );

      expect(result.restoredLike, isFalse);
      final merged = await database.libraryDao.getSongById('server-song');
      expect(merged!.starred!.isAtSameMomentAs(canonicalLikedAt), isTrue);
      final starRows = await database
          .customSelect(
            "SELECT action FROM star_sync_queue WHERE item_type = 'song' "
            "AND item_id = 'server-song';",
          )
          .get();
      expect(starRows, isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test(
    'merges an old rating into an unrated replacement',
    () async {
      await database.customStatement(
        'UPDATE songs SET user_rating = 4 WHERE id = ?;',
        <Object?>['remote-song'],
      );

      await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );

      final merged = await database.libraryDao.getSongById('server-song');
      expect(merged!.userRating, 4);
    },
    skip: !sqliteAvailable,
  );

  test(
    'transfers absence evidence and mutation journal to the replacement identity',
    () async {
      final now = DateTime.now();
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      await database
          .into(database.starredAbsenceCandidatesTable)
          .insert(
            StarredAbsenceCandidatesTableCompanion.insert(
              serverId: 1,
              entityType: 'song',
              entityId: 'remote-song',
              firstObservedAt: now,
              lastObservedAt: now,
            ),
          );
      await database
          .into(database.librarySyncLocalMutationsTable)
          .insert(
            LibrarySyncLocalMutationsTableCompanion.insert(
              entityType: 'song',
              entityId: 'remote-song',
              operation: 'rating',
              createdAt: now,
            ),
          );

      await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );

      final absenceRows = await database
          .customSelect(
            'SELECT entity_id FROM starred_absence_candidates '
            "WHERE entity_type = 'song';",
          )
          .get();
      expect(absenceRows.single.read<String>('entity_id'), 'server-song');
      final mutationRows = await database
          .customSelect(
            'SELECT entity_id FROM library_sync_local_mutations '
            "WHERE entity_type = 'song';",
          )
          .get();
      expect(mutationRows.single.read<String>('entity_id'), 'server-song');
      final typedAliases = await database
          .customSelect(
            "SELECT old_id, new_id FROM entity_identity_aliases "
            "WHERE entity_type = 'song';",
          )
          .get();
      expect(typedAliases, hasLength(1));
      expect(typedAliases.single.read<String>('old_id'), 'remote-song');
      expect(typedAliases.single.read<String>('new_id'), 'server-song');
    },
    skip: !sqliteAvailable,
  );
}

Future<int> _count(
  NavisDatabase database,
  String table,
  String songId,
) async {
  final row = await database
      .customSelect(
        'SELECT COUNT(*) AS count FROM $table WHERE song_id = ?;',
        variables: <Variable<Object>>[Variable<String>(songId)],
      )
      .getSingle();
  return row.read<int>('count');
}
