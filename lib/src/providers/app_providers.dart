import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:connectivity_plus/connectivity_plus.dart';
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
import 'package:navis/src/database/daos/app_settings_dao.dart';
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
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/settings/data/battery_optimization_service.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/routing/desktop_layout.dart' show isDesktopRuntime;
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/network_cost_bridge.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:path_provider/path_provider.dart';

const String _syncDiagnosticsRoot = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ROOT',
);
const bool _syncDiagnosticsEnabled = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS',
  defaultValue: false,
);

Future<Directory> _readRollingCacheDirectory() async {
  if (_syncDiagnosticsRoot.isEmpty) {
    return getTemporaryDirectory();
  }
  final directory = Directory('$_syncDiagnosticsRoot/cache');
  await directory.create(recursive: true);
  return directory;
}

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
  final networkUsageMeter = ref.read(networkUsageMeterProvider);
  final service = CoverArtHttpFileService(
    loadCoordinator: coordinator,
    reportNetworkUsage: _networkUsageReporter(networkUsageMeter),
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
  if (_syncDiagnosticsEnabled) {
    final override = ref.watch(syncDiagnosticsOverridesProvider).networkType;
    if (override != null) {
      return override;
    }
  }
  final connectivity = ref.watch(connectivityProvider);
  return resolveNetworkType(
    connectivity.asData?.value ?? const <ConnectivityResult>[],
  );
});

final networkCostBridgeProvider = Provider<NetworkCostBridge>((ref) {
  return NetworkCostBridge();
});

/// Native metering hint. `null` means the platform cannot report cost.
final nativeNetworkMeteredProvider = FutureProvider<bool?>((ref) async {
  if (_syncDiagnosticsEnabled) {
    final override = ref.watch(syncDiagnosticsOverridesProvider).nativeMetered;
    if (override != null) {
      return override;
    }
  }
  ref.watch(connectivityProvider);
  return ref.read(networkCostBridgeProvider).isActiveNetworkMetered();
});

final backgroundSyncUnmeteredOnlyProvider = Provider<bool>((ref) {
  if (_syncDiagnosticsEnabled) {
    final override = ref
        .watch(syncDiagnosticsOverridesProvider)
        .backgroundSyncUnmeteredOnly;
    if (override != null) {
      return override;
    }
  }
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.backgroundSyncUnmeteredOnly;
});

final syncNetworkPolicyProvider = Provider<SyncNetworkPolicy>((ref) {
  final networkType = ref.watch(networkTypeProvider);
  final nativeMetered = ref.watch(nativeNetworkMeteredProvider).asData?.value;
  final unmeteredOnly = ref.watch(backgroundSyncUnmeteredOnlyProvider);
  final base = resolveSyncNetworkPolicy(
    networkType: networkType,
    nativeMetered: nativeMetered,
    backgroundSyncUnmeteredOnly: unmeteredOnly,
  );
  if (!_syncDiagnosticsEnabled) {
    return base;
  }
  final overrides = ref.watch(syncDiagnosticsOverridesProvider);
  return SyncNetworkPolicy(
    networkType: base.networkType,
    isMetered: base.isMetered,
    allowsBackgroundSync:
        overrides.automaticSyncAllowed ?? base.allowsBackgroundSync,
    allowsHardProbe: base.allowsHardProbe,
    allowsInteractiveHydration:
        overrides.interactiveHydrationAllowed ??
        base.allowsInteractiveHydration,
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

NetworkUsageReporter _networkUsageReporter(
  NetworkUsageMeter meter, {
  NetworkType? networkType,
}) {
  return ({required category, required bytes, operation}) {
    meter.record(
      category: category,
      bytes: bytes,
      operation: operation,
      networkType: networkType,
    );
  };
}

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

final showAlbumsPageProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.showAlbumsPage;
});

final showRadioPageProvider = Provider<bool>((ref) {
  if (ref.watch(
    syncDiagnosticsOverridesProvider.select(
      (overrides) => overrides.radioPresentationFixture,
    ),
  )) {
    return true;
  }
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
  // Sync progress updates capabilities and timestamps on the server config.
  // Those fields must not tear down the active transport: a follow-up album
  // request may still be using it. Rebuild only when its connection identity
  // actually changes.
  final connection = ref.watch(
    serverConfigStateProvider.select((state) {
      final config = state.asData?.value;
      if (config == null || config.password.trim().isEmpty) {
        return null;
      }
      return (
        url: config.url,
        username: config.username,
        password: config.password,
        apiVersion: config.apiVersion,
        useLegacyAuth: config.useLegacyAuth,
      );
    }),
  );
  if (connection == null) {
    return null;
  }
  final networkType = ref.watch(networkTypeProvider);
  final networkUsageMeter = ref.read(networkUsageMeterProvider);

  final authType = connection.useLegacyAuth
      ? SubsonicAuthType.legacyPassword
      : SubsonicAuthType.token;

  final client = SubsonicApiClient(
    baseUrl: connection.url,
    authConfig: SubsonicAuthConfig(
      username: connection.username,
      password: connection.password,
      apiVersion: connection.apiVersion,
      authType: authType,
    ),
    maxConnectionsPerHost: switch (networkType) {
      NetworkType.wifi => 24,
      NetworkType.cellular => 8,
      NetworkType.offline => 4,
      NetworkType.other => 12,
    },
    reportNetworkUsage: _networkUsageReporter(
      networkUsageMeter,
      networkType: networkType,
    ),
  );
  // A network-quality rebuild must let responses already owned by this client
  // finish. Session teardown explicitly force-closes the active client before
  // credentials are invalidated.
  ref.onDispose(() => client.close(force: false));
  return client;
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
  if (_syncDiagnosticsEnabled) {
    return '';
  }
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
      if (_syncDiagnosticsEnabled) {
        return CloneDiagnosticsExternalScrobbleCredentialStore();
      }
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
        !_syncDiagnosticsEnabled &&
        (ref.read(appSettingsProvider).asData?.value.scrobbleEnabled ?? true),
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
typedef AudioBootstrapAttemptGate = Future<void> Function();

final audioBootstrapTimeoutProvider = Provider<Duration>((_) {
  return const Duration(seconds: 5);
});

/// Waits briefly between failed startup attempts so transient platform audio
/// initialization failures recover without requiring an action from the user.
final audioBootstrapRetryDelayProvider = Provider<Duration>((_) {
  return const Duration(seconds: 3);
});

/// A no-op production hook used only by isolated diagnostics to simulate a
/// transient failure before constructing the platform audio handler.
final audioBootstrapAttemptGateProvider = Provider<AudioBootstrapAttemptGate>(
  (_) => () async {},
);

final audioHandlerInitializerProvider = Provider<AudioHandlerInitializer>((
  ref,
) {
  return () async {
    AppSettingsModel? hydratedSettings;
    try {
      final settingsRepository = ref.read(settingsRepositoryProvider);
      hydratedSettings = await settingsRepository.getSettings();
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'App settings preload failed before audio init. '
        '$error\n$stackTrace',
      );
    }

    final volumeController = ref.read(playbackVolumeProvider.notifier);
    if (hydratedSettings != null) {
      volumeController.hydrate(
        volume: hydratedSettings.desktopPlaybackVolume,
        lastAudibleVolume: hydratedSettings.desktopLastAudibleVolume,
      );
    }
    final initialVolume = ref.read(playbackVolumeProvider);

    final database = ref.read(navisDatabaseProvider);
    final networkUsageMeter = ref.read(networkUsageMeterProvider);
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
        readRollingCacheDirectory: _readRollingCacheDirectory,
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
        // media_kit cannot seek LockCachingAudioSource's local proxy; desktop
        // plays via direct HTTPS and fills the rolling cache with a sidecar.
        readUsesSidecarRollingCache: () => isDesktopRuntime,
      ),
      readApiClient: () => ref.read(subsonicApiProvider),
      rollingCacheManager: ref.read(rollingCacheManagerProvider),
      readRollingCacheBudgetBytes: () =>
          ref.read(rollingCacheBudgetBytesProvider),
      scrobbleService: ref.read(scrobbleServiceProvider),
      listenBrainzFeedbackService: ref.read(
        listenBrainzFeedbackServiceProvider,
      ),
      starSyncDao: database.starSyncDao,
      initialVolume: initialVolume,
      reportNetworkUsage: _networkUsageReporter(networkUsageMeter),
      reportRollingCacheActivity: (activity) {
        if (!ref.mounted) {
          return;
        }
        try {
          ref.read(rollingCacheActivityProvider.notifier).update(activity);
        } on StateError {
          // The target notifier can be disposed immediately before this
          // initializer during root-container teardown.
        }
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
    final persistedAliases = await database.songIdentityDao.getAliases();
    if (persistedAliases.isNotEmpty) {
      await handler.applySongIdentityAliases(<String, String>{
        for (final alias in persistedAliases)
          alias.oldSongId: alias.canonicalSongId,
      });
    }

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
          final settings = await ref.read(appSettingsProvider.future);
          final restoredVolume = volumeController.hydrate(
            volume: settings.desktopPlaybackVolume,
            lastAudibleVolume: settings.desktopLastAudibleVolume,
          );
          await handler.setVolume(restoredVolume);
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
  Timer? _retryTimer;
  bool _didAttempt = false;
  int _attemptEpoch = 0;
  int _activeAttempt = 0;

  bool get isRetryScheduled => _retryTimer?.isActive ?? false;

  @override
  AudioBootstrapState build() {
    ref.onDispose(() {
      _retryTimer?.cancel();
    });
    return const AudioBootstrapState.initializing();
  }

  void ensureInitialized() {
    if (state.isReady) {
      return;
    }
    unawaited(_initialize());
  }

  /// Wait for any handler construction/queue restoration before clearing all
  /// session playback state. This prevents a late bootstrap completion from
  /// restoring a signed-out queue after teardown has already returned.
  Future<void> resetSessionAndWait() async {
    final pending = _inFlight;
    if (pending != null) {
      await pending;
    }
    await state.handler?.resetSession();
  }

  /// Supersedes a stuck startup attempt without waiting for its native future.
  ///
  /// Session recovery must remain available when a platform audio service
  /// never resolves. Any handler that does arrive later is disposed by the
  /// stale-completion branch in [_initialize].
  Future<void> abortForSessionTeardown() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _activeAttempt = ++_attemptEpoch;
    invalidateNavisPlaybackHandlerInitialization();
    final attachedHandler = state.handler;
    if (attachedHandler != null) {
      try {
        await attachedHandler.resetSession();
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Resetting attached playback during startup recovery failed: '
          '$error\n$stackTrace',
        );
      }
    }
    await ref.read(audioHandlerStateProvider.notifier).clearHandler();
    state = AudioBootstrapState.failed(
      'Playback initialization was stopped.',
      attempt: _activeAttempt,
    );
  }

  Future<void> retry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    return _initialize(force: true);
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = ref.read(audioBootstrapRetryDelayProvider);
    AppLogger.info(
      'Audio bootstrap retry scheduled in ${delay.inMilliseconds}ms.',
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!ref.mounted || state.isReady) {
        return;
      }
      unawaited(_initialize(force: true));
    });
  }

  Future<void> _initialize({bool force = false}) {
    if (force) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
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
        _retryTimer?.cancel();
        _retryTimer = null;
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
        await ref.read(audioBootstrapAttemptGateProvider)();
        final initFuture = initializeHandler();
        unawaited(
          initFuture.then<void>(
            (handler) async {
              if (_activeAttempt != attemptId) {
                unawaited(() async {
                  try {
                    await disposeNavisPlaybackHandler(handler);
                  } on Object catch (error, stackTrace) {
                    AppLogger.warning(
                      'Discarding stale audio bootstrap handler failed: '
                      '$error\n$stackTrace',
                    );
                  }
                }());
                return;
              }
              if (!timedOut) {
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
        _scheduleRetry();
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
    StreamProvider.family<List<AlbumsTableData>, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsByArtist(artistId);
    });

final artistAlbumSectionsProvider =
    StreamProvider.family<ArtistAlbumSections, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao
          .watchArtistAlbumBuckets(artistId)
          .map(
            (buckets) => ArtistAlbumSections(
              albums: buckets.primaryAlbums,
              featuredIn: buckets.featuredInAlbums,
            ),
          );
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

  final albumSub = dao
      .watchAlbumById(albumId)
      .listen(
        (album) {
          songsSub?.cancel();
          if (album == null) {
            songsSub = null;
            controller.add(null);
          } else {
            songsSub = dao.watchSongsByAlbum(albumId).listen((songs) {
              controller.add(AlbumWithSongs(album: album, songs: songs));
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
  final usePresentationFixture = ref.watch(
    syncDiagnosticsOverridesProvider.select(
      (overrides) => overrides.radioPresentationFixture,
    ),
  );
  if (usePresentationFixture) {
    return const <InternetRadioStation>[
      InternetRadioStation(
        id: 'diagnostics-radio-station',
        name: 'Navis Test Radio',
        streamUrl: 'https://example.invalid/navis-test-radio',
      ),
    ];
  }
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
  final database = ref.watch(navisDatabaseProvider);
  const safStorage = AndroidSafStorage();
  return DriftRollingCacheManager(
    cacheDao: database.cacheDao,
    songIdentityDao: database.songIdentityDao,
    entryExists: (entry) => entry.storageKind == 'androidSaf'
        ? safStorage.exists(entry.filePath)
        : Future<bool>.value(File(entry.filePath).existsSync()),
  );
});

class RollingCacheActivityController extends Notifier<RollingCacheActivity> {
  @override
  RollingCacheActivity build() => const RollingCacheActivity.idle();

  void update(RollingCacheActivity activity) {
    state = activity;
  }
}

final rollingCacheActivityProvider =
    NotifierProvider<RollingCacheActivityController, RollingCacheActivity>(
      RollingCacheActivityController.new,
    );

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    yield const PlaybackSnapshot.idle();
    return;
  }
  yield handler.snapshot;
  yield* handler.snapshotStream;
});

final transportVisualCueProvider = StreamProvider<TransportVisualCue>((
  ref,
) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return const Stream<TransportVisualCue>.empty();
  }
  return handler.transportVisualCueStream;
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

final playbackBufferStateProvider = StreamProvider<PlaybackBufferState>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return Stream<PlaybackBufferState>.value(
      const PlaybackBufferState.idle(),
    );
  }
  return Stream<PlaybackBufferState>.multi((controller) {
    controller.add(handler.bufferState);
    final subscription = handler.bufferStateStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });
});

/// UI-tracked playback volume for desktop controls.
///
/// This controller owns the user-selected level, audio-handler application,
/// and desktop-only persistence so UI and diagnostics use one production path.
final desktopVolumePersistenceEnabledProvider = Provider<bool>((_) {
  return isDesktopRuntime;
});

class PlaybackVolumeController extends Notifier<double> {
  static const Duration _persistenceDebounce = Duration(milliseconds: 250);

  late final SettingsRepository _settingsRepository;
  late final bool _persistenceEnabled;
  double _lastAudibleVolume = AppSettingsDao.defaultDesktopPlaybackVolume;
  bool _hydrated = false;
  Timer? _persistenceTimer;
  Future<void>? _persistenceInFlight;

  @override
  double build() {
    _settingsRepository = ref.read(settingsRepositoryProvider);
    _persistenceEnabled = ref.read(desktopVolumePersistenceEnabledProvider);
    ref.onDispose(() => _persistenceTimer?.cancel());
    return AppSettingsDao.defaultDesktopPlaybackVolume;
  }

  double get lastAudibleVolume => _lastAudibleVolume;
  bool get hydrated => _hydrated;
  bool get persistenceEnabled => _persistenceEnabled;

  double hydrate({
    required double volume,
    required double lastAudibleVolume,
  }) {
    if (_hydrated || !persistenceEnabled) {
      return state;
    }
    state = sanitizeDesktopPlaybackVolume(volume);
    _lastAudibleVolume = sanitizeDesktopLastAudibleVolume(lastAudibleVolume);
    _hydrated = true;
    return state;
  }

  Future<double> setVolume(
    double value, {
    bool rememberAsAudible = true,
    bool persistImmediately = false,
    bool throwOnPersistenceFailure = false,
  }) async {
    state = sanitizeDesktopPlaybackVolume(value);
    if (rememberAsAudible && state > 0.001) {
      _lastAudibleVolume = state;
    }
    final handler = ref.read(audioHandlerProvider);
    await handler?.setVolume(state);
    if (persistImmediately) {
      await _persistCurrentVolume(
        throwOnFailure: throwOnPersistenceFailure,
      );
    } else {
      _schedulePersistence();
    }
    return state;
  }

  Future<double> toggleMute({bool throwOnPersistenceFailure = false}) async {
    late final double resolved;
    if (state <= 0.001) {
      resolved = sanitizeDesktopLastAudibleVolume(_lastAudibleVolume);
    } else {
      _lastAudibleVolume = state;
      resolved = 0;
    }
    state = resolved;
    final handler = ref.read(audioHandlerProvider);
    await handler?.setVolume(state);
    await _persistCurrentVolume(
      throwOnFailure: throwOnPersistenceFailure,
    );
    return state;
  }

  Future<void> flushPersistence({bool throwOnFailure = false}) {
    return _persistCurrentVolume(throwOnFailure: throwOnFailure);
  }

  void _schedulePersistence() {
    if (!persistenceEnabled) {
      return;
    }
    _persistenceTimer?.cancel();
    _persistenceTimer = Timer(_persistenceDebounce, () {
      unawaited(_persistCurrentVolume());
    });
  }

  Future<void> _persistCurrentVolume({bool throwOnFailure = false}) async {
    _persistenceTimer?.cancel();
    _persistenceTimer = null;
    if (!persistenceEnabled) {
      return;
    }
    final volume = state;
    final lastAudibleVolume = _lastAudibleVolume;
    final previous = _persistenceInFlight;
    final operation = () async {
      if (previous != null) {
        try {
          await previous;
        } on Object {
          // A newer write must still run after an earlier failure.
        }
      }
      await _settingsRepository.saveDesktopPlaybackVolume(
        volume: volume,
        lastAudibleVolume: lastAudibleVolume,
      );
    }();
    _persistenceInFlight = operation;
    try {
      await operation;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Desktop playback volume persistence failed: '
        '$error\n$stackTrace',
      );
      if (throwOnFailure) {
        rethrow;
      }
    } finally {
      if (identical(_persistenceInFlight, operation)) {
        _persistenceInFlight = null;
      }
    }
  }
}

final playbackVolumeProvider =
    NotifierProvider<PlaybackVolumeController, double>(
      PlaybackVolumeController.new,
    );

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

  final title = preferNonEmpty(song?.title, matchingMediaItem?.title);
  final artist = preferNonEmpty(song?.artistName, matchingMediaItem?.artist);
  if (title == null || artist == null) {
    return null;
  }

  return (
    artist: artist,
    title: title,
    album: preferNonEmpty(song?.albumName, matchingMediaItem?.album),
    durationSeconds: song?.duration ?? matchingMediaItem?.duration?.inSeconds,
  );
}

final lyricsProvider = FutureProvider.family<LyricsResolution, String>((
  ref,
  songId,
) async {
  final api = ref.watch(subsonicApiProvider);
  final database = ref.read(navisDatabaseProvider);
  final dao = database.libraryDao;
  final song = (await dao.getSongsByIds(<String>[songId])).firstOrNull;
  final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
  final lookupMetadata = navisResolveLyricsLookupMetadata(
    songId: songId,
    song: song,
    currentMediaItem: currentMediaItem,
  );
  final cachedTrack = await database.cacheDao.getCachedTrack(songId);
  final resolver = LyricsResolver(
    libraryDao: dao,
    lrclibClient: ref.read(lrclibClientProvider),
    apiClient: api,
  );
  return resolver.resolve(
    songId: songId,
    metadata: lookupMetadata,
    useLrclib: ref.read(useLrclibProvider),
    lyricsCacheTtlSeconds: cachedTrack?.cacheType == CacheType.permanent
        ? permanentLyricsCacheTtlSeconds
        : normalLyricsCacheTtlSeconds,
  );
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
  final networkUsageMeter = ref.read(networkUsageMeterProvider);
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
    readProfileIdentity: () {
      final config = ref.read(serverConfigProvider).asData?.value;
      return config == null ? null : '${config.url}|${config.username}';
    },
    reportNetworkUsage: _networkUsageReporter(networkUsageMeter),
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

/// Ordered library pages including hidden pages.
final libraryPageOrderProvider = Provider<List<LibrarySection>>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return sanitizeLibraryPageOrder(settings.libraryPageOrder);
});

/// Ordered library pages filtered by the current page visibility toggles.
final visibleLibrarySectionsProvider = Provider<List<LibrarySection>>((ref) {
  return visibleLibrarySections(
    orderedSections: ref.watch(libraryPageOrderProvider),
    showAlbums: ref.watch(showAlbumsPageProvider),
    showLiked: ref.watch(showLikedPageProvider),
    showArtists: ref.watch(showArtistsPageProvider),
    showPlaylists: ref.watch(showPlaylistsPageProvider),
    showRadio: ref.watch(showRadioPageProvider),
  );
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

/// When `true`, the next [updateProvider] fetch bypasses the 24-hour throttle.
class UpdateForceCheckNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void requestForceCheck() => state = true;

  bool consumeForceCheck() {
    if (!state) {
      return false;
    }
    state = false;
    return true;
  }
}

final updateForceCheckProvider =
    NotifierProvider<UpdateForceCheckNotifier, bool>(
      UpdateForceCheckNotifier.new,
    );

final installSourceServiceProvider = Provider<InstallSourceService>((ref) {
  return InstallSourceService();
});

final updateCheckStoreProvider = Provider<UpdateCheckStore>((ref) {
  return UpdateCheckStore();
});

final updateServiceProvider = Provider<UpdateService>((ref) {
  final meter = ref.watch(networkUsageMeterProvider);
  return UpdateService(
    networkUsageReporter: ({required category, required bytes, operation}) {
      meter.record(category: category, bytes: bytes, operation: operation);
    },
  );
});

/// Checks whether a newer Navis release is available on Forgejo.
/// Auto-disposed so it re-runs each time a screen watches it freshly.
final updateProvider = FutureProvider.autoDispose<UpdateInfo?>((ref) async {
  final settingsAsync = ref.watch(appSettingsProvider);
  if (settingsAsync.isLoading) {
    return null;
  }
  final settings = settingsAsync.asData?.value;
  if (settings != null && !settings.updateCheckEnabled) {
    return null;
  }

  final forceCheck = ref
      .read(updateForceCheckProvider.notifier)
      .consumeForceCheck();

  return UpdateRepository(
    installSourceService: ref.read(installSourceServiceProvider),
    updateCheckStore: ref.read(updateCheckStoreProvider),
  ).checkForUpdate(
    includePrerelease: AppConstants.updateChannel == 'dev',
    forceCheck: forceCheck,
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
