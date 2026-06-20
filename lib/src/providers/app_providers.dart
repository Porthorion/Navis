import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show BorderRadius;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
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
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/settings/data/battery_optimization_service.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/routing/desktop_layout.dart' show isDesktopRuntime;
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path_provider/path_provider.dart';

final navisDatabaseProvider = Provider<NavisDatabase>((ref) {
  final database = NavisDatabase();
  ref.onDispose(database.close);
  return database;
});

// ---------------------------------------------------------------------------
// Cover art cache manager
// ---------------------------------------------------------------------------

/// Watches the user's cover-art cache-object limit setting.
final _coverArtMaxObjectsProvider = StreamProvider<int>((ref) {
  return ref
      .watch(navisDatabaseProvider)
      .appSettingsDao
      .watchCoverArtCacheMaxObjects();
});

/// The single active [CacheManager] for all cover art images.
///
/// Uses [ref.read] (not [ref.watch]) so the provider **never** rebuilds
/// reactively. This is critical: [flutter_cache_manager] opens its SQLite
/// database asynchronously inside the constructor. If `dispose()` is called
/// before `openDatabase()` returns, the internal `db!` is still null and the
/// null-check throws. By reading the setting once at creation time, we
/// guarantee no reactive rebuilds, so the manager's lifecycle is:
///   1. Created (DB open starts asynchronously).
///   2. Runs for the lifetime of the app.
///   3. Explicitly invalidated via [ref.invalidate] from the settings screen
///      — by which point the DB has been open for seconds and disposal is safe.
final coverArtLoadCoordinatorProvider = Provider<CoverArtLoadCoordinator>((
  ref,
) {
  return CoverArtLoadCoordinator();
});

final coverArtCacheManagerProvider = Provider<CacheManager>((ref) {
  // ref.read, not ref.watch — prevents reactive rebuilds caused by the
  // settings stream emitting at startup (AsyncLoading → AsyncData), which
  // would dispose the manager before its internal SQLite DB finishes opening.
  final maxObjects = ref.read(_coverArtMaxObjectsProvider).value ?? 0;
  final coordinator = ref.watch(coverArtLoadCoordinatorProvider);
  final service = CoverArtHttpFileService(
    loadCoordinator: coordinator,
    reportNetworkUsage: ({required category, required bytes}) {
      ref
          .read(networkUsageMeterProvider)
          .record(
            category: category,
            bytes: bytes,
          );
    },
  );
  final manager = createCoverArtCacheManager(
    maxNrOfCacheObjects: maxObjects,
    fileService: service,
  );
  ref.onDispose(() {
    service.close(force: true);
    // ignore: discarded_futures
    manager.dispose();
  });
  return manager;
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

final networkUsageMeterProvider = Provider<NetworkUsageMeter>((ref) {
  final meter = NetworkUsageMeter(
    dao: ref.watch(navisDatabaseProvider).networkUsageDao,
    readNetworkType: () => ref.read(networkTypeProvider),
  );
  unawaited(
    meter.pruneOld().catchError((Object error, StackTrace stackTrace) {
      AppLogger.debug('Network usage prune failed: $error\n$stackTrace');
    }),
  );
  return meter;
});

DateTime _networkUsageSinceForDays(int days) {
  final now = DateTime.now();
  if (days <= 1) {
    return DateTime(now.year, now.month, now.day);
  }
  return now.subtract(Duration(days: days));
}

final networkUsageCategoryTotalsProvider =
    StreamProvider.family<List<NetworkUsageCategoryTotal>, int>((ref, days) {
      final since = _networkUsageSinceForDays(days);
      return ref
          .watch(navisDatabaseProvider)
          .networkUsageDao
          .watchCategoryTotalsSince(since);
    });

final networkUsageTotalProvider = StreamProvider.family<NetworkUsageTotal, int>(
  (ref, days) {
    final since = _networkUsageSinceForDays(days);
    return ref
        .watch(navisDatabaseProvider)
        .networkUsageDao
        .watchTotalSince(
          since,
        );
  },
);

final networkUsageSessionTotalsProvider =
    Provider<List<NetworkUsageSessionTotal>>((ref) {
      return ref.watch(networkUsageMeterProvider).sessionTotals;
    });

class StreamingQuality {
  const StreamingQuality({required this.label, this.maxBitRate, this.format});

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

final lrclibClientProvider = Provider<LrclibClient>((_) {
  return LrclibClient();
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

final useLrclibProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.useLrclib;
});

final albumQueueEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.albumQueueEnabled;
});

final likedQueueEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.likedQueueEnabled;
});

final matchFlowEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.matchFlowEnabled;
});

final matchFlowDaoProvider = Provider<MatchFlowDao>((ref) {
  return ref.watch(navisDatabaseProvider).matchFlowDao;
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
    reportNetworkUsage: ({required category, required bytes}) {
      ref
          .read(networkUsageMeterProvider)
          .record(
            category: category,
            bytes: bytes,
            networkType: networkType,
          );
    },
  );
});

/// Whether a Last.fm API key is bundled at build time via NAVIS_LASTFM_API_KEY.
final lastFmBundledKeyProvider = Provider<bool>((_) {
  return AppConstants.lastFmApiKey.trim().isNotEmpty;
});

/// The effective Last.fm API key.
///
/// Prefers the build-time key (NAVIS_LASTFM_API_KEY). When no build-time key
/// is present, falls back to the user-provided key stored in app settings.
final lastFmApiKeyProvider = Provider<String>((ref) {
  const bundledKey = AppConstants.lastFmApiKey;
  if (bundledKey.trim().isNotEmpty) {
    return bundledKey.trim();
  }
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.lastFmApiKey?.trim() ?? '';
});

final hasLastFmApiKeyProvider = Provider<bool>((ref) {
  return ref.watch(lastFmApiKeyProvider).isNotEmpty;
});

/// Last.fm client used for recommendation lookups.
///
/// Returns `null` when no API key is available (neither bundled nor user-set).
final lastFmApiClientProvider = Provider<LastFmApiClient?>((ref) {
  final apiKey = ref.watch(lastFmApiKeyProvider);
  if (apiKey.isEmpty) {
    return null;
  }
  return LastFmApiClient(apiKey: apiKey);
});

final lastFmApiClientFactoryProvider =
    Provider<LastFmApiClient Function(String)>(
      (_) =>
          (apiKey) => LastFmApiClient(apiKey: apiKey),
    );

final listenBrainzApiClientProvider = Provider<ListenBrainzApiClient>((_) {
  return ListenBrainzApiClient();
});

final externalScrobbleCredentialStoreProvider =
    Provider<ExternalScrobbleCredentialStore>((_) {
      return const FlutterExternalScrobbleCredentialStore();
    });

final legacyInstantMixSettingProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.legacyInstantMixEnabled;
});

final legacyInstantMixLockedProvider = Provider<bool>((ref) {
  return !ref.watch(hasLastFmApiKeyProvider);
});

enum PreferredMixMode { sameVibes, legacyInstantMix }

final preferredMixModeProvider = Provider<PreferredMixMode>((ref) {
  if (ref.watch(legacyInstantMixLockedProvider)) {
    return PreferredMixMode.legacyInstantMix;
  }
  return ref.watch(legacyInstantMixSettingProvider)
      ? PreferredMixMode.legacyInstantMix
      : PreferredMixMode.sameVibes;
});

final scrobbleServiceProvider = Provider<ScrobbleService>((ref) {
  final database = ref.watch(navisDatabaseProvider);
  final service = DriftScrobbleService(
    dao: database.scrobbleDao,
    readApiClient: () => ref.read(subsonicApiProvider),
    readScrobbleEnabled: () =>
        ref.read(appSettingsProvider).asData?.value.scrobbleEnabled ?? true,
    readListenBrainzCredentials: () async {
      final settings =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      if (!settings.listenBrainzScrobblingEnabled ||
          !settings.listenBrainzTokenValid) {
        return null;
      }
      final token =
          (await ref
                  .read(externalScrobbleCredentialStoreProvider)
                  .readListenBrainzToken())
              ?.trim() ??
          '';
      if (token.isEmpty) {
        return null;
      }
      return ListenBrainzScrobbleCredentials(userToken: token);
    },
    createListenBrainzClient: () => ref.read(listenBrainzApiClientProvider),
    onListenBrainzInvalidToken: () {
      unawaited(
        database.appSettingsDao.updateListenBrainzScrobblingState(
          enabled: false,
          tokenValid: false,
        ),
      );
    },
    readReachable: () => ref.read(networkTypeProvider) != NetworkType.offline,
  );
  service.start();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final listenBrainzFeedbackServiceProvider =
    Provider<ListenBrainzFeedbackService>((ref) {
      final database = ref.watch(navisDatabaseProvider);
      return ListenBrainzFeedbackService(
        dao: database.listenBrainzFeedbackDao,
        libraryDao: database.libraryDao,
        readCredentials: () {
          final settings =
              ref.read(appSettingsProvider).asData?.value ??
              const AppSettingsModel.defaults();
          return readListenBrainzFeedbackCredentials(
            settings: settings,
            readToken: () => ref
                .read(externalScrobbleCredentialStoreProvider)
                .readListenBrainzToken(),
          );
        },
        createClient: () => ref.read(listenBrainzApiClientProvider),
        readReachable: () =>
            ref.read(networkTypeProvider) != NetworkType.offline,
        onInvalidToken: () {
          unawaited(
            database.appSettingsDao.updateListenBrainzScrobblingState(
              enabled: false,
              tokenValid: false,
              clearUserName: true,
            ),
          );
        },
      );
    });

typedef AudioHandlerInitializer = Future<NavisPlaybackHandler> Function();

final audioBootstrapTimeoutProvider = Provider<Duration>((_) {
  return const Duration(seconds: 5);
});

final audioHandlerInitializerProvider = Provider<AudioHandlerInitializer>((
  ref,
) {
  return () async {
    try {
      await ref
          .read(appSettingsProvider.future)
          .timeout(const Duration(seconds: 2));
    } on TimeoutException {
      AppLogger.warning(
        'App settings were not hydrated before audio init. '
        'Continuing with fallback runtime defaults and retrying sync later.',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'App settings preload failed before audio init. '
        '$error\n$stackTrace',
      );
    }

    final database = ref.read(navisDatabaseProvider);
    final handler = await initNavisAudioHandler(
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: database.playQueueDao,
      matchFlowDao: database.matchFlowDao,
      historyDao: database.historyDao,
      sourceResolver: PlaybackSourceResolver(
        cacheDao: database.cacheDao,
        libraryDao: database.libraryDao,
        rollingCacheManager: ref.read(rollingCacheManagerProvider),
        readApiClient: () => ref.read(subsonicApiProvider),
        readStreamingQuality: () => ref.read(activeStreamingQualityProvider),
        readRollingCacheDirectory: getTemporaryDirectory,
        readCachedPlaybackFirst: () {
          final settings =
              ref.read(appSettingsProvider).asData?.value ??
              const AppSettingsModel.defaults();
          return settings.cachedPlaybackFirst;
        },
        readPreferAnyCache: () =>
            ref.read(networkTypeProvider) == NetworkType.cellular,
        readCanStream: () =>
            ref.read(networkTypeProvider) != NetworkType.offline,
      ),
      readApiClient: () => ref.read(subsonicApiProvider),
      rollingCacheManager: ref.read(rollingCacheManagerProvider),
      rollingCacheBudgetBytes: ref.read(rollingCacheBudgetBytesProvider),
      scrobbleService: ref.read(scrobbleServiceProvider),
      listenBrainzFeedbackService: ref.read(
        listenBrainzFeedbackServiceProvider,
      ),
      starSyncDao: database.starSyncDao,
      reportNetworkUsage: ({required category, required bytes}) {
        ref
            .read(networkUsageMeterProvider)
            .record(
              category: category,
              bytes: bytes,
            );
      },
      readRuntimeSettings: () {
        final settings =
            ref.read(appSettingsProvider).asData?.value ??
            const AppSettingsModel.defaults();
        final onCellular =
            ref.read(networkTypeProvider) == NetworkType.cellular;
        return PlaybackRuntimeSettings(
          gaplessEnabled: settings.gaplessEnabled && !onCellular,
          equalizerEnabled: settings.equalizerEnabled,
          equalizerBandGains: settings.equalizerBandGains,
          loudnessEnabled: settings.loudnessEnabled,
          loudnessTargetGainDb: settings.loudnessTargetGainDb,
          crossfadeEnabled: settings.crossfadeEnabled && !onCellular,
          crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
          crossfadeType: settings.crossfadeType,
          replayGainMode: settings.replayGainMode,
          replayGainPreamp: settings.replayGainPreamp,
          playbackSpeed: settings.playbackSpeed,
          albumQueueEnabled: settings.albumQueueEnabled,
          matchFlowEnabled: settings.matchFlowEnabled,
        );
      },
    );
    await handler.waitUntilReady();

    try {
      await handler.applyRuntimeSettings();
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Runtime settings apply failed after audio init: '
        '$error\n$stackTrace',
      );
    }

    if (ref.read(appSettingsProvider).asData?.value == null) {
      unawaited(() async {
        try {
          await ref.read(appSettingsProvider.future);
          await handler.applyRuntimeSettings();
          AppLogger.info(
            'Deferred runtime settings sync applied after settings hydration.',
          );
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Deferred runtime settings sync failed: '
            '$error\n$stackTrace',
          );
        }
      }());
    }

    return handler;
  };
});

enum AudioBootstrapStatus { initializing, ready, failed }

enum PlaybackUnavailableReason { initializing, startupFailed, unavailable }

class PlaybackUnavailableException implements Exception {
  const PlaybackUnavailableException({required this.reason, this.message});

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
    this.attempt = 0,
    this.elapsedMs,
    this.timedOut = false,
    this.recoveredFromTimeout = false,
  });

  const AudioBootstrapState.initializing({int attempt = 0})
    : status = AudioBootstrapStatus.initializing,
      handler = null,
      errorMessage = null,
      attempt = attempt,
      elapsedMs = null,
      timedOut = false,
      recoveredFromTimeout = false;

  const AudioBootstrapState.ready(
    NavisPlaybackHandler readyHandler, {
    int attempt = 0,
    int? elapsedMs,
    bool recoveredFromTimeout = false,
  }) : status = AudioBootstrapStatus.ready,
       handler = readyHandler,
       errorMessage = null,
       attempt = attempt,
       elapsedMs = elapsedMs,
       timedOut = false,
       recoveredFromTimeout = recoveredFromTimeout;

  const AudioBootstrapState.failed(
    String failureMessage, {
    int attempt = 0,
    int? elapsedMs,
    bool timedOut = false,
  }) : status = AudioBootstrapStatus.failed,
       handler = null,
       errorMessage = failureMessage,
       attempt = attempt,
       elapsedMs = elapsedMs,
       timedOut = timedOut,
       recoveredFromTimeout = false;

  final AudioBootstrapStatus status;
  final NavisPlaybackHandler? handler;
  final String? errorMessage;
  final int attempt;
  final int? elapsedMs;
  final bool timedOut;
  final bool recoveredFromTimeout;

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
    state = AudioBootstrapState.initializing(attempt: attemptId);
    final audioHandlerState = ref.read(audioHandlerStateProvider.notifier);
    unawaited(() async {
      await audioHandlerState.clearHandler();
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
        final audioHandlerState = ref.read(audioHandlerStateProvider.notifier);
        await audioHandlerState.setHandler(audioHandler);
        final elapsedMs = stopwatch.elapsedMilliseconds;
        state = AudioBootstrapState.ready(
          audioHandler,
          attempt: attemptId,
          elapsedMs: elapsedMs,
          recoveredFromTimeout: recoveredFromTimeout,
        );
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
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final audioHandlerState = ref.read(audioHandlerStateProvider.notifier);
        await audioHandlerState.clearHandler();
        state = AudioBootstrapState.failed(
          message,
          attempt: attemptId,
          elapsedMs: elapsedMs,
          timedOut: timedOut,
        );
        if (!completer.isCompleted) {
          completer.complete();
        }
      } finally {
        stopwatch.stop();
        if (_activeAttempt == attemptId) {
          _inFlight = null;
        }
      }
    }());
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

class ArtistAlbumSections {
  const ArtistAlbumSections({
    this.albums = const <AlbumsTableData>[],
    this.featuredIn = const <AlbumsTableData>[],
  });

  final List<AlbumsTableData> albums;
  final List<AlbumsTableData> featuredIn;

  bool get isEmpty => albums.isEmpty && featuredIn.isEmpty;
}

Future<void> _hydrateArtistFromServer(Ref ref, String artistId) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }

  final db = ref.read(navisDatabaseProvider);
  final detail = await api.getArtist(artistId);

  await db.libraryDao.upsertArtists(<ArtistsTableCompanion>[
    ArtistsTableCompanion.insert(
      id: detail.id,
      name: detail.name,
      albumCount: Value(detail.albumCount),
      coverArt: Value(detail.coverArt),
      starred: Value(detail.starred),
    ),
  ]);

  if (detail.albums.isEmpty) {
    return;
  }

  final totalCandidates = detail.albums.length;
  final fallbackAlbums = detail.albums
      .where((album) {
        final id = album.id.trim();
        final name = album.name.trim();
        if (id.isEmpty || name.isEmpty) {
          return false;
        }
        final songCount = album.songCount;
        if (songCount != null && songCount <= 0) {
          // Avoid creating empty placeholder albums from partial server data.
          return false;
        }
        return true;
      })
      .map(
        (album) => AlbumsTableCompanion.insert(
          id: album.id,
          name: album.name,
          artistId: Value(album.artistId ?? detail.id),
          artistName: Value(album.artist ?? detail.name),
          artists: Value(album.artists),
          songCount: Value(album.songCount),
          duration: Value(album.duration),
          year: Value(album.year),
          genre: Value(album.genre),
          coverArt: Value(album.coverArt),
          // Keep this absent so existing hydrated rows are not downgraded.
          starred: Value(album.starred),
          userRating: Value(album.userRating),
          playCount: Value(album.playCount),
          serverCreatedAt: Value(album.created),
        ),
      )
      .toList(growable: false);

  final skippedCandidates = totalCandidates - fallbackAlbums.length;
  if (skippedCandidates > 0) {
    AppLogger.debug(
      'Artist fallback hydration filtered $skippedCandidates/$totalCandidates '
      'empty candidate albums for artist=$artistId',
    );
  }

  if (fallbackAlbums.isEmpty) {
    AppLogger.debug(
      'Artist fallback hydration skipped all candidate albums for artist=$artistId',
    );
  } else {
    await db.libraryDao.upsertAlbums(fallbackAlbums);
  }

  final existingArtistAlbums = await db.libraryDao.getAlbumsByArtist(artistId);
  final staleEmptyAlbumIds = existingArtistAlbums
      .where(
        (album) =>
            !album.songsHydrated &&
            album.songCount != null &&
            album.songCount! <= 0,
      )
      .map((album) => album.id)
      .toList(growable: false);
  if (staleEmptyAlbumIds.isNotEmpty) {
    await db.libraryDao.deleteAlbumsByIds(staleEmptyAlbumIds);
    AppLogger.debug(
      'Artist fallback hydration pruned ${staleEmptyAlbumIds.length} empty '
      'albums for artist=$artistId',
    );
  }
}

Future<void> _hydrateAlbumFromServer(Ref ref, String albumId) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }

  final db = ref.read(navisDatabaseProvider);
  var detail = await api.getAlbum(albumId);
  if (detail.songs.isEmpty && (detail.songCount ?? 0) > 0) {
    AppLogger.warning(
      'Album hydrate returned empty songs on first attempt for album=$albumId. '
      'Retrying once.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final retried = await api.getAlbum(albumId);
    if (retried.songs.isNotEmpty) {
      detail = retried;
      AppLogger.info(
        'Album hydrate retry recovered ${retried.songs.length} songs for '
        'album=$albumId.',
      );
    }
  }

  final existingSongs = await db.libraryDao.watchSongsByAlbum(detail.id).first;
  final shouldPreserveExistingSongs =
      detail.songs.isEmpty &&
      existingSongs.isNotEmpty &&
      (detail.songCount == null || detail.songCount! > 0);
  if (shouldPreserveExistingSongs) {
    AppLogger.warning(
      'Album hydrate returned empty songs for album=${detail.id}; preserving '
      '${existingSongs.length} existing local tracks.',
    );
  }
  final effectiveSongCount =
      shouldPreserveExistingSongs && detail.songCount == null
      ? existingSongs.length
      : detail.songCount;

  final artistRows = <String, ArtistsTableCompanion>{};
  final primaryArtistId = detail.artistId?.trim();
  if (primaryArtistId != null && primaryArtistId.isNotEmpty) {
    final primaryArtistName = (detail.artist ?? '').trim();
    artistRows[primaryArtistId] = ArtistsTableCompanion.insert(
      id: primaryArtistId,
      name: primaryArtistName.isEmpty ? primaryArtistId : primaryArtistName,
      coverArt: Value(detail.coverArt),
    );
  }

  for (final song in detail.songs) {
    final songArtistId = song.artistId?.trim();
    if (songArtistId == null || songArtistId.isEmpty) {
      continue;
    }
    artistRows.putIfAbsent(songArtistId, () {
      final songArtistName = (song.artist ?? '').trim();
      return ArtistsTableCompanion.insert(
        id: songArtistId,
        name: songArtistName.isEmpty ? songArtistId : songArtistName,
      );
    });
  }

  if (artistRows.isNotEmpty) {
    await db.libraryDao.upsertArtists(
      artistRows.values.toList(growable: false),
    );
  }

  await db.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
    AlbumsTableCompanion.insert(
      id: detail.id,
      name: detail.name,
      artistId: Value(detail.artistId),
      artistName: Value(detail.artist),
      artists: Value(detail.artists),
      songCount: Value(effectiveSongCount),
      duration: Value(detail.duration),
      year: Value(detail.year),
      genre: Value(detail.genre),
      coverArt: Value(detail.coverArt),
      songsHydrated: const Value(true),
      starred: Value(detail.starred),
      userRating: Value(detail.userRating),
      playCount: Value(detail.playCount),
      serverCreatedAt: Value(detail.created),
    ),
  ]);

  if (!shouldPreserveExistingSongs) {
    await db.libraryDao.replaceSongsForAlbum(
      detail.id,
      detail.songs
          .map(
            (song) => SongsTableCompanion.insert(
              id: song.id,
              title: song.title,
              albumId: Value(song.albumId ?? detail.id),
              artistId: Value(song.artistId),
              artistName: Value(song.artist),
              albumName: Value(song.album ?? detail.name),
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
            ),
          )
          .toList(growable: false),
    );
  }

  await db.libraryDao.markAlbumSongsHydrated(detail.id);
}

Future<void> _refreshAlbumInfoFromServer(Ref ref, String albumId) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }
  final db = ref.read(navisDatabaseProvider);
  final now = DateTime.now();
  final info = await api.getAlbumInfo2(albumId);
  await db.libraryDao.upsertAlbumInfoCache(
    albumId: albumId,
    notes: info.notes,
    musicBrainzId: info.musicBrainzId,
    lastFmUrl: info.lastFmUrl,
    smallImageUrl: info.smallImageUrl,
    mediumImageUrl: info.mediumImageUrl,
    largeImageUrl: info.largeImageUrl,
    fetchedAt: now,
  );
}

Future<void> refreshAlbumFromServer(Ref ref, String albumId) async {
  await _hydrateAlbumFromServer(ref, albumId);
  try {
    await _refreshAlbumInfoFromServer(ref, albumId);
  } on Object catch (error, stackTrace) {
    AppLogger.debug(
      'Album info refresh failed for album=$albumId: $error\n$stackTrace',
    );
  }
  ref.invalidate(albumInfoProvider(albumId));
}

final refreshAlbumFromServerProvider =
    Provider.family<Future<void> Function(), String>((ref, albumId) {
      return () => refreshAlbumFromServer(ref, albumId);
    });

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
  final controller = StreamController<ArtistsTableData?>();
  var requestedServerFallback = false;

  final sub = dao
      .watchArtistById(artistId)
      .listen(
        (artist) {
          if (artist == null && !requestedServerFallback) {
            requestedServerFallback = true;
            // Don't emit null yet — keep the StreamProvider in AsyncLoading
            // so the UI shows a shimmer placeholder while we fetch from the
            // server.  If hydration fails, propagate the error so the UI can
            // show an ErrorState with a retry button.
            unawaited(
              _hydrateArtistFromServer(ref, artistId)
                  .timeout(const Duration(seconds: 15))
                  .catchError((Object error, StackTrace stackTrace) {
                    controller.addError(error, stackTrace);
                  }),
            );
          } else {
            controller.add(artist);
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

final albumsByArtistProvider =
    StreamProvider.family<List<AlbumsTableData>, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final controller = StreamController<List<AlbumsTableData>>();
      var requestedServerFallback = false;

      final sub = dao
          .watchAlbumsByArtist(artistId)
          .listen(
            (albums) {
              controller.add(albums);
              if (albums.isNotEmpty || requestedServerFallback) {
                return;
              }
              requestedServerFallback = true;
              unawaited(
                _hydrateArtistFromServer(ref, artistId).catchError((
                  Object error,
                  StackTrace stackTrace,
                ) {
                  AppLogger.warning(
                    'Artist albums fallback hydration failed for artist=$artistId: '
                    '$error\n$stackTrace',
                  );
                }),
              );
            },
            onError: controller.addError,
            onDone: controller.close,
          );

      ref.onDispose(() {
        sub.cancel();
        controller.close();
      });

      return controller.stream;
    });

final artistAlbumSectionsProvider =
    StreamProvider.family<ArtistAlbumSections, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final controller = StreamController<ArtistAlbumSections>();
      var requestedServerFallback = false;

      final sub = dao
          .watchArtistAlbumBuckets(artistId)
          .listen(
            (buckets) {
              final sections = ArtistAlbumSections(
                albums: buckets.primaryAlbums,
                featuredIn: buckets.featuredInAlbums,
              );
              controller.add(sections);
              if (!sections.isEmpty || requestedServerFallback) {
                return;
              }
              requestedServerFallback = true;
              unawaited(
                _hydrateArtistFromServer(ref, artistId).catchError((
                  Object error,
                  StackTrace stackTrace,
                ) {
                  AppLogger.warning(
                    'Artist album sections fallback hydration failed for '
                    'artist=$artistId: $error\n$stackTrace',
                  );
                }),
              );
            },
            onError: controller.addError,
            onDone: controller.close,
          );

      ref.onDispose(() {
        sub.cancel();
        controller.close();
      });

      return controller.stream;
    });

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
  var requestedServerFallback = false;

  final albumSub = dao
      .watchAlbumById(albumId)
      .listen(
        (album) {
          songsSub?.cancel();
          if (album == null) {
            songsSub = null;
            if (!requestedServerFallback) {
              requestedServerFallback = true;
              // Don't emit null yet — keep the StreamProvider in AsyncLoading
              // so the UI shows a shimmer placeholder while we fetch from the
              // server.  If hydration fails, propagate the error so the UI can
              // show an ErrorState with a retry button.
              unawaited(
                _hydrateAlbumFromServer(ref, albumId)
                    .timeout(const Duration(seconds: 15))
                    .catchError((Object error, StackTrace stackTrace) {
                      controller.addError(error, stackTrace);
                    }),
              );
            } else {
              // Hydration was already attempted and the DB still returns null.
              // The album genuinely does not exist on the server.
              controller.add(null);
            }
          } else {
            songsSub = dao.watchSongsByAlbum(albumId).listen((songs) {
              controller.add(AlbumWithSongs(album: album, songs: songs));
              if (songs.isNotEmpty || requestedServerFallback) {
                return;
              }
              requestedServerFallback = true;
              unawaited(
                _hydrateAlbumFromServer(ref, albumId).catchError((
                  Object error,
                  StackTrace stackTrace,
                ) {
                  AppLogger.warning(
                    'Album songs fallback hydration failed for album=$albumId: '
                    '$error\n$stackTrace',
                  );
                }),
              );
            }, onError: controller.addError);
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
      return dao.watchAlbumsPage(sort: request.sort, limit: request.limit);
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

final likedAlbumSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongsFromLikedAlbums();
});

final songsBySortProvider =
    StreamProvider.family<List<SongsTableData>, SongSortOrder>((ref, sort) {
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
final songStarredProvider = StreamProvider.family<bool, String>((ref, songId) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongStarred(songId);
});

final songRatingProvider = StreamProvider.family<int?, String>((ref, songId) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongRating(songId);
});

final albumRatingProvider = StreamProvider.family<int?, String>((ref, albumId) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumRating(albumId);
});

final genresProvider = StreamProvider<List<GenresTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchGenres();
});

final albumsByGenreProvider =
    StreamProvider.family<List<AlbumsTableData>, String>((ref, genre) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsByGenre(genre);
    });

final songsByGenreProvider =
    StreamProvider.family<List<SongsTableData>, String>((ref, genre) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchSongsByGenre(genre);
    });

final songsByArtistProvider =
    StreamProvider.family<List<SongsTableData>, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchSongsByArtist(artistId);
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
    .family<SearchResult3, String>((ref, query) async {
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
  NavisPlaybackHandler? _currentHandler;

  @override
  NavisPlaybackHandler? build() {
    _currentHandler = null;
    ref.onDispose(() {
      final current = _currentHandler;
      if (current == null) {
        return;
      }
      beginNavisPlaybackHandlerTeardown(current);
      unawaited(disposeNavisPlaybackHandler(current));
    });
    return null;
  }

  Future<void> setHandler(NavisPlaybackHandler handler) async {
    final previous = _currentHandler;
    _currentHandler = handler;
    state = handler;
    if (previous != null && !identical(previous, handler)) {
      beginNavisPlaybackHandlerTeardown(previous);
      await disposeNavisPlaybackHandler(previous);
    }
  }

  Future<void> clearHandler() async {
    final previous = _currentHandler;
    _currentHandler = null;
    state = null;
    if (previous != null) {
      beginNavisPlaybackHandlerTeardown(previous);
      await disposeNavisPlaybackHandler(previous);
    }
  }
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

final manualTrackChangeCueProvider = StreamProvider<ManualTrackChangeCue>((
  ref,
) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return const Stream<ManualTrackChangeCue>.empty();
  }
  return handler.manualTrackChangeCueStream;
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

/// Emits an event whenever a playback source load fails or times out.
final playbackLoadFailureProvider = StreamProvider<PlaybackLoadFailure>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return const Stream<PlaybackLoadFailure>.empty();
  }
  return handler.loadFailureStream;
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

/// UI-tracked playback volume for desktop controls.
///
/// The audio handler currently exposes a setter but not a reactive stream for
/// volume, so the UI keeps the latest user-selected value here.
class PlaybackVolumeController extends Notifier<double> {
  double _lastAudibleVolume = 1;

  @override
  double build() => 1;

  double setVolume(double value, {bool rememberAsAudible = true}) {
    if (value < 0) {
      state = 0;
      return state;
    }
    if (value > 1) {
      state = 1;
      return state;
    }
    state = value;
    if (rememberAsAudible && state > 0.001) {
      _lastAudibleVolume = state;
    }
    return state;
  }

  double toggleMute() {
    if (state <= 0.001) {
      final restored = _lastAudibleVolume <= 0.001 ? 1.0 : _lastAudibleVolume;
      state = restored;
      return state;
    }
    _lastAudibleVolume = state;
    state = 0;
    return state;
  }
}

final playbackVolumeProvider =
    NotifierProvider<PlaybackVolumeController, double>(
      PlaybackVolumeController.new,
    );

typedef LyricsLookupMetadata = ({
  String artist,
  String title,
  String? album,
  int? durationSeconds,
});

@visibleForTesting
LyricsLookupMetadata? navisResolveLyricsLookupMetadata({
  required String songId,
  SongsTableData? song,
  MediaItem? currentMediaItem,
}) {
  final matchingMediaItem =
      currentMediaItem != null && currentMediaItem.id == songId
      ? currentMediaItem
      : null;

  final title = _preferNonEmpty(song?.title, matchingMediaItem?.title);
  final artist = _preferNonEmpty(song?.artistName, matchingMediaItem?.artist);
  if (title == null || artist == null) {
    return null;
  }

  return (
    artist: artist,
    title: title,
    album: _preferNonEmpty(song?.albumName, matchingMediaItem?.album),
    durationSeconds: song?.duration ?? matchingMediaItem?.duration?.inSeconds,
  );
}

final lyricsProvider = FutureProvider.family<LyricsResolution, String>((
  ref,
  songId,
) async {
  final api = ref.watch(subsonicApiProvider);
  final dao = ref.read(navisDatabaseProvider).libraryDao;
  final song = (await dao.getSongsByIds(<String>[songId])).firstOrNull;
  final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
  final lookupMetadata = navisResolveLyricsLookupMetadata(
    songId: songId,
    song: song,
    currentMediaItem: currentMediaItem,
  );

  // 1) Server synced -> server plain
  if (api != null) {
    try {
      final serverLyrics = await api.getLyricsBySongId(songId);
      final source = _resolveServerLyricsSource(serverLyrics);
      if (source != null) {
        return LyricsResolution(lyrics: serverLyrics, source: source);
      }
    } on SubsonicNotFoundException {
      // Continue fallback chain.
    } on SubsonicApiException {
      // Continue fallback chain.
    } on SubsonicConnectionException {
      // Continue fallback chain to allow cache hits.
    }

    if (lookupMetadata != null) {
      try {
        final legacy = await api.getLyrics(
          artist: lookupMetadata.artist,
          title: lookupMetadata.title,
        );
        if (_hasAnyLyrics(legacy)) {
          return LyricsResolution(
            lyrics: legacy,
            source: LyricsSource.serverPlain,
          );
        }
      } on SubsonicException {
        // Continue fallback chain.
      }
    }
  }

  // 2) External cache.
  // Return immediately only if synced lyrics are already cached — best quality.
  // If only plain lyrics are cached, continue to step 3 to try upgrading to
  // synced via LrcLib.
  final cached = await dao.getExternalLyricsCache(songId);
  final cachedResolution = cached == null
      ? null
      : _lyricsResolutionFromExternalCache(cached);
  final hasOnlyCachedPlain =
      cached != null &&
      cached.syncedLyrics == null &&
      cached.plainLyrics != null;
  if (cachedResolution != null && !hasOnlyCachedPlain) {
    return cachedResolution;
  }

  // 3) LRCLIB synced -> LRCLIB plain (opt-in; default true per product decision).
  if (!ref.read(useLrclibProvider) || lookupMetadata == null) {
    if (cachedResolution != null) return cachedResolution;
    return const LyricsResolution(
      lyrics: LyricsList(),
      source: LyricsSource.serverPlain,
    );
  }

  final now = DateTime.now();
  if (cached != null &&
      cached.lastFailedAt != null &&
      now.isBefore(
        cached.lastFailedAt!.add(_externalLyricsBackoff(cached.failureCount)),
      )) {
    if (cachedResolution != null) return cachedResolution;
    return const LyricsResolution(
      lyrics: LyricsList(),
      source: LyricsSource.lrclibPlain,
    );
  }

  final expected = LrclibMatchCandidate(
    artist: lookupMetadata.artist,
    title: lookupMetadata.title,
    album: lookupMetadata.album,
    durationSeconds: lookupMetadata.durationSeconds,
  );
  final lrclib = ref.read(lrclibClientProvider);

  try {
    LrclibLyrics? best;
    var bestScore = 0.0;

    final direct = await lrclib.getLyrics(
      artist: lookupMetadata.artist,
      title: lookupMetadata.title,
      album: lookupMetadata.album,
      duration: lookupMetadata.durationSeconds,
    );
    if (direct != null) {
      final score = scoreCandidate(
        expected: expected,
        candidate: LrclibMatchCandidate(
          artist: direct.artistName,
          title: direct.trackName,
          album: direct.albumName,
          durationSeconds: direct.duration,
        ),
      ).value;
      if (score >= 0.7) {
        best = direct;
        bestScore = score;
      }
    }

    if (best == null) {
      final candidates = await lrclib.searchLyrics(
        artist: lookupMetadata.artist,
        title: lookupMetadata.title,
      );
      for (final candidate in candidates) {
        final score = scoreCandidate(
          expected: expected,
          candidate: LrclibMatchCandidate(
            artist: candidate.artistName,
            title: candidate.trackName,
            album: candidate.albumName,
            durationSeconds: candidate.duration,
          ),
        ).value;
        if (score > bestScore && score >= 0.7) {
          best = candidate;
          bestScore = score;
        }
      }
    }

    if (best == null) {
      if (cachedResolution == null) {
        await dao.recordExternalLyricsFailure(songId);
      }
      if (cachedResolution != null) return cachedResolution;
      return const LyricsResolution(
        lyrics: LyricsList(),
        source: LyricsSource.lrclibPlain,
      );
    }

    final parsedSynced = _tryParseLrc(best.syncedLyrics);
    // If LrcLib only has plain and we already have plain cached, skip the write
    // and return the existing cache — no upgrade available.
    if (parsedSynced == null && cachedResolution != null) {
      AppLogger.debug(
        'Lyrics: LrcLib has no synced lyrics for $songId; keeping existing plain cache.',
      );
      return cachedResolution;
    }
    final source = parsedSynced != null
        ? LyricsSource.lrclibSynced
        : LyricsSource.lrclibPlain;
    final resolvedLyrics = parsedSynced ?? LyricsList(value: best.plainLyrics);

    await dao.upsertExternalLyricsCache(
      songId: songId,
      source: source.name,
      syncedLyrics: best.syncedLyrics,
      plainLyrics: best.plainLyrics,
      ttlSeconds: 31536000,
      failureCount: 0,
      lastFailedAt: null,
    );
    AppLogger.info('Lyrics source resolved: ${source.name} for song=$songId');
    return LyricsResolution(lyrics: resolvedLyrics, source: source);
  } on Object {
    // If we already have plain lyrics cached, return them rather than throwing.
    if (cachedResolution != null) return cachedResolution;
    await dao.recordExternalLyricsFailure(songId);
    throw const LyricsNetworkException();
  }
});

final albumInfoProvider = FutureProvider.family<AlbumInfo?, String>((
  ref,
  albumId,
) async {
  final dao = ref.read(navisDatabaseProvider).libraryDao;
  final cached = await dao.getAlbumInfoCache(albumId);
  final now = DateTime.now();
  if (cached != null && now.difference(cached.fetchedAt).inDays < 7) {
    return AlbumInfo(
      notes: cached.notes,
      musicBrainzId: cached.musicBrainzId,
      lastFmUrl: cached.lastFmUrl,
      smallImageUrl: cached.smallImageUrl,
      mediumImageUrl: cached.mediumImageUrl,
      largeImageUrl: cached.largeImageUrl,
    );
  }

  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    if (cached == null) return null;
    return AlbumInfo(
      notes: cached.notes,
      musicBrainzId: cached.musicBrainzId,
      lastFmUrl: cached.lastFmUrl,
      smallImageUrl: cached.smallImageUrl,
      mediumImageUrl: cached.mediumImageUrl,
      largeImageUrl: cached.largeImageUrl,
    );
  }

  try {
    final info = await api.getAlbumInfo2(albumId);
    await dao.upsertAlbumInfoCache(
      albumId: albumId,
      notes: info.notes,
      musicBrainzId: info.musicBrainzId,
      lastFmUrl: info.lastFmUrl,
      smallImageUrl: info.smallImageUrl,
      mediumImageUrl: info.mediumImageUrl,
      largeImageUrl: info.largeImageUrl,
      fetchedAt: now,
    );
    return info;
  } on Object {
    if (cached == null) rethrow;
    return AlbumInfo(
      notes: cached.notes,
      musicBrainzId: cached.musicBrainzId,
      lastFmUrl: cached.lastFmUrl,
      smallImageUrl: cached.smallImageUrl,
      mediumImageUrl: cached.mediumImageUrl,
      largeImageUrl: cached.largeImageUrl,
    );
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

class HomeLikedOnlyFilterController extends Notifier<bool> {
  @override
  bool build() => false;

  bool get enabled => state;

  set enabled(bool value) => state = value;
}

final homeLikedOnlyFilterProvider =
    NotifierProvider<HomeLikedOnlyFilterController, bool>(
      HomeLikedOnlyFilterController.new,
    );

final downloadedSongIdsProvider = StreamProvider<Set<String>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracksByType(CacheType.permanent)
      .map((tracks) => tracks.map((track) => track.songId).toSet());
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
    appSettingsDao: db.appSettingsDao,
    cacheDao: db.cacheDao,
    downloadQueueDao: db.downloadQueueDao,
    libraryDao: db.libraryDao,
    readApiClient: () => ref.read(subsonicApiProvider),
    readWifiOnly: () =>
        ref.read(appSettingsProvider).asData?.value.wifiOnlyDownloads ?? false,
    readIsWifi: () =>
        isDesktopRuntime || ref.read(networkTypeProvider) == NetworkType.wifi,
    readCustomDownloadFolderEnabled: () =>
        ref.read(customDownloadFolderEnabledProvider),
    readCustomDownloadFolderPath: () =>
        ref.read(customDownloadFolderPathProvider),
    lrclibClient: ref.read(lrclibClientProvider),
    readCoverArtCacheManager: () => ref.read(coverArtCacheManagerProvider),
    reportNetworkUsage: ({required category, required bytes}) {
      ref
          .read(networkUsageMeterProvider)
          .record(
            category: category,
            bytes: bytes,
          );
    },
  );
  ref.listen<bool>(wifiOnlyDownloadsProvider, (previous, next) {
    if (previous != next) {
      unawaited(service.processQueuedDownloads());
    }
  });
  ref.listen<NetworkType>(networkTypeProvider, (previous, next) {
    if (previous != next) {
      unawaited(service.processQueuedDownloads());
    }
  });
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

final customDownloadFolderEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.customDownloadFolderEnabled;
});

final customDownloadFolderPathProvider = Provider<String?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.customDownloadFolderPath;
});

/// Current theme mode string ('light', 'dark', 'oled', 'system').
final themeModeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.themeMode;
});

/// Current color scheme seed color value (null = default white).
final colorSchemeSeedProvider = Provider<int?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.colorSchemeSeed;
});

/// Current locale override code (null = follow system locale).
final appLocaleProvider = Provider<String?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.appLocale;
});

/// Whether the Now Playing screen background should be tinted with album art.
final artTintedNowPlayingProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.artTintedNowPlaying;
});

/// Whether lyrics should open in fullscreen mode by default.
///
/// Backed by a persisted compatibility boolean in app settings.
final fullscreenModeLyricsProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.skipSilenceEnabled;
});

/// Whether app-wide accent color should follow currently playing album art.
final dynamicAlbumColorEnabledProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.dynamicAlbumColorEnabled;
});

/// Album grid density override. Null = auto-compute from screen width.
final albumGridDensityProvider = Provider<int?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.albumGridDensity;
});

/// Converts a shape preset string to a [BorderRadius].
///
/// - 'square'  → [BorderRadius.zero]
/// - 'circle'  → very large radius (effectively circular)
/// - 'rounded' or any other → [BorderRadius.circular(12)]
BorderRadius coverArtShapeToRadius(String shape) {
  switch (shape) {
    case 'square':
      return BorderRadius.zero;
    case 'circle':
      return BorderRadius.circular(9999);
    default:
      return BorderRadius.circular(12);
  }
}

/// Shape preset for cover art in library / carousel cards.
final coverArtShapeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.coverArtShape == 'square' ? 'square' : 'rounded';
});

/// Shape preset for the Now Playing album art.
final nowPlayingArtShapeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.nowPlayingArtShape;
});

/// Shape preset for artist cards.
final artistCardShapeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.artistCardShape;
});

/// Artist view layout: 'list' or 'grid'.
final artistViewModeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.artistViewMode;
});

/// Home layout density: 'comfortable' or 'compact'.
final homeDensityProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.homeDensity == 'compact' ? 'compact' : 'comfortable';
});

/// Desktop navigation sidebar style: 'comfortable', 'compact', or 'icons'.
final desktopNavbarStyleProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  final style = settings.desktopNavbarStyle;
  return (style == 'compact' || style == 'icons') ? style : 'comfortable';
});

/// Whether the desktop navigation sidebar autohides.
final desktopNavbarAutohideProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.desktopNavbarAutohide;
});

/// Ordered list of home section IDs (null = default order).
final homeSectionOrderProvider = Provider<List<String>?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.homeSectionOrder;
});

/// Hidden home section IDs (null = none hidden).
final homeSectionsHiddenProvider = Provider<List<String>?>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.homeSectionsHidden;
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
    .family<List<AudioMuseRecommendation>, String>((ref, artistId) async {
      final repo = ref.watch(audioMuseRepositoryProvider);
      if (repo == null) return const [];
      return repo.getSimilarArtists(artistId);
    });

/// AI-powered similar albums for a given album ID.
/// Returns an empty list when AudioMuse is unavailable.
final audioMuseSimilarAlbumsProvider = FutureProvider.autoDispose
    .family<List<AudioMuseRecommendation>, String>((ref, albumId) async {
      final repo = ref.watch(audioMuseRepositoryProvider);
      if (repo == null) return const [];
      return repo.getSimilarAlbums(albumId);
    });

/// AI-powered song recommendations for smart auto-queue.
final audioMuseSongRecommendationsProvider = FutureProvider.autoDispose
    .family<List<AudioMuseRecommendation>, String>((ref, seedSongId) async {
      final repo = ref.watch(audioMuseRepositoryProvider);
      if (repo == null) return const [];
      return repo.getRecommendations(seedSongId: seedSongId);
    });

LyricsSource? _resolveServerLyricsSource(LyricsList lyrics) {
  if (lyrics.structuredLyrics.isNotEmpty) {
    final first = lyrics.structuredLyrics.first;
    final hasSynced = first.line.any((line) => line.start != null);
    if (hasSynced) {
      return LyricsSource.serverSynced;
    }
    final hasUnsyncedLine = first.line.any(
      (line) => (line.value ?? '').trim().isNotEmpty,
    );
    if (hasUnsyncedLine) {
      return LyricsSource.serverPlain;
    }
  }
  if ((lyrics.value ?? '').trim().isNotEmpty) {
    return LyricsSource.serverPlain;
  }
  return null;
}

bool _hasAnyLyrics(LyricsList lyrics) {
  return _resolveServerLyricsSource(lyrics) != null;
}

Duration _externalLyricsBackoff(int failureCount) {
  if (failureCount <= 0) {
    return Duration.zero;
  }
  final minutes = failureCount * failureCount;
  final cappedMinutes = minutes > 1440 ? 1440 : minutes;
  return Duration(minutes: cappedMinutes);
}

String? _preferNonEmpty(String? primary, String? fallback) {
  final trimmedPrimary = primary?.trim();
  if (trimmedPrimary != null && trimmedPrimary.isNotEmpty) {
    return trimmedPrimary;
  }
  final trimmedFallback = fallback?.trim();
  if (trimmedFallback != null && trimmedFallback.isNotEmpty) {
    return trimmedFallback;
  }
  return null;
}

LyricsResolution? _lyricsResolutionFromExternalCache(
  ExternalLyricsCacheTableData cache,
) {
  final source = switch (cache.source) {
    'lrclibSynced' || 'lrclib_synced' => LyricsSource.lrclibSynced,
    'lrclibPlain' || 'lrclib_plain' => LyricsSource.lrclibPlain,
    'serverSynced' => LyricsSource.serverSynced,
    'serverPlain' => LyricsSource.serverPlain,
    _ => null,
  };
  if (source == null) {
    return null;
  }

  // For synced sources (server or lrclib), try the LRC column first.
  if (source == LyricsSource.serverSynced ||
      source == LyricsSource.lrclibSynced) {
    final synced = _tryParseLrc(cache.syncedLyrics);
    if (synced != null) {
      return LyricsResolution(lyrics: synced, source: source);
    }
  }

  // Fall back to plain text for any source.
  final plain = cache.plainLyrics;
  if (plain != null && plain.trim().isNotEmpty) {
    return LyricsResolution(
      lyrics: LyricsList(value: plain),
      source:
          source == LyricsSource.serverSynced ||
              source == LyricsSource.serverPlain
          ? LyricsSource.serverPlain
          : LyricsSource.lrclibPlain,
    );
  }
  return null;
}

LyricsList? _tryParseLrc(String? lrc) {
  if (lrc == null || lrc.trim().isEmpty) {
    return null;
  }
  final regex = RegExp(r'^\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\](.*)$');
  final parsed = <LyricLine>[];

  for (final raw in lrc.split('\n')) {
    final line = raw.trim();
    final match = regex.firstMatch(line);
    if (match == null) {
      continue;
    }

    final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
    final fractionText = match.group(3);
    final fraction = int.tryParse(fractionText ?? '') ?? 0;
    final millis = fractionText == null
        ? 0
        : fractionText.length == 3
        ? fraction
        : fraction * 10;
    final start = minutes * 60000 + seconds * 1000 + millis;
    parsed.add(LyricLine(start: start, value: (match.group(4) ?? '').trim()));
  }

  if (parsed.isEmpty) {
    return null;
  }

  parsed.sort((a, b) => (a.start ?? 0).compareTo(b.start ?? 0));
  final lines = <LyricLine>[];
  for (var i = 0; i < parsed.length; i++) {
    final current = parsed[i];
    final nextStart = i + 1 < parsed.length ? parsed[i + 1].start : null;
    final duration = (current.start != null && nextStart != null)
        ? (nextStart - current.start!).clamp(0, 60000)
        : null;
    lines.add(
      LyricLine(start: current.start, duration: duration, value: current.value),
    );
  }

  return LyricsList(
    structuredLyrics: <StructuredLyrics>[
      StructuredLyrics(synced: true, line: lines),
    ],
  );
}

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
