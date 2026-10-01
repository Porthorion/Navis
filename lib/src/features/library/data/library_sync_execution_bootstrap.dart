import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/utils/connectivity.dart';

/// Constructs the production database/API sync pipeline without any UI,
/// audio, notification, or diagnostics dependency.
///
/// Foreground and Android headless execution use this same bootstrap so their
/// planner, engine, coordinator, durable queue, and execution lease cannot
/// drift into separate implementations.
class LibrarySyncExecutionBootstrap {
  const new _();

  static AdaptiveLibrarySyncCoordinator createCoordinator({
    required SubsonicApiClient client,
    required NavisDatabase database,
    required ServerConfigRepository serverConfigRepository,
    required SyncNetworkPolicy Function() readSyncNetworkPolicy,
    required Duration staleAfter,
    required NetworkType initialNetworkType,
    required bool Function() readHasActivePlayback,
    required bool Function() readIsForeground,
    int? Function()? readMeteredResponseBudgetBytes,
    Future<void> Function(Map<String, String> aliases)?
    onBeforeSongIdentityRemap,
    String? Function()? readActiveSongId,
    Set<String> Function()? readProtectedSongIds,
    String executionOwnerKind = 'foreground',
    bool isBackgroundExecution = false,
    Duration? executionLeaseTtl,
    Duration? executionLeaseHeartbeatInterval,
  }) {
    final executor = DriftLibrarySyncEngine(
      api: SubsonicLibrarySyncApi(client),
      database: database,
      serverConfigRepository: serverConfigRepository,
      staleAfter: staleAfter,
      networkType: initialNetworkType,
      readSyncNetworkPolicy: readSyncNetworkPolicy,
      readMeteredResponseBudgetBytes: readMeteredResponseBudgetBytes,
      onBeforeSongIdentityRemap: onBeforeSongIdentityRemap,
      readActiveSongId: readActiveSongId,
      readProtectedSongIds: readProtectedSongIds,
    );
    return AdaptiveLibrarySyncCoordinator(
      executor: executor,
      database: database,
      serverConfigRepository: serverConfigRepository,
      readSyncNetworkPolicy: readSyncNetworkPolicy,
      staleAfter: staleAfter,
      readHasActivePlayback: readHasActivePlayback,
      readIsForeground: readIsForeground,
      executionOwnerKind: executionOwnerKind,
      isBackgroundExecution: isBackgroundExecution,
      executionLeaseTtl: executionLeaseTtl,
      executionLeaseHeartbeatInterval: executionLeaseHeartbeatInterval,
    );
  }
}
