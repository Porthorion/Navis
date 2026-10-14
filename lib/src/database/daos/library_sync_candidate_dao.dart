import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/database_utils.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_albums_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_artists_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_songs_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'library_sync_candidate_dao.g.dart';

abstract final class LibraryCandidateApplyState {
  static const unchanged = 0;
  static const changed = 1;
}

@DriftAccessor(
  tables: [
    LibrarySyncCandidateArtistsTable,
    LibrarySyncCandidateAlbumsTable,
    LibrarySyncCandidateSongsTable,
    ArtistsTable,
    AlbumsTable,
    SongsTable,
  ],
)
class LibrarySyncCandidateDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$LibrarySyncCandidateDaoMixin {
  new(super.attachedDatabase);

  static const _candidateWritePageSize = 384;
  static const _candidateCleanupPageSize = 512;

  Future<void> clearAll() async {
    await transaction(() async {
      await delete(librarySyncCandidateSongsTable).go();
      await delete(librarySyncCandidateAlbumsTable).go();
      await delete(librarySyncCandidateArtistsTable).go();
    });
  }

  Future<void> clearThroughGeneration({
    required int serverId,
    required int generation,
  }) => _clearGeneration(serverId, generation, '<=');

  Future<void> clearGeneration({
    required int serverId,
    required int generation,
  }) => _clearGeneration(serverId, generation, '=');

  Future<void> _clearGeneration(
    int serverId,
    int generation,
    String operator,
  ) async {
    for (final table in <TableInfo<Table, Object?>>[
      librarySyncCandidateSongsTable,
      librarySyncCandidateAlbumsTable,
      librarySyncCandidateArtistsTable,
    ]) {
      await _clearCandidateRowsPaged(
        tableName: table.actualTableName,
        serverId: serverId,
        generation: generation,
        generationOperator: operator,
      );
    }
  }

  Future<void> _clearCandidateRowsPaged({
    required String tableName,
    required int serverId,
    required int generation,
    required String generationOperator,
  }) async {
    while (true) {
      final deleted = await customUpdate(
        'DELETE FROM $tableName WHERE rowid IN ( '
        'SELECT rowid FROM $tableName '
        'WHERE server_id = ?1 AND generation $generationOperator ?2 '
        'LIMIT $_candidateCleanupPageSize)',
        variables: <Variable<Object>>[
          Variable<int>(serverId),
          Variable<int>(generation),
        ],
      );
      if (deleted == 0) break;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> replaceArtists({
    required int serverId,
    required int generation,
    required List<ArtistsTableCompanion> artists,
  }) async {
    final catalogArtists = artists
        .where(
          (artist) => !isExternalCatalogSource(
            id: artist.id.value,
            apiIsExternal: artist.isExternal.present
                ? artist.isExternal.value
                : null,
          ),
        )
        .toList(growable: false);
    await _clearCandidateRowsPaged(
      tableName: 'library_sync_candidate_artists',
      serverId: serverId,
      generation: generation,
      generationOperator: '=',
    );
    await _writeCandidatePages(
      librarySyncCandidateArtistsTable,
      catalogArtists,
      (artist) => LibrarySyncCandidateArtistsTableCompanion.insert(
        serverId: serverId,
        generation: generation,
        id: artist.id.value,
        name: artist.name.value,
        albumCount: artist.albumCount,
        coverArt: artist.coverArt,
        starred: artist.starred,
        artistMbid: artist.artistMbid,
      ),
    );
  }

  Future<void> upsertAlbums({
    required int serverId,
    required int generation,
    required List<AlbumsTableCompanion> albums,
  }) async {
    final catalogAlbums = albums
        .where(
          (album) => !isExternalCatalogSource(
            id: album.id.value,
            apiIsExternal: album.isExternal.present
                ? album.isExternal.value
                : null,
          ),
        )
        .toList(growable: false);
    if (catalogAlbums.isEmpty) {
      return;
    }
    await _writeCandidatePages(
      librarySyncCandidateAlbumsTable,
      catalogAlbums,
      (album) {
        var candidate = LibrarySyncCandidateAlbumsTableCompanion.insert(
          serverId: serverId,
          generation: generation,
          id: album.id.value,
          name: album.name.value,
          artistId: album.artistId,
          artistName: album.artistName,
          artists: album.artists,
          songCount: album.songCount,
          duration: album.duration,
          year: album.year,
          coverArt: album.coverArt,
          releaseMbid: album.releaseMbid,
          songsHydrated: album.songsHydrated,
          starred: album.starred,
          userRating: album.userRating,
          playCount: album.playCount,
          syncedAt: album.syncedAt,
          serverCreatedAt: album.serverCreatedAt,
          recentlyAddedRank: album.recentlyAddedRank,
        );
        // A later album-detail response commonly lacks `created`. Keep a
        // creation date already collected from the newest/catalog feed.
        if (!candidate.serverCreatedAt.present ||
            candidate.serverCreatedAt.value == null) {
          candidate = candidate.copyWith(serverCreatedAt: const Value.absent());
        }
        return candidate;
      },
      onConflict: (candidate) => DoUpdate(
        (_) => candidate.copyWith(
          songsHydrated: const Value.absent(),
          carriedForward: const Value.absent(),
          applyState: const Value(null),
        ),
        target: [
          librarySyncCandidateAlbumsTable.serverId,
          librarySyncCandidateAlbumsTable.generation,
          librarySyncCandidateAlbumsTable.id,
        ],
      ),
    );
  }

  Future<void>
  _writeCandidatePages<T extends Table, R, I, C extends Insertable<R>>(
    TableInfo<T, R> table,
    List<I> items,
    C Function(I) toCandidate, {
    UpsertClause<T, R> Function(C)? onConflict,
  }) async {
    for (final page in chunked(items, _candidateWritePageSize)) {
      await batch((batch) {
        for (final item in page) {
          final candidate = toCandidate(item);
          batch.insert(
            table,
            candidate,
            onConflict: onConflict?.call(candidate),
          );
        }
      });
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> replaceSongsForAlbums({
    required int serverId,
    required int generation,
    required Map<String, List<SongsTableCompanion>> songsByAlbum,
  }) async {
    final catalogSongsByAlbum = <String, List<SongsTableCompanion>>{
      for (final entry in songsByAlbum.entries)
        entry.key: entry.value
            .where(
              (song) => !isExternalCatalogSource(
                id: song.id.value,
                apiIsExternal: song.isExternal.present
                    ? song.isExternal.value
                    : null,
              ),
            )
            .toList(growable: false),
    };
    if (catalogSongsByAlbum.isEmpty) {
      return;
    }
    var chunk = <String, List<SongsTableCompanion>>{};
    var songCount = 0;
    for (final entry in catalogSongsByAlbum.entries) {
      final exceedsBound =
          chunk.isNotEmpty &&
          (chunk.length >= 24 ||
              songCount + entry.value.length > _candidateWritePageSize);
      if (exceedsBound) {
        await _replaceSongsForAlbumsChunk(serverId, generation, chunk);
        await Future<void>.delayed(Duration.zero);
        chunk = <String, List<SongsTableCompanion>>{};
        songCount = 0;
      }
      chunk[entry.key] = entry.value;
      songCount += entry.value.length;
    }
    if (chunk.isNotEmpty) {
      await _replaceSongsForAlbumsChunk(serverId, generation, chunk);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _replaceSongsForAlbumsChunk(
    int serverId,
    int generation,
    Map<String, List<SongsTableCompanion>> songsByAlbum,
  ) async {
    final albumIds = songsByAlbum.keys.toSet();
    await transaction(() async {
      await (delete(librarySyncCandidateSongsTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.generation.equals(generation) &
                table.albumId.isIn(albumIds),
          ))
          .go();
      await batch((batch) {
        for (final song in songsByAlbum.values.expand((rows) => rows)) {
          batch.insert(
            librarySyncCandidateSongsTable,
            _candidateSong(serverId, generation, song),
            onConflict: DoUpdate(
              (old) => _candidateSong(serverId, generation, song),
              target: [
                librarySyncCandidateSongsTable.serverId,
                librarySyncCandidateSongsTable.generation,
                librarySyncCandidateSongsTable.id,
              ],
            ),
          );
        }
      });
    });
  }

  Future<void> markAlbumsHydrated({
    required int serverId,
    required int generation,
    required Iterable<String> albumIds,
  }) async {
    final ids = albumIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    await (update(librarySyncCandidateAlbumsTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.generation.equals(generation) &
              table.id.isIn(ids),
        ))
        .write(
          const LibrarySyncCandidateAlbumsTableCompanion(
            songsHydrated: Value(true),
            carriedForward: Value(false),
            applyState: Value(null),
          ),
        );
  }

  Future<List<String>> getPendingAlbumIds({
    required int serverId,
    required int generation,
    int? limit,
    Iterable<String>? preferredIds,
  }) async {
    final preferred = preferredIds?.toSet() ?? const <String>{};
    if (preferred.isNotEmpty) {
      final query = selectOnly(librarySyncCandidateAlbumsTable)
        ..addColumns([librarySyncCandidateAlbumsTable.id])
        ..where(
          librarySyncCandidateAlbumsTable.serverId.equals(serverId) &
              librarySyncCandidateAlbumsTable.generation.equals(generation) &
              librarySyncCandidateAlbumsTable.songsHydrated.equals(false) &
              librarySyncCandidateAlbumsTable.id.isIn(preferred),
        );
      if (limit != null) {
        query.limit(limit);
      }
      final rows = await query.get();
      if (rows.isNotEmpty) {
        return rows
            .map((row) => row.read(librarySyncCandidateAlbumsTable.id)!)
            .toList(growable: false);
      }
    }
    final query = selectOnly(librarySyncCandidateAlbumsTable)
      ..addColumns([librarySyncCandidateAlbumsTable.id])
      ..where(
        librarySyncCandidateAlbumsTable.serverId.equals(serverId) &
            librarySyncCandidateAlbumsTable.generation.equals(generation) &
            librarySyncCandidateAlbumsTable.songsHydrated.equals(false),
      )
      ..orderBy([OrderingTerm.asc(librarySyncCandidateAlbumsTable.id)]);
    if (limit != null) {
      query.limit(limit);
    }
    final rows = await query.get();
    return rows
        .map((row) => row.read(librarySyncCandidateAlbumsTable.id)!)
        .toList(growable: false);
  }

  Future<int> countAlbums({required int serverId, required int generation}) =>
      _countAlbums(serverId, generation, pending: false);

  Future<int> countPendingAlbums({
    required int serverId,
    required int generation,
  }) => _countAlbums(serverId, generation, pending: true);

  Future<int> _countAlbums(
    int serverId,
    int generation, {
    required bool pending,
  }) async {
    final count = librarySyncCandidateAlbumsTable.id.count();
    final row =
        await (selectOnly(librarySyncCandidateAlbumsTable)
              ..addColumns([count])
              ..where(
                _generationFilter(
                      librarySyncCandidateAlbumsTable,
                      serverId,
                      generation,
                    ) &
                    (pending
                        ? librarySyncCandidateAlbumsTable.songsHydrated.equals(
                            false,
                          )
                        : const Constant(true)),
              ))
            .getSingle();
    final resolvedCount = row.read(count) ?? 0;
    return resolvedCount;
  }

  Future<Set<String>> getArtistIds({
    required int serverId,
    required int generation,
  }) => _getIds(librarySyncCandidateArtistsTable, serverId, generation);

  Future<Set<String>> getAlbumIds({
    required int serverId,
    required int generation,
  }) => _getIds(librarySyncCandidateAlbumsTable, serverId, generation);

  Future<Set<String>> _getIds(
    TableInfo<Table, Object?> table,
    int serverId,
    int generation,
  ) async {
    final id = table.columnsByName['id']! as GeneratedColumn<String>;
    final rows =
        await (selectOnly(table)
              ..addColumns([id])
              ..where(_generationFilter(table, serverId, generation)))
            .get();
    return rows.map((row) => row.read(id)!).toSet();
  }

  Future<Map<String, int?>> getAlbumSongCounts({
    required int serverId,
    required int generation,
    required Iterable<String> albumIds,
  }) async {
    final ids = albumIds.toSet();
    if (ids.isEmpty) {
      return const <String, int?>{};
    }
    final rows =
        await (select(librarySyncCandidateAlbumsTable)..where(
              (table) =>
                  table.serverId.equals(serverId) &
                  table.generation.equals(generation) &
                  table.id.isIn(ids),
            ))
            .get();
    return <String, int?>{for (final row in rows) row.id: row.songCount};
  }

  /// Reuses authoritative local songs only when the candidate album has the
  /// same complete metadata and expected song count.
  ///
  /// Some compatible servers cap their bulk `search3` index below a large
  /// library's complete song set. These rows are absent from the index, not
  /// necessarily changed on the server. Carrying forward a matching hydrated
  /// local album avoids turning every later repair into redundant `getAlbum`
  /// requests. New or changed albums remain pending for detail hydration.
  Future<List<String>> carryForwardPendingAlbums({
    required int serverId,
    required int generation,
    bool markHydrated = false,
  }) async {
    final pending =
        await (select(librarySyncCandidateAlbumsTable)..where(
              (table) =>
                  table.serverId.equals(serverId) &
                  table.generation.equals(generation) &
                  table.songsHydrated.equals(false),
            ))
            .get();
    final carriedIds = <String>[];
    for (final candidate in pending) {
      final existing =
          await (select(albumsTable)
                ..where((table) => table.id.equals(candidate.id))
                ..limit(1))
              .getSingleOrNull();
      if (existing == null ||
          existing.isProvisional ||
          !existing.songsHydrated ||
          !_candidateMatchesExistingAlbum(candidate, existing)) {
        continue;
      }
      final songs =
          await (select(songsTable)..where(
                (table) =>
                    table.albumId.equals(candidate.id) &
                    table.serverDeletedAt.isNull(),
              ))
              .get();
      final expectedSongCount = candidate.songCount;
      if (expectedSongCount == null || songs.length != expectedSongCount) {
        continue;
      }
      await replaceSongsForAlbums(
        serverId: serverId,
        generation: generation,
        songsByAlbum: <String, List<SongsTableCompanion>>{
          candidate.id: songs.map((song) => song.toCompanion(false)).toList(),
        },
      );
      await (update(librarySyncCandidateAlbumsTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.generation.equals(generation) &
                table.id.equals(candidate.id),
          ))
          .write(
            LibrarySyncCandidateAlbumsTableCompanion(
              songsHydrated: markHydrated
                  ? const Value(true)
                  : const Value.absent(),
              carriedForward: Value(true),
            ),
          );
      carriedIds.add(candidate.id);
    }
    return carriedIds;
  }

  bool _candidateMatchesExistingAlbum(
    LibrarySyncCandidateAlbumsTableData candidate,
    AlbumsTableData existing,
  ) {
    return candidate.name == existing.name &&
        candidate.artistId == existing.artistId &&
        candidate.songCount == existing.songCount &&
        candidate.duration == existing.duration &&
        candidate.year == existing.year &&
        candidate.coverArt == existing.coverArt;
  }

  Future<List<LibrarySyncCandidateArtistsTableData>> getArtists({
    required int serverId,
    required int generation,
  }) {
    return (select(librarySyncCandidateArtistsTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.generation.equals(generation),
        ))
        .get();
  }

  Future<List<LibrarySyncCandidateArtistsTableData>> getUnclassifiedArtists({
    required int serverId,
    required int generation,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateArtistsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    unclassified: true,
  );

  Future<List<LibrarySyncCandidateAlbumsTableData>> getUnclassifiedAlbums({
    required int serverId,
    required int generation,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateAlbumsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    unclassified: true,
  );

  Future<List<LibrarySyncCandidateSongsTableData>> getUnclassifiedSongs({
    required int serverId,
    required int generation,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateSongsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    unclassified: true,
  );

  Future<List<LibrarySyncCandidateArtistsTableData>> getChangedArtistsPage({
    required int serverId,
    required int generation,
    required String afterId,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateArtistsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    afterId: afterId,
  );

  Future<List<LibrarySyncCandidateAlbumsTableData>> getChangedAlbumsPage({
    required int serverId,
    required int generation,
    required String afterId,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateAlbumsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    afterId: afterId,
  );

  Future<List<LibrarySyncCandidateSongsTableData>> getChangedSongsPage({
    required int serverId,
    required int generation,
    required String afterId,
    required int limit,
  }) => _candidatePage(
    librarySyncCandidateSongsTable,
    serverId: serverId,
    generation: generation,
    limit: limit,
    afterId: afterId,
  );

  Future<List<LibrarySyncCandidateSongsTableData>> getSongsPage({
    required int serverId,
    required int generation,
    required String afterId,
    required int limit,
  }) {
    return (select(librarySyncCandidateSongsTable)
          ..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.generation.equals(generation) &
                table.id.isBiggerThanValue(afterId),
          )
          ..orderBy([(table) => OrderingTerm.asc(table.id)])
          ..limit(limit))
        .get();
  }

  Future<List<SongsTableData>> getStaleSongsPage({
    required int serverId,
    required int generation,
    required String afterId,
    required int limit,
  }) {
    // Reset references need absence confirmation even if legacy preservation
    // made them provisional or they never had server parent IDs.
    return customSelect(
      '''
      SELECT s.*
      FROM songs s
      LEFT JOIN library_sync_candidate_songs c
        ON c.server_id = ?1
       AND c.generation = ?2
       AND c.id = s.id
      WHERE c.id IS NULL
        AND s.id > ?3
        AND s.server_deleted_at IS NULL
        AND (
          (s.is_provisional = 0
            AND (s.album_id IS NOT NULL OR s.artist_id IS NOT NULL))
          OR (s.is_external = 0
            AND s.catalog_availability = 'pendingRebuild')
        )
        AND NOT EXISTS (
          SELECT 1
          FROM library_sync_candidate_albums pending
          WHERE pending.server_id = ?1
            AND pending.generation = ?2
            AND pending.id = s.album_id
            AND pending.songs_hydrated = 0
        )
      ORDER BY s.id ASC
      LIMIT ?4
      ''',
      variables: <Variable<Object>>[
        Variable<int>(serverId),
        Variable<int>(generation),
        Variable<String>(afterId),
        Variable<int>(limit),
      ],
      readsFrom: {songsTable, librarySyncCandidateSongsTable},
    ).map((row) => songsTable.map(row.data)).get();
  }

  Future<void> classifyArtists({
    required int serverId,
    required int generation,
    required Iterable<String> changedIds,
    required Iterable<String> unchangedIds,
  }) => _classifyCandidates(
    librarySyncCandidateArtistsTable,
    serverId: serverId,
    generation: generation,
    changedIds: changedIds,
    unchangedIds: unchangedIds,
  );

  Future<void> classifyAlbums({
    required int serverId,
    required int generation,
    required Iterable<String> changedIds,
    required Iterable<String> unchangedIds,
  }) => _classifyCandidates(
    librarySyncCandidateAlbumsTable,
    serverId: serverId,
    generation: generation,
    changedIds: changedIds,
    unchangedIds: unchangedIds,
  );

  Future<void> classifySongs({
    required int serverId,
    required int generation,
    required Iterable<String> changedIds,
    required Iterable<String> unchangedIds,
  }) => _classifyCandidates(
    librarySyncCandidateSongsTable,
    serverId: serverId,
    generation: generation,
    changedIds: changedIds,
    unchangedIds: unchangedIds,
  );

  Future<void> _classifyCandidates<T extends Table, R>(
    TableInfo<T, R> table, {
    required int serverId,
    required int generation,
    required Iterable<String> changedIds,
    required Iterable<String> unchangedIds,
  }) async {
    await transaction(() async {
      for (final (ids, state) in [
        (changedIds.toSet().toList(), LibraryCandidateApplyState.changed),
        (unchangedIds.toSet().toList(), LibraryCandidateApplyState.unchanged),
      ]) {
        if (ids.isEmpty) continue;
        await (update(table)..where(
              (_) =>
                  _generationFilter(table, serverId, generation) &
                  (table.columnsByName['id']! as GeneratedColumn<String>).isIn(
                    ids,
                  ),
            ))
            .write(
              RawValuesInsertable<R>({'apply_state': Variable<int>(state)}),
            );
      }
    });
  }

  Expression<bool> _generationFilter(
    TableInfo<Table, Object?> table,
    int serverId,
    int generation,
  ) =>
      (table.columnsByName['server_id']! as GeneratedColumn<int>).equals(
        serverId,
      ) &
      (table.columnsByName['generation']! as GeneratedColumn<int>).equals(
        generation,
      );

  Future<List<R>> _candidatePage<T extends Table, R>(
    TableInfo<T, R> table, {
    required int serverId,
    required int generation,
    required int limit,
    bool unclassified = false,
    String? afterId,
  }) {
    final id = table.columnsByName['id']! as GeneratedColumn<String>;
    final state = table.columnsByName['apply_state']! as GeneratedColumn<int>;
    return (select(table)
          ..where(
            (_) =>
                _generationFilter(table, serverId, generation) &
                (unclassified
                    ? state.isNull()
                    : state.equals(LibraryCandidateApplyState.changed)) &
                (afterId == null
                    ? const Constant(true)
                    : id.isBiggerThanValue(afterId)),
          )
          ..orderBy([(_) => OrderingTerm.asc(id)])
          ..limit(limit))
        .get();
  }

  Future<List<LibrarySyncCandidateAlbumsTableData>> getAlbums({
    required int serverId,
    required int generation,
  }) {
    return (select(librarySyncCandidateAlbumsTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.generation.equals(generation),
        ))
        .get();
  }

  Future<void> replaceRecentlyAddedRanks({
    required int serverId,
    required int generation,
    required Map<String, int> ranks,
  }) async {
    final normalizedRanks = <String, int>{
      for (final entry in ranks.entries)
        if (entry.key.trim().isNotEmpty && entry.value >= 0)
          entry.key.trim(): entry.value,
    };
    await transaction(() async {
      await (update(librarySyncCandidateAlbumsTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.generation.equals(generation),
          ))
          .write(
            const LibrarySyncCandidateAlbumsTableCompanion(
              recentlyAddedRank: Value(null),
            ),
          );
      if (normalizedRanks.isEmpty) return;
      await batch((batch) {
        for (final entry in normalizedRanks.entries) {
          batch.update(
            librarySyncCandidateAlbumsTable,
            LibrarySyncCandidateAlbumsTableCompanion(
              recentlyAddedRank: Value(entry.value),
            ),
            where: (table) =>
                table.serverId.equals(serverId) &
                table.generation.equals(generation) &
                table.id.equals(entry.key),
          );
        }
      });
    });
  }

  Future<Map<String, int>> getRecentlyAddedRanks({
    required int serverId,
    required int generation,
  }) async {
    final rows =
        await (select(librarySyncCandidateAlbumsTable)..where(
              (table) =>
                  table.serverId.equals(serverId) &
                  table.generation.equals(generation) &
                  table.recentlyAddedRank.isNotNull(),
            ))
            .get();
    return <String, int>{
      for (final row in rows) row.id: row.recentlyAddedRank!,
    };
  }

  LibrarySyncCandidateSongsTableCompanion _candidateSong(
    int serverId,
    int generation,
    SongsTableCompanion song,
  ) {
    return LibrarySyncCandidateSongsTableCompanion.insert(
      serverId: serverId,
      generation: generation,
      id: song.id.value,
      title: song.title.value,
      albumId: song.albumId,
      artistId: song.artistId,
      artistName: song.artistName,
      albumName: song.albumName,
      track: song.track,
      discNumber: song.discNumber,
      duration: song.duration,
      bitRate: song.bitRate,
      sampleRate: song.sampleRate,
      contentType: song.contentType,
      suffix: song.suffix,
      size: song.size,
      coverArt: song.coverArt,
      starred: song.starred,
      recordingMbid: song.recordingMbid,
      userRating: song.userRating,
      playCount: song.playCount,
      createdAt: song.createdAt,
      replayGainTrackGain: song.replayGainTrackGain,
      replayGainAlbumGain: song.replayGainAlbumGain,
      replayGainTrackPeak: song.replayGainTrackPeak,
      replayGainAlbumPeak: song.replayGainAlbumPeak,
    );
  }
}
