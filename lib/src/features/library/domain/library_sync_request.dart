/// Computes the foreground and worker freshness window for a sync interval.
Duration syncStaleAfterForInterval(int minutes) {
  if (minutes <= 0) return const Duration(hours: 24);
  // Leave tolerance for timer rounding at the configured interval boundary.
  final toleranceSeconds = (minutes * 60 * 0.05).round().clamp(10, 120);
  return Duration(seconds: minutes * 60 - toleranceSeconds);
}

enum LibrarySyncTrigger {
  startup,
  interval,
  resume,
  reconnect,
  user,
  interaction,
  migration,
  invariant,
}

enum LibrarySyncIntent { automatic, checkForUpdates, repair }

/// The user-facing owner of a legacy request during the compatibility window.
///
/// This is intentionally separate from [LibrarySyncIntent]: both a library
/// repair and a destructive device-cache reset eventually run a catalog
/// rebuild, but their confirmation, progress, and durable history must remain
/// distinguishable.
enum LibrarySyncRequestCaller {
  unspecified,
  manualCatalogCheck,
  repairLibrary,
  cacheReset,
}

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

class LibrarySyncRequest {
  const new({
    required this.trigger,
    required this.intent,
    this.target = const LibrarySyncTarget.catalog(),
    this.allowMeteredBroadOverride = false,
    this.allowMeteredLimitedDiscovery = false,
    this.caller = LibrarySyncRequestCaller.unspecified,
  });

  const new automatic({
    LibrarySyncTrigger trigger = LibrarySyncTrigger.interval,
  }) : this(trigger: trigger, intent: LibrarySyncIntent.automatic);

  const new checkForUpdates({
    bool allowMeteredBroadOverride = false,
    bool allowMeteredLimitedDiscovery = true,
  }) : this(
         trigger: LibrarySyncTrigger.user,
         intent: LibrarySyncIntent.checkForUpdates,
         allowMeteredBroadOverride: allowMeteredBroadOverride,
         allowMeteredLimitedDiscovery: allowMeteredLimitedDiscovery,
         caller: LibrarySyncRequestCaller.manualCatalogCheck,
       );

  const new repair({bool allowMeteredBroadOverride = false})
    : this(
        trigger: LibrarySyncTrigger.user,
        intent: LibrarySyncIntent.repair,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
        caller: LibrarySyncRequestCaller.repairLibrary,
      );

  const new cacheReset({bool allowMeteredBroadOverride = false})
    : this(
        trigger: LibrarySyncTrigger.user,
        intent: LibrarySyncIntent.repair,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
        caller: LibrarySyncRequestCaller.cacheReset,
      );

  final LibrarySyncTrigger trigger;
  final LibrarySyncIntent intent;
  final LibrarySyncTarget target;

  /// Ephemeral one-time override for broad catalog work on a metered network.
  /// Never persisted into durable work rows.
  final bool allowMeteredBroadOverride;

  /// Allows the foreground "Check for updates" action to inspect one bounded
  /// newest-album page on a metered network. This never permits artist-wide
  /// verification, bulk-song indexing, or a catalog repair.
  final bool allowMeteredLimitedDiscovery;

  /// Preserved only while adapting legacy callers to the typed sync request.
  final LibrarySyncRequestCaller caller;

  /// Returns the same request with the broad metered override applied.
  ///
  /// Used by the coordinator to decorate an admission with an in-session
  /// repair consent; the grant itself stays in controller memory.
  LibrarySyncRequest copyWithMeteredBroadOverride() {
    return LibrarySyncRequest(
      trigger: trigger,
      intent: intent,
      target: target,
      allowMeteredBroadOverride: true,
      allowMeteredLimitedDiscovery: allowMeteredLimitedDiscovery,
      caller: caller,
    );
  }
}

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
