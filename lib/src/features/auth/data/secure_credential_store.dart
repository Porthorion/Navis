import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class SecureCredentialStore {
  Future<void> savePassword(String password);
  Future<String?> readPassword();
  Future<void> clearPassword();
}

class FlutterSecureCredentialStore implements SecureCredentialStore {
  const FlutterSecureCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _passwordKey = 'navis.auth.active_server.password';
  static String? _sessionPasswordFallback;
  static bool _didLogSaveFallbackWarning = false;
  static bool _didLogReadFallbackWarning = false;
  static bool _didLogClearFallbackWarning = false;

  final FlutterSecureStorage _storage;

  @override
  Future<void> savePassword(String password) async {
    try {
      await _storage.write(key: _passwordKey, value: password);
      _sessionPasswordFallback = null;
    } on Object catch (error) {
      // Keep desktop/macOS local dev usable when keychain entitlements are
      // unavailable by falling back to in-memory session storage.
      _sessionPasswordFallback = password;
      if (!_didLogSaveFallbackWarning) {
        _didLogSaveFallbackWarning = true;
        AppLogger.warning(
          'Secure credential save failed; using session fallback: $error',
        );
      }
    }
  }

  @override
  Future<String?> readPassword() async {
    try {
      final value = await _storage.read(key: _passwordKey);
      return value ?? _sessionPasswordFallback;
    } on Object catch (error) {
      if (!_didLogReadFallbackWarning) {
        _didLogReadFallbackWarning = true;
        AppLogger.warning(
          'Secure credential read failed; using session fallback: $error',
        );
      }
      return _sessionPasswordFallback;
    }
  }

  @override
  Future<void> clearPassword() async {
    _sessionPasswordFallback = null;
    try {
      await _storage.delete(key: _passwordKey);
    } on Object catch (error) {
      if (!_didLogClearFallbackWarning) {
        _didLogClearFallbackWarning = true;
        AppLogger.warning('Secure credential clear failed: $error');
      }
    }
  }
}
