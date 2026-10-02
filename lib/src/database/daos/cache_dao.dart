import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/listenbrainz_weekly_cache_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:path/path.dart' as p;

part 'cache_dao.g.dart';

@DriftAccessor(tables: [CachedTracksTable, ListenBrainzWeeklyCacheTable])
class CacheDao extends DatabaseAccessor<NavisDatabase> with _$CacheDaoMixin {
  new(super.attachedDatabase);

  Stream<List<CachedTracksTableData>> watchCachedTracks() {
    final query = select(cachedTracksTable)
      ..orderBy([(table) => OrderingTerm.desc(table.lastAccessedAt)]);
    return query.watch();
  }

  /// Watch only tracks of a given [cacheType] (rolling or permanent).
  Stream<List<CachedTracksTableData>> watchCachedTracksByType(
    CacheType cacheType,
  ) {
    final query = select(cachedTracksTable)
      ..where((t) => t.cacheType.equalsValue(cacheType))
      ..orderBy([(t) => OrderingTerm.desc(t.lastAccessedAt)]);
    return query.watch();
  }

  Future<void> upsertCachedTrack(CachedTracksTableCompanion companion) {
    return into(cachedTracksTable).insertOnConflictUpdate(companion);
  }

  /// Upserts [companions] in transactions of [chunkSize] rows, so every
  /// cache-derived query re-runs once per chunk instead of once per row.
  Future<void> upsertCachedTracks(
    List<CachedTracksTableCompanion> companions, {
    int chunkSize = 250,
  }) async {
    for (var offset = 0; offset < companions.length; offset += chunkSize) {
      final end = offset + chunkSize < companions.length
          ? offset + chunkSize
          : companions.length;
      await batch(
        (batch) => batch.insertAllOnConflictUpdate(
          cachedTracksTable,
          companions.sublist(offset, end),
        ),
      );
    }
  }

  /// Like [upsertCachedTrack] but never downgrades a [CacheType.permanent]
  /// entry to [CacheType.rolling]. Use this when the rolling cache registers a
  /// playback write so that already-downloaded tracks keep their status.
  Future<void> upsertRollingCachedTrack(
    CachedTracksTableCompanion companion,
  ) async {
    final existing = await getCachedTrack(companion.songId.value);
    if (existing != null && existing.cacheType == CacheType.permanent) {
      // Already permanently downloaded — just update the access time.
      await touchTrack(companion.songId.value);
      return;
    }
    await into(cachedTracksTable).insertOnConflictUpdate(companion);
  }

  Future<List<CachedTracksTableData>> getCachedTracks() {
    final query = select(cachedTracksTable);
    return query.get();
  }

  Future<CachedTracksTableData?> getCachedTrack(String songId) {
    final query = select(cachedTracksTable)
      ..where((table) => table.songId.equals(songId))
      ..limit(1);
    return query.getSingleOrNull();
  }

  Future<int> getRollingTotalBytes() async {
    final aggregate = cachedTracksTable.fileSize.sum();
    final query = selectOnly(cachedTracksTable)
      ..where(cachedTracksTable.cacheType.equals(CacheType.rolling.name))
      ..addColumns(<Expression<Object>>[aggregate]);
    final row = await query.getSingleOrNull();
    final resolvedCount = row?.read(aggregate) ?? 0;
    return resolvedCount;
  }

  Future<List<CachedTracksTableData>> getRollingEntriesOrderedByLastAccessed({
    int? limit,
  }) {
    final query = select(cachedTracksTable)
      ..where((table) => table.cacheType.equals(CacheType.rolling.name))
      ..orderBy([(table) => OrderingTerm.asc(table.lastAccessedAt)]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Future<void> deleteCachedTracksBySongIds(Iterable<String> songIds) async {
    final ids = songIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return;
    }
    await (delete(
      cachedTracksTable,
    )..where((table) => table.songId.isIn(ids))).go();
  }

  Future<void> touchTrack(String songId) async {
    await (update(
      cachedTracksTable,
    )..where((table) => table.songId.equals(songId))).write(
      CachedTracksTableCompanion(lastAccessedAt: Value(DateTime.now())),
    );
  }

  Future<void> updateCacheType(String songId, CacheType cacheType) {
    return (update(
      cachedTracksTable,
    )..where((table) => table.songId.equals(songId))).write(
      CachedTracksTableCompanion(
        cacheType: Value(cacheType),
        lastAccessedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> removeCachedTrack(String songId) {
    return (delete(
      cachedTracksTable,
    )..where((table) => table.songId.equals(songId))).go();
  }

  /// Get all song IDs that are permanently cached.
  Future<Set<String>> getPermanentlyCachedSongIds() async {
    final query = selectOnly(cachedTracksTable)
      ..where(cachedTracksTable.cacheType.equals(CacheType.permanent.name))
      ..addColumns([cachedTracksTable.songId]);
    final rows = await query.get();
    return rows.map((r) => r.read(cachedTracksTable.songId)!).toSet();
  }

  /// Get all permanent cache entries (for stale-file pruning).
  /// Forgets every cached or downloaded track whose file lies outside
  /// [root], returning how many were forgotten. Android `content://` grants
  /// are kept.
  ///
  /// A clone diagnostics profile is a copy of a real profile, so these rows
  /// can name the user's own downloads and cache files; the clone's download
  /// normalization, cache eviction or catalog deletions would then move or
  /// delete them. Gates that need media copy it inside [root] first.
  Future<int> forgetEntriesOutside(String root) async {
    final normalizedRoot = p.normalize(p.absolute(root));
    final rows = await select(cachedTracksTable).get();
    final outside = <String>[
      for (final row in rows)
        if (!row.filePath.startsWith('content://') &&
            !p.isWithin(normalizedRoot, p.normalize(p.absolute(row.filePath))))
          row.songId,
    ];
    if (outside.isEmpty) return 0;
    await transaction(() async {
      for (var start = 0; start < outside.length; start += 500) {
        final batch = outside.sublist(
          start,
          start + 500 < outside.length ? start + 500 : outside.length,
        );
        await (delete(
          cachedTracksTable,
        )..where((t) => t.songId.isIn(batch))).go();
      }
    });
    return outside.length;
  }

  Future<List<CachedTracksTableData>> getPermanentEntries() {
    final query = select(cachedTracksTable)
      ..where((t) => t.cacheType.equals(CacheType.permanent.name));
    return query.get();
  }

  /// Return a map of songId → CacheType for all cached tracks.
  ///
  /// Used for efficient batch dedup checks during album/playlist enqueue.
  Future<Map<String, CacheType>> getCacheTypesForSongIds(
    Iterable<String> songIds,
  ) async {
    final ids = songIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) return {};
    final query = select(cachedTracksTable)..where((t) => t.songId.isIn(ids));
    final rows = await query.get();
    return {for (final r in rows) r.songId: r.cacheType};
  }

  /// Return full cache rows keyed by songId.
  ///
  /// Used by download enqueue paths that need format/bitrate compatibility
  /// checks without issuing one lookup per song.
  Future<Map<String, CachedTracksTableData>> getCachedTracksForSongIds(
    Iterable<String> songIds,
  ) async {
    final ids = songIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) return {};
    final query = select(cachedTracksTable)..where((t) => t.songId.isIn(ids));
    final rows = await query.get();
    return {for (final r in rows) r.songId: r};
  }

  Future<void> clearCachedTracks() {
    return delete(cachedTracksTable).go();
  }

  Future<List<ListenBrainzWeeklyCacheTableData>>
  getListenBrainzWeeklyCacheForUser(String userName) {
    final query = select(listenBrainzWeeklyCacheTable)
      ..where((table) => table.listenBrainzUserName.equals(userName))
      ..orderBy([(table) => OrderingTerm.asc(table.sourcePatch)]);
    return query.get();
  }

  Future<String?> getLatestListenBrainzWeeklyCacheUserName() async {
    final query = selectOnly(listenBrainzWeeklyCacheTable)
      ..addColumns(<Expression<Object>>[
        listenBrainzWeeklyCacheTable.listenBrainzUserName,
      ])
      ..orderBy([OrderingTerm.desc(listenBrainzWeeklyCacheTable.fetchedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.read(listenBrainzWeeklyCacheTable.listenBrainzUserName);
  }

  Future<void> upsertListenBrainzWeeklyCache(
    ListenBrainzWeeklyCacheTableCompanion companion,
  ) {
    return into(listenBrainzWeeklyCacheTable).insertOnConflictUpdate(companion);
  }

  Future<void> deleteListenBrainzWeeklyCacheForUserSources(
    String userName,
    Iterable<String> sourcePatches,
  ) async {
    final sources = sourcePatches
        .map((sourcePatch) => sourcePatch.trim())
        .where((sourcePatch) => sourcePatch.isNotEmpty)
        .toList(growable: false);
    if (sources.isEmpty) {
      return;
    }
    await (delete(listenBrainzWeeklyCacheTable)..where(
          (table) =>
              table.listenBrainzUserName.equals(userName) &
              table.sourcePatch.isIn(sources),
        ))
        .go();
  }
}
