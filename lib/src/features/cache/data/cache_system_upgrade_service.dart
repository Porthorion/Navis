import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';

/// Requires existing profiles to clear data from the retired library cache
/// before using the current rolling-cache contract.
class CacheSystemUpgradeService {
  CacheSystemUpgradeService({
    required this.database,
    required this.cacheResetService,
  });

  /// Increment when a cache layout cannot safely share state with the prior
  /// implementation. Fresh installs receive this value during DB creation.
  static const int currentVersion = 2;

  final NavisDatabase database;
  final LibraryCacheResetService cacheResetService;

  Future<bool> needsReset() async {
    return (await database.cacheSystemStateDao.getVersion() ?? 0) <
        currentVersion;
  }

  /// Clears recoverable cache and library state, preserving permanent
  /// downloads, then records the completed one-time upgrade.
  Future<void> resetAndMarkCurrent() async {
    await cacheResetService.reset();
    await database.cacheSystemStateDao.markVersion(currentVersion);
  }
}
