import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';
import 'package:navis/src/utils/song_id_utils.dart';

enum HomeRandomShowcaseSource { likedDiscovery, serverRandom, localFallback }

abstract class HomeRandomShowcaseItem {
  const HomeRandomShowcaseItem();

  String get stableId;
}

class HomeRandomShowcaseAlbum extends HomeRandomShowcaseItem {
  const HomeRandomShowcaseAlbum({
    required this.id,
    required this.name,
    required this.source,
    this.artist,
    this.coverArtId,
    this.year,
    this.songCount,
  });

  factory HomeRandomShowcaseAlbum.fromServer(Album album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artist,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.serverRandom,
    );
  }

  factory HomeRandomShowcaseAlbum.fromLocal(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.localFallback,
    );
  }

  factory HomeRandomShowcaseAlbum.fromLocalDiscovery(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.likedDiscovery,
    );
  }

  factory HomeRandomShowcaseAlbum.fromSimilarSong(Song song) {
    final albumId = song.albumId?.trim();
    final albumName = song.album?.trim();
    return HomeRandomShowcaseAlbum(
      id: albumId ?? song.id,
      name: (albumName != null && albumName.isNotEmpty)
          ? albumName
          : song.title,
      artist: song.artist,
      coverArtId: song.coverArt,
      year: song.year,
      source: HomeRandomShowcaseSource.likedDiscovery,
    );
  }

  final String id;
  final String name;
  final String? artist;
  final String? coverArtId;
  final int? year;
  final int? songCount;
  final HomeRandomShowcaseSource source;

  @override
  String get stableId => 'album:$id';
}

class HomeRandomShowcaseListenBrainz extends HomeRandomShowcaseItem {
  factory HomeRandomShowcaseListenBrainz({
    required ListenBrainzDiscoverPlaylist playlist,
  }) {
    return HomeRandomShowcaseListenBrainz._(
      playlist: playlist,
      sourcePatch: playlist.playlist.sourcePatch,
      displayTitle: playlist.displayTitle,
      isLoading: playlist.recommendations.isEmpty && !playlist.matchingComplete,
    );
  }

  const HomeRandomShowcaseListenBrainz.loading({
    required this.sourcePatch,
    required this.displayTitle,
  }) : playlist = null,
       isLoading = true;

  const HomeRandomShowcaseListenBrainz._({
    required this.playlist,
    required this.sourcePatch,
    required this.displayTitle,
    required this.isLoading,
  });

  final ListenBrainzDiscoverPlaylist? playlist;
  final String? sourcePatch;
  final String displayTitle;
  final bool isLoading;

  @override
  String get stableId {
    final source = sourcePatch?.trim();
    if (source != null && source.isNotEmpty) {
      return 'listenbrainz:$source';
    }
    return 'listenbrainz:${playlist!.playlist.identifier}';
  }
}

const int _homeRandomShowcaseLimit = 12;
const int _homeRandomDiscoverySeedCount = 3;
const int _homeRandomDiscoveryMinLikedSongs = 5;
const int _homeRandomDiscoverySongCountPerSeed = 20;
const int _homeRandomDiscoveryMinResults = 6;
const Duration _homeRandomDiscoverySimilarSongTimeout = Duration(
  milliseconds: 1200,
);
const int _listenBrainzDiscoverTrackPreviewLimit = 35;
const int _listenBrainzDiscoverSearchSongCount = 8;
const int _listenBrainzDiscoverPlaylistDetailParallelism = 2;
const int _listenBrainzDiscoverSearchParallelism = 6;
const int _listenBrainzDiscoverAutomaticSearchParallelism = 2;
const int _listenBrainzDiscoverSearchEmitBatchSize = 6;
const Duration _listenBrainzDiscoverDefaultStartupIdleDelay = Duration(
  minutes: 2,
);
const double _listenBrainzDiscoverMinimumScore = 0.75;
const double _listenBrainzDiscoverMinimumFieldScore = 0.75;
const double _listenBrainzDiscoverAmbiguousDelta = 0.03;
const List<String> _listenBrainzShowcaseSourcePatches = <String>[
  'weekly-exploration',
  'weekly-jams',
];

List<ListenBrainzDiscoverPlaylist>? _listenBrainzDiscoverSessionCache;
List<ListenBrainzDiscoverPlaylist>? _listenBrainzDiscoverLastVisible;
int? _listenBrainzDiscoverSessionCacheEpoch;
String? _listenBrainzDiscoverSessionCacheKey;
final Map<String, ListenBrainzResolvedRecommendation>
_listenBrainzDiscoverMatchCache =
    <String, ListenBrainzResolvedRecommendation>{};

class _BoundedAsyncQueue {
  _BoundedAsyncQueue(this.maxConcurrent)
    : assert(maxConcurrent > 0, 'maxConcurrent must be positive');

  final int maxConcurrent;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await operation();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }
}

@visibleForTesting
void debugResetListenBrainzDiscoverSessionCacheForTests() {
  _listenBrainzDiscoverSessionCache = null;
  _listenBrainzDiscoverLastVisible = null;
  _listenBrainzDiscoverSessionCacheEpoch = null;
  _listenBrainzDiscoverSessionCacheKey = null;
  _listenBrainzDiscoverMatchCache.clear();
}

enum ListenBrainzRecommendationMatchStatus {
  pending,
  matched,
  unmatched,
  ambiguous,
}

class ListenBrainzResolvedRecommendation {
  const ListenBrainzResolvedRecommendation({
    required this.track,
    required this.status,
    this.song,
    this.tableSong,
  });

  final ListenBrainzPlaylistTrack track;
  final ListenBrainzRecommendationMatchStatus status;
  final Song? song;
  final SongsTableData? tableSong;

  bool get isPlayable =>
      status == ListenBrainzRecommendationMatchStatus.matched && song != null;

  bool get hasServerSong =>
      status == ListenBrainzRecommendationMatchStatus.matched &&
      tableSong != null &&
      isServerAddressableSongId(tableSong!.id) &&
      tableSong!.serverDeletedAt == null;

  ListenBrainzResolvedRecommendation copyWith({
    ListenBrainzPlaylistTrack? track,
    ListenBrainzRecommendationMatchStatus? status,
    Song? song,
    SongsTableData? tableSong,
  }) {
    return ListenBrainzResolvedRecommendation(
      track: track ?? this.track,
      status: status ?? this.status,
      song: song ?? this.song,
      tableSong: tableSong ?? this.tableSong,
    );
  }
}

class ListenBrainzDiscoverPlaylist {
  const ListenBrainzDiscoverPlaylist({
    required this.playlist,
    required this.recommendations,
    this.matchingComplete = false,
  });

  final ListenBrainzPlaylist playlist;
  final List<ListenBrainzResolvedRecommendation> recommendations;
  final bool matchingComplete;

  String get displayTitle => playlist.recommendationDisplayTitle;

  int get totalCount => recommendations.length;
  int get matchedCount => playableSongs.length;

  List<Song> get playableSongs => recommendations
      .where((recommendation) => recommendation.isPlayable)
      .map((recommendation) => recommendation.song!)
      .toList(growable: false);

  ListenBrainzDiscoverPlaylist copyWith({
    ListenBrainzPlaylist? playlist,
    List<ListenBrainzResolvedRecommendation>? recommendations,
    bool? matchingComplete,
  }) {
    return ListenBrainzDiscoverPlaylist(
      playlist: playlist ?? this.playlist,
      recommendations: recommendations ?? this.recommendations,
      matchingComplete: matchingComplete ?? this.matchingComplete,
    );
  }
}

class HomeRandomShowcaseShuffleSeedNotifier extends Notifier<int> {
  @override
  int build() => Random().nextInt(1 << 31);

  void reshuffle() {
    state = Random().nextInt(1 << 31);
  }
}

final homeRandomShowcaseShuffleSeedProvider =
    NotifierProvider<HomeRandomShowcaseShuffleSeedNotifier, int>(
      HomeRandomShowcaseShuffleSeedNotifier.new,
    );

class ListenBrainzDiscoverRefreshEpochNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void refresh() {
    state++;
  }
}

final listenBrainzDiscoverRefreshEpochProvider =
    NotifierProvider<ListenBrainzDiscoverRefreshEpochNotifier, int>(
      ListenBrainzDiscoverRefreshEpochNotifier.new,
    );

final listenBrainzDiscoverStartupIdleDelayProvider = Provider<Duration>(
  (_) => _listenBrainzDiscoverDefaultStartupIdleDelay,
);

final listenBrainzDiscoverStartupSyncStateProvider = Provider<LibrarySyncState>(
  (ref) {
    try {
      return ref.watch(librarySyncControllerProvider);
    } on Object {
      return const LibrarySyncState.idle();
    }
  },
);

final listenBrainzDiscoverStreamProvider =
    StreamProvider<List<ListenBrainzDiscoverPlaylist>>(
      _listenBrainzDiscoverStream,
    );

Stream<List<ListenBrainzDiscoverPlaylist>> _listenBrainzDiscoverStream(
  Ref ref,
) async* {
  final refreshEpoch = ref.watch(listenBrainzDiscoverRefreshEpochProvider);
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  final networkType = ref.watch(networkTypeProvider);
  final credentialStore = ref.read(externalScrobbleCredentialStoreProvider);
  final db = ref.read(navisDatabaseProvider);
  final cacheDao = db.cacheDao;
  final api = ref.read(subsonicApiProvider);
  final dao = db.libraryDao;
  final client = ref.read(listenBrainzApiClientProvider);
  final startupIdleDelay = ref.watch(
    listenBrainzDiscoverStartupIdleDelayProvider,
  );
  final syncState = ref.watch(listenBrainzDiscoverStartupSyncStateProvider);
  if (!settings.listenBrainzTokenValid) {
    AppLogger.debug(
      'ListenBrainz discover skipped: stored token is not marked valid.',
    );
    _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  final userName = settings.listenBrainzUserName?.trim();
  if (userName == null || userName.isEmpty) {
    AppLogger.debug(
      'ListenBrainz discover skipped: no validated ListenBrainz username.',
    );
    _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  final token = (await credentialStore.readListenBrainzToken())?.trim() ?? '';
  if (token.isEmpty) {
    AppLogger.debug(
      'ListenBrainz discover skipped: no stored ListenBrainz token.',
    );
    _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
    yield const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  final sessionKey = userName.toLowerCase();
  if (_listenBrainzDiscoverSessionCacheEpoch != refreshEpoch ||
      _listenBrainzDiscoverSessionCacheKey != sessionKey) {
    _listenBrainzDiscoverSessionCache = null;
    _listenBrainzDiscoverLastVisible = null;
    _listenBrainzDiscoverSessionCacheEpoch = refreshEpoch;
    _listenBrainzDiscoverSessionCacheKey = sessionKey;
    _listenBrainzDiscoverMatchCache.clear();
  }

  final persistentCached = refreshEpoch == 0
      ? await _loadListenBrainzWeeklyCache(
          cacheDao: cacheDao,
          userName: sessionKey,
        )
      : const <ListenBrainzDiscoverPlaylist>[];
  AppLogger.debug(
    'ListenBrainz discover weekly cache '
    '${persistentCached.isEmpty ? 'miss' : 'hit'}: count='
    '${persistentCached.length} sourcePatches='
    '${persistentCached.map((playlist) => playlist.playlist.sourcePatch ?? 'none').join(',')}.',
  );
  if (persistentCached.isNotEmpty) {
    _listenBrainzDiscoverLastVisible = persistentCached;
    yield persistentCached;
  }

  if (networkType == NetworkType.offline) {
    AppLogger.debug(
      'ListenBrainz discover offline: using cached playlists count='
      '${_listenBrainzDiscoverSessionCache?.length ?? persistentCached.length}.',
    );
    yield _listenBrainzDiscoverSessionCache ??
        (persistentCached.isNotEmpty ? persistentCached : null) ??
        const <ListenBrainzDiscoverPlaylist>[];
    return;
  }

  try {
    final cached = _listenBrainzDiscoverSessionCache;
    if (cached != null) {
      yield cached;
      return;
    }
    final normalStartup = refreshEpoch == 0;
    final automaticRefresh = normalStartup;
    if (persistentCached.isEmpty) {
      final loading = _listenBrainzLoadingDiscoverPlaylists();
      _listenBrainzDiscoverLastVisible = loading;
      AppLogger.debug(
        'ListenBrainz discover emitted weekly loading placeholders.',
      );
      yield loading;
    }

    if (automaticRefresh) {
      AppLogger.debug(
        'ListenBrainz discover background resolver scheduled: '
        'user=$sessionKey epoch=$refreshEpoch.',
      );
      await Future<void>.delayed(Duration.zero);
      if (!ref.mounted) {
        return;
      }
      final currentSyncState = ref.read(
        listenBrainzDiscoverStartupSyncStateProvider,
      );
      if (currentSyncState.status == LibrarySyncStatus.running ||
          syncState.status == LibrarySyncStatus.running) {
        final waitingState =
            currentSyncState.status == LibrarySyncStatus.running
            ? currentSyncState
            : syncState;
        _scheduleListenBrainzSyncGateFallbackLog(
          ref: ref,
          fallback: startupIdleDelay,
        );
        AppLogger.debug(
          'ListenBrainz discover waiting for startup sync: '
          'status=${waitingState.status.name} stage=${waitingState.stage.name}.',
        );
        return;
      }
      AppLogger.debug(
        'ListenBrainz discover sync gate opened: '
        'status=${currentSyncState.status.name} '
        'stage=${currentSyncState.stage.name}.',
      );
    } else {
      AppLogger.debug(
        'ListenBrainz discover manual refresh bypassed startup sync gate: '
        'epoch=$refreshEpoch.',
      );
    }

    await for (final visible in _resolveListenBrainzWeeklyPlaylists(
      ref: ref,
      client: client,
      api: api,
      dao: dao,
      cacheDao: cacheDao,
      userName: userName,
      sessionKey: sessionKey,
      token: token,
      cachedPlaylists: persistentCached,
      automaticRefresh: automaticRefresh,
    )) {
      yield visible;
    }
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      AppLogger.warning(
        'ListenBrainz discover disabled: token rejected with status=$status.',
      );
      await db.appSettingsDao.updateListenBrainzScrobblingState(
        enabled: false,
        tokenValid: false,
        clearUserName: true,
      );
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
    if (_listenBrainzDiscoverSessionCache != null) {
      AppLogger.debug(
        'ListenBrainz discover fetch failed: using cached playlists count='
        '${_listenBrainzDiscoverSessionCache!.length}.',
      );
      yield _listenBrainzDiscoverSessionCache!;
      return;
    }
    if (_listenBrainzDiscoverLastVisible != null) {
      yield _listenBrainzDiscoverLastVisible!;
      return;
    }
    rethrow;
  }
}

void _scheduleListenBrainzSyncGateFallbackLog({
  required Ref ref,
  required Duration fallback,
}) {
  if (fallback <= Duration.zero) {
    return;
  }
  final timer = Timer(fallback, () {
    if (!ref.mounted) {
      return;
    }
    final syncState = ref.read(listenBrainzDiscoverStartupSyncStateProvider);
    if (syncState.status != LibrarySyncStatus.running) {
      return;
    }
    AppLogger.debug(
      'ListenBrainz discover sync gate fallback elapsed; still deferring: '
      'status=${syncState.status.name} stage=${syncState.stage.name}.',
    );
  });
  ref.onDispose(timer.cancel);
}

Stream<List<ListenBrainzDiscoverPlaylist>> _resolveListenBrainzWeeklyPlaylists({
  required Ref ref,
  required ListenBrainzApiClient client,
  required SubsonicApiClient? api,
  required LibraryDao dao,
  required CacheDao cacheDao,
  required String userName,
  required String sessionKey,
  required String token,
  required List<ListenBrainzDiscoverPlaylist> cachedPlaylists,
  required bool automaticRefresh,
}) async* {
  var resolvedPlaylists = <ListenBrainzDiscoverPlaylist>[];
  final playlistMetadata = await _fetchListenBrainzPlaylistMetadata(
    client: client,
    userName: userName,
    token: token,
  );
  if (!ref.mounted) {
    return;
  }
  final targetMetadata = _selectListenBrainzShowcaseMetadata(
    playlistMetadata,
  );
  AppLogger.debug(
    'ListenBrainz discover metadata fetched count='
    '${playlistMetadata.length} selectedTargets=${targetMetadata.length}.',
  );
  final hasPersistentCache = cachedPlaylists.isNotEmpty;
  if (hasPersistentCache &&
      _listenBrainzMetadataMatchesCachedPlaylists(
        targetMetadata,
        cachedPlaylists,
      )) {
    final unresolvedCount = _listenBrainzUnresolvedRecommendationCount(
      cachedPlaylists,
    );
    AppLogger.debug(
      'ListenBrainz discover metadata check result=unchanged count='
      '${targetMetadata.length}.',
    );
    AppLogger.debug(
      'ListenBrainz discover cached unresolved rematch count=$unresolvedCount.',
    );
    if (unresolvedCount == 0) {
      _listenBrainzDiscoverSessionCache = cachedPlaylists;
      return;
    }
    resolvedPlaylists = cachedPlaylists;
  } else {
    if (hasPersistentCache) {
      AppLogger.debug(
        'ListenBrainz discover metadata check result=changed count='
        '${targetMetadata.length}.',
      );
    }
    if (targetMetadata.isEmpty) {
      AppLogger.debug(
        'ListenBrainz discover skipped: ListenBrainz returned no weekly '
        'recommendation playlists.',
      );
      _listenBrainzDiscoverLastVisible = const <ListenBrainzDiscoverPlaylist>[];
      _listenBrainzDiscoverSessionCache =
          const <ListenBrainzDiscoverPlaylist>[];
      await _saveListenBrainzWeeklyCache(
        cacheDao: cacheDao,
        userName: sessionKey,
        playlists: const <ListenBrainzDiscoverPlaylist>[],
      );
      yield const <ListenBrainzDiscoverPlaylist>[];
      return;
    }
    final detailQueue = _BoundedAsyncQueue(
      _listenBrainzDiscoverPlaylistDetailParallelism,
    );
    final detailResults = await Future.wait(
      targetMetadata.map(
        (metadata) => detailQueue.run(
          () => _fetchListenBrainzTargetDetail(
            client: client,
            metadata: metadata,
            token: token,
          ),
        ),
      ),
    );
    if (!ref.mounted) {
      return;
    }
    resolvedPlaylists = detailResults
        .whereType<ListenBrainzDiscoverPlaylist>()
        .toList(growable: false);
  }

  final localSongsSnapshot = await dao.getAllSongs();
  if (!ref.mounted) {
    return;
  }
  final localCandidates = _ListenBrainzLocalCandidateSnapshot.fromSongs(
    localSongsSnapshot,
  );
  final beforeLocalMatched = _listenBrainzMatchedRecommendationCount(
    resolvedPlaylists,
  );
  resolvedPlaylists = await Future.wait(
    resolvedPlaylists.map(
      (playlist) => _resolveListenBrainzTracksFromLocalSnapshot(
        playlist: playlist,
        localCandidates: localCandidates,
      ),
    ),
  );
  if (!ref.mounted) {
    return;
  }
  final afterLocalMatched = _listenBrainzMatchedRecommendationCount(
    resolvedPlaylists,
  );
  AppLogger.debug(
    'ListenBrainz discover local pass matched='
    '${afterLocalMatched - beforeLocalMatched} totalMatched=$afterLocalMatched.',
  );

  final unresolvedCount = _listenBrainzUnresolvedRecommendationCount(
    resolvedPlaylists,
  );
  if (unresolvedCount > 0) {
    final searchParallelism = automaticRefresh
        ? _listenBrainzDiscoverAutomaticSearchParallelism
        : _listenBrainzDiscoverSearchParallelism;
    AppLogger.debug(
      'ListenBrainz discover search3 start: '
      'unresolved=$unresolvedCount concurrency=$searchParallelism.',
    );
    await for (final updated in _resolveListenBrainzTrackSearchMisses(
      api: api,
      dao: dao,
      playlists: resolvedPlaylists,
      maxConcurrent: searchParallelism,
    )) {
      if (!ref.mounted) {
        return;
      }
      resolvedPlaylists = updated;
    }
    if (!ref.mounted) {
      return;
    }
  }

  resolvedPlaylists = resolvedPlaylists
      .map((playlist) => playlist.copyWith(matchingComplete: true))
      .toList(growable: false);
  for (final discoverPlaylist in resolvedPlaylists) {
    final matchedCount = discoverPlaylist.matchedCount;
    AppLogger.debug(
      'ListenBrainz discover target ready: '
      'sourcePatch="${discoverPlaylist.playlist.sourcePatch ?? 'unknown'}" '
      'title="${discoverPlaylist.playlist.title}" '
      'detailTracks=${discoverPlaylist.playlist.tracks.length} '
      'tracks=${discoverPlaylist.totalCount} matched=$matchedCount.',
    );
    if (matchedCount == 0) {
      AppLogger.debug(
        'ListenBrainz discover removed target: '
        'sourcePatch="${discoverPlaylist.playlist.sourcePatch ?? 'unknown'}" '
        'title="${discoverPlaylist.playlist.title}" reason=zero_matches.',
      );
    }
  }
  final visible = _visibleListenBrainzDiscoverPlaylists(resolvedPlaylists);
  _listenBrainzDiscoverLastVisible = visible;
  _listenBrainzDiscoverSessionCache = visible;
  await _saveListenBrainzWeeklyCache(
    cacheDao: cacheDao,
    userName: sessionKey,
    playlists: visible,
  );
  AppLogger.debug(
    'ListenBrainz discover weekly cache saved: matched='
    '${visible.fold<int>(0, (sum, playlist) => sum + playlist.matchedCount)} '
    'total=${visible.fold<int>(0, (sum, playlist) => sum + playlist.totalCount)}.',
  );
  yield visible;
}

final listenBrainzDiscoverProvider =
    FutureProvider<List<ListenBrainzDiscoverPlaylist>>((ref) async {
      var latest = const <ListenBrainzDiscoverPlaylist>[];
      await for (final value in _listenBrainzDiscoverStream(ref)) {
        latest = value;
      }
      return latest;
    });

Future<List<ListenBrainzPlaylist>> _fetchListenBrainzPlaylistMetadata({
  required ListenBrainzApiClient client,
  required String userName,
  required String token,
}) async {
  try {
    final recommendations = await client.getRecommendationPlaylists(
      userName: userName,
      userToken: token,
    );
    AppLogger.debug(
      'ListenBrainz discover recommendations fetched count='
      '${recommendations.length}.',
    );
    AppLogger.debug(
      'ListenBrainz discover recommendation sourcePatches='
      '${recommendations.map((playlist) => playlist.sourcePatch ?? 'none').toSet().join(',')}.',
    );
    return recommendations;
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      rethrow;
    }
    AppLogger.debug(
      'ListenBrainz discover recommendations fetch failed: '
      'status=${status ?? 'unknown'}.',
    );
  }

  return const <ListenBrainzPlaylist>[];
}

Future<ListenBrainzDiscoverPlaylist?> _fetchListenBrainzTargetDetail({
  required ListenBrainzApiClient client,
  required ListenBrainzPlaylist metadata,
  required String token,
}) async {
  final identifier = metadata.identifier.trim();
  if (identifier.isEmpty) {
    return null;
  }
  final ListenBrainzPlaylist playlistDetail;
  try {
    playlistDetail = await client.getPlaylist(
      identifier,
      fetchMetadata: true,
      userToken: token,
    );
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      rethrow;
    }
    AppLogger.debug(
      'ListenBrainz discover skipped target detail fetch: '
      'title="${metadata.title}" status=${status ?? 'unknown'}.',
    );
    return null;
  }

  final playlist = playlistDetail.copyWith(
    sourcePatch: playlistDetail.sourcePatch ?? metadata.sourcePatch,
  );
  final tracks = playlist.tracks
      .take(_listenBrainzDiscoverTrackPreviewLimit)
      .toList(growable: false);
  if (tracks.isEmpty) {
    AppLogger.debug(
      'ListenBrainz discover removed target: '
      'sourcePatch="${metadata.sourcePatch ?? 'unknown'}" '
      'title="${playlist.title}" reason=zero_tracks.',
    );
    return null;
  }

  return ListenBrainzDiscoverPlaylist(
    playlist: playlist,
    recommendations: tracks
        .map(
          (track) => ListenBrainzResolvedRecommendation(
            track: track,
            status: ListenBrainzRecommendationMatchStatus.pending,
          ),
        )
        .toList(growable: false),
  );
}

Future<ListenBrainzDiscoverPlaylist>
_resolveListenBrainzTracksFromLocalSnapshot({
  required ListenBrainzDiscoverPlaylist playlist,
  required _ListenBrainzLocalCandidateSnapshot localCandidates,
}) async {
  final recommendations = <ListenBrainzResolvedRecommendation>[];
  for (final recommendation in playlist.recommendations) {
    if (recommendation.isPlayable) {
      recommendations.add(recommendation);
      continue;
    }
    final cacheKey = _listenBrainzMatchCacheKey(
      playlist.playlist,
      recommendation.track,
    );
    final cached = _listenBrainzDiscoverMatchCache[cacheKey];
    if (cached != null && cached.isPlayable) {
      recommendations.add(cached);
      continue;
    }
    final localMatch = _pickListenBrainzTrackMatch(
      recommendation.track,
      localCandidates.candidatesFor(recommendation.track),
    );
    if (localMatch.isPlayable) {
      _listenBrainzDiscoverMatchCache[cacheKey] = localMatch;
    }
    recommendations.add(localMatch.isPlayable ? localMatch : recommendation);
  }
  return playlist.copyWith(recommendations: recommendations);
}

Stream<List<ListenBrainzDiscoverPlaylist>>
_resolveListenBrainzTrackSearchMisses({
  required SubsonicApiClient? api,
  required LibraryDao dao,
  required List<ListenBrainzDiscoverPlaylist> playlists,
  required int maxConcurrent,
}) async* {
  var current = playlists
      .map(
        (playlist) => playlist.copyWith(
          recommendations: playlist.recommendations.toList(growable: false),
        ),
      )
      .toList(growable: false);
  if (api == null) {
    current = current
        .map(
          (playlist) => playlist.copyWith(
            recommendations: playlist.recommendations
                .map(
                  (recommendation) =>
                      _listenBrainzRecommendationNeedsResolution(
                        recommendation,
                      )
                      ? ListenBrainzResolvedRecommendation(
                          track: recommendation.track,
                          status:
                              ListenBrainzRecommendationMatchStatus.unmatched,
                        )
                      : recommendation,
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    yield current;
    return;
  }

  final searchQueue = _BoundedAsyncQueue(maxConcurrent);
  final pending =
      <
        int,
        Future<
          ({
            int taskId,
            int playlistIndex,
            int recommendationIndex,
            ListenBrainzResolvedRecommendation recommendation,
          })
        >
      >{};
  var nextTaskId = 0;

  for (var playlistIndex = 0; playlistIndex < current.length; playlistIndex++) {
    final playlist = current[playlistIndex];
    for (
      var recommendationIndex = 0;
      recommendationIndex < playlist.recommendations.length;
      recommendationIndex++
    ) {
      final recommendation = playlist.recommendations[recommendationIndex];
      if (!_listenBrainzRecommendationNeedsResolution(recommendation)) {
        continue;
      }
      final taskId = nextTaskId++;
      pending[taskId] = searchQueue.run(
        () => _resolveListenBrainzRemoteSearchMiss(
          api: api,
          playlist: playlist.playlist,
          recommendation: recommendation,
          taskId: taskId,
          playlistIndex: playlistIndex,
          recommendationIndex: recommendationIndex,
        ),
      );
    }
  }

  var completionsSinceYield = 0;
  while (pending.isNotEmpty) {
    final completed = await Future.any(pending.values);
    final removedTask = pending.remove(completed.taskId);
    if (removedTask == null) {
      continue;
    }
    final playlist = current[completed.playlistIndex];
    final recommendations = playlist.recommendations.toList(growable: true);
    recommendations[completed.recommendationIndex] = completed.recommendation;
    current = current.toList(growable: true);
    current[completed.playlistIndex] = playlist.copyWith(
      recommendations: recommendations.toList(growable: false),
    );
    current = current.toList(growable: false);
    completionsSinceYield++;
    if (pending.isEmpty ||
        completionsSinceYield >= _listenBrainzDiscoverSearchEmitBatchSize) {
      completionsSinceYield = 0;
      current = await _persistListenBrainzSearchMatches(dao, current);
      yield current;
    }
  }
}

Future<
  ({
    int taskId,
    int playlistIndex,
    int recommendationIndex,
    ListenBrainzResolvedRecommendation recommendation,
  })
>
_resolveListenBrainzRemoteSearchMiss({
  required SubsonicApiClient api,
  required ListenBrainzPlaylist playlist,
  required ListenBrainzResolvedRecommendation recommendation,
  required int taskId,
  required int playlistIndex,
  required int recommendationIndex,
}) async {
  final track = recommendation.track;
  final cacheKey = _listenBrainzMatchCacheKey(playlist, track);
  final cached = _listenBrainzDiscoverMatchCache[cacheKey];
  if (cached != null && cached.isPlayable) {
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: cached,
    );
  }
  try {
    final query = <String>[
      track.title,
      if (track.creator != null) track.creator!,
      if (track.album != null) track.album!,
    ].join(' ');
    final search = await api.search3(
      query: query,
      artistCount: 0,
      albumCount: 0,
      songCount: _listenBrainzDiscoverSearchSongCount,
    );
    final match = _pickListenBrainzTrackMatch(
      track,
      search.songs.map(_listenBrainzRemoteCandidate).toList(growable: false),
    );
    if (match.isPlayable) {
      _listenBrainzDiscoverMatchCache[cacheKey] = match;
    }
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: match,
    );
  } on Object {
    final unmatched = ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    );
    return (
      taskId: taskId,
      playlistIndex: playlistIndex,
      recommendationIndex: recommendationIndex,
      recommendation: unmatched,
    );
  }
}

ListenBrainzResolvedRecommendation _pickListenBrainzTrackMatch(
  ListenBrainzPlaylistTrack track,
  List<_ListenBrainzSongCandidate> candidates,
) {
  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.creator ?? '');
  if (expectedTitle.isEmpty || expectedArtist.isEmpty || candidates.isEmpty) {
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    );
  }

  final expectedRecordingMbid = track.recordingMbid?.trim().toLowerCase();
  var candidatesToScore = candidates;
  if (expectedRecordingMbid != null && expectedRecordingMbid.isNotEmpty) {
    final mbidMatches = candidates
        .where(
          (candidate) =>
              candidate.recordingMbid?.trim().toLowerCase() ==
              expectedRecordingMbid,
        )
        .toList(growable: false);
    if (mbidMatches.length == 1) {
      return ListenBrainzResolvedRecommendation(
        track: track,
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: mbidMatches.single.song,
        tableSong: mbidMatches.single.tableSong,
      );
    }
    if (mbidMatches.length > 1) {
      candidatesToScore = mbidMatches;
    }
  }

  final scored = <({Song song, double score, double albumScore})>[];
  final tableSongsById = <String, SongsTableData>{};
  final expectedAlbum = normalizeMetadata(track.album ?? '');
  for (final candidate in candidatesToScore) {
    final candidateTitle = candidate.normalizedTitle;
    final candidateArtist = candidate.normalizedArtist;
    if (candidateTitle.isEmpty || candidateArtist.isEmpty) {
      continue;
    }
    final titleScore = _listenBrainzFieldScore(expectedTitle, candidateTitle);
    final artistScore = _listenBrainzFieldScore(
      expectedArtist,
      candidateArtist,
    );
    if (titleScore < _listenBrainzDiscoverMinimumFieldScore ||
        artistScore < _listenBrainzDiscoverMinimumFieldScore) {
      continue;
    }
    var score = (titleScore * 0.58) + (artistScore * 0.32);
    var albumScore = 0.0;
    final candidateAlbum = candidate.normalizedAlbum;
    if (expectedAlbum.isNotEmpty && candidateAlbum.isNotEmpty) {
      albumScore = _listenBrainzFieldScore(expectedAlbum, candidateAlbum);
      score += albumScore * 0.06;
    }
    final expectedDuration = track.durationSeconds;
    final candidateDuration = candidate.song.duration;
    if (expectedDuration != null && candidateDuration != null) {
      final diff = (expectedDuration - candidateDuration).abs();
      if (diff <= 3) {
        score += 0.04;
      } else if (diff > 15) {
        score -= 0.08;
      }
    }
    scored.add((
      song: candidate.song,
      score: score.clamp(0.0, 1.0),
      albumScore: albumScore,
    ));
    final tableSong = candidate.tableSong;
    if (tableSong != null) {
      tableSongsById[candidate.song.id] = tableSong;
    }
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  if (scored.isEmpty ||
      scored.first.score < _listenBrainzDiscoverMinimumScore) {
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    );
  }
  if (scored.length > 1 &&
      scored.first.score - scored[1].score <
          _listenBrainzDiscoverAmbiguousDelta &&
      (scored.first.albumScore - scored[1].albumScore).abs() <
          _listenBrainzDiscoverAmbiguousDelta &&
      scored.first.song.id != scored[1].song.id) {
    if (_listenBrainzCanChooseEquivalentTopMatch(
      track: track,
      first: scored.first.song,
      second: scored[1].song,
    )) {
      return ListenBrainzResolvedRecommendation(
        track: track,
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: scored.first.song,
        tableSong: tableSongsById[scored.first.song.id],
      );
    }
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.ambiguous,
    );
  }
  return ListenBrainzResolvedRecommendation(
    track: track,
    status: ListenBrainzRecommendationMatchStatus.matched,
    song: scored.first.song,
    tableSong: tableSongsById[scored.first.song.id],
  );
}

bool _listenBrainzCanChooseEquivalentTopMatch({
  required ListenBrainzPlaylistTrack track,
  required Song first,
  required Song second,
}) {
  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.creator ?? '');
  if (expectedTitle.isEmpty || expectedArtist.isEmpty) {
    return false;
  }

  final firstTitle = normalizeMetadata(first.title);
  final secondTitle = normalizeMetadata(second.title);
  final firstArtist = normalizeMetadata(first.artist ?? '');
  final secondArtist = normalizeMetadata(second.artist ?? '');
  if (firstTitle != expectedTitle ||
      secondTitle != expectedTitle ||
      firstArtist != expectedArtist ||
      secondArtist != expectedArtist) {
    return false;
  }

  final expectedAlbum = normalizeMetadata(track.album ?? '');
  if (expectedAlbum.isNotEmpty) {
    final firstAlbum = normalizeMetadata(first.album ?? '');
    final secondAlbum = normalizeMetadata(second.album ?? '');
    if (firstAlbum == expectedAlbum && secondAlbum != expectedAlbum) {
      return true;
    }
    if (secondAlbum == expectedAlbum && firstAlbum != expectedAlbum) {
      return false;
    }
  }

  final expectedDuration = track.durationSeconds;
  if (expectedDuration != null) {
    final firstDuration = first.duration;
    final secondDuration = second.duration;
    final firstDiff = firstDuration == null
        ? 1 << 20
        : (firstDuration - expectedDuration).abs();
    final secondDiff = secondDuration == null
        ? 1 << 20
        : (secondDuration - expectedDuration).abs();
    if ((firstDiff - secondDiff).abs() > 3) {
      return firstDiff < secondDiff;
    }
  }

  return true;
}

Future<List<ListenBrainzDiscoverPlaylist>> _persistListenBrainzSearchMatches(
  LibraryDao dao,
  List<ListenBrainzDiscoverPlaylist> playlists,
) async {
  final songsById = <String, Song>{};
  for (final playlist in playlists) {
    for (final recommendation in playlist.recommendations) {
      final song = recommendation.song;
      if (recommendation.tableSong != null ||
          song == null ||
          !isServerAddressableSongId(song.id)) {
        continue;
      }
      songsById[song.id] = song;
    }
  }
  if (songsById.isEmpty) {
    return playlists;
  }

  final artistsById = <String, ArtistsTableCompanion>{};
  final albumsById = <String, AlbumsTableCompanion>{};
  final songRows = <SongsTableCompanion>[];
  for (final song in songsById.values) {
    final artistId = song.artistId?.trim();
    if (artistId != null && artistId.isNotEmpty) {
      artistsById[artistId] = ArtistsTableCompanion.insert(
        id: artistId,
        name: (song.artist?.trim().isNotEmpty ?? false)
            ? song.artist!.trim()
            : artistId,
        coverArt: Value(song.coverArt),
      );
    }

    final albumId = song.albumId?.trim();
    if (albumId != null && albumId.isNotEmpty) {
      albumsById[albumId] = AlbumsTableCompanion.insert(
        id: albumId,
        name: (song.album?.trim().isNotEmpty ?? false)
            ? song.album!.trim()
            : albumId,
        artistId: Value(
          artistId == null || artistId.isEmpty ? null : artistId,
        ),
        artistName: Value(song.artist),
        songCount: const Value(1),
        duration: Value(song.duration),
        coverArt: Value(song.coverArt),
      );
    }

    songRows.add(_listenBrainzSongCompanion(song));
  }

  await dao.upsertArtists(artistsById.values.toList(growable: false));
  await dao.upsertAlbums(albumsById.values.toList(growable: false));
  await dao.upsertSongs(songRows);

  return playlists
      .map(
        (playlist) => playlist.copyWith(
          recommendations: playlist.recommendations
              .map((recommendation) {
                final song = recommendation.song;
                if (recommendation.tableSong != null ||
                    song == null ||
                    !songsById.containsKey(song.id)) {
                  return recommendation;
                }
                final persisted = recommendation.copyWith(
                  tableSong: _listenBrainzTableSong(song),
                );
                _listenBrainzDiscoverMatchCache[_listenBrainzMatchCacheKey(
                      playlist.playlist,
                      recommendation.track,
                    )] =
                    persisted;
                return persisted;
              })
              .toList(growable: false),
        ),
      )
      .toList(growable: false);
}

SongsTableData _listenBrainzTableSong(Song song) {
  return SongsTableData(
    id: song.id,
    title: song.title,
    albumId: song.albumId,
    artistId: song.artistId,
    artistName: song.artist,
    albumName: song.album,
    track: song.track,
    discNumber: song.discNumber,
    duration: song.duration,
    bitRate: song.bitRate,
    sampleRate: song.sampleRate,
    contentType: song.contentType,
    suffix: song.suffix,
    size: song.size,
    coverArt: song.coverArt,
    starred: song.starred,
    userRating: song.userRating,
    playCount: song.playCount,
    createdAt: song.created,
    replayGainTrackGain: song.replayGain?.trackGain,
    replayGainAlbumGain: song.replayGain?.albumGain,
    replayGainTrackPeak: song.replayGain?.trackPeak,
    replayGainAlbumPeak: song.replayGain?.albumPeak,
  );
}

SongsTableCompanion _listenBrainzSongCompanion(Song song) {
  return SongsTableCompanion.insert(
    id: song.id,
    title: song.title,
    albumId: Value(song.albumId),
    artistId: Value(song.artistId),
    artistName: Value(song.artist),
    albumName: Value(song.album),
    track: Value(song.track),
    discNumber: Value(song.discNumber),
    duration: Value(song.duration),
    bitRate: Value(song.bitRate),
    sampleRate: Value(song.sampleRate),
    contentType: Value(song.contentType),
    suffix: Value(song.suffix),
    size: Value(song.size),
    coverArt: Value(song.coverArt),
    starred: Value(song.starred),
    userRating: Value(song.userRating),
    playCount: Value(song.playCount),
    createdAt: Value(song.created),
    replayGainTrackGain: Value(song.replayGain?.trackGain),
    replayGainAlbumGain: Value(song.replayGain?.albumGain),
    replayGainTrackPeak: Value(song.replayGain?.trackPeak),
    replayGainAlbumPeak: Value(song.replayGain?.albumPeak),
  );
}

typedef _ListenBrainzSongCandidate = ({
  Song song,
  String? recordingMbid,
  SongsTableData? tableSong,
  String normalizedTitle,
  String normalizedArtist,
  String normalizedAlbum,
});

class _ListenBrainzLocalCandidateSnapshot {
  _ListenBrainzLocalCandidateSnapshot._({
    required this.all,
    required this.byNormalizedTitle,
  });

  factory _ListenBrainzLocalCandidateSnapshot.fromSongs(
    List<SongsTableData> songs,
  ) {
    final all = songs.map(_listenBrainzLocalCandidate).toList(growable: false);
    final byTitle = <String, List<_ListenBrainzSongCandidate>>{};
    for (final candidate in all) {
      final title = candidate.normalizedTitle;
      if (title.isEmpty) {
        continue;
      }
      byTitle
          .putIfAbsent(title, () => <_ListenBrainzSongCandidate>[])
          .add(
            candidate,
          );
    }
    return _ListenBrainzLocalCandidateSnapshot._(
      all: all,
      byNormalizedTitle: {
        for (final entry in byTitle.entries)
          entry.key: List<_ListenBrainzSongCandidate>.unmodifiable(
            entry.value,
          ),
      },
    );
  }

  final List<_ListenBrainzSongCandidate> all;
  final Map<String, List<_ListenBrainzSongCandidate>> byNormalizedTitle;

  List<_ListenBrainzSongCandidate> candidatesFor(
    ListenBrainzPlaylistTrack track,
  ) {
    final title = normalizeMetadata(track.title);
    final exactTitleCandidates = byNormalizedTitle[title];
    if (exactTitleCandidates != null && exactTitleCandidates.isNotEmpty) {
      return exactTitleCandidates;
    }

    final expectedArtist = normalizeMetadata(track.creator ?? '');
    if (expectedArtist.isEmpty) {
      return const <_ListenBrainzSongCandidate>[];
    }

    final expectedArtistTokens =
        expectedArtist.split(' ').where((t) => t.length > 1).toSet();
    if (expectedArtistTokens.isEmpty) {
      return const <_ListenBrainzSongCandidate>[];
    }

    return all.where((candidate) {
      final candidateArtist = candidate.normalizedArtist;
      if (candidateArtist.isEmpty) return false;
      if (candidateArtist == expectedArtist) return true;
      if (candidateArtist.contains(expectedArtist) ||
          expectedArtist.contains(candidateArtist)) {
        return true;
      }
      final candidateArtistTokens =
          candidateArtist.split(' ').where((t) => t.length > 1).toSet();
      return expectedArtistTokens
          .intersection(candidateArtistTokens)
          .isNotEmpty;
    }).toList(growable: false);
  }
}

_ListenBrainzSongCandidate _listenBrainzLocalCandidate(SongsTableData song) {
  final songObj = Song(
    id: song.id,
    title: song.title,
    album: song.albumName,
    albumId: song.albumId,
    artist: song.artistName,
    artistId: song.artistId,
    track: song.track,
    discNumber: song.discNumber,
    duration: song.duration,
    bitRate: song.bitRate,
    sampleRate: song.sampleRate,
    contentType: song.contentType,
    suffix: song.suffix,
    size: song.size,
    coverArt: song.coverArt,
    starred: song.starred,
    userRating: song.userRating,
    playCount: song.playCount,
    created: song.createdAt,
    replayGain:
        song.replayGainTrackGain == null &&
            song.replayGainAlbumGain == null &&
            song.replayGainTrackPeak == null &&
            song.replayGainAlbumPeak == null
        ? null
        : ReplayGain(
            trackGain: song.replayGainTrackGain,
            albumGain: song.replayGainAlbumGain,
            trackPeak: song.replayGainTrackPeak,
            albumPeak: song.replayGainAlbumPeak,
          ),
  );
  return (
    song: songObj,
    recordingMbid: song.recordingMbid,
    tableSong: song,
    normalizedTitle: normalizeMetadata(song.title),
    normalizedArtist: normalizeMetadata(song.artistName ?? ''),
    normalizedAlbum: normalizeMetadata(song.albumName ?? ''),
  );
}

_ListenBrainzSongCandidate _listenBrainzRemoteCandidate(Song song) {
  return (
    song: song,
    recordingMbid: null,
    tableSong: null,
    normalizedTitle: normalizeMetadata(song.title),
    normalizedArtist: normalizeMetadata(song.artist ?? ''),
    normalizedAlbum: normalizeMetadata(song.album ?? ''),
  );
}

String _listenBrainzMatchCacheKey(
  ListenBrainzPlaylist playlist,
  ListenBrainzPlaylistTrack track,
) {
  final sourcePatch = playlist.sourcePatch?.trim() ?? '';
  final playlistId = playlist.identifier.trim();
  final identity =
      track.recordingMbid?.trim() ??
      track.recordingMsid?.trim() ??
      '${track.title}|${track.creator ?? ''}|${track.album ?? ''}|${track.durationMs ?? ''}';
  return '$sourcePatch|$playlistId|$identity';
}

double _listenBrainzFieldScore(String expected, String actual) {
  if (expected == actual) {
    return 1;
  }
  if (actual.contains(expected) || expected.contains(actual)) {
    return 0.82;
  }
  final expectedTokens = expected.split(' ').where((t) => t.length > 1).toSet();
  final actualTokens = actual.split(' ').where((t) => t.length > 1).toSet();
  if (expectedTokens.isEmpty || actualTokens.isEmpty) {
    return 0;
  }
  final overlap = expectedTokens.intersection(actualTokens).length;
  return overlap / expectedTokens.length;
}

/// Starred / liked songs from local DB (limit 5 for home preview).
final homeLikedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchStarredSongs(limit: 5);
});

/// Recently added albums from the server API.
final homeRecentlyAddedProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'newest',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Recently played **albums** derived from local play history.
final homeRecentlyPlayedAlbumsProvider = StreamProvider<List<AlbumsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedAlbums(limit: 20);
});

/// Random albums from the server API.
final homeRandomAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'random',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Most played songs from local DB ordered by playCount (limit 5).
final homeMostPlayedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchMostPlayedSongs(limit: 5);
});

final homeDownloadedLikedSongsProvider = StreamProvider<List<SongsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  final downloadedSongIds =
      ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{};
  return dao.watchAllStarredSongs().map(
    (songs) => songs
        .where((song) => downloadedSongIds.contains(song.id))
        .take(5)
        .toList(growable: false),
  );
});

final homeDownloadedRecentlyAddedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

final homeDownloadedRecentlyPlayedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).historyDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchRecentlyPlayedAlbums(limit: null)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

final homeDownloadedRandomAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((
      ref,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      final random = Random();
      return dao.watchAlbumsSorted(sort: AlbumSortOrder.name).map((albums) {
        final filtered = albums
            .where((album) => downloadedAlbumIds.contains(album.id))
            .toList(growable: true);
        filtered.shuffle(random);
        return filtered.take(20).toList(growable: false);
      });
    });

final homeRandomAlbumShowcaseProvider =
    FutureProvider.family<
      List<HomeRandomShowcaseAlbum>,
      ({bool downloadedOnly, bool likedOnly})
    >((ref, filters) async {
      final downloadedOnly = filters.downloadedOnly;
      final likedOnly = filters.likedOnly;
      final networkType = ref.watch(networkTypeProvider);
      final shuffleSeed = ref.watch(homeRandomShowcaseShuffleSeedProvider);
      final localPreferred =
          downloadedOnly || likedOnly || networkType == NetworkType.offline;

      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final allAlbums = await dao.getAllAlbums();

      final downloadedAlbumIds = downloadedOnly
          ? (ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
                const <String>{})
          : const <String>{};
      final scopedAlbums = downloadedOnly
          ? allAlbums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .toList(growable: false)
          : allAlbums;
      final scopedById = <String, AlbumsTableData>{
        for (final album in scopedAlbums) album.id: album,
      };
      // Intentional non-reactive snapshot: liking/unliking a song should not
      // reshuffle the random showcase unless an explicit refresh/sync occurs.
      final likedSongsSnapshot =
          ref.read(likedSongsProvider).asData?.value ??
          const <SongsTableData>[];

      if (!localPreferred) {
        final api = ref.watch(subsonicApiProvider);
        if (api != null) {
          final eligibleLikedSongs = likedSongsSnapshot
              .where((song) => song.id.trim().isNotEmpty)
              .toList(growable: true);

          if (eligibleLikedSongs.length >= _homeRandomDiscoveryMinLikedSongs) {
            final discovery = await _buildLikedDiscoveryAlbums(
              api: api,
              likedSongs: eligibleLikedSongs,
              scopedById: scopedById,
              shuffleSeed: shuffleSeed,
            );
            if (discovery.length >= _homeRandomDiscoveryMinResults) {
              return discovery
                  .take(_homeRandomShowcaseLimit)
                  .toList(growable: false);
            }
          }

          try {
            final serverRandom = await ref.watch(
              homeRandomAlbumsProvider.future,
            );
            if (serverRandom.isNotEmpty) {
              return serverRandom
                  .take(_homeRandomShowcaseLimit)
                  .map(HomeRandomShowcaseAlbum.fromServer)
                  .toList(growable: false);
            }
          } on Exception {
            // Fall back to local candidates when server random fails.
          }
        }
      }

      final candidates = <AlbumsTableData>[];
      if (likedOnly) {
        final deduped = <String, AlbumsTableData>{};

        final likedAlbums = await dao.getLikedAlbums();
        for (final likedAlbum in likedAlbums) {
          final scopedAlbum = scopedById[likedAlbum.id];
          if (scopedAlbum == null) {
            continue;
          }
          deduped[scopedAlbum.id] = scopedAlbum;
        }

        if (deduped.length < _homeRandomShowcaseLimit) {
          final downloadedSongIds = downloadedOnly
              ? (ref.watch(downloadedSongIdsProvider).asData?.value ??
                    const <String>{})
              : const <String>{};

          for (final song in likedSongsSnapshot) {
            if (downloadedOnly && !downloadedSongIds.contains(song.id)) {
              continue;
            }
            final albumId = song.albumId?.trim();
            if (albumId == null || albumId.isEmpty) {
              continue;
            }
            final scopedAlbum = scopedById[albumId];
            if (scopedAlbum == null) {
              continue;
            }
            deduped[scopedAlbum.id] = scopedAlbum;
          }
        }

        candidates.addAll(deduped.values);
      } else {
        candidates.addAll(scopedAlbums);
      }

      final random = Random(
        shuffleSeed ^
            (downloadedOnly ? 0x9e3779b9 : 0) ^
            (likedOnly ? 0x7f4a7c15 : 0) ^
            candidates.length,
      );
      candidates.shuffle(random);
      return candidates
          .take(_homeRandomShowcaseLimit)
          .map(HomeRandomShowcaseAlbum.fromLocal)
          .toList(growable: false);
    });

final homeRandomShowcaseProvider =
    FutureProvider.family<
      List<HomeRandomShowcaseItem>,
      ({bool downloadedOnly, bool likedOnly})
    >((ref, filters) async {
      final albums = await ref.watch(
        homeRandomAlbumShowcaseProvider(filters).future,
      );
      return _prependListenBrainzShowcase(ref, filters, albums);
    });

List<HomeRandomShowcaseItem> _prependListenBrainzShowcase(
  Ref ref,
  ({bool downloadedOnly, bool likedOnly}) filters,
  List<HomeRandomShowcaseAlbum> albums,
) {
  if (filters.downloadedOnly || filters.likedOnly) {
    return albums;
  }
  final listenBrainz = ref.watch(listenBrainzDiscoverStreamProvider);
  final streamItems = listenBrainz.maybeWhen(
    data: (playlists) => <HomeRandomShowcaseListenBrainz>[
      for (final playlist in playlists)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ],
    orElse: () => null,
  );
  if (streamItems != null) {
    if (streamItems.isEmpty) {
      return albums;
    }
    return <HomeRandomShowcaseItem>[
      ...streamItems,
      ...albums.take(_homeRandomShowcaseLimit - streamItems.length),
    ];
  }
  final cached = _listenBrainzDiscoverSessionCache;
  if (cached != null) {
    final items = <HomeRandomShowcaseListenBrainz>[
      for (final playlist in cached)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ];
    return <HomeRandomShowcaseItem>[
      ...items,
      ...albums.take(_homeRandomShowcaseLimit - items.length),
    ];
  }
  final lastVisible = _listenBrainzDiscoverLastVisible;
  if (lastVisible != null) {
    final items = <HomeRandomShowcaseListenBrainz>[
      for (final playlist in lastVisible)
        HomeRandomShowcaseListenBrainz(playlist: playlist),
    ];
    return <HomeRandomShowcaseItem>[
      ...items,
      ...albums.take(_homeRandomShowcaseLimit - items.length),
    ];
  }
  final items = listenBrainz.maybeWhen(
    loading: () => _listenBrainzLoadingShowcaseItems(ref),
    orElse: () => const <HomeRandomShowcaseListenBrainz>[],
  );
  if (items.isEmpty) {
    return albums;
  }
  return <HomeRandomShowcaseItem>[
    ...items,
    ...albums.take(_homeRandomShowcaseLimit - items.length),
  ];
}

List<HomeRandomShowcaseListenBrainz> _listenBrainzLoadingShowcaseItems(
  Ref ref,
) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  if (!settings.listenBrainzTokenValid ||
      settings.listenBrainzUserName?.trim().isEmpty != false ||
      ref.watch(networkTypeProvider) == NetworkType.offline) {
    return const <HomeRandomShowcaseListenBrainz>[];
  }
  return const <HomeRandomShowcaseListenBrainz>[
    HomeRandomShowcaseListenBrainz.loading(
      sourcePatch: 'weekly-exploration',
      displayTitle: 'Weekly Exploration',
    ),
    HomeRandomShowcaseListenBrainz.loading(
      sourcePatch: 'weekly-jams',
      displayTitle: 'Weekly Jams',
    ),
  ];
}

List<ListenBrainzDiscoverPlaylist> _listenBrainzLoadingDiscoverPlaylists() {
  return const <ListenBrainzDiscoverPlaylist>[
    ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'weekly-exploration',
        title: 'Weekly Exploration',
        sourcePatch: 'weekly-exploration',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    ),
    ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'weekly-jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    ),
  ];
}

Future<List<ListenBrainzDiscoverPlaylist>> _loadListenBrainzWeeklyCache({
  required CacheDao cacheDao,
  required String userName,
}) async {
  final rows = await cacheDao.getListenBrainzWeeklyCacheForUser(userName);
  if (rows.isEmpty) {
    return const <ListenBrainzDiscoverPlaylist>[];
  }
  final bySourcePatch = <String, ListenBrainzDiscoverPlaylist>{};
  for (final row in rows) {
    final playlist = _listenBrainzDiscoverPlaylistFromCache(row);
    if (playlist == null) {
      continue;
    }
    bySourcePatch[row.sourcePatch] = playlist;
  }
  return _listenBrainzShowcaseSourcePatches
      .map((sourcePatch) => bySourcePatch[sourcePatch])
      .whereType<ListenBrainzDiscoverPlaylist>()
      .toList(growable: false);
}

Future<void> _saveListenBrainzWeeklyCache({
  required CacheDao cacheDao,
  required String userName,
  required List<ListenBrainzDiscoverPlaylist> playlists,
}) async {
  await cacheDao.deleteListenBrainzWeeklyCacheForUserSources(
    userName,
    _listenBrainzShowcaseSourcePatches,
  );
  for (final playlist in playlists) {
    final sourcePatch = playlist.playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      continue;
    }
    await cacheDao.upsertListenBrainzWeeklyCache(
      ListenBrainzWeeklyCacheTableCompanion.insert(
        listenBrainzUserName: userName,
        sourcePatch: sourcePatch,
        playlistIdentifier: playlist.playlist.identifier,
        title: playlist.playlist.title,
        weekMarker: Value(_listenBrainzWeekMarker(playlist.playlist)),
        playlistDate: Value(playlist.playlist.date),
        recommendationsJson: jsonEncode(
          playlist.recommendations
              .map(_listenBrainzRecommendationToCacheJson)
              .toList(growable: false),
        ),
        matchedCount: Value(playlist.matchedCount),
        totalCount: Value(playlist.totalCount),
        fetchedAt: DateTime.now(),
      ),
    );
  }
}

ListenBrainzDiscoverPlaylist? _listenBrainzDiscoverPlaylistFromCache(
  ListenBrainzWeeklyCacheTableData row,
) {
  try {
    final decoded = jsonDecode(row.recommendationsJson);
    if (decoded is! List) {
      return null;
    }
    final recommendations = decoded
        .whereType<Map<Object?, Object?>>()
        .map((json) {
          return _listenBrainzRecommendationFromCacheJson(
            Map<String, dynamic>.from(json),
          );
        })
        .whereType<ListenBrainzResolvedRecommendation>()
        .toList(growable: false);
    if (recommendations.isEmpty) {
      return null;
    }
    return ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: row.playlistIdentifier,
        title: row.title,
        date: row.playlistDate,
        sourcePatch: row.sourcePatch,
        tracks: recommendations
            .map((recommendation) => recommendation.track)
            .toList(growable: false),
      ),
      recommendations: recommendations,
      matchingComplete: true,
    );
  } on Object catch (error) {
    AppLogger.debug(
      'ListenBrainz discover ignored corrupt weekly cache: '
      'sourcePatch="${row.sourcePatch}" error=$error.',
    );
    return null;
  }
}

Map<String, dynamic> _listenBrainzRecommendationToCacheJson(
  ListenBrainzResolvedRecommendation recommendation,
) {
  return <String, dynamic>{
    'track': _listenBrainzTrackToCacheJson(recommendation.track),
    'status': recommendation.status.name,
    'song': recommendation.song?.toJson(),
  };
}

ListenBrainzResolvedRecommendation? _listenBrainzRecommendationFromCacheJson(
  Map<String, dynamic> json,
) {
  final trackJson = json['track'];
  if (trackJson is! Map) {
    return null;
  }
  final track = _listenBrainzTrackFromCacheJson(
    Map<String, dynamic>.from(trackJson),
  );
  if (track == null) {
    return null;
  }
  final statusName = json['status'] as String?;
  final status = ListenBrainzRecommendationMatchStatus.values
      .where((value) => value.name == statusName)
      .firstOrNull;
  if (status == null) {
    return null;
  }
  final songJson = json['song'];
  final song = songJson is Map
      ? Song.fromJson(Map<String, dynamic>.from(songJson))
      : null;
  return ListenBrainzResolvedRecommendation(
    track: track,
    status:
        song == null && status == ListenBrainzRecommendationMatchStatus.matched
        ? ListenBrainzRecommendationMatchStatus.unmatched
        : status,
    song: song,
    tableSong: song == null ? null : _listenBrainzTableSong(song),
  );
}

Map<String, dynamic> _listenBrainzTrackToCacheJson(
  ListenBrainzPlaylistTrack track,
) {
  return <String, dynamic>{
    'title': track.title,
    'creator': track.creator,
    'album': track.album,
    'durationMs': track.durationMs,
    'identifiers': track.identifiers,
    'recordingMbid': track.recordingMbid,
    'recordingMsid': track.recordingMsid,
    'image': track.image,
  };
}

ListenBrainzPlaylistTrack? _listenBrainzTrackFromCacheJson(
  Map<String, dynamic> json,
) {
  final title = json['title'] as String?;
  if (title == null || title.trim().isEmpty) {
    return null;
  }
  return ListenBrainzPlaylistTrack(
    title: title,
    creator: json['creator'] as String?,
    album: json['album'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt(),
    identifiers:
        (json['identifiers'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
    recordingMbid: json['recordingMbid'] as String?,
    recordingMsid: json['recordingMsid'] as String?,
    image: json['image'] as String?,
  );
}

String? _listenBrainzWeekMarker(ListenBrainzPlaylist playlist) {
  final date = playlist.date;
  if (date != null) {
    return date.toIso8601String();
  }
  final match = RegExp(
    'week of ([0-9]{4}-[0-9]{2}-[0-9]{2})',
    caseSensitive: false,
  ).firstMatch(playlist.title);
  return match?.group(1);
}

String _listenBrainzPlaylistVersionMarker(ListenBrainzPlaylist playlist) {
  final weekMarker = _listenBrainzWeekMarker(playlist)?.trim();
  if (weekMarker != null && weekMarker.isNotEmpty) {
    return weekMarker;
  }
  return playlist.title.trim();
}

bool _listenBrainzMetadataMatchesCachedPlaylists(
  List<ListenBrainzPlaylist> metadata,
  List<ListenBrainzDiscoverPlaylist> cached,
) {
  if (metadata.length != cached.length) {
    return false;
  }
  final cachedBySourcePatch = <String, ListenBrainzDiscoverPlaylist>{};
  for (final playlist in cached) {
    final sourcePatch = playlist.playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      return false;
    }
    cachedBySourcePatch[sourcePatch] = playlist;
  }
  for (final playlist in metadata) {
    final sourcePatch = playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      return false;
    }
    final cachedPlaylist = cachedBySourcePatch[sourcePatch]?.playlist;
    if (cachedPlaylist == null) {
      return false;
    }
    if (cachedPlaylist.identifier != playlist.identifier) {
      return false;
    }
    if (_listenBrainzPlaylistVersionMarker(cachedPlaylist) !=
        _listenBrainzPlaylistVersionMarker(playlist)) {
      return false;
    }
  }
  return true;
}

bool _listenBrainzRecommendationNeedsResolution(
  ListenBrainzResolvedRecommendation recommendation,
) {
  return !recommendation.isPlayable;
}

int _listenBrainzUnresolvedRecommendationCount(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists.fold<int>(0, (sum, playlist) {
    return sum +
        playlist.recommendations
            .where(_listenBrainzRecommendationNeedsResolution)
            .length;
  });
}

int _listenBrainzMatchedRecommendationCount(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists.fold<int>(0, (sum, playlist) {
    return sum +
        playlist.recommendations.where((recommendation) {
          return recommendation.isPlayable;
        }).length;
  });
}

List<ListenBrainzDiscoverPlaylist> _visibleListenBrainzDiscoverPlaylists(
  List<ListenBrainzDiscoverPlaylist> playlists,
) {
  return playlists
      .where(
        (playlist) =>
            playlist.totalCount > 0 &&
            (!playlist.matchingComplete || playlist.matchedCount > 0),
      )
      .toList(growable: false);
}

List<ListenBrainzPlaylist> _selectListenBrainzShowcaseMetadata(
  Iterable<ListenBrainzPlaylist> playlists,
) {
  final bySourcePatch = <String, ListenBrainzPlaylist>{};
  for (final playlist in playlists) {
    final sourcePatch = playlist.sourcePatch?.trim();
    if (sourcePatch == null || sourcePatch.isEmpty) {
      continue;
    }
    if (!bySourcePatch.containsKey(sourcePatch)) {
      bySourcePatch[sourcePatch] = playlist;
    }
  }
  return _listenBrainzShowcaseSourcePatches
      .map((sourcePatch) => bySourcePatch[sourcePatch])
      .whereType<ListenBrainzPlaylist>()
      .toList(growable: false);
}

Future<List<HomeRandomShowcaseAlbum>> _buildLikedDiscoveryAlbums({
  required SubsonicApiClient api,
  required List<SongsTableData> likedSongs,
  required Map<String, AlbumsTableData> scopedById,
  required int shuffleSeed,
}) async {
  final likedAlbumIds = likedSongs
      .map((song) => song.albumId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  if (likedAlbumIds.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final seedPool = likedSongs.toList(growable: true);
  seedPool.shuffle(Random(shuffleSeed ^ 0x1f123bb5));
  final seedSongs = seedPool
      .where((song) => song.id.trim().isNotEmpty)
      .take(_homeRandomDiscoverySeedCount)
      .toList(growable: false);
  if (seedSongs.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final unseenCandidates = <String, HomeRandomShowcaseAlbum>{};
  final knownCandidates = <String, HomeRandomShowcaseAlbum>{};
  final similarSongResults = await Future.wait(
    seedSongs.map(
      (seed) => _fetchHomeRandomDiscoverySimilarSongs(
        api: api,
        seedSongId: seed.id,
      ),
    ),
  );

  for (final similarSongs in similarSongResults) {
    if (similarSongs.isEmpty) {
      continue;
    }

    for (final song in similarSongs) {
      final albumId = song.albumId?.trim();
      if (albumId == null || albumId.isEmpty) {
        continue;
      }
      if (unseenCandidates.containsKey(albumId) ||
          knownCandidates.containsKey(albumId)) {
        continue;
      }

      final scopedAlbum = scopedById[albumId];
      final showcaseAlbum = scopedAlbum != null
          ? HomeRandomShowcaseAlbum.fromLocalDiscovery(scopedAlbum)
          : HomeRandomShowcaseAlbum.fromSimilarSong(song);
      if (likedAlbumIds.contains(albumId)) {
        knownCandidates[albumId] = showcaseAlbum;
      } else {
        unseenCandidates[albumId] = showcaseAlbum;
      }
    }
  }

  return <HomeRandomShowcaseAlbum>[
    ...unseenCandidates.values,
    ...knownCandidates.values,
  ];
}

Future<List<Song>> _fetchHomeRandomDiscoverySimilarSongs({
  required SubsonicApiClient api,
  required String seedSongId,
}) async {
  final cancelToken = CancelToken();
  try {
    return await api
        .getSimilarSongs(
          seedSongId,
          count: _homeRandomDiscoverySongCountPerSeed,
          cancelToken: cancelToken,
        )
        .timeout(
          _homeRandomDiscoverySimilarSongTimeout,
          onTimeout: () {
            cancelToken.cancel('Home liked-song discovery timed out');
            throw TimeoutException(
              'Home liked-song discovery timed out for seed $seedSongId',
              _homeRandomDiscoverySimilarSongTimeout,
            );
          },
        );
  } on TimeoutException {
    AppLogger.debug(
      'Home liked-song discovery seed skipped after '
      '${_homeRandomDiscoverySimilarSongTimeout.inMilliseconds}ms.',
    );
    return const <Song>[];
  } on DioException catch (error) {
    if (!CancelToken.isCancel(error)) {
      AppLogger.debug(
        'Home liked-song discovery seed skipped: '
        '${error.response?.statusCode ?? error.type.name}.',
      );
    }
    return const <Song>[];
  } on Exception {
    return const <Song>[];
  }
}

final homeDownloadedMostPlayedSongsProvider =
    StreamProvider<List<SongsTableData>>((
      ref,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedSongIds =
          ref.watch(downloadedSongIdsProvider).asData?.value ??
          const <String>{};
      return dao
          .watchMostPlayedSongs(limit: null)
          .map(
            (songs) => songs
                .where((song) => downloadedSongIds.contains(song.id))
                .take(5)
                .toList(growable: false),
          );
    });

// ---------------------------------------------------------------------------
// Kept for backwards compat / possible future use — can be removed later.
// ---------------------------------------------------------------------------

final homeRecentlyPlayedProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedSongs(limit: 20);
});

final homeFrequentAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'frequent',
    size: 20,
    cancelToken: cancelToken,
  );
});

final homeStarredSongsProvider = FutureProvider<List<Song>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Song>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return (await api.getStarred2(cancelToken: cancelToken)).songs;
});
