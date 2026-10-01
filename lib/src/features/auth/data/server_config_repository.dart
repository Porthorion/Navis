import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/utils/app_logger.dart';

enum RetainedServerMatch { none, same, different }

class RetainedServerMismatchException implements Exception {
  const new();

  @override
  String toString() =>
      'A different retained server profile must be explicitly removed first.';
}

class ServerConfigRepository {
  new(this._database, {required this._credentials});

  final NavisDatabase _database;
  final SecureCredentialStore _credentials;

  ServerDao get _serverDao => _database.serverDao;

  Stream<ServerConfigModel?> watchActiveServer() {
    return _serverDao.watchActiveServer().asyncMap(_mapRowToModel);
  }

  Future<ServerConfigModel?> getActiveServer() async {
    final row = await _serverDao.getActiveServer();
    return await _mapRowToModel(row);
  }

  Future<ServerConfigModel?> getRetainedServer() async {
    final row = await _serverDao.getRetainedServer();
    return row == null ? null : _mapRetainedRowToModel(row);
  }

  Future<RetainedServerMatch> compareRetainedServer(
    ServerConfigModel candidate,
  ) async {
    final retained = await _serverDao.getRetainedServer();
    if (retained == null) {
      return RetainedServerMatch.none;
    }
    return _sameIdentity(
          retained.url,
          retained.username,
          candidate.url,
          candidate.username,
        )
        ? RetainedServerMatch.same
        : RetainedServerMatch.different;
  }

  Future<void> save(ServerConfigModel config) async {
    final retained = await _serverDao.getRetainedServer();
    if (retained != null &&
        !_sameIdentity(
          retained.url,
          retained.username,
          config.url,
          config.username,
        )) {
      throw const RetainedServerMismatchException();
    }
    await _credentials.savePassword(config.password);
    try {
      if (retained == null) {
        await _serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            name: Value(config.name),
            url: config.url,
            username: config.username.trim(),
            apiVersion: config.apiVersion,
            capabilities: Value(config.capabilitiesJson),
            lastSynced: Value(config.lastSynced),
            lastFullSynced: Value(config.lastFullSyncedAt),
            isAuthenticated: const Value(true),
          ),
        );
      } else {
        await _serverDao.updateRetainedServer(
          retained.id,
          ServerConfigTableCompanion(
            name: Value(config.name),
            url: Value(config.url),
            username: Value(config.username.trim()),
            apiVersion: Value(config.apiVersion),
            capabilities: Value(
              _mergeCapabilities(
                retained.capabilities,
                config.capabilitiesJson,
              ),
            ),
            isAuthenticated: const Value(true),
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      try {
        await _credentials.clearPassword();
      } on Object {
        // Keep the original persistence error as the primary failure signal.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> signOutKeepData() async {
    Object? databaseError;
    StackTrace? databaseStackTrace;
    try {
      await _serverDao.markSignedOut();
    } on Object catch (error, stackTrace) {
      databaseError = error;
      databaseStackTrace = stackTrace;
    }

    try {
      await _credentials.clearPassword();
    } on Object {
      if (databaseError != null && databaseStackTrace != null) {
        Error.throwWithStackTrace(databaseError, databaseStackTrace);
      }
      rethrow;
    }

    if (databaseError != null && databaseStackTrace != null) {
      Error.throwWithStackTrace(databaseError, databaseStackTrace);
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
      await _serverDao.markSignedOut();
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

  ServerConfigModel _mapRetainedRowToModel(ServerConfigTableData row) {
    return ServerConfigModel(
      id: row.id,
      name: row.name,
      url: row.url,
      username: row.username,
      password: '',
      apiVersion: row.apiVersion,
      capabilitiesJson: row.capabilities,
      lastSynced: row.lastSynced,
      lastFullSyncedAt: row.lastFullSynced,
    );
  }

  bool _sameIdentity(
    String leftUrl,
    String leftUsername,
    String rightUrl,
    String rightUsername,
  ) {
    return _normalizeServerUrl(leftUrl) == _normalizeServerUrl(rightUrl) &&
        leftUsername.trim() == rightUsername.trim();
  }

  String _normalizeServerUrl(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return trimmed.replaceFirst(RegExp(r'/+$'), '');
    }
    final path = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/+$'), '');
    final defaultPort =
        (uri.scheme.toLowerCase() == 'https' && uri.port == 443) ||
        (uri.scheme.toLowerCase() == 'http' && uri.port == 80);
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo,
      host: uri.host.toLowerCase(),
      port: defaultPort ? null : (uri.hasPort ? uri.port : null),
      path: path,
    ).toString();
  }

  String? _mergeCapabilities(String? retained, String? probed) {
    if (retained == null || retained.trim().isEmpty) {
      return probed;
    }
    if (probed == null || probed.trim().isEmpty) {
      return retained;
    }
    try {
      final retainedRoot = jsonDecode(retained);
      final probedRoot = jsonDecode(probed);
      if (retainedRoot is! Map<String, dynamic> ||
          probedRoot is! Map<String, dynamic>) {
        return probed;
      }
      return jsonEncode(<String, dynamic>{
        ...probedRoot,
        if (retainedRoot['navis'] != null) 'navis': retainedRoot['navis'],
      });
    } on FormatException {
      return probed;
    }
  }

  Future<void> _clearPasswordIfPossible() async {
    try {
      await _credentials.clearPassword();
    } on Object catch (error) {
      AppLogger.warning(
        'Secure credential clear failed: ${error.runtimeType}.',
      );
    }
  }

  Future<String?> _readPasswordIfPossible() async {
    try {
      return await _credentials.readPassword();
    } on Object catch (error) {
      AppLogger.warning('Secure credential read failed: ${error.runtimeType}.');
      return null;
    }
  }
}
