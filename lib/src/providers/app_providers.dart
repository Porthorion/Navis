import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/utils/connectivity.dart';

final navisDatabaseProvider = Provider<NavisDatabase>((ref) {
  final database = NavisDatabase();
  ref.onDispose(database.close);
  return database;
});

final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  final connectivity = Connectivity();
  return connectivity.onConnectivityChanged;
});

final networkTypeProvider = Provider<NetworkType>((ref) {
  final connectivity = ref.watch(connectivityProvider);
  return resolveNetworkType(
    connectivity.asData?.value ?? const <ConnectivityResult>[],
  );
});

class StreamingQuality {
  const StreamingQuality({required this.label, this.maxBitRate});

  final String label;
  final int? maxBitRate;
}

final activeStreamingQualityProvider = Provider<StreamingQuality>((ref) {
  final networkType = ref.watch(networkTypeProvider);
  return switch (networkType) {
    NetworkType.wifi => const StreamingQuality(label: 'wifi-original'),
    NetworkType.cellular => const StreamingQuality(
      label: 'cellular-320k',
      maxBitRate: 320,
    ),
    NetworkType.offline || NetworkType.other => const StreamingQuality(
      label: 'auto-original',
    ),
  };
});

final subsonicApiProvider = Provider<SubsonicApiClient?>((ref) {
  final config = ref.watch(serverConfigStateProvider).asData?.value;
  if (config == null) {
    return null;
  }

  final authType = config.useLegacyAuth
      ? SubsonicAuthType.legacyPassword
      : SubsonicAuthType.token;

  return SubsonicApiClient(
    baseUrl: config.url,
    authConfig: SubsonicAuthConfig(
      username: config.username,
      password: config.password,
      apiVersion: config.apiVersion,
      authType: authType,
    ),
  );
});

class AlbumWithSongs {
  const AlbumWithSongs({required this.album, required this.songs});

  final AlbumsTableData album;
  final List<SongsTableData> songs;
}

final artistsProvider = StreamProvider<List<ArtistsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchArtists();
});

final albumProvider = StreamProvider.family<AlbumWithSongs?, String>((
  ref,
  albumId,
) async* {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  await for (final album in dao.watchAlbumById(albumId)) {
    if (album == null) {
      yield null;
      continue;
    }

    final songs = await dao.watchSongsByAlbum(albumId).first;
    yield AlbumWithSongs(album: album, songs: songs);
  }
});

final albumListProvider = StreamProvider.family<List<AlbumsTableData>, String>((
  ref,
  type,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAllAlbums();
});

final searchResultsProvider = FutureProvider.family<SearchResult3, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) {
    return const SearchResult3();
  }

  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const SearchResult3();
  }

  return api.search3(query: query);
});

final playerStateProvider = Provider<String>((_) => 'idle');

class QueueController extends Notifier<List<String>> {
  @override
  List<String> build() => const <String>[];

  void replace(List<String> ids) => state = List<String>.unmodifiable(ids);

  void add(String id) =>
      state = List<String>.unmodifiable(<String>[...state, id]);

  void clear() => state = const <String>[];
}

final queueProvider = NotifierProvider<QueueController, List<String>>(
  QueueController.new,
);

final lyricsProvider = FutureProvider.family<LyricsList, String>((
  ref,
  songId,
) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const LyricsList();
  }
  return api.getLyricsBySongId(songId);
});

final downloadProgressProvider = StreamProvider.family<double?, String>((
  ref,
  songId,
) {
  final dao = ref.watch(navisDatabaseProvider).downloadQueueDao;
  return dao.watchQueue().map((items) {
    for (final item in items) {
      if (item.songId == songId) {
        return item.progress;
      }
    }
    return null;
  });
});

final downloadQueueProvider = StreamProvider<List<DownloadQueueTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).downloadQueueDao;
  return dao.watchQueue();
});

class CacheStats {
  const CacheStats({required this.trackCount, required this.totalBytes});

  final int trackCount;
  final int totalBytes;
}

final rollingCacheStatsProvider = StreamProvider<CacheStats>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao.watchCachedTracks().map((tracks) {
    final filtered = tracks
        .where((track) => track.cacheType == CacheType.rolling)
        .toList();
    final total = filtered.fold<int>(0, (sum, item) => sum + item.fileSize);
    return CacheStats(trackCount: filtered.length, totalBytes: total);
  });
});

final permanentCacheStatsProvider = StreamProvider<CacheStats>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao.watchCachedTracks().map((tracks) {
    final filtered = tracks
        .where((track) => track.cacheType == CacheType.permanent)
        .toList();
    final total = filtered.fold<int>(0, (sum, item) => sum + item.fileSize);
    return CacheStats(trackCount: filtered.length, totalBytes: total);
  });
});

final savePlayQueueProvider = Provider<Future<void> Function(List<String>)>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).playQueueDao;
  return (songIds) async {
    await dao.saveQueue(songIds: songIds);
  };
});

final connectivityHintProvider = Provider<String>((ref) {
  final network = ref.watch(networkTypeProvider);
  return network.name;
});

final serverReachabilityProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return false;
  }

  try {
    await api.ping();
    return true;
  } on Object {
    return false;
  }
});

Future<void> seedDefaultServerConfig(Ref ref) async {
  final notifier = ref.read(serverConfigProvider.notifier);
  await notifier.save(
    const ServerConfigModel(
      url: 'http://localhost:4533',
      username: 'demo',
      password: 'demo',
      apiVersion: '1.16.1',
    ),
  );
}
