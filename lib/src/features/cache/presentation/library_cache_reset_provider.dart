import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
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
  );
});

final cacheSystemUpgradeNeededProvider = FutureProvider<bool>((ref) {
  return ref.watch(cacheSystemUpgradeServiceProvider).needsReset();
});
