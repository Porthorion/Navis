import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class ExternalScrobbleCredentialStore {
  Future<void> saveListenBrainzToken(String value);
  Future<String?> readListenBrainzToken();
  Future<void> clearListenBrainzToken();
}

/// Process-local credential storage for isolated diagnostics.
///
/// Clone runs must never read from or write to the device credential store.
class CloneDiagnosticsExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  String? _listenBrainzToken;

  @override
  Future<void> saveListenBrainzToken(String value) async {
    _listenBrainzToken = value;
  }

  @override
  Future<String?> readListenBrainzToken() async => _listenBrainzToken;

  @override
  Future<void> clearListenBrainzToken() async {
    _listenBrainzToken = null;
  }
}

class FlutterExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  const new({
    this._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    ),
    this.storageDeadline = const Duration(seconds: 5),
  });

  static const _listenBrainzTokenKey =
      'navis.external_scrobble.listenbrainz.token';

  final FlutterSecureStorage _storage;

  /// Bound for one native token operation. A stuck platform channel surfaces as
  /// unavailability instead of wedging scrobble dispatch.
  final Duration storageDeadline;

  @override
  Future<void> saveListenBrainzToken(String value) {
    return _write(_listenBrainzTokenKey, value);
  }

  @override
  Future<String?> readListenBrainzToken() {
    return _read(_listenBrainzTokenKey);
  }

  @override
  Future<void> clearListenBrainzToken() {
    return _delete(_listenBrainzTokenKey);
  }

  Future<void> _write(String key, String value) async {
    try {
      await runSerializedSecureStorage(
        () => _storage.write(key: key, value: value),
        storageDeadline,
      );
    } on Object catch (error) {
      AppLogger.warning(
        'External credential save failed: ${error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await runSerializedSecureStorage(
        () => _storage.read(key: key),
        storageDeadline,
      );
    } on Object catch (error) {
      AppLogger.warning(
        'External credential read failed: ${error.runtimeType}',
      );
      // Null would make a stored token look absent, which drops queued
      // listens; unavailability must stay distinguishable from removal.
      throw const CredentialReadException();
    }
  }

  Future<void> _delete(String key) async {
    try {
      await runSerializedSecureStorage(
        () => _storage.delete(key: key),
        storageDeadline,
      );
    } on Object catch (error) {
      AppLogger.warning(
        'External credential clear failed: ${error.runtimeType}',
      );
      rethrow;
    }
  }
}
