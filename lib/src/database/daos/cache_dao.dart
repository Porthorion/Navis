import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/listenbrainz_weekly_cache_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

part 'cache_dao.g.dart';

@DriftAccessor(tables: [CachedTracksTable, ListenBrainzWeeklyCacheTable])
class CacheDao extends DatabaseAccessor<NavisDatabase> with _$CacheDaoMixin {
  CacheDao(super.attachedDatabase);

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
    return row?.read(aggregate) ?? 0;
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

  Future<void> upsertListenBrainzWeeklyCache(
    ListenBrainzWeeklyCacheTableCompanion companion,
  ) {
    return into(
      listenBrainzWeeklyCacheTable,
    ).insertOnConflictUpdate(companion);
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
