import 'dart:async';

import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

typedef NetworkUsageReporter = void Function({
  required NetworkUsageCategory category,
  required int bytes,
  String? operation,
});

enum NetworkUsageCategory {
  audioStream('audio_stream'),
  download('download'),
  coverArt('cover_art'),
  librarySync('library_sync'),
  lyrics('lyrics'),
  scrobble('scrobble'),
  recommendations('recommendations'),
  updates('updates'),
  otherApi('other_api');

  new(this.key);

  final String key;
}

class NetworkUsageMeter {
  new({
    required this._dao,
    required this._readNetworkType,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const retention = Duration(days: 30);

  /// Records are aggregated in memory and written at most this often. Every
  /// HTTP request used to insert its own row, which during a sync meant
  /// thousands of fenced commits on the database writer.
  static const flushInterval = Duration(seconds: 5);
  static const _maxBufferedKeys = 64;

  final NetworkUsageDao _dao;
  final NetworkType Function() _readNetworkType;
  final DateTime Function() _now;
  final Map<
    ({String category, String? operation, String networkType}),
    ({int bytes, int requests})
  >
  _buffered = {};
  Timer? _flushTimer;

  void record({
    required NetworkUsageCategory category,
    required int bytes,
    String? operation,
    int requestCount = 1,
    NetworkType? networkType,
  }) {
    if (bytes <= 0 && requestCount <= 0) {
      return;
    }
    final resolvedNetwork = networkType ?? _readNetworkType();
    final bufferKey = (
      category: category.key,
      operation: operation,
      networkType: resolvedNetwork.name,
    );
    final buffered = _buffered[bufferKey] ?? (bytes: 0, requests: 0);
    _buffered[bufferKey] = (
      bytes: buffered.bytes + bytes,
      requests: buffered.requests + requestCount,
    );
    if (_buffered.length >= _maxBufferedKeys) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(flushInterval, () => unawaited(flush()));
    }
  }

  /// Writes the aggregated records now. Called periodically and on disposal.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffered.isEmpty) return;
    final entries = _buffered.entries.toList(growable: false);
    _buffered.clear();
    final occurredAt = _now();
    for (final entry in entries) {
      try {
        await _dao.recordUsage(
          category: entry.key.category,
          operation: entry.key.operation,
          networkType: entry.key.networkType,
          bytes: entry.value.bytes,
          requestCount: entry.value.requests,
          occurredAt: occurredAt,
        );
      } on Object catch (error, stackTrace) {
        AppLogger.debug('Network usage record failed: $error\n$stackTrace');
      }
    }
  }

  void dispose() {
    unawaited(flush());
  }

  Future<void> pruneOld() {
    return _dao.pruneOlderThan(_now().subtract(retention));
  }

  Future<void> clearAll() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _buffered.clear();
    await _dao.clearAll();
  }
}

NetworkUsageCategory networkUsageCategoryForSubsonicPath(String path) {
  switch (path) {
    case '/rest/getAlbum.view':
    case '/rest/getArtist.view':
    case '/rest/getArtists.view':
    case '/rest/getAlbumList2.view':
    case '/rest/getIndexes.view':
    case '/rest/getStarred2.view':
    case '/rest/search3.view':
    case '/rest/getPlaylists.view':
    case '/rest/getPlaylist.view':
    case '/rest/getAlbumInfo2.view':
    case '/rest/getArtistInfo2.view':
      return NetworkUsageCategory.librarySync;
    case '/rest/getLyricsBySongId.view':
    case '/rest/getLyrics.view':
      return NetworkUsageCategory.lyrics;
    case '/rest/scrobble.view':
      return NetworkUsageCategory.scrobble;
    case '/rest/getRandomSongs.view':
    case '/rest/getSimilarSongs.view':
    case '/rest/getSimilarSongs2.view':
      return NetworkUsageCategory.recommendations;
    default:
      return NetworkUsageCategory.otherApi;
  }
}
