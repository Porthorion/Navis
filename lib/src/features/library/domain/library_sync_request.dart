/// Computes the foreground and worker freshness window for a sync interval.
Duration syncStaleAfterForInterval(int minutes) {
  if (minutes <= 0) return const Duration(hours: 24);
  // Leave tolerance for timer rounding at the configured interval boundary.
  final toleranceSeconds = (minutes * 60 * 0.05).round().clamp(10, 120);
  return Duration(seconds: minutes * 60 - toleranceSeconds);
}

/// Request origins are persisted by index: only append values.
/// Unused origins remain readable in historical diagnostics rows.
enum SyncRunOrigin {
  libraryPullToRefresh,
  settingsRepair,
  cacheReset,
  homeRefresh,
  desktopCommand,
  startup,
  timer,
  resume,
  reconnect,
  interaction,
  androidWorker,
  migration,
  invariant,
  // Retained because historical run rows persist this enum index.
  legacyRecovery,
}

/// Intent values are persisted by index: only append values.
enum SyncRunIntent {
  automaticCatalogCheck,
  manualCatalogCheck,
  repairLibrary,
  targetHydration,
  auxiliaryRefresh,
}

/// A user grant for metered network work. Unmetered access is a network
/// condition, not a grant, so it is deliberately not represented here.
enum SyncNetworkGrant { none, boundedMeteredDiscovery, broadMeteredOnce }

/// Persisted by index in `library_sync_run_request.target_kind`: only append
/// new values. Schema 87 purged rows of the retired index 6.
enum LibrarySyncTargetKind {
  catalog,
  artist,
  album,
  playlist,
  playlistHeaders,
  starred;

  bool get requiresEntityId => switch (this) {
    artist || album || playlist => true,
    _ => false,
  };
}

class LibrarySyncTarget {
  const new(this.kind, {this.entityId});

  const new catalog() : kind = LibrarySyncTargetKind.catalog, entityId = null;

  const new artist(String id)
    : kind = LibrarySyncTargetKind.artist,
      entityId = id;

  const new album(String id)
    : kind = LibrarySyncTargetKind.album,
      entityId = id;

  const new playlist(String id)
    : kind = LibrarySyncTargetKind.playlist,
      entityId = id;

  const new playlistHeaders()
    : kind = LibrarySyncTargetKind.playlistHeaders,
      entityId = null;

  const new starred() : kind = LibrarySyncTargetKind.starred, entityId = null;

  final LibrarySyncTargetKind kind;
  final String? entityId;
}

/// Stable durable-work key for a targeted sync request.
///
/// Subsonic identifiers are only unique within an entity type. Prefixing the
/// ID prevents an artist, album, and playlist with the same server ID from
/// overwriting each other's queued hydration work.
String librarySyncTargetWorkKey(LibrarySyncTarget target) {
  final entityId = target.entityId?.trim();
  if (entityId != null && entityId.isNotEmpty) {
    return '${target.kind.name}:$entityId';
  }
  return target.kind == LibrarySyncTargetKind.catalog
      ? ''
      : '@${target.kind.name}';
}

/// Extracts an entity ID from either a namespaced key or a legacy raw ID.
String librarySyncTargetEntityIdFromWorkKey(
  LibrarySyncTargetKind kind,
  String workKey,
) {
  final prefix = '${kind.name}:';
  return workKey.startsWith(prefix)
      ? workKey.substring(prefix.length)
      : workKey;
}

/// Immutable caller policy shared by planning, admission and execution.
class LibrarySyncRequest {
  const new({
    required this.origin,
    required this.intent,
    this.target = const LibrarySyncTarget.catalog(),
    this.grant = SyncNetworkGrant.none,
  });

  const new automatic({SyncRunOrigin origin = SyncRunOrigin.timer})
    : this(origin: origin, intent: SyncRunIntent.automaticCatalogCheck);

  const new checkForUpdates({
    SyncNetworkGrant grant = SyncNetworkGrant.boundedMeteredDiscovery,
  }) : this(
         origin: SyncRunOrigin.libraryPullToRefresh,
         intent: SyncRunIntent.manualCatalogCheck,
         grant: grant,
       );

  const new cacheReset({SyncNetworkGrant grant = SyncNetworkGrant.none})
    : this(
        origin: SyncRunOrigin.cacheReset,
        intent: SyncRunIntent.repairLibrary,
        grant: grant,
      );

  static const int currentContractVersion = 1;

  final SyncRunOrigin origin;
  final SyncRunIntent intent;
  final LibrarySyncTarget target;

  /// Ephemeral network consent from the current caller, never durable work.
  final SyncNetworkGrant grant;

  bool get isAutomatic => intent == SyncRunIntent.automaticCatalogCheck;
  bool get isInteraction => origin == SyncRunOrigin.interaction;

  bool get canProbeCircuitEarly => switch (origin) {
    SyncRunOrigin.libraryPullToRefresh ||
    SyncRunOrigin.settingsRepair ||
    SyncRunOrigin.cacheReset ||
    SyncRunOrigin.homeRefresh ||
    SyncRunOrigin.desktopCommand ||
    SyncRunOrigin.interaction ||
    SyncRunOrigin.reconnect ||
    SyncRunOrigin.resume => true,
    _ => false,
  };

  int get priority => isInteraction
      ? 100
      : switch (intent) {
          SyncRunIntent.repairLibrary => 80,
          SyncRunIntent.automaticCatalogCheck => 20,
          _ => 60,
        };

  /// Diagnostics classify the target independently of its automatic policy.
  SyncRunIntent get runHistoryIntent => switch (target.kind) {
    LibrarySyncTargetKind.catalog => intent,
    LibrarySyncTargetKind.starred ||
    LibrarySyncTargetKind.playlistHeaders => SyncRunIntent.auxiliaryRefresh,
    _ => SyncRunIntent.targetHydration,
  };

  /// Automatic checks and explicit discovery never join by catalog alone.
  /// Repair Library and cache reset retain separate recovery identities.
  String get coalescingKey {
    final recoveryOrigin = switch (origin) {
      SyncRunOrigin.settingsRepair || SyncRunOrigin.cacheReset => origin.name,
      _ => '',
    };
    return [
      runHistoryIntent.name,
      target.kind.name,
      target.entityId ?? '',
      grant.name,
      recoveryOrigin,
    ].join(':');
  }
}

/// Names are persisted in durable work and state; retain them when refactoring.
/// Historical run-row indices are mapped only at the DAO boundary.
enum LibrarySyncPlanKind {
  probe,
  targetedHydration,
  deltaReconcile,
  catalogSnapshot,
  compatibilityAudit,
  fullRepair,
}

class LibrarySyncPlan {
  const new({
    required this.kind,
    required this.reason,
    this.shouldExecute = true,
    this.deferred = false,
  });

  final LibrarySyncPlanKind kind;
  final String reason;
  final bool shouldExecute;
  final bool deferred;
}
