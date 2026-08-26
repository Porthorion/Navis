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

enum LibrarySyncTargetKind {
  catalog,
  artist,
  album,
  playlist,
  playlistHeaders,
  starred,
  genres,
}

class LibrarySyncTarget {
  const LibrarySyncTarget(this.kind, {this.entityId});

  const LibrarySyncTarget.catalog()
    : kind = LibrarySyncTargetKind.catalog,
      entityId = null;

  const LibrarySyncTarget.artist(String id)
    : kind = LibrarySyncTargetKind.artist,
      entityId = id;

  const LibrarySyncTarget.album(String id)
    : kind = LibrarySyncTargetKind.album,
      entityId = id;

  const LibrarySyncTarget.playlist(String id)
    : kind = LibrarySyncTargetKind.playlist,
      entityId = id;

  const LibrarySyncTarget.playlistHeaders()
    : kind = LibrarySyncTargetKind.playlistHeaders,
      entityId = null;

  const LibrarySyncTarget.starred()
    : kind = LibrarySyncTargetKind.starred,
      entityId = null;

  const LibrarySyncTarget.genres()
    : kind = LibrarySyncTargetKind.genres,
      entityId = null;

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
  const LibrarySyncRequest({
    required this.trigger,
    required this.intent,
    this.target = const LibrarySyncTarget.catalog(),
    this.allowMeteredBroadOverride = false,
    this.allowMeteredLimitedDiscovery = false,
    this.caller = LibrarySyncRequestCaller.unspecified,
  });

  const LibrarySyncRequest.automatic({
    LibrarySyncTrigger trigger = LibrarySyncTrigger.interval,
  }) : this(trigger: trigger, intent: LibrarySyncIntent.automatic);

  const LibrarySyncRequest.checkForUpdates({
    bool allowMeteredBroadOverride = false,
    bool allowMeteredLimitedDiscovery = true,
  }) : this(
         trigger: LibrarySyncTrigger.user,
         intent: LibrarySyncIntent.checkForUpdates,
         allowMeteredBroadOverride: allowMeteredBroadOverride,
         allowMeteredLimitedDiscovery: allowMeteredLimitedDiscovery,
         caller: LibrarySyncRequestCaller.manualCatalogCheck,
       );

  const LibrarySyncRequest.repair({
    bool allowMeteredBroadOverride = false,
  }) : this(
         trigger: LibrarySyncTrigger.user,
         intent: LibrarySyncIntent.repair,
         allowMeteredBroadOverride: allowMeteredBroadOverride,
         caller: LibrarySyncRequestCaller.repairLibrary,
       );

  const LibrarySyncRequest.cacheReset({
    bool allowMeteredBroadOverride = false,
  }) : this(
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
  const LibrarySyncPlan({
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
