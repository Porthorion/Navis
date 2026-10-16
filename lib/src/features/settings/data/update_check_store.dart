import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists update-check timing, the last verified update, and the last
/// update announced in Library.
class UpdateCheckStore {
  new({this._throttle = const Duration(hours: 1), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const _fileName = 'update_check_state.json';

  final Duration _throttle;
  final DateTime Function() _now;
  Future<void> _writes = Future<void>.value();

  Future<bool> shouldCheck({bool force = false}) async {
    if (force) {
      return true;
    }
    final lastCheck = await readLastCheckAt();
    if (lastCheck == null) {
      return true;
    }
    return _now().difference(lastCheck) >= _throttle;
  }

  Future<DateTime?> readLastCheckAt() async {
    final raw = (await _readState())['lastCheckAt'];
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  /// Reads the version and build key last announced by a Library pull.
  Future<String?> readNotifiedVersion() async {
    final raw = (await _readState())['notifiedVersion'];
    return raw is String ? raw : null;
  }

  /// Reads the last verified update, or null when none is stored.
  Future<Map<String, Object?>?> readVerifiedUpdate() async {
    final raw = (await _readState())['verifiedUpdate'];
    return raw is Map<String, Object?> ? raw : null;
  }

  Future<void> recordCheck([DateTime? checkedAt]) =>
      _mergeState('lastCheckAt', (checkedAt ?? _now()).toIso8601String());

  /// Records a notice without changing the last manifest-fetch timestamp.
  Future<void> recordNotifiedVersion(String version) =>
      _mergeState('notifiedVersion', version);

  /// Stores the last update a completed manifest fetch verified, so a
  /// throttled check can keep showing it.
  Future<void> recordVerifiedUpdate(Map<String, Object?> value) =>
      _mergeState('verifiedUpdate', value);

  Future<void> clearVerifiedUpdate() => _mergeState('verifiedUpdate', null);

  Future<void> _mergeState(String key, Object? value) {
    final write = _writes.then((_) async {
      final state = await _readState();
      if (value == null) {
        state.remove(key);
      } else {
        state[key] = value;
      }
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state));
    });
    _writes = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return write;
  }

  Future<Map<String, dynamic>> _readState() async {
    final file = await _stateFile();
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }

  Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }
}
