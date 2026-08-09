import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

part 'server_dao.g.dart';

@DriftAccessor(tables: [ServerConfigTable])
class ServerDao extends DatabaseAccessor<NavisDatabase> with _$ServerDaoMixin {
  ServerDao(super.db);

  Stream<ServerConfigTableData?> watchActiveServer() {
    final query = select(serverConfigTable)
      ..where((table) => table.isAuthenticated.equals(true))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Future<ServerConfigTableData?> getActiveServer() {
    final query = select(serverConfigTable)
      ..where((table) => table.isAuthenticated.equals(true))
      ..limit(1);
    return query.getSingleOrNull();
  }

  Future<ServerConfigTableData?> getRetainedServer() {
    final query = select(serverConfigTable)..limit(1);
    return query.getSingleOrNull();
  }

  Future<void> saveServer(ServerConfigTableCompanion companion) async {
    await transaction(() async {
      await delete(serverConfigTable).go();
      await into(serverConfigTable).insert(companion);
    });
  }

  Future<void> updateRetainedServer(
    int id,
    ServerConfigTableCompanion companion,
  ) {
    return (update(
      serverConfigTable,
    )..where((table) => table.id.equals(id))).write(companion);
  }

  Future<void> markSignedOut() {
    return update(serverConfigTable).write(
      const ServerConfigTableCompanion(isAuthenticated: Value(false)),
    );
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

  Future<void> updateCapabilities(String? value) {
    return update(serverConfigTable).write(
      ServerConfigTableCompanion(
        capabilities: Value(value),
      ),
    );
  }

  Future<void> clearSyncTimestamps() {
    return update(serverConfigTable).write(
      const ServerConfigTableCompanion(
        lastSynced: Value(null),
        lastFullSynced: Value(null),
      ),
    );
  }

  Future<void> clearServer() => delete(serverConfigTable).go();
}
