import 'package:navis/src/routing/app_routes.dart';

enum RequiredLibraryRebuildReason {
  initialLogin,
  manualCacheReset,
  cacheUpgrade,
  playbackRecovery;

  String get routeValue => switch (this) {
    RequiredLibraryRebuildReason.initialLogin => 'initial-login',
    RequiredLibraryRebuildReason.manualCacheReset => 'manual-cache-reset',
    RequiredLibraryRebuildReason.cacheUpgrade => 'cache-upgrade',
    RequiredLibraryRebuildReason.playbackRecovery => 'playback-recovery',
  };

  static RequiredLibraryRebuildReason? parse(String? value) => switch (value) {
    'initial-login' => RequiredLibraryRebuildReason.initialLogin,
    'manual-cache-reset' => RequiredLibraryRebuildReason.manualCacheReset,
    'cache-upgrade' => RequiredLibraryRebuildReason.cacheUpgrade,
    'playback-recovery' => RequiredLibraryRebuildReason.playbackRecovery,
    _ => null,
  };
}

String requiredLibraryRebuildRoute(
  RequiredLibraryRebuildReason reason, {
  bool allowMeteredBroadOverride = false,
  bool homeWarmupEligible = false,
}) {
  return '${AppRoutes.libraryRebuild}?reason=${reason.routeValue}'
      '${allowMeteredBroadOverride ? '&metered=1' : ''}'
      '${homeWarmupEligible ? '&homeWarmupEligible=1' : ''}';
}
