import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/cache_system_state_table.dart';

part 'cache_system_state_dao.g.dart';

@DriftAccessor(tables: [CacheSystemStateTable])
class CacheSystemStateDao extends DatabaseAccessor<NavisDatabase>
    with _$CacheSystemStateDaoMixin {
  CacheSystemStateDao(super.attachedDatabase);

  static const int singletonId = 1;

  Future<int?> getVersion() async {
    final row =
        await (select(cacheSystemStateTable)
              ..where((table) => table.id.equals(singletonId))
              ..limit(1))
            .getSingleOrNull();
    return row?.cacheSystemVersion;
  }

  Future<void> markVersion(int version) {
    return into(cacheSystemStateTable).insertOnConflictUpdate(
      CacheSystemStateTableCompanion.insert(
        id: Value<int>(singletonId),
        cacheSystemVersion: version,
      ),
    );
  }
}
