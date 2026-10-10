import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/providers/app_providers.dart';

enum SessionRoutePhase { loading, unauthenticated, initialSyncRequired, ready }

/// Full freshness remains distinct from a usable partial first catalog.
/// Legacy completed profiles keep their persisted lastSynced evidence.
bool hasCompletedInitialCatalog({
  DateTime? lastSynced,
  DateTime? lastCatalogSyncedAt,
}) => lastSynced != null || lastCatalogSyncedAt != null;

bool hasUsableInitialCatalog({
  DateTime? lastSynced,
  DateTime? lastCatalogSyncedAt,
  DateTime? initialCatalogUsableAt,
  required int currentGeneration,
}) =>
    hasCompletedInitialCatalog(
      lastSynced: lastSynced,
      lastCatalogSyncedAt: lastCatalogSyncedAt,
    ) ||
    (currentGeneration > 0 && initialCatalogUsableAt != null);

/// Whether the authenticated profile still needs its first usable catalog.
Future<bool> isInitialCatalogSetupPending(
  NavisDatabase database,
  ServerConfigModel config,
) async {
  if (config.lastSynced != null || config.id == null) return false;
  final persisted = await database.librarySyncDao.getOrCreateState(config.id!);
  return !hasUsableInitialCatalog(
    lastCatalogSyncedAt: persisted.lastCatalogSyncedAt,
    initialCatalogUsableAt: persisted.initialCatalogUsableAt,
    currentGeneration: persisted.currentGeneration,
  );
}

/// A first-setup run completes once no blocking catalog work or verification
/// remains, even if server-incomplete album details still need retries.
bool isCompletedInitialSyncRun(LibrarySyncState result) =>
    result.status == LibrarySyncStatus.succeeded &&
    !result.hasBlockingPendingAlbums &&
    result.remainingVerificationCount == 0 &&
    result.candidateGeneration == null &&
    result.candidateStatus == null;

/// A verified server-owned album detail gap may continue in the background
/// after the authoritative catalog has been published. Other partial work
/// remains on the full-screen route.
bool isUsableIncompleteAlbumSyncRun(LibrarySyncState result) =>
    (result.status == LibrarySyncStatus.partial ||
        result.status == LibrarySyncStatus.succeeded) &&
    result.stage == LibrarySyncStage.completed &&
    result.metadataReady &&
    !result.isHydrating &&
    result.onlyIncompleteAlbumDetails &&
    result.catalogPublishedThisRun &&
    (result.pendingHydrationCount ?? 0) > 0 &&
    result.remainingVerificationCount == 0 &&
    result.candidateGeneration == null &&
    result.candidateStatus == null;

/// Records validated readiness and its model/cache stamps in one transaction.
/// Null versions leave their installation stamps unchanged.
Future<bool> recordInitialCatalogReadiness({
  required NavisDatabase database,
  required int serverId,
  required LibrarySyncState result,
  String? syncModelVersion,
  int? cacheEpoch,
}) async {
  if (!isCompletedInitialSyncRun(result) &&
      !isUsableIncompleteAlbumSyncRun(result)) {
    return false;
  }
  return await database.transaction(() async {
    final server = await database.serverDao.getActiveServer();
    if (server?.id != serverId) return false;
    final persisted = await database.librarySyncDao.getOrCreateState(serverId);
    if (persisted.currentGeneration <= 0 ||
        persisted.candidateGeneration != null ||
        persisted.candidateStatus != null) {
      return false;
    }
    if (isCompletedInitialSyncRun(result)) {
      if (!hasCompletedInitialCatalog(
        lastSynced: server?.lastSynced,
        lastCatalogSyncedAt: persisted.lastCatalogSyncedAt,
      )) {
        return false;
      }
    }
    if (isUsableIncompleteAlbumSyncRun(result)) {
      if (await database.libraryDao.countPendingHydrationAlbums() !=
          result.pendingHydrationCount) {
        return false;
      }
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          initialCatalogUsableAt: Value(DateTime.now().toUtc()),
        ),
      );
    }
    if (syncModelVersion != null) {
      await database.appSettingsDao.setLastFullSyncAppBuild(syncModelVersion);
    }
    if (cacheEpoch != null) {
      await database.cacheSystemStateDao.markVersion(cacheEpoch);
    }
    return true;
  });
}

final initialSyncRequiredProvider = FutureProvider<bool>((ref) async {
  final config = ref.watch(serverConfigStateProvider).asData?.value;
  if (config == null) {
    return false;
  }
  if (config.lastSynced != null) return false;
  // Routing still requires setup while the profile has no persisted identity.
  if (config.id == null) return true;
  return await isInitialCatalogSetupPending(
    ref.watch(navisDatabaseProvider),
    config,
  );
});

final sessionRoutePhaseProvider = Provider<SessionRoutePhase>((ref) {
  final config = ref.watch(serverConfigStateProvider);
  if (config.isLoading && !config.hasValue) {
    return SessionRoutePhase.loading;
  }
  if (config.asData?.value == null) {
    return SessionRoutePhase.unauthenticated;
  }
  final initialRequired = ref.watch(initialSyncRequiredProvider);
  return initialRequired.when(
    data: (required) => required
        ? SessionRoutePhase.initialSyncRequired
        : SessionRoutePhase.ready,
    loading: () => SessionRoutePhase.loading,
    error: (_, _) => SessionRoutePhase.initialSyncRequired,
  );
});
