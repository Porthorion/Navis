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

  Future<List<SongIdentityAlias>> getAliases() => _songAliases().get();

  Selectable<SongIdentityAlias> _songAliases({
    DateTime? matchedSince,
    String? oldId,
  }) =>
      customSelect(
        "SELECT a.* FROM entity_identity_aliases a WHERE a.entity_type = 'song' "
        'AND a.id = (SELECT MAX(latest.id) FROM entity_identity_aliases latest '
        'WHERE latest.entity_type = a.entity_type AND latest.old_id = a.old_id) '
        '${matchedSince == null ? '' : 'AND a.matched_at >= ? '}'
        '${oldId == null ? '' : 'AND a.old_id = ? '}',
        variables: [
          if (matchedSince != null) Variable<DateTime>(matchedSince),
          if (oldId != null) Variable<String>(oldId),
        ],
        readsFrom: {entityIdentityAliasTable},
      ).map(
        (row) => SongIdentityAlias(
          oldSongId: row.read<String>('old_id'),
          canonicalSongId: row.read<String>('new_id'),
          matchReason: row.read<String>('match_reason'),
          matchedAt: row.read<DateTime>('matched_at'),
        ),
      );

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
  ) => _songAliases(matchedSince: matchedSince).get();

  Future<String> resolveCanonicalId(String songId) async {
    var current = songId;
    final visited = <String>{};
    while (visited.add(current)) {
      final row = await _songAliases(oldId: current).getSingleOrNull();
      if (row == null || row.canonicalSongId == current) return current;
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
    _validateIds(_IdentityKind.song, oldId, canonicalId);

    final timestamp = matchedAt ?? DateTime.now();
    final alias = SongIdentityAlias(
      oldSongId: oldId,
      canonicalSongId: canonicalId,
      matchReason: matchReason,
      matchedAt: timestamp,
    );

    final oldCache = await _cacheRow(oldId);
    final canonicalCache = await _cacheRow(canonicalId);
    final cacheChoice = await _chooseCacheWinner(
      oldCache: oldCache,
      canonicalCache: canonicalCache,
    );

    final restoredLike = await _remapIdentity(
      _IdentityKind.song,
      oldId,
      canonicalId,
      matchReason,
      timestamp,
      beforeReferences: () async {
        await _remapCache(
          oldSongId: oldId,
          canonicalSongId: canonicalId,
          oldCache: oldCache,
          canonicalCache: canonicalCache,
          winner: cacheChoice.winner,
        );
        // A canonical queued download keeps its job and progress intact.
        await customUpdate(
          'DELETE FROM download_queue WHERE song_id = ? AND EXISTS ( '
          'SELECT 1 FROM download_queue WHERE song_id = ?)',
          variables: [Variable<String>(oldId), Variable<String>(canonicalId)],
          updates: {downloadQueueTable},
        );
      },
      afterAlias: () async {
        await delete(listenBrainzWeeklyCacheTable).go();
        await markCanonical(canonicalId);
      },
    );

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
    return await _remapIdentity(
      _IdentityKind.album,
      oldAlbumId,
      canonicalAlbumId,
      matchReason,
      matchedAt ?? DateTime.now(),
    );
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
    return await _remapIdentity(
      _IdentityKind.artist,
      oldArtistId,
      canonicalArtistId,
      matchReason,
      matchedAt ?? DateTime.now(),
    );
  }

  void _validateIds(_IdentityKind kind, String oldId, String canonicalId) {
    if (oldId.isEmpty || canonicalId.isEmpty || oldId == canonicalId) {
      throw ArgumentError(
        '${kind.label} identity remapping requires two distinct IDs.',
      );
    }
  }

  TableInfo<Table, Object?> _identityTable(_IdentityKind kind) =>
      switch (kind) {
        _IdentityKind.song => songsTable,
        _IdentityKind.album => albumsTable,
        _IdentityKind.artist => artistsTable,
      };

  List<(TableInfo<Table, Object?>, String)> _plainReferences(
    _IdentityKind kind,
  ) => switch (kind) {
    _IdentityKind.song => [
      (downloadQueueTable, 'song_id'),
      (playQueueItemsTable, 'song_id'),
      (playlistSongsTable, 'song_id'),
    ],
    _IdentityKind.album => [(songsTable, 'album_id')],
    _IdentityKind.artist => [
      (songsTable, 'artist_id'),
      (albumsTable, 'artist_id'),
    ],
  };

  Future<bool> _remapIdentity(
    _IdentityKind kind,
    String oldIdentity,
    String canonicalIdentity,
    String matchReason,
    DateTime matchedAt, {
    Future<void> Function()? beforeReferences,
    Future<void> Function()? afterAlias,
  }) async {
    final oldId = oldIdentity.trim();
    final canonicalId = canonicalIdentity.trim();
    _validateIds(kind, oldId, canonicalId);
    final table = _identityTable(kind);
    return await transaction(() async {
      Future<QueryRow?> read(String id) => customSelect(
        'SELECT * FROM ${table.actualTableName} WHERE id = ?',
        variables: [Variable<String>(id)],
        readsFrom: {table},
      ).getSingleOrNull();
      final canonical = await read(canonicalId);
      if (canonical == null) {
        throw StateError('Canonical ${kind.name} $canonicalId does not exist.');
      }
      final old = await read(oldId);
      if (old == null && kind.requireOld) return false;

      await beforeReferences?.call();
      for (final (reference, column) in _plainReferences(kind)) {
        await customUpdate(
          'UPDATE ${reference.actualTableName} SET $column = ? WHERE $column = ?',
          variables: [Variable<String>(canonicalId), Variable<String>(oldId)],
          updates: {reference},
          updateKind: UpdateKind.update,
        );
      }
      if (kind == _IdentityKind.song) {
        // History, matches and lyrics have no surrogate IDs to regenerate;
        // their keys ignore the same collisions as the former insert/select.
        // Outbox rows retain the existing update/ignore semantics.
        for (final reference in <TableInfo<Table, Object?>>[
          playHistoryTable,
          matchFlowSongsTable,
          externalLyricsCacheTable,
          scrobbleQueueTable,
          listenBrainzFeedbackQueueTable,
        ]) {
          await customUpdate(
            'UPDATE OR IGNORE ${reference.actualTableName} SET song_id = ? WHERE song_id = ?',
            variables: [Variable<String>(canonicalId), Variable<String>(oldId)],
            updates: {reference},
            updateKind: UpdateKind.update,
          );
          await customUpdate(
            'DELETE FROM ${reference.actualTableName} WHERE song_id = ?',
            variables: [Variable<String>(oldId)],
            updates: {reference},
          );
        }
      }
      await customUpdate(
        'UPDATE star_sync_queue SET item_id = ? WHERE item_type = ? AND item_id = ?',
        variables: [
          Variable<String>(canonicalId),
          Variable<String>(kind.name),
          Variable<String>(oldId),
        ],
        updates: {starSyncQueueTable},
        updateKind: UpdateKind.update,
      );
      await customUpdate(
        'UPDATE OR IGNORE starred_absence_candidates SET entity_id = ? '
        'WHERE entity_type = ? AND entity_id = ?',
        variables: [
          Variable<String>(canonicalId),
          Variable<String>(kind.name),
          Variable<String>(oldId),
        ],
        updates: {attachedDatabase.starredAbsenceCandidatesTable},
        updateKind: UpdateKind.update,
      );
      await customUpdate(
        'DELETE FROM starred_absence_candidates WHERE entity_type = ? AND entity_id = ?',
        variables: [Variable<String>(kind.name), Variable<String>(oldId)],
        updates: {attachedDatabase.starredAbsenceCandidatesTable},
      );
      await customUpdate(
        'UPDATE library_sync_local_mutations SET entity_id = ? WHERE entity_type = ? AND entity_id = ?',
        variables: [
          Variable<String>(canonicalId),
          Variable<String>(kind.name),
          Variable<String>(oldId),
        ],
        updates: {attachedDatabase.librarySyncLocalMutationsTable},
        updateKind: UpdateKind.update,
      );

      // An explicit canonical annotation wins; otherwise carry the old local value.
      final starred = canonical.readNullable<DateTime>('starred') == null
          ? old?.readNullable<DateTime>('starred')
          : null;
      final rating =
          kind.hasRating && canonical.readNullable<int>('user_rating') == null
          ? old?.readNullable<int>('user_rating')
          : null;
      if (starred != null || rating != null) {
        await customUpdate(
          'UPDATE ${table.actualTableName} SET '
          '${[if (starred != null) 'starred = ?', if (rating != null) 'user_rating = ?'].join(', ')} WHERE id = ?',
          variables: [
            if (starred != null) Variable<DateTime>(starred),
            if (rating != null) Variable<int>(rating),
            Variable<String>(canonicalId),
          ],
          updates: {table},
          updateKind: UpdateKind.update,
        );
      }
      if (starred != null) {
        await attachedDatabase.starSyncDao.queueStarAction(
          itemId: canonicalId,
          itemType: kind.name,
          action: 'star',
        );
      }
      await into(entityIdentityAliasTable).insert(
        EntityIdentityAliasTableCompanion.insert(
          entityType: kind.name,
          oldId: oldId,
          newId: canonicalId,
          matchReason: matchReason,
          matchedAt: matchedAt,
          serverId: const Value(null),
        ),
        onConflict: DoUpdate(
          (_) => EntityIdentityAliasTableCompanion(
            serverId: const Value(null),
            newId: Value(canonicalId),
            matchReason: Value(matchReason),
            matchedAt: Value(matchedAt),
          ),
          target: [
            entityIdentityAliasTable.entityType,
            entityIdentityAliasTable.oldId,
          ],
        ),
      );
      await afterAlias?.call();
      await customUpdate(
        'DELETE FROM ${table.actualTableName} WHERE id = ?',
        variables: [Variable<String>(oldId)],
        updates: {table},
      );
      return starred != null;
    });
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
      // A permanent download keeps its lyrics while the library is being
      // rebuilt: clearLibraryData removes the songs row until the catalog
      // re-inserts it, and cached_tracks still references the download.
      await customUpdate(
        '''
        DELETE FROM external_lyrics_cache
        WHERE NOT EXISTS (
          SELECT 1
          FROM songs s
          WHERE s.id = external_lyrics_cache.song_id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM cached_tracks c
          WHERE c.song_id = external_lyrics_cache.song_id
            AND c.cache_type = 'permanent'
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

enum _IdentityKind {
  song('Song', hasRating: true, requireOld: false),
  album('Album', hasRating: true, requireOld: true),
  artist('Artist', hasRating: false, requireOld: true);

  new(this.label, {required this.hasRating, required this.requireOld});
  final String label;
  final bool hasRating;
  final bool requireOld;
}
