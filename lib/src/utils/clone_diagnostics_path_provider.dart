import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Resolves a desktop clone diagnostics run's per-user directories inside its
/// isolated root.
///
/// A clone copies a real profile but runs as the same OS user, so the
/// platform directories would otherwise be the real app's: the clone would
/// read and overwrite its What's New marker, window geometry, update-check
/// state and image-cache indexes, and its startup cache maintenance would
/// prune the real rolling cache. Replacing the platform implementation also
/// covers plugins that resolve these directories themselves, such as
/// flutter_cache_manager, without changing the XDG variables that fonts,
/// themes and the desktop session rely on.
class CloneDiagnosticsPathProvider extends PathProviderPlatform {
  new({required String root, required this._platform})
    : _root = p.normalize(p.absolute(root));

  final String _root;
  final PathProviderPlatform _platform;

  /// Shares `<root>/cache` with the clone's rolling cache, so startup cache
  /// maintenance scans the clone's own audio files.
  @override
  Future<String?> getTemporaryPath() => _directory('cache');

  /// `<root>/support` is also the clone's default download root.
  @override
  Future<String?> getApplicationSupportPath() => _directory('support');

  @override
  Future<String?> getApplicationCachePath() => _directory('cache');

  /// Keeps an accidental default database open away from the real profile.
  @override
  Future<String?> getApplicationDocumentsPath() => _directory('documents');

  @override
  Future<String?> getLibraryPath() => _directory('library');

  @override
  Future<String?> getDownloadsPath() => _directory('downloads');

  // Desktop platforms have no external storage; keep their own answer.
  @override
  Future<String?> getExternalStoragePath() =>
      _platform.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _platform.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _platform.getExternalStoragePaths(type: type);

  Future<String> _directory(String name) async {
    final directory = Directory(p.join(_root, name));
    await directory.create(recursive: true);
    return directory.path;
  }
}
