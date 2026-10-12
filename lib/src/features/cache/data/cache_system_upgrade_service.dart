import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';

/// Renews committed libraries when the app major/minor cache epoch changes.
class CacheSystemUpgradeService {
  new({
    required this.database,
    required this.cacheResetService,
    required this.triggerFullLibraryScan,
    required this.currentEpoch,
    required this.hasCommittedCatalog,
  });

  static int epochFromVersion(String version) {
    final parts = version.split('+').first.split('.');
    if (parts.length != 3) throw FormatException('Invalid app version');
    final major = int.parse(parts[0]);
    final minor = int.parse(parts[1]);
    if (major < 0 || minor < 0 || minor >= 1000) {
      throw FormatException('Invalid app version');
    }
    return major * 1000 + minor;
  }

  final NavisDatabase database;
  final LibraryCacheResetService cacheResetService;
  final Future<bool> Function() triggerFullLibraryScan;

  final Future<int?> Function() currentEpoch;
  final Future<bool> Function() hasCommittedCatalog;

  Future<bool> needsReset() async {
    final epoch = await currentEpoch();
    if (epoch == null) return false;
    final stored = await database.cacheSystemStateDao.getVersion();
    if (stored == epoch) return false;
    if (!await hasCommittedCatalog()) {
      await database.cacheSystemStateDao.markVersion(epoch);
      return false;
    }
    return true;
  }

  Future<LibraryCacheQueueSnapshot?> resetRecoverableCache() =>
      cacheResetService.reset();

  Future<void> markCurrentVersionAfterSuccessfulScan() async {
    final epoch = await currentEpoch();
    if (epoch != null) await database.cacheSystemStateDao.markVersion(epoch);
  }

  /// Clears recoverable cache and library state, preserving permanent
  /// downloads, then completes a full server scan before acknowledging the
  /// one-time upgrade. A failed scan intentionally leaves the upgrade pending
  /// so a profile is never left with an empty library without a retry path.
  Future<void> resetAndMarkCurrent() async {
    final queueSnapshot = await resetRecoverableCache();
    if (!await triggerFullLibraryScan()) {
      throw StateError('The library scan did not complete after cache reset.');
    }
    await queueSnapshot?.restore();
    await markCurrentVersionAfterSuccessfulScan();
  }
}
