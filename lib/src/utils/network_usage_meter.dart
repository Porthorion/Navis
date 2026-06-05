import 'dart:async';

import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

typedef NetworkUsageReporter =
    void Function({required NetworkUsageCategory category, required int bytes});

enum NetworkUsageCategory {
  audioStream('audio_stream'),
  download('download'),
  coverArt('cover_art'),
  librarySync('library_sync'),
  lyrics('lyrics'),
  scrobble('scrobble'),
  recommendations('recommendations'),
  updates('updates'),
  otherApi('other_api')
  ;

  const NetworkUsageCategory(this.key);

  final String key;
}

class NetworkUsageSessionTotal {
  const NetworkUsageSessionTotal({
    required this.category,
    required this.networkType,
    required this.bytes,
    required this.requestCount,
  });

  final String category;
  final String networkType;
  final int bytes;
  final int requestCount;
}

class NetworkUsageMeter {
  NetworkUsageMeter({
    required NetworkUsageDao dao,
    required NetworkType Function() readNetworkType,
    DateTime Function()? now,
  }) : _dao = dao,
       _readNetworkType = readNetworkType,
       _now = now ?? DateTime.now;

  static const retention = Duration(days: 30);

  final NetworkUsageDao _dao;
  final NetworkType Function() _readNetworkType;
  final DateTime Function() _now;
  final Map<String, ({int bytes, int requests})> _sessionTotals = {};

  List<NetworkUsageSessionTotal> get sessionTotals {
    return _sessionTotals.entries
        .map((entry) {
          final parts = entry.key.split('|');
          return NetworkUsageSessionTotal(
            category: parts.first,
            networkType: parts.length > 1 ? parts[1] : NetworkType.other.name,
            bytes: entry.value.bytes,
            requestCount: entry.value.requests,
          );
        })
        .toList(growable: false)
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
  }

  void record({
    required NetworkUsageCategory category,
    required int bytes,
    int requestCount = 1,
    NetworkType? networkType,
  }) {
    if (bytes <= 0 && requestCount <= 0) {
      return;
    }
    final resolvedNetwork = networkType ?? _readNetworkType();
    final key = '${category.key}|${resolvedNetwork.name}';
    final existing = _sessionTotals[key] ?? (bytes: 0, requests: 0);
    _sessionTotals[key] = (
      bytes: existing.bytes + (bytes < 0 ? 0 : bytes),
      requests: existing.requests + (requestCount < 1 ? 1 : requestCount),
    );
    unawaited(
      _dao
          .recordUsage(
            category: category.key,
            networkType: resolvedNetwork.name,
            bytes: bytes,
            requestCount: requestCount,
            occurredAt: _now(),
          )
          .catchError((Object error, StackTrace stackTrace) {
            AppLogger.debug(
              'Network usage record failed: $error\n$stackTrace',
            );
          }),
    );
  }

  Future<void> pruneOld() {
    return _dao.pruneOlderThan(_now().subtract(retention));
  }

  Future<void> clearAll() async {
    _sessionTotals.clear();
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
    case '/rest/getGenres.view':
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
