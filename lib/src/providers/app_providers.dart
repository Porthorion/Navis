import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show BaseOptions;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart'
    show mapEquals, setEquals, visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_recovery.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/equalizer/data/eq_repository.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/data/artwork_call_recorder.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/integrations/data/external_dio.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/annotation_sync_dispatcher.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/guarded_system_artwork_loader.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/settings/data/battery_optimization_service.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart' show isDesktopRuntime;
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/utils/network_cost_bridge.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const String _syncDiagnosticsRoot = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ROOT',
);
const bool _syncDiagnosticsEnabled = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS',
  defaultValue: false,
);
const String _syncDiagnosticsMode = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_MODE',
);
const String _syncDiagnosticsLastFmKeyFile = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_LASTFM_KEY_FILE',
);
const bool _syncDiagnosticsMuted = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_MUTED',
  defaultValue: false,
);

Future<Directory> _readRollingCacheDirectory() async {
  if (_syncDiagnosticsRoot.isEmpty) {
    return await getTemporaryDirectory();
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
/// Uses [Ref.read] (not [Ref.watch]) so the provider **never** rebuilds
/// reactively. This is critical: `flutter_cache_manager` opens its SQLite
/// database asynchronously inside the constructor. If `dispose()` is called
/// before `openDatabase()` returns, the internal `db!` is still null and the
/// null-check throws. By reading the setting once at creation time, we
/// guarantee no reactive rebuilds, so the manager's lifecycle is:
///   1. Created (DB open starts asynchronously).
///   2. Runs for the lifetime of the app.
///   3. Explicitly invalidated via [Ref.invalidate] from the settings screen
///      — by which point the DB has been open for seconds and disposal is safe.
final coverArtLoadCoordinatorProvider = Provider<CoverArtLoadCoordinator>((
  ref,
) {
  return CoverArtLoadCoordinator();
});

/// Cover art recovery orchestration (plan F6/F7): targeted eviction of
/// corrupt entries and one coalesced entity-metadata refresh per missing
/// cover reference, routed through the sync controller's targeted requests.
final coverArtRecoveryProvider = Provider<CoverArtRecoveryCoordinator>((ref) {
  return CoverArtRecoveryCoordinator(
    refreshEntityForCover: (coverArtId) async {
      final database = ref.read(navisDatabaseProvider);
      final controller = ref.read(librarySyncControllerProvider.notifier);
      // Route by which entity currently owns this cover reference: the
      // refresh may change the cover ID or bump its revision, after which
      // widgets retry the resulting cover identity.
      final albumRow = await database
          .customSelect(
            'SELECT id FROM albums WHERE cover_art = ? LIMIT 1;',
            variables: <Variable<Object>>[Variable<String>(coverArtId)],
          )
          .getSingleOrNull();
      if (albumRow != null) {
        await controller.requestTarget(
          LibrarySyncTarget.album(albumRow.read<String>('id')),
        );
        return;
      }
      final artistRow = await database
          .customSelect(
            'SELECT id FROM artists WHERE cover_art = ? LIMIT 1;',
            variables: <Variable<Object>>[Variable<String>(coverArtId)],
          )
          .getSingleOrNull();
      if (artistRow != null) {
        await controller.requestTarget(
          LibrarySyncTarget.artist(artistRow.read<String>('id')),
        );
        return;
      }
      final songAlbumRow = await database
          .customSelect(
            'SELECT album_id FROM songs WHERE cover_art = ? '
            'AND album_id IS NOT NULL LIMIT 1;',
            variables: <Variable<Object>>[Variable<String>(coverArtId)],
          )
          .getSingleOrNull();
      if (songAlbumRow != null) {
        await controller.requestTarget(
          LibrarySyncTarget.album(songAlbumRow.read<String>('album_id')),
        );
      }
    },
  );
});

final artworkCallRecorderProvider = Provider<ArtworkCallRecorder>((ref) {
  final recorder = ref.watch(integrationCallRecorderProvider);
  ref.listen(integrationPolicyProvider, (_, policy) {
    recorder.beginPolicyEpoch(policy);
  }, fireImmediately: true);
  return ArtworkCallRecorder(
    recorder: recorder,
    isServerUri: (uri) =>
        integrationFeatureForArtworkUri(
          uri,
          serverHost: ref.read(serverHostProvider),
        ) ==
        null,
  );
});

/// Creates the playback artwork transport with disposal-safe policy callbacks.
@visibleForTesting
CoverArtHttpFileService createPlaybackArtworkFileService(Ref ref) {
  final service = CoverArtHttpFileService(
    authenticateUri: (uri) => ref.mounted
        ? ref.read(subsonicApiProvider)?.authenticateCoverArtUri(uri) ?? uri
        : uri,
    connectionTimeout: const Duration(seconds: 10),
    responseTimeout: const Duration(seconds: 15),
    bodyReadTimeout: const Duration(seconds: 30),
    allowUri: (uri) =>
        ref.mounted &&
        integrationAllowsArtworkHost(
          ref.read(integrationPolicyProvider),
          uri,
          serverHost: ref.read(serverHostProvider),
        ),
    isServerUri: (uri) =>
        ref.mounted &&
        integrationFeatureForArtworkUri(
              uri,
              serverHost: ref.read(serverHostProvider),
            ) ==
            null,
    recorder: ref.read(integrationCallRecorderProvider),
    reportNetworkUsage: _networkUsageReporter(
      ref.read(networkUsageMeterProvider),
    ),
  );
  return service;
}

final coverArtCacheManagerProvider = Provider<CacheManager>((ref) {
  // ref.read, not ref.watch — prevents reactive rebuilds caused by the
  // settings stream emitting at startup (AsyncLoading → AsyncData), which
  // would dispose the manager before its internal SQLite DB finishes opening.
  final maxObjects = ref.read(_coverArtMaxObjectsProvider).value ?? 0;
  final coordinator = ref.watch(coverArtLoadCoordinatorProvider);
  final networkUsageMeter = ref.read(networkUsageMeterProvider);
  final service = CoverArtHttpFileService(
    authenticateUri: (uri) => ref.mounted
        ? ref.read(subsonicApiProvider)?.authenticateCoverArtUri(uri) ?? uri
        : uri,
    recorder: ref.read(integrationCallRecorderProvider),
    loadCoordinator: coordinator,
    reportNetworkUsage: _networkUsageReporter(networkUsageMeter),
    // Read per request: the user's choices apply to a manager that already
    // exists, and the manager must not be rebuilt by settings changes.
    allowUri: (uri) => integrationAllowsArtworkHost(
      ref.read(integrationPolicyProvider),
      uri,
      serverHost: ref.read(serverHostProvider),
    ),
    // Loads that name their feature (radio art) are also checked against
    // that feature's switch, at dispatch, after any queue wait.
    allowFeatureUri: (uri, featureKey) => integrationAllowsArtworkFeatureKey(
      ref.read(integrationPolicyProvider),
      uri,
      featureKey,
      serverHost: ref.read(serverHostProvider),
    ),
    isServerUri: (uri) =>
        integrationFeatureForArtworkUri(
          uri,
          serverHost: ref.read(serverHostProvider),
        ) ==
        null,
    onMissingCover: (coverArtId) {
      // One coalesced metadata refresh per missing reference (plan F7);
      // failures land in logs and the cooldown prevents loops.
      unawaited(
        ref.read(coverArtRecoveryProvider).handleMissingCover(coverArtId),
      );
    },
  );
  final manager = createCoverArtCacheManager(
    maxNrOfCacheObjects: maxObjects,
    fileService: service,
  );
  ref.onDispose(() {
    service.close(force: true);
    unawaited(manager.dispose());
  });
  return manager;
});

// AudioService and session teardown must share the same repository owner.
final systemArtworkCacheManagerProvider = Provider<CacheManager>((ref) {
  final service = createSystemArtworkFileService(
    authenticateUri: (uri) => ref.mounted
        ? ref.read(subsonicApiProvider)?.authenticateCoverArtUri(uri) ?? uri
        : uri,
    allowUri: (uri) =>
        ref.mounted &&
        integrationAllowsRadioArtworkUri(
          ref.read(integrationPolicyProvider),
          uri,
          serverHost: ref.read(serverHostProvider),
        ),
    recorder: ref.read(integrationCallRecorderProvider),
    isServerUri: (uri) =>
        ref.mounted &&
        integrationFeatureForArtworkUri(
              uri,
              serverHost: ref.read(serverHostProvider),
            ) ==
            null,
    reportNetworkUsage: _networkUsageReporter(
      ref.read(networkUsageMeterProvider),
    ),
  );
  final manager = createCoverArtCacheManager(
    cacheKey: systemArtworkCacheKey,
    fileService: service,
  );
  ref.onDispose(() {
    service.close(force: true);
    unawaited(manager.dispose());
  });
  return manager;
});

final clearCoverArtCachesProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    await Future.wait([
      ref.read(coverArtCacheManagerProvider).emptyCache(),
      ref.read(systemArtworkCacheManagerProvider).emptyCache(),
    ]);
  };
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
  return await ref.read(networkCostBridgeProvider).isActiveNetworkMetered();
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
  ref.onDispose(meter.dispose);
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
        .watchTotalSince(since);
  },
);

final eqRepositoryProvider = Provider<EqRepository>(
  (ref) => EqRepository(ref.watch(navisDatabaseProvider).eqDao),
);

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

final lrclibClientProvider = Provider<LrclibClient>((ref) {
  return LrclibClient(
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.lrclib,
      options: LrclibClient.baseOptions,
    ),
  );
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

/// Whether lyrics may be looked up on LRCLIB: the integration policy allows
/// `lrclib.lyrics` (master, LRCLIB and the lyrics switch).
final useLrclibProvider = Provider<bool>((ref) {
  return ref.watch(
    integrationPolicyProvider.select(
      (policy) => policy.allows(IntegrationFeature.lrclibLyrics),
    ),
  );
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

/// Whether a Last.fm API key is bundled at build time (masked define pair, or
/// the plain NAVIS_LASTFM_API_KEY dev define).
final lastFmBundledKeyProvider = Provider<bool>((_) {
  return AppConstants.lastFmApiKey.trim().isNotEmpty;
});

/// The effective Last.fm API key.
///
/// Prefers the build-time key (see [AppConstants.lastFmApiKey]). When no
/// build-time key is present, falls back to the user-provided key stored in app
/// settings.
final lastFmApiKeyProvider = Provider<String>((ref) {
  if (_syncDiagnosticsEnabled) {
    if (_syncDiagnosticsMode == 'clone' &&
        _syncDiagnosticsLastFmKeyFile.isNotEmpty) {
      try {
        const path = _syncDiagnosticsLastFmKeyFile;
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
          return '';
        }
        final file = File(path);
        final mode = file.statSync().mode;
        if ((mode & 0x3f) != 0 || (mode & 0x100) == 0) return '';
        return file.readAsStringSync().trim();
      } on FileSystemException {
        return '';
      }
    }
    return '';
  }
  final bundledKey = AppConstants.lastFmApiKey;
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
  return LastFmApiClient(
    apiKey: apiKey,
    cache: ref.watch(integrationJsonCacheProvider),
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.lastFm,
      options: LastFmApiClient.baseOptions,
    ),
  );
});

/// The signed-in server account as a stable, non-credential key (a hash of
/// the server URL and username), or null while signed out. Integration
/// results that hold library ids (Deezer artist mappings, remembered top-song
/// matches, Home's New Releases and Trending) are kept per account, since
/// library ids are only unique within one server.
final integrationAccountScopeProvider = Provider<String?>((ref) {
  final identity = ref.watch(
    serverConfigStateProvider.select((state) {
      final config = state.asData?.value;
      return config == null ? null : (config.url, config.username);
    }),
  );
  return identity == null
      ? null
      : sha256
            .convert(utf8.encode(jsonEncode([identity.$1, identity.$2])))
            .toString();
});

/// Re-runs the integration results that are relative to the library, after a
/// library sync changed it: an empty New Releases computed before the first
/// sync must not outlive it. Trending Now refreshes itself after a sync
/// (`homeTrendingSyncRefreshBridgeProvider`).
final refreshIntegrationLibraryResultsProvider = Provider<void Function()>(
  (ref) => () {
    ref
      ..invalidate(deezerArtistResolverProvider)
      ..invalidate(artistDeezerIdProvider)
      ..invalidate(artistTopTrackSeedsProvider)
      ..invalidate(homeNewReleasesProvider);
  },
);

/// Deletes the remembered top-song and Trending matches and Deezer artist
/// mappings, which point at library ids, when the server data is wiped
/// (sign-out) or the library cache is reset, then refreshes what was built
/// from them.
final clearIntegrationLibraryCacheProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    final store = ref.read(artistTopTrackMatchStoreProvider);
    final trendingStore = ref.read(trendingMatchStoreProvider);
    final cache = ref.read(integrationJsonCacheProvider);
    await store.clear();
    await trendingStore.clear();
    await cache.clearNamespace(DeezerCache.artistIdNamespace);
    ref.read(refreshIntegrationLibraryResultsProvider)();
    ref
      ..invalidate(trendingTrackResolverProvider)
      ..invalidate(homeTrendingProvider);
  },
);

/// Refreshes Home's ListenBrainz weekly playlists after a token check, so
/// Integrations need not import Home.
final refreshWeeklyPlaylistsAfterTokenValidationProvider =
    Provider<void Function()>(
      (ref) =>
          () => ref
              .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
              .refreshAfterTokenValidation(),
    );

/// The Deezer client, shared so its request limiter covers every Deezer
/// feature. Deezer needs no key; each feature checks its own switch.
final deezerApiClientProvider = Provider<DeezerApiClient>((ref) {
  return DeezerApiClient(
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.deezer,
      options: DeezerApiClient.baseOptions,
    ),
  );
});

/// Disk cache for external-service responses, in the application support
/// directory (inside the clone root for clone diagnostics).
final integrationJsonCacheProvider = Provider<IntegrationJsonCache>(
  (_) => IntegrationJsonCache(),
);

/// Library artist → Deezer artist id, cached per server account and library
/// artist.
final deezerArtistResolverProvider = Provider<DeezerArtistResolver>((ref) {
  return DeezerArtistResolver(
    client: ref.watch(deezerApiClientProvider),
    cache: ref.watch(integrationJsonCacheProvider),
    accountScope: ref.watch(integrationAccountScopeProvider) ?? 'signed-out',
  );
});

/// Deezer artist details, related artists, albums and album details, cached
/// on disk. Each feature checks its own switch before reading.
final deezerCatalogProvider = Provider<DeezerCatalog>((ref) {
  return DeezerCatalog(
    client: ref.watch(deezerApiClientProvider),
    cache: ref.watch(integrationJsonCacheProvider),
  );
});

final lastFmApiClientFactoryProvider =
    Provider<LastFmApiClient Function(String)>((ref) {
      final createDio = ref.watch(externalDioFactoryProvider);
      return (apiKey) => LastFmApiClient(
        apiKey: apiKey,
        cache: ref.read(integrationJsonCacheProvider),
        dio: createDio(
          IntegrationService.lastFm,
          options: LastFmApiClient.baseOptions,
        ),
      );
    });

final listenBrainzApiClientProvider = Provider<ListenBrainzApiClient>((ref) {
  return ListenBrainzApiClient(
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.listenBrainz,
      options: ListenBrainzApiClient.baseOptions,
    ),
  );
});

final externalScrobbleCredentialStoreProvider =
    Provider<ExternalScrobbleCredentialStore>((_) {
      if (_syncDiagnosticsEnabled) {
        return CloneDiagnosticsExternalScrobbleCredentialStore();
      }
      return const FlutterExternalScrobbleCredentialStore();
    });

/// The user's external-integration choices combined with the credentials that
/// gate them.
///
/// Derived from scalar settings only, so unrelated settings saves do not
/// rebuild it, and `==` stops dependents rebuilding when the outcome is
/// unchanged. It denies everything while settings load or fail to load.
final integrationPolicyProvider = Provider<IntegrationPolicy>((ref) {
  final inputs = ref.watch(
    appSettingsProvider.select((async) {
      final settings = async.asData?.value;
      if (settings == null) {
        return null;
      }
      return (
        master: settings.externalIntegrationsEnabled,
        disabledJson: settings.disabledIntegrations,
        useLrclib: settings.useLrclib,
        updateCheckEnabled: settings.updateCheckEnabled,
        listenBrainzScrobblingEnabled: settings.listenBrainzScrobblingEnabled,
        legacyInstantMixEnabled: settings.legacyInstantMixEnabled,
        listenBrainzTokenValid: settings.listenBrainzTokenValid,
      );
    }),
  );
  if (inputs == null) {
    return const IntegrationPolicy.denyAll();
  }
  return IntegrationPolicy.resolve(
    masterEnabled: inputs.master,
    disabledJson: inputs.disabledJson,
    useLrclib: inputs.useLrclib,
    updateCheckEnabled: inputs.updateCheckEnabled,
    listenBrainzScrobblingEnabled: inputs.listenBrainzScrobblingEnabled,
    legacyInstantMixEnabled: inputs.legacyInstantMixEnabled,
    lastFmVerified: ref.watch(hasLastFmApiKeyProvider),
    listenBrainzVerified: inputs.listenBrainzTokenValid,
  );
});

/// Calls to external services and timed pipeline spans, for the
/// `/v1/diagnostics/integrations` endpoint and the debug log.
final integrationCallRecorderProvider = Provider<IntegrationCallRecorder>((
  ref,
) {
  final recorder = IntegrationCallRecorder();
  ref.listen(integrationPolicyProvider, (_, policy) {
    recorder.beginPolicyEpoch(policy);
  }, fireImmediately: true);
  return recorder;
});

/// Builds the guarded `Dio` for an external service. Every client of a
/// service other than the user's own server takes its `Dio` from here.
///
/// The policy is read per request, not captured, so clients built before a
/// settings change obey it too.
final externalDioFactoryProvider = Provider<ExternalDioFactory>((ref) {
  final recorder = ref.watch(integrationCallRecorderProvider);
  return (service, {options}) => createExternalDio(
    service,
    readPolicy: () => ref.read(integrationPolicyProvider),
    recorder: recorder,
    options: options,
  );
});

/// The host of the user's Subsonic server. Artwork from this host always
/// loads; artwork from any other host is subject to the integration policy.
final serverHostProvider = Provider<String?>((ref) {
  return ref.watch(
    serverConfigStateProvider.select((state) {
      final url = state.asData?.value?.url;
      if (url == null || url.trim().isEmpty) return null;
      final host = Uri.tryParse(url.trim())?.host;
      return host == null || host.isEmpty ? null : host.toLowerCase();
    }),
  );
});

/// The policy for settings that were just read from storage, for code that
/// must not trust a provider that may still be loading.
IntegrationPolicy integrationPolicyFromSettings(
  AppSettingsModel settings, {
  required bool lastFmVerified,
}) {
  return IntegrationPolicy.resolve(
    masterEnabled: settings.externalIntegrationsEnabled,
    disabledJson: settings.disabledIntegrations,
    useLrclib: settings.useLrclib,
    updateCheckEnabled: settings.updateCheckEnabled,
    listenBrainzScrobblingEnabled: settings.listenBrainzScrobblingEnabled,
    legacyInstantMixEnabled: settings.legacyInstantMixEnabled,
    lastFmVerified: lastFmVerified,
    listenBrainzVerified: settings.listenBrainzTokenValid,
  );
}

enum PreferredMixMode { sameVibes, legacyInstantMix }

/// Same Vibes while the policy allows `lastfm.sameVibes`, the server's mix
/// otherwise.
final preferredMixModeProvider = Provider<PreferredMixMode>((ref) {
  return ref
          .watch(integrationPolicyProvider)
          .allows(IntegrationFeature.lastFmSameVibes)
      ? PreferredMixMode.sameVibes
      : PreferredMixMode.legacyInstantMix;
});

final scrobbleServiceProvider = Provider<ScrobbleService>((ref) {
  final database = ref.watch(navisDatabaseProvider);
  final service = DriftScrobbleService(
    dao: database.scrobbleDao,
    readApiClient: () => ref.read(subsonicApiProvider),
    readScrobbleEnabled: () =>
        !_syncDiagnosticsEnabled &&
        (ref.read(appSettingsProvider).asData?.value.scrobbleEnabled ?? true),
    readListenBrainzCredentials: () => readListenBrainzScrobbleCredentials(
      policy: ref.read(integrationPolicyProvider),
      readToken: () => ref
          .read(externalScrobbleCredentialStoreProvider)
          .readListenBrainzToken(),
    ),
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
        readCredentials: () => readListenBrainzFeedbackCredentials(
          policy: ref.read(integrationPolicyProvider),
          readToken: () => ref
              .read(externalScrobbleCredentialStoreProvider)
              .readListenBrainzToken(),
        ),
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

final annotationSyncDispatcherProvider = Provider<AnnotationSyncDispatcher>((
  ref,
) {
  final database = ref.watch(navisDatabaseProvider);
  final dispatcher = AnnotationSyncDispatcher(
    dao: database.starSyncDao,
    readClient: () => ref.read(subsonicApiProvider),
    readAccountIdentity: () async {
      final config = await ref
          .read(serverConfigRepositoryProvider)
          .getActiveServer();
      if (config == null) return null;
      if (const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS')) {
        final uri = Uri.tryParse(config.url);
        if (!const bool.fromEnvironment(
              'NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE',
            ) ||
            uri?.scheme != 'http' ||
            !const {'127.0.0.1', '::1'}.contains(uri?.host) ||
            config.username != 'diagnostics') {
          return null;
        }
      }
      return '${config.id}|${config.url}|${config.username}';
    },
    canConnect: () => ref.read(networkTypeProvider) != NetworkType.offline,
  );
  // Isolated diagnostics never transmit copied user annotations to a server.
  if (!const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS') ||
      const bool.fromEnvironment('NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE')) {
    dispatcher.start();
  }
  ref.onDispose(dispatcher.dispose);
  return dispatcher;
});
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

/// Upper bound on waiting for the first connectivity event before the
/// startup queue restore.
const Duration audioBootstrapConnectivityWait = Duration(seconds: 2);

final audioHandlerInitializerProvider = Provider<AudioHandlerInitializer>((
  ref,
) {
  return () async {
    ref.read(annotationSyncDispatcherProvider);
    // Queue restoration resolves remote sources during audio initialization.
    // Hydrate the retained session first so the resolver does not mistake an
    // as-yet-loading credential for a signed-out session on cold start.
    final sessionHydration = ref.read(serverConfigProvider.future);
    // The resolver treats a network type it does not know yet as offline.
    // On Android the media service starts before any UI subscribes to
    // connectivity, so wait briefly for its first event; a late event is
    // covered by the deferred-restore retry.
    final connectivityHydration = ref
        .read(connectivityProvider.future)
        .timeout(audioBootstrapConnectivityWait)
        .then<void>(
          (_) {},
          onError: (Object error) {
            AppLogger.info('Connectivity unknown before queue restore: $error');
          },
        );
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

    var hydratedEq = EqConfiguration.flat();
    try {
      hydratedEq = (await ref.read(eqRepositoryProvider).load()).configuration;
    } on Object catch (error, stackTrace) {
      AppLogger.warning('EQ preload failed. $error\n$stackTrace');
    }
    final volumeController = ref.read(playbackVolumeProvider.notifier);
    if (hydratedSettings != null && !_syncDiagnosticsMuted) {
      volumeController.hydrate(
        volume: hydratedSettings.desktopPlaybackVolume,
        lastAudibleVolume: hydratedSettings.desktopLastAudibleVolume,
      );
    }
    final initialVolume = _syncDiagnosticsMuted
        ? 0.0
        : ref.read(playbackVolumeProvider);

    final database = ref.read(navisDatabaseProvider);
    final networkUsageMeter = ref.read(networkUsageMeterProvider);
    await sessionHydration;
    await connectivityHydration;
    final windowsArtwork = GuardedSystemArtworkLoader(
      artworkRecorder: ref.read(artworkCallRecorderProvider),
      readCacheManager: () => ref.read(coverArtCacheManagerProvider),
      readPolicy: () => ref.mounted
          ? ref.read(integrationPolicyProvider)
          : const IntegrationPolicy.denyAll(),
      readServerHost: () => ref.mounted ? ref.read(serverHostProvider) : null,
    );
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
      readSystemArtworkCacheManager: () =>
          ref.read(systemArtworkCacheManagerProvider),
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
      readPermanentArtwork: ref.read(permanentArtworkStoreProvider).fileFor,
      reportRollingCacheActivity: (activity) {
        if (!ref.mounted) {
          return;
        }
        try {
          ref.read(rollingCacheActivityProvider.notifier).update(activity);
          // Riverpod can throw StateError when the target notifier is disposed.
          // Keep this catch limited to that documented teardown race.
          // ignore: avoid_catching_errors
        } on StateError {
          // The target notifier can be disposed immediately before this
          // initializer during root-container teardown.
        }
      },
      startPersonalRadio: (autoPlay) async =>
          (await ref
                  .read(personalRadioProvider.notifier)
                  .start(autoPlay: autoPlay))
              .succeeded,
      playbackArtworkFileService: createPlaybackArtworkFileService(ref),
      fetchWindowsArtwork: windowsArtwork.fetch,
      readWindowsArtworkAllowed: windowsArtwork.isAllowed,
      readRadioMetadataAllowed: () => ref
          .read(integrationPolicyProvider)
          .allows(IntegrationFeature.radioNowPlaying),
      readRadioPlaybackAllowed: (stream) =>
          ref.read(integrationPolicyProvider).masterEnabled ||
          stream.host.toLowerCase() ==
              ref.read(serverHostProvider)?.toLowerCase(),
      readRadioArtworkAllowed: (uri) => integrationAllowsRadioArtworkUri(
        ref.read(integrationPolicyProvider),
        uri,
        serverHost: ref.read(serverHostProvider),
      ),
      createRadioMetadataDio: () => ref.read(externalDioFactoryProvider)(
        IntegrationService.radioMetadata,
        options: BaseOptions(headers: {'User-Agent': AppConstants.userAgent}),
      ),
      startPreferredMix: (seedId) async {
        final settings = await ref
            .read(settingsRepositoryProvider)
            .getSettings();
        final useServer = !integrationPolicyFromSettings(
          settings,
          lastFmVerified: ref.read(hasLastFmApiKeyProvider),
        ).allows(IntegrationFeature.lastFmSameVibes);
        if (useServer) {
          ref.read(sameVibesProvider.notifier).deactivate();
          await ref.read(instantMixProvider.notifier).activate(seedId);
          if (!ref.read(instantMixProvider).active) {
            throw StateError('Server mix did not insert playable tracks.');
          }
        } else {
          ref.read(instantMixProvider.notifier).deactivate();
          await ref.read(sameVibesProvider.notifier).activate(seedId);
          if (!ref.read(sameVibesProvider).active) {
            throw StateError('Same Vibes did not insert playable tracks.');
          }
        }
      },
      togglePreferredMix: (seedId) async {
        final settings = await ref
            .read(settingsRepositoryProvider)
            .getSettings();
        final useServer = !integrationPolicyFromSettings(
          settings,
          lastFmVerified: ref.read(hasLastFmApiKeyProvider),
        ).allows(IntegrationFeature.lastFmSameVibes);
        if (useServer && ref.read(instantMixProvider).active) {
          ref.read(instantMixProvider.notifier).deactivate();
          return;
        }
        if (!useServer && ref.read(sameVibesProvider).active) {
          ref.read(sameVibesProvider.notifier).deactivate();
          return;
        }
        if (useServer) {
          ref.read(sameVibesProvider.notifier).deactivate();
          await ref.read(instantMixProvider.notifier).activate(seedId);
          if (!ref.read(instantMixProvider).active) {
            throw StateError('Server mix did not insert playable tracks.');
          }
        } else {
          ref.read(instantMixProvider.notifier).deactivate();
          await ref.read(sameVibesProvider.notifier).activate(seedId);
          if (!ref.read(sameVibesProvider).active) {
            throw StateError('Same Vibes did not insert playable tracks.');
          }
        }
      },
      readRuntimeSettings: () {
        final settings =
            ref.read(appSettingsProvider).asData?.value ??
            hydratedSettings ??
            const AppSettingsModel.defaults();
        final onCellular =
            ref.read(networkTypeProvider) == NetworkType.cellular;
        final adjustments = ref
            .read(playbackAdjustmentsProvider)
            .asData
            ?.value
            .values;
        return PlaybackRuntimeSettings(
          equalizer:
              ref.read(equalizerProvider).asData?.value.configuration ??
              hydratedEq,
          gaplessEnabled: settings.gaplessEnabled && !onCellular,
          crossfadeEnabled: settings.crossfadeEnabled,
          crossfadeAllowStreaming: !onCellular,
          crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
          crossfadeType: settings.crossfadeType,
          replayGainMode: settings.replayGainMode,
          replayGainPreamp: settings.replayGainPreamp,
          playbackSpeed: adjustments?.speed ?? settings.playbackSpeed,
          playbackPitchSemitones:
              adjustments?.pitchSemitones ?? settings.playbackPitchSemitones,
          lockPitchToSpeed:
              adjustments?.lockPitchToSpeed ?? settings.lockPitchToSpeed,
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

    if (!_syncDiagnosticsMuted &&
        ref.read(appSettingsProvider).asData?.value == null) {
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

    ref.listen<IntegrationPolicy>(integrationPolicyProvider, (_, _) {
      handler.updateRadioMetadata();
    });
    return handler;
  };
});

enum AudioBootstrapStatus { initializing, ready, failed }

enum PlaybackUnavailableReason { initializing, startupFailed, unavailable }

class PlaybackUnavailableException implements Exception {
  const new({required this.reason, this.message});

  final PlaybackUnavailableReason reason;
  final String? message;

  @override
  String toString() => message ?? reason.name;
}

class AudioBootstrapState {
  const new({
    required this.status,
    this.handler,
    this.errorMessage,
    this.attempt = 0,
    this.elapsedMs,
    this.timedOut = false,
    this.recoveredFromTimeout = false,
  });

  const new initializing({this.attempt = 0})
    : status = AudioBootstrapStatus.initializing,
      handler = null,
      errorMessage = null,
      elapsedMs = null,
      timedOut = false,
      recoveredFromTimeout = false;

  const new ready(
    NavisPlaybackHandler readyHandler, {
    this.attempt = 0,
    this.elapsedMs,
    this.recoveredFromTimeout = false,
  }) : status = AudioBootstrapStatus.ready,
       handler = readyHandler,
       errorMessage = null,
       timedOut = false;

  const new failed(
    String failureMessage, {
    this.attempt = 0,
    this.elapsedMs,
    this.timedOut = false,
  }) : status = AudioBootstrapStatus.failed,
       handler = null,
       errorMessage = failureMessage,
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
    // Session retirement is not a startup failure; the next request may rebuild.
    _inFlight = null;
    _didAttempt = false;
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
  const new({required this.album, required this.songs});

  final AlbumsTableData album;
  final List<SongsTableData> songs;
}

class ArtistAlbumSections {
  const new({
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

final artistByIdProvider = StreamProvider.autoDispose
    .family<ArtistsTableData?, String>((ref, artistId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchArtistById(artistId);
    });

// Auto-disposed: a visited artist's album watch must not keep re-running on
// every library write after the page closes.
final artistAlbumSectionsProvider = StreamProvider.autoDispose
    .family<ArtistAlbumSections, String>((ref, artistId) {
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

// Auto-disposed: album cards, menus and the Now Playing panel each watch an
// album briefly, and every instance holds two live database watches.
final albumProvider = StreamProvider.autoDispose.family<AlbumWithSongs?, String>((
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
          unawaited(songsSub?.cancel());
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
    unawaited(albumSub.cancel());
    unawaited(songsSub?.cancel());
    unawaited(controller.close());
  });

  return controller.stream;
});

typedef AlbumPageRequest = ({AlbumSortOrder sort, int limit});
typedef AlbumListRequest = ({AlbumSortOrder sort, bool likedOnly});
typedef AlbumYearSectionsRequest = ({bool likedOnly, bool downloadedOnly});

final albumPageSizeProvider = Provider<int>((_) => 60);

final albumCountProvider = StreamProvider<int>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumCount();
});

// Each page request (limit 60, 120, ...) is its own instance; auto-dispose
// frees earlier limits once the grid watches the next one.
final pagedAlbumsProvider = StreamProvider.autoDispose
    .family<List<AlbumsTableData>, AlbumPageRequest>((ref, request) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumsPage(sort: request.sort, limit: request.limit);
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

/// All recently liked albums; callers filter before taking a pane-sized preview.
final likedAlbumsRecentProvider = StreamProvider<List<AlbumsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchRecentlyLikedAlbums(limit: null);
});

final likedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAllStarredSongs();
});

final likedAlbumSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongsFromLikedAlbums();
});

// Per-song and per-list families are auto-disposed: rows are created while
// scrolling long lists, and each instance holds a live database watch.
final songByIdProvider = StreamProvider.autoDispose
    .family<SongsTableData?, String>((ref, songId) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchSongById(songId);
    });

/// Emits `true` when the song with `songId` is starred/liked.
final songStarredProvider = StreamProvider.autoDispose.family<bool, String>((
  ref,
  songId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongStarred(songId);
});

final songRatingProvider = StreamProvider.autoDispose.family<int?, String>((
  ref,
  songId,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongRating(songId);
});

final albumRatingProvider = StreamProvider.family<int?, String>((ref, albumId) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchAlbumRating(albumId);
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

/// Download badges for every album with download activity, from one query.
final albumDownloadSummariesProvider =
    StreamProvider<Map<String, AlbumTileDownloadState>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchAlbumDownloadSummaries().map(
        (summaries) => <String, AlbumTileDownloadState>{
          for (final summary in summaries)
            summary.albumId: albumTileDownloadStateFromSummary(summary),
        },
      );
    });

@visibleForTesting
AlbumTileDownloadState albumTileDownloadStateFromSummary(
  AlbumDownloadSummary summary,
) {
  final total = summary.totalTrackCount;
  if (total <= 0) return const AlbumTileDownloadState.idle();
  final downloaded = summary.downloadedTrackCount;
  return AlbumTileDownloadState(
    fullyDownloaded: downloaded >= total,
    downloadedTrackCount: downloaded,
    totalTrackCount: total,
    queued: summary.queued,
    progress: ((downloaded + summary.inFlightProgress) / total).clamp(0.0, 1.0),
  );
}

/// One album card's download badge. Cards select their own entry, so a card
/// rebuilds only when its album's state changes.
final albumTileDownloadStateProvider = Provider.autoDispose
    .family<AlbumTileDownloadState, String>((ref, albumId) {
      return ref.watch(
        albumDownloadSummariesProvider.select(
          (summaries) =>
              summaries.asData?.value[albumId] ??
              const AlbumTileDownloadState.idle(),
        ),
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
  return await api.getInternetRadioStations();
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
  return RollingCacheManager(
    cacheDao: database.cacheDao,
    songIdentityDao: database.songIdentityDao,
    entryExists: (entry) => storedAudioExists(
      locator: entry.filePath,
      storageKind: entry.storageKind,
    ),
  );
});

class RollingCacheActivityController extends Notifier<RollingCacheActivity> {
  @override
  RollingCacheActivity build() => const RollingCacheActivity.idle();

  // Preserve the update command used by the playback activity callback.
  // ignore: use_setters_to_change_properties
  void update(RollingCacheActivity activity) {
    state = activity;
  }
}

final rollingCacheActivityProvider =
    NotifierProvider<RollingCacheActivityController, RollingCacheActivity>(
      RollingCacheActivityController.new,
    );

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) {
    return Stream<PlaybackSnapshot>.value(const PlaybackSnapshot.idle());
  }
  return Stream<PlaybackSnapshot>.multi((controller) {
    // Attach before delivering the seed. An async* initial yield can pause
    // before yield* subscribes, losing seek settlement on a broadcast stream.
    final subscription = handler.snapshotStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.add(handler.snapshot);
    controller.onCancel = subscription.cancel;
  });
});

final transportVisualCueProvider = StreamProvider<TransportVisualCue>((ref) {
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

/// Songs the handler dropped from the queue after accepting them. A plain
/// stream, so a subscriber receives every event even while no widget listens.
final queueSongsDroppedProvider = Provider<Stream<QueueSongsDropped>>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler?.droppedSongsStream ?? const Stream<QueueSongsDropped>.empty();
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
    return Stream<PlaybackBufferState>.value(const PlaybackBufferState.idle());
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

  double hydrate({required double volume, required double lastAudibleVolume}) {
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
      await _persistCurrentVolume(throwOnFailure: throwOnPersistenceFailure);
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
    await _persistCurrentVolume(throwOnFailure: throwOnPersistenceFailure);
    return state;
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
  // Only the playing item's metadata can supplement the lookup, so watch just
  // that. Watching the whole media item would re-run every cached lyrics
  // lookup on each track change or artwork re-emit.
  final currentMetadata = ref.watch(
    currentMediaItemProvider.select((value) {
      final item = value.asData?.value;
      if (item == null || item.id != songId) return null;
      return (
        title: item.title,
        artist: item.artist,
        album: item.album,
        duration: item.duration,
      );
    }),
  );
  final lookupMetadata = navisResolveLyricsLookupMetadata(
    songId: songId,
    song: song,
    currentMediaItem: currentMetadata == null
        ? null
        : MediaItem(
            id: songId,
            title: currentMetadata.title,
            artist: currentMetadata.artist,
            album: currentMetadata.album,
            duration: currentMetadata.duration,
          ),
  );
  final cachedTrack = await database.cacheDao.getCachedTrack(songId);
  final resolver = LyricsResolver(
    libraryDao: dao,
    lrclibClient: ref.read(lrclibClientProvider),
    apiClient: api,
  );
  return await resolver.resolve(
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

  return await api.getArtistInfo2(artistId);
});

final downloadQueueProvider = StreamProvider<List<DownloadQueueTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).downloadQueueDao;
  return dao.watchQueue();
});

class CacheStats {
  const new({required this.trackCount, required this.totalBytes});

  final int trackCount;
  final int totalBytes;
}

// Cache-derived views emit only when their value changes: most
// cached_tracks writes (a playback touch, a download's progress) leave them
// unchanged, and every emission rebuilds badges and lists.
final rollingCacheStatsProvider = StreamProvider<CacheStats>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracksByType(CacheType.rolling)
      .map(_cacheStatsOf)
      .distinct(_sameCacheStats);
});

final permanentCacheStatsProvider = StreamProvider<CacheStats>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracksByType(CacheType.permanent)
      .map(_cacheStatsOf)
      .distinct(_sameCacheStats);
});

CacheStats _cacheStatsOf(List<CachedTracksTableData> tracks) => CacheStats(
  trackCount: tracks.length,
  totalBytes: tracks.fold<int>(0, (sum, item) => sum + item.fileSize),
);

bool _sameCacheStats(CacheStats a, CacheStats b) =>
    a.trackCount == b.trackCount && a.totalBytes == b.totalBytes;

final cachedSongIdsProvider = StreamProvider<Set<String>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracks()
      .map((tracks) => tracks.map((track) => track.songId).toSet())
      .distinct(setEquals);
});

/// Maps songId → CacheType for all cached tracks (rolling + permanent).
final cachedSongTypesProvider = StreamProvider<Map<String, CacheType>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).cacheDao;
  return dao
      .watchCachedTracks()
      .map((tracks) => {for (final t in tracks) t.songId: t.cacheType})
      .distinct(mapEquals);
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
      .map((tracks) => tracks.map((track) => track.songId).toSet())
      .distinct(setEquals);
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
      // One join returning only the distinct album and artist ids, instead
      // of loading every downloaded song after each cached_tracks write.
      return ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .watchDownloadedContentIds()
          .distinct(
            (a, b) =>
                setEquals(a.albumIds, b.albumIds) &&
                setEquals(a.artistIds, b.artistIds),
          );
    });

/// Provides the list of permanently cached tracks.
/// Songs for the Downloads screen (downloaded or queued), keyed by ID.
final downloadRelatedSongsProvider =
    StreamProvider.autoDispose<Map<String, SongsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      return dao.watchDownloadRelatedSongs();
    });

final permanentCachedTracksProvider =
    StreamProvider<List<CachedTracksTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).cacheDao;
      return dao.watchCachedTracksByType(CacheType.permanent);
    });

/// Clone diagnostics keep downloads and their artwork inside the run root.
final Future<Directory> Function()? _downloadSupportDirectoryOverride =
    _syncDiagnosticsEnabled &&
        _syncDiagnosticsMode == 'clone' &&
        _syncDiagnosticsRoot.isNotEmpty
    ? () async {
        final directory = Directory('$_syncDiagnosticsRoot/support');
        await directory.create(recursive: true);
        return directory;
      }
    : null;

/// Durable cover art of permanent downloads, shared by the download service,
/// cover art widgets, and the system media art cache.
final permanentArtworkStoreProvider = Provider<PermanentArtworkStore>((ref) {
  return PermanentArtworkStore(
    readApplicationSupportDirectory: _downloadSupportDirectoryOverride,
    // Resolved on first use: cover widgets read this store, and the meter
    // opens the database.
    reportNetworkUsage: ({required category, required bytes, operation}) => ref
        .read(networkUsageMeterProvider)
        .record(category: category, bytes: bytes, operation: operation),
  );
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
    readIsOnline: () => ref.read(networkTypeProvider) != NetworkType.offline,
    readIsWifi: () =>
        isDesktopRuntime || ref.read(networkTypeProvider) == NetworkType.wifi,
    readCustomDownloadFolderEnabled: () =>
        ref.read(customDownloadFolderEnabledProvider),
    readCustomDownloadFolderPath: () =>
        ref.read(customDownloadFolderPathProvider),
    lrclibClient: ref.read(lrclibClientProvider),
    readLyricsAllowed: () => ref.read(useLrclibProvider),
    readCoverArtCacheManager: () => ref.read(coverArtCacheManagerProvider),
    readProfileIdentity: () {
      final config = ref.read(serverConfigProvider).asData?.value;
      return config == null ? null : '${config.url}|${config.username}';
    },
    readApplicationSupportDirectory: _downloadSupportDirectoryOverride,
    artworkStore: ref.read(permanentArtworkStoreProvider),
    readLocalizations: () =>
        resolveNotificationLocalizations(ref.read(appLocaleProvider)),
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
  ref.listen(customDownloadFolderEnabledProvider, (previous, next) {
    if (previous != next) unawaited(service.refreshDownloadFolder());
  });
  ref.listen(customDownloadFolderPathProvider, (previous, next) {
    if (previous != next) unawaited(service.refreshDownloadFolder());
  });
  ref.onDispose(service.dispose);
  return service;
});

/// Persistent configuration hold reported by the existing download queue owner.
final downloadFolderProblemProvider = StreamProvider<DownloadFolderProblem?>(
  (ref) => ref.watch(downloadServiceProvider).folderChanges,
);

/// One notice per unresolved folder problem, when a download is requested.
final downloadFolderNoticeProvider = StreamProvider<DownloadFolderProblem>(
  (ref) => ref.watch(downloadServiceProvider).folderNotices,
);

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

/// The saved download quality (and whether its one-time prompt was answered).
final downloadQualityPreferenceProvider =
    StreamProvider<DownloadQualityPreference>((ref) {
      return ref
          .watch(navisDatabaseProvider)
          .appSettingsDao
          .watchDownloadQualityPreference();
    });

/// The configured number of concurrent downloads (1 to 4).
final maxConcurrentDownloadsProvider = StreamProvider<int>((ref) {
  return ref
      .watch(navisDatabaseProvider)
      .appSettingsDao
      .watchMaxConcurrentDownloads();
});

/// Whether the download queue is paused.
final downloadsPausedProvider = StreamProvider<bool>((ref) {
  return ref.watch(navisDatabaseProvider).appSettingsDao.watchDownloadsPaused();
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

/// Current colour style (Neutral, Pastel, Immersive or Night).
final colorStyleProvider = Provider<NavisColorStyle>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return NavisColorStyle.parse(settings.colorStyle);
});

/// Whether Auto mode uses OLED when the device is dark.
final oledForAutoProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.oledForAuto;
});

/// Whether surfaces use flat rendering.
final flatSurfacesProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.flatSurfaces;
});

/// Areas affected when the Flat Surfaces switch is enabled.
final flatAreasProvider = Provider<FlatAreas>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.flatAreas;
});

/// Saved colour tuning, using the identity while settings load or fail.
final colorTuningProvider = Provider<ColorTuning>((ref) {
  final settings = ref.watch(appSettingsProvider).asData?.value;
  return settings?.colorTuning ?? ColorTuning.none;
});

/// Temporary drag state; callers clear it after persistence or cancellation.
class ColorTuningPreviewNotifier extends Notifier<ColorTuning?> {
  @override
  ColorTuning? build() => null;

  // Drag commands pair with clear(); this is the preview API shared by controls.
  // ignore: use_setters_to_change_properties
  void preview(ColorTuning adjustment) => state = adjustment;
  void clear() => state = null;
}

final colorTuningPreviewProvider =
    NotifierProvider<ColorTuningPreviewNotifier, ColorTuning?>(
      ColorTuningPreviewNotifier.new,
    );

final effectiveColorTuningProvider = Provider<ColorTuning>((ref) {
  final preview = ref.watch(colorTuningPreviewProvider);
  final persisted = ref.watch(colorTuningProvider);
  return preview ?? persisted;
});

/// Whether album-card captions use the optional title shade.
final albumArtShadeProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.albumArtShade;
});

/// Effective caption shade; cover colour applies only while Shade is enabled.
final albumTitleShadeModeProvider = Provider<AlbumTitleShade>((ref) {
  if (!ref.watch(albumArtShadeProvider)) return AlbumTitleShade.classic;
  return ref.watch(albumArtColoredShadeProvider)
      ? AlbumTitleShade.color
      : AlbumTitleShade.dark;
});

/// Saved Use Cover Color preference, meaningful while Shade is enabled.
final albumArtColoredShadeProvider = Provider<bool>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.albumArtColoredShade;
});

/// Daily window for the Night colour style.
final nightScheduleProvider = Provider<NightSchedule>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return NightSchedule(
    enabled: settings.nightScheduleEnabled,
    startMinutes: settings.nightScheduleStartMinutes,
    endMinutes: settings.nightScheduleEndMinutes,
  );
});

final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Applies the scheduled Night style without changing the saved user style.
final effectiveColorStyleProvider = Provider<NavisColorStyle>((ref) {
  final style = ref.watch(colorStyleProvider);
  final schedule = ref.watch(nightScheduleProvider);
  final now = ref.watch(nowProvider)();
  if (schedule.enabled) {
    final untilBoundary = schedule.nextBoundaryAfter(now).difference(now);
    // Suspended desktops may resume without advancing Dart timers. Recheck the
    // wall clock within fifteen minutes even when the boundary was hours away.
    const recheckCap = Duration(minutes: 15);
    final timer = Timer(
      untilBoundary < recheckCap ? untilBoundary : recheckCap,
      ref.invalidateSelf,
    );
    ref.onDispose(timer.cancel);
  }
  return schedule.isActiveAt(now) ? NavisColorStyle.night : style;
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

/// Current Now Playing background, defaulting to tinted while settings load.
final nowPlayingBackgroundProvider = Provider<NowPlayingBackground>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.nowPlayingBackground;
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

final gridArtworkSizeProvider = Provider<GridArtworkSize>((ref) {
  return ref.watch(
    appSettingsProvider.select(
      (settings) =>
          settings.asData?.value.gridArtworkSize ?? GridArtworkSize.auto,
    ),
  );
});

final homeRecommendationsAutoAdvanceProvider = Provider<bool>((ref) {
  return ref.watch(
    appSettingsProvider.select(
      (settings) =>
          settings.asData?.value.homeRecommendationsAutoAdvance ?? false,
    ),
  );
});

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

/// The shape setting [ArtworkShapeRole] artwork follows; map it to corners
/// with [artworkBorderRadius].
final artworkShapeProvider = Provider.family<String, ArtworkShapeRole>(
  (ref, role) => switch (role) {
    ArtworkShapeRole.cover => ref.watch(coverArtShapeProvider),
    ArtworkShapeRole.nowPlaying => ref.watch(nowPlayingArtShapeProvider),
    ArtworkShapeRole.artist => ref.watch(artistCardShapeProvider),
  },
);

/// Artist view layout: 'list' or 'grid'.
final artistViewModeProvider = Provider<String>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.artistViewMode;
});

/// App-wide Density covers Home and lists, using the existing homeDensity column.
final densityProvider = Provider<NavisDensity>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.density;
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
  return dao.watchCustomColorPresets().map(decodeAccentSeeds);
});

/// The app's own package metadata (version, build number, etc.).
/// Cached for the lifetime of the app — the version never changes at runtime.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return await PackageInfo.fromPlatform();
});

/// Carries a manual "Check now" request to the next [updateProvider] run,
/// which then bypasses the 24-hour throttle.
///
/// The request is a plain field rather than provider state: [updateProvider]
/// consumes it while building, and a provider must not modify another
/// provider during its build.
class UpdateForceCheckNotifier extends Notifier<void> {
  bool _requested = false;

  @override
  void build() {}

  void requestForceCheck() => _requested = true;

  bool consumeForceCheck() {
    final requested = _requested;
    _requested = false;
    return requested;
  }
}

final updateForceCheckProvider =
    NotifierProvider<UpdateForceCheckNotifier, void>(
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
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.updates,
      options: BaseOptions(headers: {'User-Agent': AppConstants.userAgent}),
    ),
    networkUsageReporter: meter.record,
  );
});

/// Retains the updater's last manifest check for diagnostics.
final updateRepositoryProvider = Provider<UpdateRepository>((ref) {
  return UpdateRepository(
    dio: ref.watch(externalDioFactoryProvider)(
      IntegrationService.updates,
      options: BaseOptions(headers: {'User-Agent': AppConstants.userAgent}),
    ),
    installSourceService: ref.watch(installSourceServiceProvider),
    updateCheckStore: ref.watch(updateCheckStoreProvider),
  );
});

/// Checks whether a newer signed Navis release is available.
/// Auto-disposed so it re-runs each time a screen watches it freshly.
final updateProvider = FutureProvider.autoDispose<UpdateInfo?>((ref) async {
  final isLoading = ref.watch(
    appSettingsProvider.select((settings) => settings.isLoading),
  );
  if (isLoading) {
    return null;
  }
  final (serviceEnabled, automaticEnabled) = ref.watch(
    integrationPolicyProvider.select(
      (policy) => (
        policy.isServiceEnabled(IntegrationService.updates),
        policy.isFeatureSwitchOn(IntegrationFeature.updatesAutomatic),
      ),
    ),
  );
  // Only the master and updates service switches block a manual "Check now".
  // Read the flag before deciding, so an automatic check that is off never
  // swallows a pending manual request.
  final forceCheck = ref
      .read(updateForceCheckProvider.notifier)
      .consumeForceCheck();
  if (!serviceEnabled) {
    return null;
  }
  if (!forceCheck && !automaticEnabled) {
    return null;
  }

  return await ref
      .read(updateRepositoryProvider)
      .checkForUpdate(forceCheck: forceCheck);
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
