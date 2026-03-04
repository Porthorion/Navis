import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_api_client.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_repository.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/settings/data/battery_optimization_service.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:path_provider/path_provider.dart';

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
  const StreamingQuality({
    required this.label,
    this.maxBitRate,
    this.format,
  });

  final String label;
  final int? maxBitRate;
  final String? format;
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final database = ref.watch(navisDatabaseProvider);
  return SettingsRepository(database.appSettingsDao);
});

final batteryOptimizationServiceProvider = Provider<BatteryOptimizationService>(
  (_) {
    return const BatteryOptimizationService();
  },
);

final appSettingsProvider = StreamProvider<AppSettingsModel>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  return repository.watchSettings();
});

final showRadioPageProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.showRadioPage;
});

final showPlaylistsPageProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.showPlaylistsPage;
});

final showArtistsPageProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.showArtistsPage;
});

final showLikedPageProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.showLikedPage;
});

final activeStreamingQualityProvider = Provider<StreamingQuality>((ref) {
  final networkType = ref.watch(networkTypeProvider);
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();

  final isWifi = networkType == NetworkType.wifi;
  final bitRate = isWifi
      ? settings.wifiMaxBitRate
      : settings.cellularMaxBitRate;
  final format = isWifi ? settings.wifiFormat : settings.cellularFormat;
  final profilePrefix = isWifi ? 'wifi' : 'nonwifi';

  if (bitRate == null && (format == null || format.trim().isEmpty)) {
    return StreamingQuality(label: '$profilePrefix-original');
  }

  final normalizedFormat = format?.trim();
  return StreamingQuality(
    label:
        '$profilePrefix-${bitRate ?? 'orig'}-${normalizedFormat ?? 'original'}',
    maxBitRate: bitRate,
    format: normalizedFormat,
  );
});

final subsonicApiProvider = Provider<SubsonicApiClient?>((ref) {
  final config = ref.watch(serverConfigStateProvider).asData?.value;
  if (config == null || config.password.trim().isEmpty) {
    return null;
  }
  final networkType = ref.watch(networkTypeProvider);

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
    maxConnectionsPerHost: switch (networkType) {
      NetworkType.wifi => 24,
      NetworkType.cellular => 8,
      NetworkType.offline => 4,
      NetworkType.other => 12,
    },
  );
});

final scrobbleServiceProvider = Provider<ScrobbleService>((ref) {
  final database = ref.watch(navisDatabaseProvider);
  final service = DriftScrobbleService(
    dao: database.scrobbleDao,
    readApiClient: () => ref.read(subsonicApiProvider),
    readScrobbleEnabled: () =>
        ref.read(appSettingsProvider).asData?.value.scrobbleEnabled ?? true,
    readReachable: () => ref.read(networkTypeProvider) != NetworkType.offline,
  );
  service.start();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

typedef AudioHandlerInitializer = Future<NavisPlaybackHandler> Function();

final audioBootstrapTimeoutProvider = Provider<Duration>((_) {
  return const Duration(seconds: 5);
});

final audioHandlerInitializerProvider = Provider<AudioHandlerInitializer>((
  ref,
) {
  return () async {
    final database = ref.read(navisDatabaseProvider);
    final handler = await initNavisAudioHandler(
      libraryDao: database.libraryDao,
      playQueueDao: database.playQueueDao,
      historyDao: database.historyDao,
      sourceResolver: PlaybackSourceResolver(
        cacheDao: database.cacheDao,
        rollingCacheManager: ref.read(rollingCacheManagerProvider),
        readApiClient: () => ref.read(subsonicApiProvider),
        readStreamingQuality: () => ref.read(activeStreamingQualityProvider),
        readRollingCacheDirectory: getTemporaryDirectory,
        readIsWifi: () => ref.read(networkTypeProvider) == NetworkType.wifi,
      ),
      readApiClient: () => ref.read(subsonicApiProvider),
      rollingCacheManager: ref.read(rollingCacheManagerProvider),
      rollingCacheBudgetBytes: ref.read(rollingCacheBudgetBytesProvider),
      scrobbleService: ref.read(scrobbleServiceProvider),
      starSyncDao: database.starSyncDao,
      readRuntimeSettings: () {
        final settings =
            ref.read(appSettingsProvider).asData?.value ??
            const AppSettingsModel.defaults();
        return PlaybackRuntimeSettings(
          gaplessEnabled: settings.gaplessEnabled,
          equalizerEnabled: settings.equalizerEnabled,
          equalizerBandGains: settings.equalizerBandGains,
          loudnessEnabled: settings.loudnessEnabled,
          loudnessTargetGainDb: settings.loudnessTargetGainDb,
          crossfadeEnabled: settings.crossfadeEnabled,
          crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
          crossfadeType: settings.crossfadeType,
          replayGainMode: settings.replayGainMode,
          replayGainPreamp: settings.replayGainPreamp,
          playbackSpeed: settings.playbackSpeed,
        );
      },
    );
    await handler.waitUntilReady();
    return handler;
  };
});

enum AudioBootstrapStatus { initializing, ready, failed }

enum PlaybackUnavailableReason { initializing, startupFailed, unavailable }

class PlaybackUnavailableException implements Exception {
  const PlaybackUnavailableException({
    required this.reason,
    this.message,
  });

  final PlaybackUnavailableReason reason;
  final String? message;

  @override
  String toString() => message ?? reason.name;
}

class AudioBootstrapState {
  const AudioBootstrapState({
    required this.status,
    this.handler,
    this.errorMessage,
  });

  const AudioBootstrapState.initializing()
    : status = AudioBootstrapStatus.initializing,
      handler = null,
      errorMessage = null;

  const AudioBootstrapState.ready(NavisPlaybackHandler readyHandler)
    : status = AudioBootstrapStatus.ready,
      handler = readyHandler,
      errorMessage = null;

  const AudioBootstrapState.failed(String failureMessage)
    : status = AudioBootstrapStatus.failed,
      handler = null,
      errorMessage = failureMessage;

  final AudioBootstrapStatus status;
  final NavisPlaybackHandler? handler;
  final String? errorMessage;

  bool get isReady => status == AudioBootstrapStatus.ready && handler != null;
}

class AudioBootstrapController extends Notifier<AudioBootstrapState> {
  Future<void>? _inFlight;
  bool _didAttempt = false;
  int _attemptEpoch = 0;
  int _activeAttempt = 0;

  @override
  AudioBootstrapState build() => const AudioBootstrapState.initializing();

  void ensureInitialized() {
    if (state.isReady) {
      return;
    }
    unawaited(_initialize());
  }

  Future<void> retry() => _initialize(force: true);

  Future<void> _initialize({bool force = false}) {
    if (_inFlight != null && !force) {
      return _inFlight!;
    }
    if (_didAttempt && !force && state.status == AudioBootstrapStatus.failed) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    final attemptId = ++_attemptEpoch;
    _activeAttempt = attemptId;
    _inFlight = completer.future;
    _didAttempt = true;
    state = const AudioBootstrapState.initializing();
    final audioHandlerState = ref.read<AudioHandlerStateController>(
      audioHandlerStateProvider.notifier,
    );
    audioHandlerState.state = null;
    unawaited(
      () async {
        final stopwatch = Stopwatch()..start();
        final timeout = ref.read(audioBootstrapTimeoutProvider);
        final initializeHandler = ref.read(audioHandlerInitializerProvider);
        var timedOut = false;

        Future<void> promoteReady(
          NavisPlaybackHandler audioHandler, {
          required bool recoveredFromTimeout,
        }) async {
          if (_activeAttempt != attemptId) {
            return;
          }
          final audioHandlerState = ref.read<AudioHandlerStateController>(
            audioHandlerStateProvider.notifier,
          );
          audioHandlerState.state = audioHandler;
          state = AudioBootstrapState.ready(audioHandler);
          final elapsedMs = stopwatch.elapsedMilliseconds;
          if (recoveredFromTimeout) {
            AppLogger.info(
              'Audio bootstrap recovered after timeout in ${elapsedMs}ms '
              '(attempt=$attemptId).',
            );
          } else {
            AppLogger.info(
              'Audio bootstrap ready in ${elapsedMs}ms '
              '(attempt=$attemptId).',
            );
          }
          if (!completer.isCompleted) {
            completer.complete();
          }
        }

        try {
          AppLogger.info('Audio bootstrap start (attempt=$attemptId).');
          final initFuture = initializeHandler();
          unawaited(
            initFuture.then<void>(
              (handler) async {
                if (_activeAttempt != attemptId || !timedOut) {
                  return;
                }
                await promoteReady(handler, recoveredFromTimeout: true);
              },
              onError: (Object error, StackTrace stackTrace) {
                if (_activeAttempt != attemptId || !timedOut) {
                  return;
                }
                AppLogger.error(
                  'Audio bootstrap asynchronous completion failed after timeout '
                  '(attempt=$attemptId).',
                  error,
                  stackTrace,
                );
              },
            ),
          );

          final audioHandler = await initFuture.timeout(timeout);
          if (_activeAttempt != attemptId) {
            if (!completer.isCompleted) {
              completer.complete();
            }
            return;
          }
          await promoteReady(audioHandler, recoveredFromTimeout: false);
        } on Object catch (error, stackTrace) {
          if (_activeAttempt != attemptId) {
            if (!completer.isCompleted) {
              completer.complete();
            }
            return;
          }
          timedOut = error is TimeoutException;
          final message = error is TimeoutException
              ? 'Playback initialization timed out after ${timeout.inSeconds}s.'
              : 'Playback initialization failed.';
          AppLogger.error(message, error, stackTrace);
          final audioHandlerState = ref.read<AudioHandlerStateController>(
            audioHandlerStateProvider.notifier,
          );
          audioHandlerState.state = null;
          state = AudioBootstrapState.failed(message);
          if (!completer.isCompleted) {
            completer.complete();
          }
        } finally {
          stopwatch.stop();
          if (_activeAttempt == attemptId) {
            _inFlight = null;
          }
        }
      }(),
    );
    return completer.future;
  }
}

final audioBootstrapControllerProvider =
    NotifierProvider<AudioBootstrapController, AudioBootstrapState>(
      AudioBootstrapController.new,
    );

class AlbumWithSongs {
  const AlbumWithSongs({required this.album, required this.songs});

  final AlbumsTableData album;
  final List<SongsTableData> songs;
}

final artistsProvider = StreamProvider<List<ArtistsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchArtists();
});

final likedArtistsProvider = StreamProvider<List<ArtistsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchLikedArtists();
});

final artistByIdProvider = StreamProvider.family<ArtistsTableData?, String>((
  ref,
  artistId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchArtistById(artistId);
});

final albumsByArtistProvider =
    StreamProvider.family<List<AlbumsTableData>, String>(
      (ref, artistId) {
        final dao = ref.watch(navisDatabaseProvider).libraryDao;
        return dao.watchAlbumsByArtist(artistId);
      },
    );

final albumProvider = StreamProvider.family<AlbumWithSongs?, String>((
  ref,
  albumId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;

  // Use switchMap semantics: when the album row changes (e.g. starred toggled),
  // cancel the previous songs subscription and start a fresh one so the outer
  // stream is never paused.  asyncExpand() would pause watchAlbumById() forever
  // because watchSongsByAlbum() never completes, silently dropping DB updates.
  final controller = StreamController<AlbumWithSongs?>();
  StreamSubscription<List<SongsTableData>>? songsSub;

  final albumSub = dao
      .watchAlbumById(albumId)
      .listen(
        (album) {
          songsSub?.cancel();
          if (album == null) {
            controller.add(null);
            songsSub = null;
          } else {
            songsSub = dao
                .watchSongsByAlbum(albumId)
                .listen(
                  (songs) => controller.add(
                    AlbumWithSongs(album: album, songs: songs),
                  ),
                  onError: controller.addError,
                );
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );

  ref.onDispose(() {
    albumSub.cancel();
    songsSub?.cancel();
    controller.close();
  });

  return controller.stream;
});

typedef AlbumPageRequest = ({AlbumSortOrder sort, int limit});
typedef LikedAlbumPageRequest = ({AlbumSortOrder sort, int limit});
typedef AlbumListRequest = ({AlbumSortOrder sort, bool likedOnly});
typedef AlbumYearSectionsRequest = ({bool likedOnly, bool downloadedOnly});

final albumPageSizeProvider = Provider<int>((_) => 60);

final albumCountProvider = StreamProvider<int>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumCount();
});

final likedAlbumCountProvider = StreamProvider<int>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumCount(likedOnly: true);
});

final pagedAlbumsProvider =
    StreamProvider.family<List<AlbumsTableData>, AlbumPageRequest>((
      ref,
      request,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsPage(
        sort: request.sort,
        limit: request.limit,
      );
    });

final likedPagedAlbumsProvider =
    StreamProvider.family<List<AlbumsTableData>, LikedAlbumPageRequest>((
      ref,
      request,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsPage(
        sort: request.sort,
        limit: request.limit,
        likedOnly: true,
      );
    });

final sortedAlbumsProvider =
    StreamProvider.family<List<AlbumsTableData>, AlbumListRequest>((
      ref,
      request,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsSorted(
        sort: request.sort,
        likedOnly: request.likedOnly,
      );
    });

final likedAlbumsProvider = StreamProvider<List<AlbumsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchLikedAlbums();
});

/// The 6 most recently liked albums, ordered by starred timestamp descending.
/// Used by the liked tab to cap the album grid and avoid excessive scrolling.
final likedAlbumsRecentProvider = StreamProvider<List<AlbumsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchRecentlyLikedAlbums(limit: 6);
});

final albumListProvider = StreamProvider.family<List<AlbumsTableData>, String>((
  ref,
  type,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAllAlbums();
});

final songsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongsSorted(SongSortOrder.newest);
});

final likedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAllStarredSongs();
});

final songsBySortProvider =
    StreamProvider.family<List<SongsTableData>, SongSortOrder>((
      ref,
      sort,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchSongsSorted(sort);
    });

final songByIdProvider = StreamProvider.family<SongsTableData?, String>((
  ref,
  songId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongById(songId);
});

/// Emits `true` when the song with [songId] is starred/liked.
final songStarredProvider = StreamProvider.family<bool, String>((
  ref,
  songId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongStarred(songId);
});

final genresProvider = StreamProvider<List<GenresTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchGenres();
});

final albumsByGenreProvider =
    StreamProvider.family<List<AlbumsTableData>, String>((
      ref,
      genre,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsByGenre(genre);
    });

final songsByGenreProvider =
    StreamProvider.family<List<SongsTableData>, String>((
      ref,
      genre,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchSongsByGenre(genre);
    });

final albumYearSectionsProvider =
    StreamProvider.family<List<AlbumYearSection>, AlbumYearSectionsRequest>((
      ref,
      request,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadState = ref.watch(downloadedContentIdsProvider);
      return dao.watchAlbumsForYearView(likedOnly: request.likedOnly).map((
        albums,
      ) {
        final filteredAlbums = request.downloadedOnly
            ? albums
                  .where(
                    (album) =>
                        downloadState.asData?.value.albumIds.contains(
                          album.id,
                        ) ??
                        false,
                  )
                  .toList(growable: false)
            : albums;
        return _buildAlbumYearSections(filteredAlbums);
      });
    });

final albumTileDownloadStateProvider =
    Provider.family<AlbumTileDownloadState, String>((ref, albumId) {
      final albumAsync = ref.watch(albumProvider(albumId));
      final cachedTypes = ref.watch(cachedSongTypesProvider).asData?.value;
      final queue = ref.watch(downloadQueueProvider).asData?.value;
      final album = albumAsync.asData?.value;
      if (album == null || cachedTypes == null || queue == null) {
        return const AlbumTileDownloadState.idle();
      }

      final songs = album.songs;
      if (songs.isEmpty) {
        return const AlbumTileDownloadState.idle();
      }

      final queueBySongId = <String, DownloadQueueTableData>{
        for (final item in queue)
          if (item.songId != null) item.songId!: item,
      };
      var completeCount = 0;
      var completedProgress = 0.0;
      var inFlightProgress = 0.0;
      var hasQueued = false;
      for (final song in songs) {
        final cacheType = cachedTypes[song.id];
        if (cacheType == CacheType.permanent) {
          completeCount += 1;
          completedProgress += 1;
          continue;
        }
        final item = queueBySongId[song.id];
        if (item == null) {
          continue;
        }
        if (item.status == DownloadStatus.downloading) {
          inFlightProgress += item.progress.clamp(0.0, 1.0);
          hasQueued = true;
          continue;
        }
        if (item.status == DownloadStatus.queued ||
            item.status == DownloadStatus.failed) {
          hasQueued = true;
        }
      }

      final totalTrackCount = songs.length;
      final progress = totalTrackCount == 0
          ? 0.0
          : ((completedProgress + inFlightProgress) / totalTrackCount).clamp(
              0.0,
              1.0,
            );
      return AlbumTileDownloadState(
        fullyDownloaded: completeCount >= totalTrackCount,
        downloadedTrackCount: completeCount,
        totalTrackCount: totalTrackCount,
        queued: hasQueued,
        progress: progress,
      );
    });

final radioStationsProvider = FutureProvider<List<InternetRadioStation>>((
  ref,
) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <InternetRadioStation>[];
  }
  return api.getInternetRadioStations();
});

final searchResultsProvider = FutureProvider.autoDispose
    .family<SearchResult3, String>((
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

class AudioHandlerStateController extends Notifier<NavisPlaybackHandler?> {
  @override
  NavisPlaybackHandler? build() => null;
}

final audioHandlerStateProvider =
    NotifierProvider<AudioHandlerStateController, NavisPlaybackHandler?>(
      AudioHandlerStateController.new,
    );

final audioHandlerProvider = Provider<NavisPlaybackHandler?>((ref) {
  return ref.watch(audioHandlerStateProvider);
});

final _rollingCacheBudgetMbStreamProvider = StreamProvider<int>((ref) {
  final dao = ref.watch(navisDatabaseProvider).appSettingsDao;
  return dao.watchRollingCacheBudgetMb();
});

final rollingCacheBudgetBytesProvider = Provider<int>((ref) {
  final mb =
      ref.watch(_rollingCacheBudgetMbStreamProvider).asData?.value ?? 2048;
  return mb * 1024 * 1024;
});

final rollingCacheManagerProvider = Provider<RollingCacheManager>((ref) {
  final cacheDao = ref.watch(navisDatabaseProvider).cacheDao;
  return DriftRollingCacheManager(cacheDao: cacheDao);
});

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    yield const PlaybackSnapshot.idle();
    return;
  }
  yield handler.snapshot;
  yield* handler.snapshotStream;
});

final playerStateProvider = Provider<PlaybackSnapshot>((ref) {
  final snapshot = ref.watch(playbackSnapshotProvider).asData?.value;
  return snapshot ?? const PlaybackSnapshot.idle();
});

final currentMediaItemProvider = StreamProvider<MediaItem?>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    yield null;
    return;
  }
  yield handler.currentMediaItem;
  yield* handler.mediaItemStream;
});

/// Emits an event whenever a radio stream encounters a mid-playback error.
/// Consumed by AppShell to display a dismissible snackbar.
final radioStreamErrorProvider = StreamProvider<void>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) return const Stream<void>.empty();
  return handler.radioStreamErrorStream;
});

/// Whether the player is currently playing audio.
final isPlayingProvider = Provider<bool>((ref) {
  return ref.watch(playerStateProvider.select((s) => s.playing));
});

/// The song ID of the currently playing track, or null.
final currentSongProvider = Provider<String?>((ref) {
  return ref.watch(playerStateProvider.select((s) => s.currentSongId));
});

/// The index of the currently playing track within the queue, or null.
final currentIndexProvider = Provider<int?>((ref) {
  return ref.watch(playerStateProvider.select((s) => s.currentIndex));
});

/// The station ID currently playing, or null when not in radio mode.
final currentRadioStationIdProvider = Provider<String?>((ref) {
  final snapshot = ref.watch(playerStateProvider);
  return snapshot.radioStation?.stationId;
});

final playbackPositionProvider = StreamProvider<Duration>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return Stream<Duration>.value(Duration.zero);
  }
  return handler.positionStream;
});

final lyricsProvider = FutureProvider.family<LyricsList, String>((
  ref,
  songId,
) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const LyricsList();
  }

  // Whether the OpenSubsonic lyrics endpoint is unsupported by this server.
  var openSubsonicUnsupported = false;

  // Try OpenSubsonic getLyricsBySongId first.
  try {
    return await api.getLyricsBySongId(songId);
  } on SubsonicNotFoundException {
    // Endpoint unsupported — fall through to legacy.
    openSubsonicUnsupported = true;
  } on SubsonicApiException {
    // Other API error (e.g. malformed response) — fall through to legacy.
    openSubsonicUnsupported = true;
  } on SubsonicConnectionException {
    // Network error — propagate as typed lyrics exception.
    throw const LyricsNetworkException();
  } on Exception {
    // Unknown exception — treat as network error.
    throw const LyricsNetworkException();
  }

  // Legacy fallback: getLyrics(artist, title).
  try {
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    final songs = await dao.getSongsByIds(<String>[songId]);
    if (songs.isEmpty) {
      return const LyricsList();
    }
    final song = songs.first;
    final artist = song.artistName;
    final title = song.title;
    if (artist == null || title.isEmpty) {
      return const LyricsList();
    }
    return await api.getLyrics(artist: artist, title: title);
  } on SubsonicConnectionException {
    throw const LyricsNetworkException();
  } on SubsonicNotFoundException {
    // Both endpoints unsupported — server doesn't support lyrics at all.
    throw const LyricsUnsupportedException();
  } on SubsonicApiException {
    // If both endpoints failed with API errors, it's an unsupported server.
    if (openSubsonicUnsupported) {
      throw const LyricsUnsupportedException();
    }
    throw const LyricsNetworkException();
  }
});

final artistInfoProvider = FutureProvider.family<ArtistInfo?, String>((
  ref,
  artistId,
) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return null;
  }

  return api.getArtistInfo2(artistId);
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
  return dao.watchCachedTracksByType(CacheType.rolling).map((tracks) {
    final total = tracks.fold<int>(0, (sum, item) => sum + item.fileSize);
    return CacheStats(trackCount: tracks.length, totalBytes: total);
  });
});

final permanentCacheStatsProvider = StreamProvider<CacheStats>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao.watchCachedTracksByType(CacheType.permanent).map((tracks) {
    final total = tracks.fold<int>(0, (sum, item) => sum + item.fileSize);
    return CacheStats(trackCount: tracks.length, totalBytes: total);
  });
});

final cachedSongIdsProvider = StreamProvider<Set<String>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao.watchCachedTracks().map(
    (tracks) => tracks.map((track) => track.songId).toSet(),
  );
});

/// Maps songId → CacheType for all cached tracks (rolling + permanent).
final cachedSongTypesProvider = StreamProvider<Map<String, CacheType>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao.watchCachedTracks().map(
    (tracks) => {for (final t in tracks) t.songId: t.cacheType},
  );
});

class DownloadedOnlyFilterController extends Notifier<bool> {
  @override
  bool build() => false;

  bool get enabled => state;

  set enabled(bool value) => state = value;
}

final downloadedOnlyFilterProvider =
    NotifierProvider<DownloadedOnlyFilterController, bool>(
      DownloadedOnlyFilterController.new,
    );

final downloadedSongIdsProvider = StreamProvider<Set<String>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracksByType(CacheType.permanent)
      .map(
        (tracks) => tracks.map((track) => track.songId).toSet(),
      );
});

/// Provides the set of album IDs and artist IDs that have permanently cached
/// (downloaded) tracks **or** are currently in the download queue, for powering
/// "Downloaded Only" library filters.
///
/// Shows albums/artists in the "Downloaded Only" library filter when at least
/// one of their songs is permanently downloaded.  The actual download content
/// remains unchanged – if the user downloaded only 1 song, only that song is
/// stored; but the parent album/artist still shows in the filtered view.
final downloadedContentIdsProvider =
    StreamProvider<({Set<String> albumIds, Set<String> artistIds})>((ref) {
      final db = ref.watch(navisDatabaseProvider);

      final cachedStream = db.cacheDao.watchCachedTracksByType(
        CacheType.permanent,
      );

      return cachedStream.asyncMap((cachedTracks) async {
        final songIds = <String>{};
        for (final t in cachedTracks) {
          songIds.add(t.songId);
        }

        if (songIds.isEmpty) {
          return (albumIds: <String>{}, artistIds: <String>{});
        }

        final songs = await db.libraryDao.getSongsByIds(songIds);
        final albumIds = <String>{};
        final artistIds = <String>{};
        for (final song in songs) {
          if (song.albumId != null) albumIds.add(song.albumId!);
          if (song.artistId != null) artistIds.add(song.artistId!);
        }
        return (albumIds: albumIds, artistIds: artistIds);
      });
    });

/// Provides the list of permanently cached tracks.
final permanentCachedTracksProvider =
    StreamProvider<List<CachedTracksTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).cacheDao;
      return dao.watchCachedTracksByType(CacheType.permanent);
    });

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final db = ref.watch(navisDatabaseProvider);
  final service = DownloadService(
    cacheDao: db.cacheDao,
    downloadQueueDao: db.downloadQueueDao,
    libraryDao: db.libraryDao,
    readApiClient: () => ref.read(subsonicApiProvider),
    readWifiOnly: () =>
        ref.read(appSettingsProvider).asData?.value.wifiOnlyDownloads ?? false,
    readIsWifi: () => ref.read(networkTypeProvider) == NetworkType.wifi,
  );
  // Service.start() is async but we fire-and-forget here — the subscription
  // inside start() processes the queue independently.
  // ignore: discarded_futures
  service.start();
  ref.onDispose(service.stop);
  return service;
});

final connectivityHintProvider = Provider<String>((ref) {
  final network = ref.watch(networkTypeProvider);
  return network.name;
});

/// Whether downloads should only proceed on Wi-Fi.
final wifiOnlyDownloadsProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.wifiOnlyDownloads;
});

final autoDownloadStarredOnWifiProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.autoDownloadStarredOnWifi;
});

/// Current theme mode string ('light', 'dark', 'oled', 'system').
final themeModeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.themeMode;
});

/// Current color scheme seed color value (null = default blue).
final colorSchemeSeedProvider = Provider<int?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.colorSchemeSeed;
});

/// Whether the Now Playing screen background should be tinted with album art.
final artTintedNowPlayingProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.artTintedNowPlaying;
});

/// Whether app-wide accent color should follow currently playing album art.
final dynamicAlbumColorEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.dynamicAlbumColorEnabled;
});

/// Custom color presets stored as a JSON list of ARGB32 ints.
final customColorPresetsProvider = StreamProvider<List<int>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).appSettingsDao;
  return dao.watchCustomColorPresets().map((json) {
    if (json == null || json.trim().isEmpty) return <int>[];
    try {
      final decoded = (jsonDecode(json) as List).cast<int>();
      return decoded;
    } on Object {
      return <int>[];
    }
  });
});

/// The app's own package metadata (version, build number, etc.).
/// Cached for the lifetime of the app — the version never changes at runtime.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return PackageInfo.fromPlatform();
});

/// Checks whether a newer Navis release is available on Forgejo.
/// Auto-disposed so it re-runs each time a screen watches it freshly.
/// Always checks stable releases only (pre-releases are never surfaced).
final updateProvider = FutureProvider.autoDispose<UpdateInfo?>((ref) async {
  return UpdateRepository().checkForUpdate(includePrerelease: false);
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

// ---------------------------------------------------------------------------
// Smart Queue — AudioMuse plugin detection
// ---------------------------------------------------------------------------

/// Probes the Navidrome server to detect whether the AudioMuse plugin is
/// installed by calling `getSimilarSongs2` with a random track.
///
/// Returns `true` when the endpoint returns at least one result (i.e. the
/// plugin is active and has analysed the library).  The result is cached
/// per server session (re-evaluated on server config change).
final smartQueueAvailableProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) return false;
  try {
    // Grab a random song to use as the probe seed.
    final randomSongs = await api.getRandomSongs(size: 1);
    if (randomSongs.isEmpty) return false;
    final probe = randomSongs.first;
    final similar = await api.getSimilarSongs(probe.id, count: 3);
    return similar.isNotEmpty;
  } on Exception {
    return false;
  }
});

// ---------------------------------------------------------------------------
// AudioMuse AI providers (direct API — disabled)
// ---------------------------------------------------------------------------

/// Whether AudioMuse AI integration is enabled and configured in settings.
///
/// **Disabled** — the AudioMuse Navidrome plugin already provides
/// AI-powered similar songs and artists transparently through the
/// standard Subsonic API (`getSimilarSongs2`, `getArtistInfo2`).
/// Direct client-to-AudioMuse communication is unnecessary and blocked
/// by the Authentik reverse-proxy. Re-enable once a viable internal
/// route is available.
final audioMuseAvailableProvider = Provider<bool>((ref) {
  // Original gate (kept for future re-enablement):
  // final settings =
  //     ref.watch(appSettingsProvider).asData?.value ??
  //     const AppSettingsModel.defaults();
  // return settings.audioMuseEnabled &&
  //     (settings.audioMuseServerUrl?.trim().isNotEmpty ?? false);
  return false;
});

/// The current AudioMuse configuration extracted from app settings.
final audioMuseConfigProvider = Provider<AudioMuseConfig>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return AudioMuseConfig(
    serverUrl: settings.audioMuseServerUrl ?? '',
    apiKey: settings.audioMuseApiKey,
    enabled: settings.audioMuseEnabled,
  );
});

/// AudioMuse repository — `null` when AudioMuse is not configured.
///
/// Consumers should check [audioMuseAvailableProvider] before using this.
final audioMuseRepositoryProvider = Provider<AudioMuseRepository?>((ref) {
  final config = ref.watch(audioMuseConfigProvider);
  if (!config.isConfigured) return null;
  final client = AudioMuseApiClient(
    baseUrl: config.serverUrl,
    apiKey: config.apiKey,
  );
  return AudioMuseRepository(client);
});

/// AI-powered similar artists for a given artist ID.
/// Returns an empty list when AudioMuse is unavailable.
final audioMuseSimilarArtistsProvider = FutureProvider.autoDispose
    .family<List<AudioMuseRecommendation>, String>(
      (ref, artistId) async {
        final repo = ref.watch(audioMuseRepositoryProvider);
        if (repo == null) return const [];
        return repo.getSimilarArtists(artistId);
      },
    );

/// AI-powered similar albums for a given album ID.
/// Returns an empty list when AudioMuse is unavailable.
final audioMuseSimilarAlbumsProvider = FutureProvider.autoDispose
    .family<List<AudioMuseRecommendation>, String>(
      (ref, albumId) async {
        final repo = ref.watch(audioMuseRepositoryProvider);
        if (repo == null) return const [];
        return repo.getSimilarAlbums(albumId);
      },
    );

/// AI-powered home screen recommendations ("You might also like").
/// Returns an empty list when AudioMuse is unavailable.
final audioMuseHomeRecommendationsProvider =
    FutureProvider<List<AudioMuseRecommendation>>((ref) async {
      final repo = ref.watch(audioMuseRepositoryProvider);
      if (repo == null) return const [];
      return repo.getHomeRecommendations();
    });

/// AI-powered song recommendations for smart auto-queue.
final audioMuseSongRecommendationsProvider = FutureProvider.autoDispose
    .family<List<AudioMuseRecommendation>, String>((ref, seedSongId) async {
      final repo = ref.watch(audioMuseRepositoryProvider);
      if (repo == null) return const [];
      return repo.getRecommendations(seedSongId: seedSongId);
    });

List<AlbumYearSection> _buildAlbumYearSections(List<AlbumsTableData> albums) {
  if (albums.isEmpty) {
    return const <AlbumYearSection>[];
  }

  final sections = <AlbumYearSection>[];
  final byYear = <int, List<AlbumsTableData>>{};
  final unknownYearAlbums = <AlbumsTableData>[];

  for (final album in albums) {
    final year = album.year;
    if (year == null) {
      unknownYearAlbums.add(album);
      continue;
    }
    (byYear[year] ??= <AlbumsTableData>[]).add(album);
  }

  final sortedYears = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final year in sortedYears) {
    final albumsForYear = byYear[year]!
      ..sort((a, b) {
        final nameComparison = a.name.compareTo(b.name);
        if (nameComparison != 0) {
          return nameComparison;
        }
        return a.id.compareTo(b.id);
      });
    sections.add(
      AlbumYearSection(
        title: '$year',
        decadeStart: (year ~/ 10) * 10,
        year: year,
        albums: List<AlbumsTableData>.unmodifiable(albumsForYear),
      ),
    );
  }

  if (unknownYearAlbums.isNotEmpty) {
    unknownYearAlbums.sort((a, b) {
      final nameComparison = a.name.compareTo(b.name);
      if (nameComparison != 0) {
        return nameComparison;
      }
      return a.id.compareTo(b.id);
    });
    sections.add(
      AlbumYearSection(
        title: 'Unknown year',
        decadeStart: null,
        year: null,
        isUnknownYear: true,
        albums: List<AlbumsTableData>.unmodifiable(unknownYearAlbums),
      ),
    );
  }

  return List<AlbumYearSection>.unmodifiable(sections);
}
