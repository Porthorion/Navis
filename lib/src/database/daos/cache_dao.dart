import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

part 'cache_dao.g.dart';

@DriftAccessor(tables: [CachedTracksTable])
class CacheDao extends DatabaseAccessor<NavisDatabase> with _$CacheDaoMixin {
  CacheDao(super.db);

  Stream<List<CachedTracksTableData>> watchCachedTracks() {
    final query = select(cachedTracksTable)
      ..orderBy([(table) => OrderingTerm.desc(table.lastAccessedAt)]);
    return query.watch();
  }

  Future<void> upsertCachedTrack(CachedTracksTableCompanion companion) {
    return into(cachedTracksTable).insertOnConflictUpdate(companion);
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
}
