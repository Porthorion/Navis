import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/external_lyrics_cache_table.dart';
import 'package:navis/src/database/tables/listenbrainz_feedback_queue_table.dart';
import 'package:navis/src/database/tables/listenbrainz_weekly_cache_table.dart';
import 'package:navis/src/database/tables/match_flow_songs_table.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/play_queue_items_table.dart';
import 'package:navis/src/database/tables/playlist_songs_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/scrobble_queue_table.dart';
import 'package:navis/src/database/tables/song_identity_aliases_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';

part 'song_identity_dao.g.dart';

class SongIdentityAlias {
  const SongIdentityAlias({
    required this.oldSongId,
    required this.canonicalSongId,
    required this.matchReason,
    required this.matchedAt,
  });

  final String oldSongId;
  final String canonicalSongId;
  final String matchReason;
  final DateTime matchedAt;
}

class SongIdentityRemapResult {
  const SongIdentityRemapResult({
    required this.alias,
    this.deletedFilePaths = const <String>[],
  });

  final SongIdentityAlias alias;
  final List<String> deletedFilePaths;
}

class ProvisionalGarbageCollectionResult {
  const ProvisionalGarbageCollectionResult({
    required this.songs,
    required this.albums,
    required this.artists,
  });

  final int songs;
  final int albums;
  final int artists;
}

@DriftAccessor(
  tables: [
    ArtistsTable,
    AlbumsTable,
    SongsTable,
    SongIdentityAliasesTable,
    CachedTracksTable,
    DownloadQueueTable,
    PlayHistoryTable,
    PlayQueueItemsTable,
    PlaylistSongsTable,
    MatchFlowSongsTable,
    ExternalLyricsCacheTable,
    ScrobbleQueueTable,
    ListenBrainzFeedbackQueueTable,
    StarSyncQueueTable,
    ListenBrainzWeeklyCacheTable,
  ],
)
class SongIdentityDao extends DatabaseAccessor<NavisDatabase>
    with _$SongIdentityDaoMixin {
  SongIdentityDao(super.attachedDatabase);

  Future<List<SongsTableData>> getProvisionalSongs() {
    final query = select(songsTable)
      ..where(
        (table) =>
            table.isProvisional.equals(true) & table.serverDeletedAt.isNull(),
      );
    return query.get();
  }

  Future<List<SongIdentityAlias>> getAliases() async {
    final rows = await select(songIdentityAliasesTable).get();
    return rows
        .map(
          (row) => SongIdentityAlias(
            oldSongId: row.oldSongId,
            canonicalSongId: row.canonicalSongId,
            matchReason: row.matchReason,
            matchedAt: row.matchedAt,
          ),
        )
        .toList(growable: false);
  }

  Future<List<SongIdentityAlias>> getAliasesMatchedSince(
    DateTime matchedSince,
  ) async {
    final rows =
        await (select(songIdentityAliasesTable)..where(
              (table) => table.matchedAt.isBiggerOrEqualValue(matchedSince),
            ))
            .get();
    return rows
        .map(
          (row) => SongIdentityAlias(
            oldSongId: row.oldSongId,
            canonicalSongId: row.canonicalSongId,
            matchReason: row.matchReason,
            matchedAt: row.matchedAt,
          ),
        )
        .toList(growable: false);
  }

  Future<String> resolveCanonicalId(String songId) async {
    var current = songId;
    final visited = <String>{};
    while (visited.add(current)) {
      final row =
          await (select(songIdentityAliasesTable)
                ..where((table) => table.oldSongId.equals(current))
                ..limit(1))
              .getSingleOrNull();
      if (row == null || row.canonicalSongId == current) {
        return current;
      }
      current = row.canonicalSongId;
    }
    return current;
  }

  Future<void> markCanonical(String songId) async {
    await (update(
      songsTable,
    )..where((table) => table.id.equals(songId))).write(
      const SongsTableCompanion(isProvisional: Value(false)),
    );
  }

  Future<SongIdentityRemapResult> remapSongIdentity({
    required String oldSongId,
    required String canonicalSongId,
    required String matchReason,
    DateTime? matchedAt,
  }) async {
    final oldId = oldSongId.trim();
    final canonicalId = canonicalSongId.trim();
    if (oldId.isEmpty || canonicalId.isEmpty || oldId == canonicalId) {
      throw ArgumentError('Song identity remapping requires two distinct IDs.');
    }

    final canonicalSong =
        await (select(songsTable)
              ..where((table) => table.id.equals(canonicalId))
              ..limit(1))
            .getSingleOrNull();
    if (canonicalSong == null) {
      throw StateError('Canonical song $canonicalId does not exist.');
    }
    final oldSong =
        await (select(songsTable)
              ..where((table) => table.id.equals(oldId))
              ..limit(1))
            .getSingleOrNull();
    if (oldSong == null) {
      throw StateError('Provisional song $oldId does not exist.');
    }

    final oldCache = await _cacheRow(oldId);
    final canonicalCache = await _cacheRow(canonicalId);
    final cacheChoice = await _chooseCacheWinner(
      oldCache: oldCache,
      canonicalCache: canonicalCache,
    );
    final timestamp = matchedAt ?? DateTime.now();
    final alias = SongIdentityAlias(
      oldSongId: oldId,
      canonicalSongId: canonicalId,
      matchReason: matchReason,
      matchedAt: timestamp,
    );

    await transaction(() async {
      await _remapCache(
        oldSongId: oldId,
        canonicalSongId: canonicalId,
        oldCache: oldCache,
        canonicalCache: canonicalCache,
        winner: cacheChoice.winner,
      );

      await customStatement(
        'UPDATE download_queue SET song_id = ? WHERE song_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'UPDATE play_queue_items SET song_id = ? WHERE song_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        '''
        INSERT OR IGNORE INTO play_history (song_id, played_at)
        SELECT ?, played_at FROM play_history WHERE song_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM play_history WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        '''
        INSERT OR IGNORE INTO playlist_songs (playlist_id, song_id, sort_order)
        SELECT playlist_id, ?, sort_order
        FROM playlist_songs
        WHERE song_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM playlist_songs WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        '''
        INSERT OR IGNORE INTO match_flow_songs (
          flow_id,
          song_id,
          sort_order,
          added_at
        )
        SELECT flow_id, ?, sort_order, added_at
        FROM match_flow_songs
        WHERE song_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM match_flow_songs WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        '''
        INSERT OR IGNORE INTO external_lyrics_cache (
          song_id,
          source,
          synced_lyrics,
          plain_lyrics,
          fetched_at,
          ttl_seconds,
          failure_count,
          last_failed_at
        )
        SELECT
          ?,
          source,
          synced_lyrics,
          plain_lyrics,
          fetched_at,
          ttl_seconds,
          failure_count,
          last_failed_at
        FROM external_lyrics_cache
        WHERE song_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM external_lyrics_cache WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        'UPDATE OR IGNORE scrobble_queue SET song_id = ? WHERE song_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM scrobble_queue WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        '''
        UPDATE OR IGNORE listenbrainz_feedback_queue
        SET song_id = ?
        WHERE song_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM listenbrainz_feedback_queue WHERE song_id = ?;',
        <Object?>[oldId],
      );
      await customStatement(
        '''
        UPDATE star_sync_queue
        SET item_id = ?
        WHERE item_type = 'song' AND item_id = ?;
        ''',
        <Object?>[canonicalId, oldId],
      );
      await into(songIdentityAliasesTable).insertOnConflictUpdate(
        SongIdentityAliasesTableCompanion.insert(
          oldSongId: oldId,
          canonicalSongId: canonicalId,
          matchReason: matchReason,
          matchedAt: timestamp,
        ),
      );
      await delete(listenBrainzWeeklyCacheTable).go();
      await (update(
        songsTable,
      )..where((table) => table.id.equals(canonicalId))).write(
        const SongsTableCompanion(isProvisional: Value(false)),
      );
      await (delete(
        songsTable,
      )..where((table) => table.id.equals(oldId))).go();
    });

    final deletedPaths = <String>[];
    for (final path in cacheChoice.losingFilePaths) {
      final file = File(path);
      try {
        if (await file.exists()) {
          await file.delete();
          deletedPaths.add(path);
        }
        final sidecar = File('$path.mime');
        if (await sidecar.exists()) {
          await sidecar.delete();
        }
      } on FileSystemException {
        // The database ownership is already canonical. Orphan cleanup retries
        // file removal later without risking rollback of the identity change.
      }
    }
    return SongIdentityRemapResult(
      alias: alias,
      deletedFilePaths: deletedPaths,
    );
  }

  Future<ProvisionalGarbageCollectionResult>
  garbageCollectUnreferencedProvisionalMetadata() async {
    return transaction(() async {
      final songs = await customUpdate(
        '''
        DELETE FROM songs
        WHERE is_provisional = 1
          AND NOT EXISTS (
            SELECT 1 FROM cached_tracks c WHERE c.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM download_queue d WHERE d.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM play_queue_items q WHERE q.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM playlist_songs p WHERE p.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM play_history h WHERE h.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM match_flow_songs m WHERE m.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM scrobble_queue s WHERE s.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM listenbrainz_feedback_queue f
            WHERE f.song_id = songs.id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM star_sync_queue st
            WHERE st.item_type = 'song' AND st.item_id = songs.id
          );
        ''',
        updates: <TableInfo<Table, Object?>>{songsTable},
      );
      await customUpdate(
        '''
        DELETE FROM external_lyrics_cache
        WHERE NOT EXISTS (
          SELECT 1
          FROM songs s
          WHERE s.id = external_lyrics_cache.song_id
        );
        ''',
        updates: <TableInfo<Table, Object?>>{externalLyricsCacheTable},
      );
      final albums = await customUpdate(
        '''
        DELETE FROM albums
        WHERE is_provisional = 1
          AND NOT EXISTS (
            SELECT 1 FROM songs s WHERE s.album_id = albums.id
          );
        ''',
        updates: <TableInfo<Table, Object?>>{albumsTable},
      );
      final artists = await customUpdate(
        '''
        DELETE FROM artists
        WHERE is_provisional = 1
          AND NOT EXISTS (
            SELECT 1 FROM albums a WHERE a.artist_id = artists.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM songs s WHERE s.artist_id = artists.id
          );
        ''',
        updates: <TableInfo<Table, Object?>>{artistsTable},
      );
      return ProvisionalGarbageCollectionResult(
        songs: songs,
        albums: albums,
        artists: artists,
      );
    });
  }

  Future<CachedTracksTableData?> _cacheRow(String songId) {
    return (select(cachedTracksTable)
          ..where((table) => table.songId.equals(songId))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<_CacheChoice> _chooseCacheWinner({
    required CachedTracksTableData? oldCache,
    required CachedTracksTableData? canonicalCache,
  }) async {
    final oldValid = await _isValidCache(oldCache);
    final canonicalValid = await _isValidCache(canonicalCache);
    CachedTracksTableData? winner;
    if (oldValid &&
        oldCache!.cacheType == CacheType.permanent &&
        (!canonicalValid || canonicalCache!.cacheType != CacheType.permanent)) {
      winner = oldCache;
    } else if (canonicalValid &&
        canonicalCache!.cacheType == CacheType.permanent) {
      winner = canonicalCache;
    } else if (canonicalValid) {
      winner = canonicalCache;
    } else if (oldValid) {
      winner = oldCache;
    } else {
      winner = canonicalCache ?? oldCache;
    }

    final losingPaths = <String>{
      if (oldCache != null && oldCache != winner) oldCache.filePath,
      if (canonicalCache != null && canonicalCache != winner)
        canonicalCache.filePath,
    }..remove(winner?.filePath);
    return _CacheChoice(
      winner: winner,
      losingFilePaths: losingPaths.toList(growable: false),
    );
  }

  Future<bool> _isValidCache(CachedTracksTableData? row) async {
    if (row == null ||
        row.downloadStatus != DownloadStatus.complete ||
        row.fileSize <= 0) {
      return false;
    }
    try {
      final file = File(row.filePath);
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _remapCache({
    required String oldSongId,
    required String canonicalSongId,
    required CachedTracksTableData? oldCache,
    required CachedTracksTableData? canonicalCache,
    required CachedTracksTableData? winner,
  }) async {
    if (oldCache == null && canonicalCache == null) {
      return;
    }
    await (delete(cachedTracksTable)..where(
          (table) => table.songId.isIn(<String>[
            oldSongId,
            canonicalSongId,
          ]),
        ))
        .go();
    if (winner == null) {
      return;
    }
    await into(cachedTracksTable).insert(
      CachedTracksTableCompanion.insert(
        songId: canonicalSongId,
        filePath: winner.filePath,
        fileSize: winner.fileSize,
        format: winner.format,
        bitRate: Value(winner.bitRate),
        lastAccessedAt: winner.lastAccessedAt,
        cacheType: winner.cacheType,
        downloadStatus: winner.downloadStatus,
      ),
    );
  }
}

class _CacheChoice {
  const _CacheChoice({
    required this.winner,
    required this.losingFilePaths,
  });

  final CachedTracksTableData? winner;
  final List<String> losingFilePaths;
}
