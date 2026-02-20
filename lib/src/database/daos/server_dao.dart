import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

part 'server_dao.g.dart';

@DriftAccessor(tables: [ServerConfigTable])
class ServerDao extends DatabaseAccessor<NavisDatabase> with _$ServerDaoMixin {
  ServerDao(super.db);

  Stream<ServerConfigTableData?> watchActiveServer() {
    final query = select(serverConfigTable)..limit(1);
    return query.watchSingleOrNull();
  }

  Future<ServerConfigTableData?> getActiveServer() {
    final query = select(serverConfigTable)..limit(1);
    return query.getSingleOrNull();
  }

  Future<void> saveServer(ServerConfigTableCompanion companion) async {
    await transaction(() async {
      await delete(serverConfigTable).go();
      await into(serverConfigTable).insert(companion);
    });
  }

  Future<void> updateLastSynced(DateTime value) {
    return update(serverConfigTable).write(
      ServerConfigTableCompanion(lastSynced: Value(value)),
    );
  }

  Future<void> updateSyncTimestamps({
    required DateTime lastSynced,
    DateTime? lastFullSynced,
  }) {
    final companion = ServerConfigTableCompanion(
      lastSynced: Value(lastSynced),
      lastFullSynced: lastFullSynced == null
          ? const Value.absent()
          : Value(lastFullSynced),
    );
    return update(serverConfigTable).write(
      companion,
    );
  }

  Future<void> clearServer() => delete(serverConfigTable).go();
}
