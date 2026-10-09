import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists the timestamp of the last successful update manifest fetch.
class UpdateCheckStore {
  new({this._throttle = const Duration(hours: 24), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const _fileName = 'update_check_state.json';

  final Duration _throttle;
  final DateTime Function() _now;

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
    final file = await _stateFile();
    if (!file.existsSync()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final raw = decoded['lastCheckAt']?.toString();
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return DateTime.tryParse(raw);
    } on Object {
      return null;
    }
  }

  Future<void> recordCheck([DateTime? checkedAt]) async {
    final file = await _stateFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, String>{
        'lastCheckAt': (checkedAt ?? _now()).toIso8601String(),
      }),
    );
  }

  Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }
}
