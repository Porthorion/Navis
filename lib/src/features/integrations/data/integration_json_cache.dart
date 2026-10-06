import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:navis/src/utils/app_logger.dart';

/// A value read from [IntegrationJsonCache].
class IntegrationCacheHit {
  const new({required this.value, required this.storedAt});

  /// The JSON value as written; may be null when null was cached (for
  /// example "this artist is not on Deezer").
  final Object? value;
  final DateTime storedAt;
}

/// Disk cache for responses of external services, one JSON file per entry.
///
/// Entries live in `<root>/integration_cache/<namespace>/<hash>.json`, where
/// the root is the application support directory unless a test injects one.
/// Clone diagnostics stay isolated because they replace the
/// `path_provider` platform, which this resolves through. Each entry stores
/// its key, so a hash collision reads as a miss, and its own expiry, so one
/// namespace can keep entries for different times ("artist found" for 30
/// days, "not found" for 7). Failures are logged and read as a miss; the
/// caller then asks the service again.
class IntegrationJsonCache {
  new({
    Future<Directory> Function()? readRootDirectory,
    DateTime Function()? now,
  }) : _readRootDirectory = readRootDirectory ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  static const directoryName = 'integration_cache';
  static final _namespacePattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  final Future<Directory> Function() _readRootDirectory;
  final DateTime Function() _now;
  var _tempCounter = 0;
  Future<Directory>? _root;

  /// The entry for [key], or null when it is absent, expired or unreadable.
  Future<IntegrationCacheHit?> read(String namespace, String key) async {
    try {
      final file = await _file(namespace, key);
      // Keep filesystem checks off the UI isolate during cache operations.
      // ignore: avoid_slow_async_io
      if (!(await file.exists())) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic> || json['key'] != key) return null;
      final storedAt = DateTime.tryParse(json['storedAt'] as String? ?? '');
      final expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '');
      if (storedAt == null || expiresAt == null) return null;
      if (!_now().isBefore(expiresAt)) return null;
      return IntegrationCacheHit(value: json['value'], storedAt: storedAt);
    } on Object catch (error) {
      AppLogger.debug(
        'IntegrationJsonCache: read failed in $namespace: $error',
      );
      return null;
    }
  }

  /// Stores [value] (anything `jsonEncode` accepts) for [ttl].
  Future<void> write(
    String namespace,
    String key,
    Object? value, {
    required Duration ttl,
  }) async {
    try {
      final file = await _file(namespace, key);
      await file.parent.create(recursive: true);
      final now = _now();
      final encoded = jsonEncode(<String, Object?>{
        'key': key,
        'storedAt': now.toUtc().toIso8601String(),
        'expiresAt': now.add(ttl).toUtc().toIso8601String(),
        'value': value,
      });
      // Write then rename, so a reader never sees half a file.
      final temp = File('${file.path}.${pid}_${_tempCounter++}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
    } on Object catch (error) {
      AppLogger.debug(
        'IntegrationJsonCache: write failed in $namespace: $error',
      );
    }
  }

  Future<void> remove(String namespace, String key) async {
    try {
      final file = await _file(namespace, key);
      // Keep filesystem checks off the UI isolate during cache operations.
      // ignore: avoid_slow_async_io
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      AppLogger.debug(
        'IntegrationJsonCache: remove failed in $namespace: $error',
      );
    }
  }

  /// Deletes every entry of [namespace].
  Future<void> clearNamespace(String namespace) async {
    try {
      final directory = await _namespaceDirectory(namespace);
      // Keep filesystem checks off the UI isolate during cache operations.
      // ignore: avoid_slow_async_io
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object catch (error) {
      AppLogger.debug(
        'IntegrationJsonCache: clear failed in $namespace: $error',
      );
    }
  }

  Future<Directory> _namespaceDirectory(String namespace) async {
    if (!_namespacePattern.hasMatch(namespace)) {
      throw ArgumentError.value(namespace, 'namespace');
    }
    final initialization = _root ??= _initializeRoot();
    try {
      final root = await initialization;
      return Directory(p.join(root.path, directoryName, namespace));
    } on Object {
      // A late failure from another caller must not clear a newer retry.
      if (identical(_root, initialization)) _root = null;
      rethrow;
    }
  }

  Future<Directory> _initializeRoot() async {
    final root = await _readRootDirectory();
    try {
      // Initialization must not block the UI isolate either.
      // ignore: avoid_slow_async_io
      if (await root.exists()) {
        final legacyName = RegExp(r'^lastfm_top_[0-9a-f]{16}\.json$');
        await for (final entry in root.list(followLinks: false)) {
          if (entry is File && legacyName.hasMatch(p.basename(entry.path))) {
            try {
              await entry.delete();
            } on FileSystemException catch (error) {
              AppLogger.debug(
                'IntegrationJsonCache: legacy entry cleanup failed: $error',
              );
            }
          }
        }
      }
    } on FileSystemException catch (error) {
      AppLogger.debug('IntegrationJsonCache: legacy cleanup failed: $error');
    }
    return root;
  }

  Future<File> _file(String namespace, String key) async {
    final directory = await _namespaceDirectory(namespace);
    final hash = sha256.convert(utf8.encode(key)).toString().substring(0, 24);
    return File(p.join(directory.path, '$hash.json'));
  }
}
