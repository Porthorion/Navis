import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Secure storage could not be read; the saved credential may still exist.
class CredentialReadException implements Exception {
  const new();

  @override
  String toString() => 'Secure credentials are temporarily unavailable.';
}

/// Secure storage could not be written, so no durable credential exists.
class CredentialWriteException implements Exception {
  const new();

  @override
  String toString() => 'Secure credentials could not be persisted.';
}

/// Tail of the native secure-storage queue. Top-level so every credential
/// store in this engine shares it: overlapping native calls race
/// secure-storage initialization and migration.
Future<void> _nativeOperations = Future<void>.value();

/// Runs [operation] after every earlier native secure-storage operation has
/// settled. The caller gets [deadline] as an error, but the queue advances only
/// when the native call itself settles, so a stuck call is never overlapped.
/// ponytail: a permanently hung plugin makes later calls time out as
/// unavailable; the startup Restart Navis recovery covers that.
Future<T> runSerializedSecureStorage<T>(
  Future<T> Function() operation,
  Duration deadline,
) {
  final task = _nativeOperations.then((_) => operation());
  _nativeOperations = task.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  return task.timeout(deadline);
}

/// Forgets queued native operations so a test's deliberately stuck call cannot
/// block later tests in the same isolate.
@visibleForTesting
void resetSecureStorageQueue() => _nativeOperations = Future<void>.value();

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
    final load = _loadFuture ??= _loadPassword();
    try {
      return await load;
    } on Object {
      if (identical(_loadFuture, load)) _loadFuture = null;
      rethrow;
    }
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
  new({
    this._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    ),
    this.requiresDurableCredentials,
    this.storageDeadline = const Duration(seconds: 5),
  });

  static const _passwordKey = 'navis.auth.active_server.password';
  static const _userInfoKey = 'navis.auth.active_server.user_info';
  static const _maxSaveAttempts = 3;
  static const _firstSaveRetryDelay = Duration(milliseconds: 200);
  static String? _sessionUserInfoFallback;
  static String? _sessionPasswordFallback;
  static bool _didLogSaveFallbackWarning = false;
  static bool _didLogReadFallbackWarning = false;
  static bool _didLogClearFallbackWarning = false;

  final FlutterSecureStorage _storage;

  /// Whether a save that cannot reach durable storage must fail instead of
  /// keeping the credential only in engine-local memory. Null defers to the
  /// platform: Android requires durable persistence before a login may be
  /// declared, while desktop keeps the local-dev session fallback for missing
  /// keychain entitlements.
  final bool? requiresDurableCredentials;

  /// Bound for one native secure-storage operation. A stuck platform channel
  /// surfaces as unavailability instead of hanging startup forever.
  final Duration storageDeadline;

  bool get _mustPersistDurableCredentials =>
      requiresDurableCredentials ?? Platform.isAndroid;

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    return runSerializedSecureStorage(operation, storageDeadline);
  }

  Future<String?> _readEntry(String key) {
    return _runSerialized(() => _storage.read(key: key));
  }

  Future<void> _writeEntry(String key, String value) {
    return _runSerialized(() => _storage.write(key: key, value: value));
  }

  Future<void> _deleteEntry(String key) {
    return _runSerialized(() => _storage.delete(key: key));
  }

  @override
  Future<void> savePassword(String password) {
    return _saveEntry(
      key: _passwordKey,
      value: password,
      onSessionFallback: (value) => _sessionPasswordFallback = value,
    );
  }

  @override
  Future<String?> readPassword() async {
    try {
      final value = await _readEntry(_passwordKey);
      return value ?? _sessionPasswordFallback;
    } on Object catch (error, stackTrace) {
      _warnReadUnavailable(error);
      if (_sessionPasswordFallback != null) return _sessionPasswordFallback;
      Error.throwWithStackTrace(const CredentialReadException(), stackTrace);
    }
  }

  @override
  Future<void> clearPassword() async {
    _sessionPasswordFallback = null;
    try {
      await _deleteEntry(_passwordKey);
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
  Future<void> saveUserInfo(String userInfo) {
    return _saveEntry(
      key: _userInfoKey,
      value: userInfo,
      onSessionFallback: (value) => _sessionUserInfoFallback = value,
    );
  }

  @override
  Future<String?> readUserInfo() async {
    if (_sessionUserInfoFallback != null) return _sessionUserInfoFallback;
    try {
      final value = await _readEntry(_userInfoKey);
      return value ?? _sessionUserInfoFallback;
    } on Object catch (error, stackTrace) {
      _warnReadUnavailable(error);
      if (_sessionPasswordFallback != null ||
          _sessionUserInfoFallback != null) {
        return _sessionUserInfoFallback;
      }
      Error.throwWithStackTrace(const CredentialReadException(), stackTrace);
    }
  }

  @override
  Future<void> clearUserInfo() async {
    _sessionUserInfoFallback = null;
    try {
      await _deleteEntry(_userInfoKey);
    } on Object catch (error) {
      if (!_didLogClearFallbackWarning) {
        _didLogClearFallbackWarning = true;
        AppLogger.warning(
          'Secure credential clear failed: ${error.runtimeType}.',
        );
      }
    }
  }

  Future<void> _saveEntry({
    required String key,
    required String value,
    required void Function(String?) onSessionFallback,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await _writeEntry(key, value);
        onSessionFallback(null);
        return;
      } on Object catch (error) {
        if (attempt < _maxSaveAttempts) {
          await Future<void>.delayed(
            _firstSaveRetryDelay * (1 << (attempt - 1)),
          );
          continue;
        }
        if (_mustPersistDurableCredentials) {
          AppLogger.startup(
            StartupEvent.credentialRecovery,
            outcome: StartupOutcome.failure,
            failureType: StartupFailure.credentials,
          );
          throw const CredentialWriteException();
        }
        // Keep desktop/macOS local dev usable when keychain entitlements are
        // unavailable by falling back to in-memory session storage.
        onSessionFallback(value);
        if (!_didLogSaveFallbackWarning) {
          _didLogSaveFallbackWarning = true;
          AppLogger.warning(
            'Secure credential save failed; using session fallback: '
            '${error.runtimeType}.',
          );
          AppLogger.startup(
            StartupEvent.credentialRecovery,
            outcome: StartupOutcome.credentialUnavailable,
            failureType: StartupFailure.credentials,
          );
        }
        return;
      }
    }
  }

  void _warnReadUnavailable(Object error) {
    if (_didLogReadFallbackWarning) {
      return;
    }
    _didLogReadFallbackWarning = true;
    AppLogger.warning('Secure credential read failed: ${error.runtimeType}.');
    AppLogger.startup(
      StartupEvent.credentialRecovery,
      outcome: StartupOutcome.credentialUnavailable,
      failureType: StartupFailure.credentials,
    );
  }
}
