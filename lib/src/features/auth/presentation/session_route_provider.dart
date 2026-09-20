import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
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

/// A first-setup run cannot dismiss the required screen while catalog work or
/// verification is still outstanding, even when a candidate was promoted.
bool isCompletedInitialSyncRun(LibrarySyncState result) =>
    result.status == LibrarySyncStatus.succeeded &&
    (result.pendingHydrationCount ?? 0) == 0 &&
    result.remainingVerificationCount == 0 &&
    result.candidateGeneration == null &&
    result.candidateStatus == null;

/// A verified server-owned album detail gap may continue in the background
/// after the authoritative catalog has been published. Other partial work
/// remains on the full-screen route.
bool isUsableIncompleteAlbumSyncRun(LibrarySyncState result) =>
    result.status == LibrarySyncStatus.partial &&
    result.stage == LibrarySyncStage.completed &&
    result.metadataReady &&
    !result.isHydrating &&
    result.onlyIncompleteAlbumDetails &&
    result.catalogPublishedThisRun &&
    (result.pendingHydrationCount ?? 0) > 0 &&
    result.remainingVerificationCount == 0 &&
    result.candidateGeneration == null &&
    result.candidateStatus == null;

Future<bool> recordInitialCatalogReadiness({
  required NavisDatabase database,
  required int serverId,
  required LibrarySyncState result,
}) async {
  if (!isCompletedInitialSyncRun(result) &&
      !isUsableIncompleteAlbumSyncRun(result)) {
    return false;
  }
  return database.transaction(() async {
    final server = await database.serverDao.getActiveServer();
    if (server?.id != serverId) return false;
    final persisted = await database.librarySyncDao.getOrCreateState(serverId);
    if (persisted.currentGeneration <= 0 ||
        persisted.candidateGeneration != null ||
        persisted.candidateStatus != null) {
      return false;
    }
    if (isCompletedInitialSyncRun(result)) {
      return hasCompletedInitialCatalog(
        lastSynced: server?.lastSynced,
        lastCatalogSyncedAt: persisted.lastCatalogSyncedAt,
      );
    }
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
    return true;
  });
}

final initialSyncRequiredProvider = FutureProvider<bool>((ref) async {
  final config = ref.watch(serverConfigStateProvider).asData?.value;
  if (config == null) {
    return false;
  }
  if (hasCompletedInitialCatalog(lastSynced: config.lastSynced)) {
    return false;
  }
  final serverId = config.id;
  if (serverId == null) {
    return true;
  }
  final persisted = await ref
      .watch(navisDatabaseProvider)
      .librarySyncDao
      .getOrCreateState(serverId);
  return !hasUsableInitialCatalog(
    lastCatalogSyncedAt: persisted.lastCatalogSyncedAt,
    initialCatalogUsableAt: persisted.initialCatalogUsableAt,
    currentGeneration: persisted.currentGeneration,
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
