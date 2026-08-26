import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final libraryCacheResetServiceProvider = Provider<LibraryCacheResetService>((
  ref,
) {
  return LibraryCacheResetService(
    database: ref.watch(navisDatabaseProvider),
    clearCoverArt: () => ref.read(coverArtCacheManagerProvider).emptyCache(),
  );
});

final cacheSystemUpgradeServiceProvider = Provider<CacheSystemUpgradeService>((
  ref,
) {
  return CacheSystemUpgradeService(
    database: ref.watch(navisDatabaseProvider),
    cacheResetService: ref.watch(libraryCacheResetServiceProvider),
    triggerFullLibraryScan: () async {
      final result = await ref
          .read(librarySyncControllerProvider.notifier)
          .forceFullSync();
      return result.status == LibrarySyncStatus.succeeded;
    },
  );
});

final cacheSystemUpgradeNeededProvider = FutureProvider<bool>((ref) {
  return ref.watch(cacheSystemUpgradeServiceProvider).needsReset();
});

/// Whether an authenticated profile must complete the current cache renewal.
///
/// The nullable state deliberately keeps routing on its current screen while
/// the persisted marker is loading. An unconfigured installation never reads
/// the marker, so Login remains independent from library-cache initialization.
final cacheSystemUpgradeRequiredProvider = Provider<bool?>((ref) {
  final serverConfig = ref.watch(serverConfigStateProvider);
  if (serverConfig.isLoading && !serverConfig.hasValue) {
    return null;
  }
  if (serverConfig.asData?.value == null) {
    return false;
  }
  final needed = ref.watch(cacheSystemUpgradeNeededProvider);
  return needed.when(
    data: (value) => value,
    loading: () => null,
    error: (_, _) => true,
  );
});
