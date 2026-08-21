import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';

/// Requires existing profiles to clear data from the retired library cache
/// before using the current rolling-cache contract.
class CacheSystemUpgradeService {
  CacheSystemUpgradeService({
    required this.database,
    required this.cacheResetService,
    required this.triggerFullLibraryScan,
  });

  /// Increment when a cache layout cannot safely share state with the prior
  /// implementation. Fresh installs receive this value during DB creation.
  static const int currentVersion = 2;

  final NavisDatabase database;
  final LibraryCacheResetService cacheResetService;
  final Future<bool> Function() triggerFullLibraryScan;

  Future<bool> needsReset() async {
    return (await database.cacheSystemStateDao.getVersion() ?? 0) <
        currentVersion;
  }

  /// Clears recoverable cache and library state, preserving permanent
  /// downloads, then completes a full server scan before acknowledging the
  /// one-time upgrade. A failed scan intentionally leaves the upgrade pending
  /// so a profile is never left with an empty library without a retry path.
  Future<void> resetAndMarkCurrent() async {
    await cacheResetService.reset();
    if (!await triggerFullLibraryScan()) {
      throw StateError('The library scan did not complete after cache reset.');
    }
    await database.cacheSystemStateDao.markVersion(currentVersion);
  }
}
