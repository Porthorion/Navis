import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart'
    show kMaxArtworkResponseBytes;
import 'package:navis/src/features/player/data/system_media_art.dart'
    show imageExtensionForBytes;
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Outcome of checking and retaining a server cover.
enum ArtworkEnsureResult {
  stored,
  alreadyPresent,
  serverMissing,
  failed;

  bool get isStored => this == stored || this == alreadyPresent;
}

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

  // ponytail: placeholder hashes cover only this probed Navidrome image;
  // verify additional server placeholders before extending detection.
  static const String _navidromeMissingCoverSha256 =
      '273a4dbd61dfbb0a12d5d8ffe780eb7a3d4d000bc9771c5411cc70ae4dfa8a1f';

  final Future<Directory> Function() _readApplicationSupportDirectory;
  final Dio _dio;
  final NetworkUsageReporter? _reportNetworkUsage;

  /// coverArtId key → stored file path, loaded once from disk.
  Map<String, String>? _index;
  Future<Map<String, String>>? _indexLoad;
  final Map<String, Future<ArtworkEnsureResult>> _pending = {};

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
    if (path == null) return null;
    final file = File(path);
    try {
      // Slow storage must not block the UI while checking a warm index.
      // ignore: avoid_slow_async_io
      if (await file.exists()) return file;
      _index?.remove(keyFor(id));
    } on Object catch (error) {
      AppLogger.warning(
        'PermanentArtworkStore: file check failed: ${error.runtimeType}',
      );
    }
    return null;
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
  Future<bool> ensure(String? coverArtId, SubsonicApiClient api) async =>
      (await ensureWithResult(coverArtId, api)).isStored;

  /// Distinguishes server absence from failures that should be retried later.
  Future<ArtworkEnsureResult> ensureWithResult(
    String? coverArtId,
    SubsonicApiClient api,
  ) {
    final id = coverArtId?.trim();
    if (id == null || id.isEmpty) {
      return Future.value(ArtworkEnsureResult.serverMissing);
    }
    final key = keyFor(id);
    return _pending[key] ??= _ensure(id, api).whenComplete(() {
      unawaited(_pending.remove(key));
    });
  }

  Future<ArtworkEnsureResult> _ensure(String id, SubsonicApiClient api) async {
    try {
      if (await fileFor(id) != null) return ArtworkEnsureResult.alreadyPresent;
      final response = await _dio.getUri<List<int>>(
        api.getCoverArtUrl(id: id, size: artworkSize),
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'User-Agent': AppConstants.userAgent},
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return ArtworkEnsureResult.failed;
      }
      _reportNetworkUsage?.call(
        category: NetworkUsageCategory.coverArt,
        bytes: bytes.length,
      );
      if (bytes.length > kMaxArtworkResponseBytes) {
        return ArtworkEnsureResult.failed;
      }
      if (sha256.convert(bytes).toString() == _navidromeMissingCoverSha256) {
        return ArtworkEnsureResult.serverMissing;
      }
      if (looksLikeSubsonicErrorDocument(bytes)) {
        // A successful HTTP response may still carry Subsonic's missing-cover error.
        final document = String.fromCharCodes(bytes);
        return RegExp(r'''code[=\s:"']+70\b''').hasMatch(document)
            ? ArtworkEnsureResult.serverMissing
            : ArtworkEnsureResult.failed;
      }
      return await _writeBytes(id, bytes)
          ? ArtworkEnsureResult.stored
          : ArtworkEnsureResult.failed;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404 ||
          error.response?.statusCode == 410) {
        return ArtworkEnsureResult.serverMissing;
      }
      AppLogger.warning(
        'PermanentArtworkStore: cover $id not fetched: ${error.type}',
      );
      return ArtworkEnsureResult.failed;
    } on Object catch (error) {
      AppLogger.warning(
        'PermanentArtworkStore: cover $id not fetched: ${error.runtimeType}',
      );
      return ArtworkEnsureResult.failed;
    }
  }

  /// Stores validated external artwork under its server cover key.
  ///
  /// Never throws.
  Future<bool> storeBytes(String coverArtId, List<int> bytes) async {
    final id = coverArtId.trim();
    if (id.isEmpty || bytes.length > kMaxArtworkResponseBytes) return false;
    final key = keyFor(id);
    final pending = _pending[key];
    if (pending != null) await pending;
    return await (_pending[key] ??=
            () async {
              if (await fileFor(id) != null) {
                return ArtworkEnsureResult.alreadyPresent;
              }
              return await _writeBytes(id, bytes)
                  ? ArtworkEnsureResult.stored
                  : ArtworkEnsureResult.failed;
            }().whenComplete(() {
              unawaited(_pending.remove(key));
            }))
        .then((result) => result.isStored);
  }

  Future<bool> _writeBytes(String id, List<int> bytes) async {
    if (bytes.length > kMaxArtworkResponseBytes) return false;
    File? part;
    try {
      final extension = imageExtensionForBytes(bytes);
      if (extension == null) return false;
      final index = await _loadIndex();
      final root = await _root();
      await root.create(recursive: true);
      final key = keyFor(id);
      final target = File(p.join(root.path, '$key$extension'));
      part = File('${target.path}$_partSuffix');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      part = null;
      index[key] = target.path;
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
