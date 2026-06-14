import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class ExternalScrobbleCredentialStore {
  Future<void> saveListenBrainzToken(String value);
  Future<String?> readListenBrainzToken();
  Future<void> clearListenBrainzToken();
}

class FlutterExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  const FlutterExternalScrobbleCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _listenBrainzTokenKey =
      'navis.external_scrobble.listenbrainz.token';

  final FlutterSecureStorage _storage;

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
      await _storage.write(key: key, value: value);
    } on Object catch (error) {
      AppLogger.warning(
        'External credential save failed: ${error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<String?> _read(String key) async {
    try {
      return _storage.read(key: key);
    } on Object catch (error) {
      AppLogger.warning(
        'External credential read failed: ${error.runtimeType}',
      );
      return null;
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Object catch (error) {
      AppLogger.warning(
        'External credential clear failed: ${error.runtimeType}',
      );
    }
  }
}
