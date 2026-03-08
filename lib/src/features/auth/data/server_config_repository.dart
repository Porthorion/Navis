import 'package:drift/drift.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/utils/app_logger.dart';

class ServerConfigRepository {
  ServerConfigRepository(
    this._database, {
    required SecureCredentialStore credentials,
  }) : _credentials = credentials;

  final NavisDatabase _database;
  final SecureCredentialStore _credentials;

  ServerDao get _serverDao => _database.serverDao;

  Stream<ServerConfigModel?> watchActiveServer() {
    return _serverDao.watchActiveServer().asyncMap(_mapRowToModel);
  }

  Future<ServerConfigModel?> getActiveServer() async {
    final row = await _serverDao.getActiveServer();
    return _mapRowToModel(row);
  }

  Future<void> save(ServerConfigModel config) async {
    await _credentials.savePassword(config.password);
    try {
      await _serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          name: Value(config.name),
          url: config.url,
          username: config.username,
          apiVersion: config.apiVersion,
          capabilities: Value(config.capabilitiesJson),
          lastSynced: Value(config.lastSynced),
          lastFullSynced: Value(config.lastFullSyncedAt),
        ),
      );
    } on Object catch (error, stackTrace) {
      try {
        await _credentials.clearPassword();
      } on Object {
        // Keep the original persistence error as the primary failure signal.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> clear() async {
    Object? serverError;
    StackTrace? serverStackTrace;
    try {
      await _serverDao.clearServer();
    } on Object catch (error, stackTrace) {
      serverError = error;
      serverStackTrace = stackTrace;
    }

    try {
      await _credentials.clearPassword();
    } on Object {
      if (serverError != null && serverStackTrace != null) {
        Error.throwWithStackTrace(serverError, serverStackTrace);
      }
      rethrow;
    }

    if (serverError != null && serverStackTrace != null) {
      Error.throwWithStackTrace(serverError, serverStackTrace);
    }
  }

  Future<void> updateLastSynced(DateTime value) {
    return _serverDao.updateLastSynced(value);
  }

  Future<void> updateSyncTimestamps({
    required DateTime lastSynced,
    DateTime? lastFullSyncedAt,
  }) {
    return _serverDao.updateSyncTimestamps(
      lastSynced: lastSynced,
      lastFullSynced: lastFullSyncedAt,
    );
  }

  Future<void> updateCapabilitiesJson(String? value) {
    return _serverDao.updateCapabilities(value);
  }

  Future<ServerConfigModel?> _mapRowToModel(ServerConfigTableData? row) async {
    if (row == null) {
      await _clearPasswordIfPossible();
      return null;
    }

    final password = await _readPasswordIfPossible();
    if (password == null || password.isEmpty) {
      await _serverDao.clearServer();
      return null;
    }

    return ServerConfigModel(
      id: row.id,
      name: row.name,
      url: row.url,
      username: row.username,
      password: password,
      apiVersion: row.apiVersion,
      capabilitiesJson: row.capabilities,
      lastSynced: row.lastSynced,
      lastFullSyncedAt: row.lastFullSynced,
    );
  }

  Future<void> _clearPasswordIfPossible() async {
    try {
      await _credentials.clearPassword();
    } on Object catch (error) {
      AppLogger.warning('Secure credential clear failed: $error');
    }
  }

  Future<String?> _readPasswordIfPossible() async {
    try {
      return await _credentials.readPassword();
    } on Object catch (error) {
      AppLogger.warning('Secure credential read failed: $error');
      return null;
    }
  }
}
