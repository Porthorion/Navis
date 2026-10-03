import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/player/data/system_media_art.dart'
    show imageExtensionForBytes;
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Cover art kept for as long as a permanent download uses it.
///
/// The cover art caches are disposable: they live in the temporary directory,
/// expire after 30 days unseen, and every cache reset empties them. A
/// downloaded song must still show its cover offline, in the app and on the
/// system media controls (Bluetooth/AVRCP, Android Auto, MPRIS, SMTC). This
/// store keeps one copy of each downloaded cover in Navis-owned app support
/// storage, never in the user's download folder, so it is never an import or
/// manual-matching candidate there.
///
/// Files are `<support>/artwork/permanent/<key>.<ext>`, with the extension
/// taken from the image bytes. Writes go through a part file and a rename, and
/// payloads without an image signature are never stored.
class PermanentArtworkStore {
  new({
    Future<Directory> Function()? readApplicationSupportDirectory,
    Dio? dio,
    this._reportNetworkUsage,
  }) : _readApplicationSupportDirectory =
           readApplicationSupportDirectory ?? getApplicationSupportDirectory,
       _dio = dio ?? Dio();

  /// One size serves every in-app use (Now Playing is the largest, 768) and
  /// the system media controls.
  static const int artworkSize = 768;

  static const String _partSuffix = '.navis-part';

  final Future<Directory> Function() _readApplicationSupportDirectory;
  final Dio _dio;
  final NetworkUsageReporter? _reportNetworkUsage;

  /// coverArtId key → stored file path, loaded once from disk.
  Map<String, String>? _index;
  Future<Map<String, String>>? _indexLoad;
  final Map<String, Future<bool>> _pending = <String, Future<bool>>{};

  /// The file-name key of [coverArtId]. Matches the system art cache keys.
  static String keyFor(String coverArtId) =>
      coverArtId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  Future<Directory> _root() async {
    final support = await _readApplicationSupportDirectory();
    return Directory(p.join(support.path, 'artwork', 'permanent'));
  }

  Future<Map<String, String>> _loadIndex() {
    if (_index case final index?) return Future.value(index);
    return _indexLoad ??= () async {
      final index = <String, String>{};
      try {
        final root = await _root();
        // Keep metadata access asynchronous so storage latency cannot stall UI.
        // ignore: avoid_slow_async_io
        if (await root.exists()) {
          await for (final entity in root.list(followLinks: false)) {
            if (entity is! File || entity.path.endsWith(_partSuffix)) continue;
            index[p.basenameWithoutExtension(entity.path)] = entity.path;
          }
        }
      } on Object catch (error) {
        // An unreadable store only means covers come from the network.
        AppLogger.warning('PermanentArtworkStore: index load failed: $error');
      }
      _index = index;
      _indexLoad = null;
      return index;
    }();
  }

  /// The stored cover for [coverArtId], or null.
  Future<File?> fileFor(String? coverArtId) async {
    final id = coverArtId?.trim();
    if (id == null || id.isEmpty) return null;
    final path = (await _loadIndex())[keyFor(id)];
    return path == null ? null : File(path);
  }

  /// The stored cover for [coverArtId] when the index is already loaded,
  /// without waiting; null when it is not stored or not loaded yet.
  File? loadedFileFor(String? coverArtId) {
    final id = coverArtId?.trim();
    if (id == null || id.isEmpty) return null;
    final path = _index?[keyFor(id)];
    return path == null ? null : File(path);
  }

  /// Number of stored covers.
  Future<int> count() async => (await _loadIndex()).length;

  /// Stores [coverArtId]'s cover unless it is already stored. Returns whether
  /// the cover is stored afterwards. Never throws.
  Future<bool> ensure(String? coverArtId, SubsonicApiClient api) {
    final id = coverArtId?.trim();
    if (id == null || id.isEmpty) return Future.value(false);
    final key = keyFor(id);
    return _pending[key] ??= _ensure(id, key, api).whenComplete(() {
      // A block body: returning the removed future would make this future
      // wait for itself.
      _pending.remove(key);
    });
  }

  Future<bool> _ensure(String id, String key, SubsonicApiClient api) async {
    final index = await _loadIndex();
    if (index.containsKey(key)) return true;
    File? part;
    try {
      final response = await _dio.getUri<List<int>>(
        api.getCoverArtUrl(id: id, size: artworkSize),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      final extension = bytes == null ? null : imageExtensionForBytes(bytes);
      if (bytes == null || extension == null) {
        AppLogger.warning(
          'PermanentArtworkStore: no image returned for cover $id',
        );
        return false;
      }
      final root = await _root();
      await root.create(recursive: true);
      final target = File(p.join(root.path, '$key$extension'));
      part = File('${target.path}$_partSuffix');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      part = null;
      index[key] = target.path;
      _reportNetworkUsage?.call(
        category: NetworkUsageCategory.coverArt,
        bytes: bytes.length,
      );
      return true;
    } on Object catch (error) {
      AppLogger.warning(
        'PermanentArtworkStore: cover $id not stored: ${error.runtimeType}',
      );
      return false;
    } finally {
      if (part != null) await tryDeleteFile(part);
    }
  }

  /// Deletes every stored cover whose id is not in [keepCoverArtIds].
  Future<void> prune(Iterable<String> keepCoverArtIds) async {
    final keep = {for (final id in keepCoverArtIds) keyFor(id.trim())};
    final index = await _loadIndex();
    for (final entry in index.entries.toList(growable: false)) {
      if (keep.contains(entry.key) || _pending.containsKey(entry.key)) {
        continue;
      }
      await tryDeleteFile(File(entry.value));
      index.remove(entry.key);
    }
  }

  /// Deletes every stored cover, for a server data reset or when all
  /// permanent downloads are cleared.
  Future<void> clear() => prune(const <String>[]);
}
