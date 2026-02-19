import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';

class ServerConfigRepository {
  const ServerConfigRepository(this._database);

  final NavisDatabase _database;

  ServerDao get _serverDao => _database.serverDao;

  Stream<ServerConfigModel?> watchActiveServer() {
    return _serverDao.watchActiveServer().map(_mapRowToModel);
  }

  Future<ServerConfigModel?> getActiveServer() async {
    final row = await _serverDao.getActiveServer();
    return _mapRowToModel(row);
  }

  Future<void> save(ServerConfigModel config) {
    return _serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        name: Value(config.name),
        url: config.url,
        username: config.username,
        apiVersion: config.apiVersion,
        capabilities: Value(config.capabilitiesJson),
        lastSynced: Value(config.lastSynced),
      ),
    );
  }

  Future<void> clear() => _serverDao.clearServer();

  ServerConfigModel? _mapRowToModel(ServerConfigTableData? row) {
    if (row == null) {
      return null;
    }

    return ServerConfigModel(
      id: row.id,
      name: row.name,
      url: row.url,
      username: row.username,
      // Password is persisted separately in secure storage in Phase 2.
      password: '',
      apiVersion: row.apiVersion,
      capabilitiesJson: row.capabilities,
      lastSynced: row.lastSynced,
    );
  }
}
