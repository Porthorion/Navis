import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/features/group_listening/data/group_listening_dtos.dart';
import 'package:navis/src/features/group_listening/data/group_listening_wire_codec.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class GroupListeningSessionCredentialStore {
  Future<void> save(GroupListeningStoredSession session);

  Future<GroupListeningStoredSession?> read();

  Future<void> clear();
}

class InMemoryGroupListeningSessionCredentialStore
    implements GroupListeningSessionCredentialStore {
  GroupListeningStoredSession? _session;

  @override
  Future<void> clear() async {
    _session = null;
  }

  @override
  Future<GroupListeningStoredSession?> read() async => _session;

  @override
  Future<void> save(GroupListeningStoredSession session) async {
    _session = session;
  }
}

class FlutterSecureGroupListeningSessionCredentialStore
    implements GroupListeningSessionCredentialStore {
  const FlutterSecureGroupListeningSessionCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _sessionKey = 'navis.group_listening.active_session';
  static GroupListeningStoredSession? _sessionFallback;
  static bool _didLogSaveFallbackWarning = false;
  static bool _didLogReadFallbackWarning = false;
  static bool _didLogClearFallbackWarning = false;

  final FlutterSecureStorage _storage;

  @override
  Future<void> clear() async {
    _sessionFallback = null;
    try {
      await _storage.delete(key: _sessionKey);
    } on Object catch (error) {
      if (!_didLogClearFallbackWarning) {
        _didLogClearFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session clear failed: $error',
        );
      }
    }
  }

  @override
  Future<GroupListeningStoredSession?> read() async {
    try {
      final rawValue = await _storage.read(key: _sessionKey);
      if (rawValue == null || rawValue.trim().isEmpty) {
        return _sessionFallback;
      }
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Stored session payload must be an object.',
        );
      }
      final session = storedSessionFromJson(decoded);
      _sessionFallback = session;
      return session;
    } on Object catch (error) {
      if (!_didLogReadFallbackWarning) {
        _didLogReadFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session read failed; using session fallback: '
          '$error',
        );
      }
      return _sessionFallback;
    }
  }

  @override
  Future<void> save(GroupListeningStoredSession session) async {
    _sessionFallback = session;
    final encoded = jsonEncode(storedSessionToJson(session));
    try {
      await _storage.write(key: _sessionKey, value: encoded);
    } on Object catch (error) {
      if (!_didLogSaveFallbackWarning) {
        _didLogSaveFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session save failed; using session fallback: '
          '$error',
        );
      }
    }
  }
}
