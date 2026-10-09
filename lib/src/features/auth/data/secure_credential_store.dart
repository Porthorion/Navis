import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class SecureCredentialStore {
  Future<void> savePassword(String password);
  Future<String?> readPassword();
  Future<void> clearPassword();
}

/// URL credentials are an optional capability for password-only store adapters.
abstract interface class ServerUrlCredentialStore
    implements SecureCredentialStore {
  Future<void> saveUserInfo(String userInfo);
  Future<String?> readUserInfo();
  Future<void> clearUserInfo();
}

class CloneDiagnosticsCredentialStore implements SecureCredentialStore {
  new(this._backing, {this._credentialPath = ''});

  final SecureCredentialStore _backing;
  final String _credentialPath;
  bool _didLoad = false;
  String? _password;
  Future<String?>? _loadFuture;

  @override
  Future<void> savePassword(String password) async {
    _didLoad = true;
    _password = password;
  }

  @override
  Future<String?> readPassword() async {
    if (_didLoad) {
      return _password;
    }
    return await (_loadFuture ??= _loadPassword());
  }

  @override
  Future<void> clearPassword() async {
    _didLoad = true;
    _password = null;
    _loadFuture = null;
  }

  Future<String?> _loadPassword() async {
    final loaded = _credentialPath.isNotEmpty
        ? (await File(
            _credentialPath,
          ).readAsString()).replaceFirst(RegExp(r'\r?\n$'), '')
        : await _backing.readPassword();
    if (!_didLoad) {
      _didLoad = true;
      _password = loaded;
    }
    return _password;
  }
}

class FlutterSecureCredentialStore implements ServerUrlCredentialStore {
  const new({this._storage = const FlutterSecureStorage()});

  static const _passwordKey = 'navis.auth.active_server.password';
  static const _userInfoKey = 'navis.auth.active_server.user_info';
  static String? _sessionUserInfoFallback;
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
          'Secure credential save failed; using session fallback: '
          '${error.runtimeType}.',
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
          'Secure credential read failed; using session fallback: '
          '${error.runtimeType}.',
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
        AppLogger.warning(
          'Secure credential clear failed: ${error.runtimeType}.',
        );
      }
    }
  }

  @override
  Future<void> saveUserInfo(String userInfo) async {
    try {
      await _storage.write(key: _userInfoKey, value: userInfo);
      _sessionUserInfoFallback = null;
    } on Object catch (error) {
      // Keep desktop/macOS local dev usable when keychain entitlements are
      // unavailable by falling back to in-memory session storage.
      _sessionUserInfoFallback = userInfo;
      if (!_didLogSaveFallbackWarning) {
        _didLogSaveFallbackWarning = true;
        AppLogger.warning(
          'Secure credential save failed; using session fallback: '
          '${error.runtimeType}.',
        );
      }
    }
  }

  @override
  Future<String?> readUserInfo() async {
    if (_sessionUserInfoFallback != null) return _sessionUserInfoFallback;
    try {
      final value = await _storage.read(key: _userInfoKey);
      return value ?? _sessionUserInfoFallback;
    } on Object catch (error) {
      if (!_didLogReadFallbackWarning) {
        _didLogReadFallbackWarning = true;
        AppLogger.warning(
          'Secure credential read failed; using session fallback: '
          '${error.runtimeType}.',
        );
      }
      return _sessionUserInfoFallback;
    }
  }

  @override
  Future<void> clearUserInfo() async {
    _sessionUserInfoFallback = null;
    try {
      await _storage.delete(key: _userInfoKey);
    } on Object catch (error) {
      if (!_didLogClearFallbackWarning) {
        _didLogClearFallbackWarning = true;
        AppLogger.warning(
          'Secure credential clear failed: ${error.runtimeType}.',
        );
      }
    }
  }
}
