import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/entity_identity_aliases_table.dart';
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
  const new({
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
  const new({
    required this.alias,
    this.deletedFilePaths = const <String>[],
    this.restoredLike = false,
  });

  final SongIdentityAlias alias;
  final List<String> deletedFilePaths;

  /// True when the replacement row lacked the old row's like and the like was
  /// carried forward with its original local timestamp plus a server star
  /// action, so other clients receive the recovered favorite.
  final bool restoredLike;
}

class ProvisionalGarbageCollectionResult {
  const new({required this.songs, required this.albums, required this.artists});

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
    EntityIdentityAliasTable,
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
    with NavisDaoTransactions, _$SongIdentityDaoMixin {
  new(super.attachedDatabase);

  /// Provisional candidates for identity reconciliation.
  ///
  /// Includes rows retained after disappearing from the server
  /// (`serverDeletedAt` set, typically because a permanent download or local
  /// references survived) so a later server scan that re-issues their content
  /// under a new ID can still relink them.
  Future<List<SongsTableData>> getProvisionalSongs() {
    final query = select(songsTable)
      ..where(
        (table) =>
            (table.isProvisional.equals(true) &
                table.serverDeletedAt.isNull()) |
            table.serverDeletedAt.isNotNull(),
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

  /// Provisional album rows awaiting identity reconciliation.
  ///
  /// Includes rows retained after disappearing from the server snapshot so a
  /// later promotion that re-issues the album under a new ID can relink it.
  Future<List<AlbumsTableData>> getProvisionalAlbums() {
    return (select(
      albumsTable,
    )..where((table) => table.isProvisional.equals(true))).get();
  }

  /// Provisional artist rows awaiting identity reconciliation.
  Future<List<ArtistsTableData>> getProvisionalArtists() {
    return (select(
      artistsTable,
    )..where((table) => table.isProvisional.equals(true))).get();
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
    await (update(songsTable)..where((table) => table.id.equals(songId))).write(
      const SongsTableCompanion(isProvisional: Value(false)),
    );
  }

  /// Moves [oldSongId]'s references, user state and cache onto
  /// [canonicalSongId] and records the alias.
  ///
  /// The losing cache file is deleted once the remap commits. When the remap
  /// runs inside a caller's transaction (catalog promotion), pass
  /// [deferredFileDeletions]: the paths are added to it instead, for the
  /// caller to delete after its own commit, so a rollback never leaves the
  /// restored rows pointing at deleted files.
  Future<SongIdentityRemapResult> remapSongIdentity({
    required String oldSongId,
    required String canonicalSongId,
    required String matchReason,
    DateTime? matchedAt,
    bool retainOldCacheFile = false,
    List<String>? deferredFileDeletions,
  }) async {
    final oldId = oldSongId.trim();
    final canonicalId = canonicalSongId.trim();
    if (oldId.isEmpty || canonicalId.isEmpty || oldId == canonicalId) {
      throw ArgumentError('Song identity remapping requires two distinct IDs.');
    }

    final timestamp = matchedAt ?? DateTime.now();
    final alias = SongIdentityAlias(
      oldSongId: oldId,
      canonicalSongId: canonicalId,
      matchReason: matchReason,
      matchedAt: timestamp,
    );

    var restoredLike = false;
    final oldCache = await _cacheRow(oldId);
    final canonicalCache = await _cacheRow(canonicalId);
    final cacheChoice = await _chooseCacheWinner(
      oldCache: oldCache,
      canonicalCache: canonicalCache,
    );

    await transaction(() async {
      // Read both rows inside the transaction so the merge below observes the
      // same state the reference remaps commit against.
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
      // A review-screen relink may target an entry whose live row is already
      // gone; the reference moves below are WHERE-guarded no-ops in that
      // case and only the alias recording remains meaningful.

      await _remapCache(
        oldSongId: oldId,
        canonicalSongId: canonicalId,
        oldCache: oldCache,
        canonicalCache: canonicalCache,
        winner: cacheChoice.winner,
      );

      await customStatement(
        'DELETE FROM download_queue WHERE song_id = ? AND EXISTS ( '
        'SELECT 1 FROM download_queue WHERE song_id = ?);',
        <Object?>[oldId, canonicalId],
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
        'UPDATE playlist_songs SET song_id = ? WHERE song_id = ?;',
        <Object?>[canonicalId, oldId],
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
      // Absence evidence attached to the old identity transfers to the
      // replacement; leftover rows for the canonical ID would only double-count
      // observations, so they are replaced by the remapped evidence.
      await customStatement(
        'UPDATE OR IGNORE starred_absence_candidates SET entity_id = ? '
        "WHERE entity_type = 'song' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM starred_absence_candidates '
        "WHERE entity_type = 'song' AND entity_id = ?;",
        <Object?>[oldId],
      );
      await customStatement(
        'UPDATE library_sync_local_mutations SET entity_id = ? '
        "WHERE entity_type = 'song' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      // Merge user state with local precedence: an explicit canonical value
      // from the server snapshot wins; otherwise the old row's favorite or
      // rating carries forward. A carried like keeps its original local
      // timestamp and is queued so the server restores it for other clients.
      final carriedStarredAt = canonicalSong.starred == null
          ? oldSong?.starred
          : null;
      final carriedRating = canonicalSong.userRating == null
          ? oldSong?.userRating
          : null;
      if (carriedStarredAt != null || carriedRating != null) {
        await (update(
          songsTable,
        )..where((table) => table.id.equals(canonicalId))).write(
          SongsTableCompanion(
            starred: carriedStarredAt != null
                ? Value(carriedStarredAt)
                : const Value.absent(),
            userRating: carriedRating != null
                ? Value(carriedRating)
                : const Value.absent(),
          ),
        );
      }
      if (carriedStarredAt != null) {
        await attachedDatabase.starSyncDao.queueStarAction(
          itemId: canonicalId,
          itemType: 'song',
          action: 'star',
        );
        restoredLike = true;
      }
      await into(songIdentityAliasesTable).insertOnConflictUpdate(
        SongIdentityAliasesTableCompanion.insert(
          oldSongId: oldId,
          canonicalSongId: canonicalId,
          matchReason: matchReason,
          matchedAt: timestamp,
        ),
      );
      await into(entityIdentityAliasTable).insertOnConflictUpdate(
        EntityIdentityAliasTableCompanion.insert(
          entityType: 'song',
          oldId: oldId,
          newId: canonicalId,
          matchReason: matchReason,
          matchedAt: timestamp,
        ),
      );
      await delete(listenBrainzWeeklyCacheTable).go();
      await (update(songsTable)..where((table) => table.id.equals(canonicalId)))
          .write(const SongsTableCompanion(isProvisional: Value(false)));
      await (delete(songsTable)..where((table) => table.id.equals(oldId))).go();
    }).then<void>((_) {
      // Raw SQL does not invalidate Drift queries. If a caller owns an outer
      // transaction, its database override replays these updates after commit.
      notifyUpdates(<TableUpdate>{
        TableUpdate.onTable(attachedDatabase.downloadQueueTable),
        TableUpdate.onTable(attachedDatabase.playQueueItemsTable),
        TableUpdate.onTable(attachedDatabase.playHistoryTable),
        TableUpdate.onTable(attachedDatabase.playlistSongsTable),
        TableUpdate.onTable(attachedDatabase.matchFlowSongsTable),
        TableUpdate.onTable(attachedDatabase.externalLyricsCacheTable),
        TableUpdate.onTable(attachedDatabase.scrobbleQueueTable),
        TableUpdate.onTable(attachedDatabase.listenBrainzFeedbackQueueTable),
        TableUpdate.onTable(attachedDatabase.starSyncQueueTable),
        TableUpdate.onTable(attachedDatabase.starredAbsenceCandidatesTable),
        TableUpdate.onTable(attachedDatabase.librarySyncLocalMutationsTable),
      });
    });

    final deletedPaths = <String>[];
    final retainedPath = retainOldCacheFile ? oldCache?.filePath : null;
    final losingPaths = <String>[
      for (final path in cacheChoice.losingFilePaths)
        if (path != retainedPath) path,
    ];
    if (deferredFileDeletions != null) {
      deferredFileDeletions.addAll(losingPaths);
      return SongIdentityRemapResult(
        alias: alias,
        deletedFilePaths: const <String>[],
        restoredLike: restoredLike,
      );
    }
    for (final path in losingPaths) {
      final file = File(path);
      try {
        // Keep metadata access asynchronous so storage latency cannot stall UI.
        // ignore: avoid_slow_async_io
        if (await file.exists()) {
          await file.delete();
          deletedPaths.add(path);
        }
        final sidecar = File('$path.mime');
        // Keep metadata access asynchronous so storage latency cannot stall UI.
        // ignore: avoid_slow_async_io
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
      restoredLike: restoredLike,
    );
  }

  /// Moves an old album identity onto its canonical replacement.
  ///
  /// Songs still referencing the old album follow it so album detail stays
  /// coherent, album-level user state merges with local precedence, pending
  /// star actions and absence evidence transfer, and the alias is recorded in
  /// the typed identity table. Safe to call inside the promotion transaction;
  /// a missing old row (already resolved) is a no-op.
  Future<bool> remapAlbumIdentity({
    required String oldAlbumId,
    required String canonicalAlbumId,
    required String matchReason,
    DateTime? matchedAt,
  }) async {
    final oldId = oldAlbumId.trim();
    final canonicalId = canonicalAlbumId.trim();
    if (oldId.isEmpty || canonicalId.isEmpty || oldId == canonicalId) {
      throw ArgumentError(
        'Album identity remapping requires two distinct IDs.',
      );
    }
    final timestamp = matchedAt ?? DateTime.now();
    var restoredLike = false;

    await transaction(() async {
      final canonicalAlbum =
          await (select(albumsTable)
                ..where((table) => table.id.equals(canonicalId))
                ..limit(1))
              .getSingleOrNull();
      if (canonicalAlbum == null) {
        throw StateError('Canonical album $canonicalId does not exist.');
      }
      final oldAlbum =
          await (select(albumsTable)
                ..where((table) => table.id.equals(oldId))
                ..limit(1))
              .getSingleOrNull();
      if (oldAlbum == null) {
        return;
      }

      await customStatement(
        'UPDATE songs SET album_id = ? WHERE album_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'UPDATE star_sync_queue SET item_id = ? '
        "WHERE item_type = 'album' AND item_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      // Absence evidence and pending local mutations transfer to the
      // replacement identity, mirroring song remaps.
      await customStatement(
        'UPDATE OR IGNORE starred_absence_candidates SET entity_id = ? '
        "WHERE entity_type = 'album' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM starred_absence_candidates '
        "WHERE entity_type = 'album' AND entity_id = ?;",
        <Object?>[oldId],
      );
      await customStatement(
        'UPDATE library_sync_local_mutations SET entity_id = ? '
        "WHERE entity_type = 'album' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );

      final carriedStarredAt = canonicalAlbum.starred == null
          ? oldAlbum.starred
          : null;
      final carriedRating = canonicalAlbum.userRating == null
          ? oldAlbum.userRating
          : null;
      if (carriedStarredAt != null || carriedRating != null) {
        await (update(
          albumsTable,
        )..where((table) => table.id.equals(canonicalId))).write(
          AlbumsTableCompanion(
            starred: carriedStarredAt != null
                ? Value(carriedStarredAt)
                : const Value.absent(),
            userRating: carriedRating != null
                ? Value(carriedRating)
                : const Value.absent(),
          ),
        );
      }
      if (carriedStarredAt != null) {
        await attachedDatabase.starSyncDao.queueStarAction(
          itemId: canonicalId,
          itemType: 'album',
          action: 'star',
        );
        restoredLike = true;
      }
      await into(entityIdentityAliasTable).insertOnConflictUpdate(
        EntityIdentityAliasTableCompanion.insert(
          entityType: 'album',
          oldId: oldId,
          newId: canonicalId,
          matchReason: matchReason,
          matchedAt: timestamp,
        ),
      );
      await (delete(
        albumsTable,
      )..where((table) => table.id.equals(oldId))).go();
    }).then<void>((_) {
      // Raw SQL does not invalidate Drift queries. If a caller owns an outer
      // transaction, its database override replays these updates after commit.
      notifyUpdates(<TableUpdate>{
        TableUpdate.onTable(attachedDatabase.songsTable),
        TableUpdate.onTable(attachedDatabase.starSyncQueueTable),
        TableUpdate.onTable(attachedDatabase.starredAbsenceCandidatesTable),
        TableUpdate.onTable(attachedDatabase.librarySyncLocalMutationsTable),
      });
    });

    return restoredLike;
  }

  /// Moves an old artist identity onto its canonical replacement.
  ///
  /// Songs and albums still referencing the old artist follow it, artist-level
  /// user state merges with local precedence, pending star actions and
  /// absence evidence transfer, and the alias is recorded in the typed
  /// identity table. Safe to call inside the promotion transaction.
  Future<bool> remapArtistIdentity({
    required String oldArtistId,
    required String canonicalArtistId,
    required String matchReason,
    DateTime? matchedAt,
  }) async {
    final oldId = oldArtistId.trim();
    final canonicalId = canonicalArtistId.trim();
    if (oldId.isEmpty || canonicalId.isEmpty || oldId == canonicalId) {
      throw ArgumentError(
        'Artist identity remapping requires two distinct IDs.',
      );
    }
    final timestamp = matchedAt ?? DateTime.now();
    var restoredLike = false;

    await transaction(() async {
      final canonicalArtist =
          await (select(artistsTable)
                ..where((table) => table.id.equals(canonicalId))
                ..limit(1))
              .getSingleOrNull();
      if (canonicalArtist == null) {
        throw StateError('Canonical artist $canonicalId does not exist.');
      }
      final oldArtist =
          await (select(artistsTable)
                ..where((table) => table.id.equals(oldId))
                ..limit(1))
              .getSingleOrNull();
      if (oldArtist == null) {
        return;
      }

      await customStatement(
        'UPDATE songs SET artist_id = ? WHERE artist_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'UPDATE albums SET artist_id = ? WHERE artist_id = ?;',
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'UPDATE star_sync_queue SET item_id = ? '
        "WHERE item_type = 'artist' AND item_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'UPDATE OR IGNORE starred_absence_candidates SET entity_id = ? '
        "WHERE entity_type = 'artist' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );
      await customStatement(
        'DELETE FROM starred_absence_candidates '
        "WHERE entity_type = 'artist' AND entity_id = ?;",
        <Object?>[oldId],
      );
      await customStatement(
        'UPDATE library_sync_local_mutations SET entity_id = ? '
        "WHERE entity_type = 'artist' AND entity_id = ?;",
        <Object?>[canonicalId, oldId],
      );

      final carriedStarredAt = canonicalArtist.starred == null
          ? oldArtist.starred
          : null;
      if (carriedStarredAt != null) {
        await (update(artistsTable)
              ..where((table) => table.id.equals(canonicalId)))
            .write(ArtistsTableCompanion(starred: Value(carriedStarredAt)));
      }
      if (carriedStarredAt != null) {
        await attachedDatabase.starSyncDao.queueStarAction(
          itemId: canonicalId,
          itemType: 'artist',
          action: 'star',
        );
        restoredLike = true;
      }
      await into(entityIdentityAliasTable).insertOnConflictUpdate(
        EntityIdentityAliasTableCompanion.insert(
          entityType: 'artist',
          oldId: oldId,
          newId: canonicalId,
          matchReason: matchReason,
          matchedAt: timestamp,
        ),
      );
      await (delete(
        artistsTable,
      )..where((table) => table.id.equals(oldId))).go();
    }).then<void>((_) {
      // Raw SQL does not invalidate Drift queries. If a caller owns an outer
      // transaction, its database override replays these updates after commit.
      notifyUpdates(<TableUpdate>{
        TableUpdate.onTable(attachedDatabase.songsTable),
        TableUpdate.onTable(attachedDatabase.albumsTable),
        TableUpdate.onTable(attachedDatabase.starSyncQueueTable),
        TableUpdate.onTable(attachedDatabase.starredAbsenceCandidatesTable),
        TableUpdate.onTable(attachedDatabase.librarySyncLocalMutationsTable),
      });
    });

    return restoredLike;
  }

  Future<ProvisionalGarbageCollectionResult>
  garbageCollectUnreferencedProvisionalMetadata() async {
    return await transaction(() async {
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
    // SAF document URIs must be validated through the platform bridge;
    // File.exists() cannot see them.
    return await storedAudioExists(
      locator: row.filePath,
      storageKind: row.storageKind,
    );
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
          (table) => table.songId.isIn(<String>[oldSongId, canonicalSongId]),
        ))
        .go();
    if (winner == null) {
      return;
    }
    await into(cachedTracksTable).insert(
      winner.toCompanion(false).copyWith(songId: Value(canonicalSongId)),
    );
  }
}

class _CacheChoice {
  const new({required this.winner, required this.losingFilePaths});

  final CachedTracksTableData? winner;
  final List<String> losingFilePaths;
}
