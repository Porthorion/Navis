import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
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
  return dao.watchAlbumById(albumId).asyncExpand((album) {
    if (album == null) {
      return Stream<AlbumWithSongs?>.value(null);
    }
    return dao
        .watchSongsByAlbum(albumId)
        .map((songs) => AlbumWithSongs(album: album, songs: songs));
  });
});

typedef AlbumPageRequest = ({AlbumSortOrder sort, int limit});

final albumPageSizeProvider = Provider<int>((_) => 60);

final albumCountProvider = StreamProvider<int>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumCount();
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

  // Try OpenSubsonic getLyricsBySongId first.
  try {
    return await api.getLyricsBySongId(songId);
  } on Exception {
    // Extension not supported — fall through to legacy endpoint.
  }

  // Legacy fallback: getLyrics(artist, title).
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
  return api.getLyrics(artist: artist, title: title);
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

/// Checks whether a newer Navis release is available on Forgejo.
/// Auto-disposed so it re-runs each time a screen watches it freshly.
final updateProvider = FutureProvider.autoDispose<UpdateInfo?>((ref) async {
  final settings =
      ref.read(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return UpdateRepository().checkForUpdate(
    includePrerelease: settings.updateChannel == 'beta',
  );
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
// AudioMuse AI providers
// ---------------------------------------------------------------------------

/// Whether AudioMuse AI integration is enabled and configured in settings.
final audioMuseAvailableProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.audioMuseEnabled &&
      (settings.audioMuseServerUrl?.trim().isNotEmpty ?? false);
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
