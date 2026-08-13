import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/library_sync_planner.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';

class AdaptiveLibrarySyncCoordinator implements LibrarySyncEngine {
  AdaptiveLibrarySyncCoordinator({
    required LibrarySyncEngine executor,
    required NavisDatabase database,
    required ServerConfigRepository serverConfigRepository,
    NetworkType? networkType,
    SyncNetworkPolicy Function()? readSyncNetworkPolicy,
    required this.staleAfter,
    required bool Function() readHasActivePlayback,
    bool Function()? readIsForeground,
    DateTime Function()? now,
    LibrarySyncPlanner planner = const LibrarySyncPlanner(),
    String executionOwnerKind = 'foreground',
    bool isBackgroundExecution = false,
  }) : _executor = executor,
       _database = database,
       _serverConfigRepository = serverConfigRepository,
       _legacyNetworkType = networkType,
       _readSyncNetworkPolicy = readSyncNetworkPolicy,
       _readHasActivePlayback = readHasActivePlayback,
       _readIsForeground = readIsForeground ?? _alwaysForeground,
       _now = now ?? DateTime.now,
       _planner = planner,
       _executionOwnerKind = _validateOwnerKind(executionOwnerKind),
       _isBackgroundExecution = isBackgroundExecution;

  static bool _alwaysForeground() => true;

  static String _validateOwnerKind(String value) {
    return switch (value) {
      'foreground' || 'androidWorker' => value,
      _ => throw ArgumentError.value(
        value,
        'executionOwnerKind',
        'must be foreground or androidWorker',
      ),
    };
  }

  final LibrarySyncEngine _executor;
  DriftLibrarySyncEngine? get driftExecutor => switch (_executor) {
    final DriftLibrarySyncEngine drift => drift,
    _ => null,
  };
  final NavisDatabase _database;
  final ServerConfigRepository _serverConfigRepository;
  final NetworkType? _legacyNetworkType;
  final SyncNetworkPolicy Function()? _readSyncNetworkPolicy;
  final Duration staleAfter;
  final bool Function() _readHasActivePlayback;
  final bool Function() _readIsForeground;
  final DateTime Function() _now;
  final LibrarySyncPlanner _planner;
  final String _executionOwnerKind;
  final bool _isBackgroundExecution;
  final Set<int> _recoveredServers = <int>{};
  Future<LibrarySyncState>? _inFlight;

  static const Duration _executionLeaseTtl = Duration(minutes: 10);
  static const Duration _executionLeaseHeartbeatInterval = Duration(minutes: 1);

  String _newLeaseToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  SyncNetworkPolicy get _syncPolicy {
    final reader = _readSyncNetworkPolicy;
    if (reader != null) {
      return reader();
    }
    final type = _legacyNetworkType ?? NetworkType.other;
    return resolveSyncNetworkPolicy(
      networkType: type,
      nativeMetered: type == NetworkType.cellular ? true : false,
      backgroundSyncUnmeteredOnly: true,
    );
  }

  NetworkType get networkType => _syncPolicy.networkType;

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final config = await _serverConfigRepository.getActiveServer();
    final serverId = config?.id;
    if (config == null || serverId == null) {
      return _executor.requestSync(
        request,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    }

    final recoveringServer = _recoveredServers.add(serverId);
    if (recoveringServer) {
      await _database.librarySyncDao.resetInterruptedWork(serverId);
    }
    var persisted = await _database.librarySyncDao.getOrCreateState(serverId);
    if (recoveringServer && persisted.currentGeneration > 0) {
      await _database.librarySyncCandidateDao.clearThroughGeneration(
        serverId: serverId,
        generation: persisted.currentGeneration,
      );
    }
    final providerFingerprint = '${config.url}|${config.apiVersion}';
    if (persisted.providerFingerprint != providerFingerprint) {
      final backendChanged = persisted.providerFingerprint != null;
      if (backendChanged) {
        await _database.librarySyncCandidateDao.clearAll();
        await _database.librarySyncDao.clearWorkForServer(serverId);
      }
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          providerFingerprint: Value(providerFingerprint),
          conditionalIndexesMode: backendChanged
              ? const Value('unknown')
              : Value(persisted.conditionalIndexesMode),
          bulkSearchMode: backendChanged
              ? const Value('unknown')
              : Value(persisted.bulkSearchMode),
          bulkSearchQuery: backendChanged
              ? const Value(null)
              : Value(persisted.bulkSearchQuery),
          candidateGeneration: backendChanged
              ? const Value(null)
              : Value(persisted.candidateGeneration),
          candidateStatus: backendChanged
              ? const Value(null)
              : Value(persisted.candidateStatus),
          candidateStartedAt: backendChanged
              ? const Value(null)
              : Value(persisted.candidateStartedAt),
        ),
      );
      persisted = await _database.librarySyncDao.getOrCreateState(serverId);
    }
    final canProbeCircuitEarly = switch (request.trigger) {
      LibrarySyncTrigger.user ||
      LibrarySyncTrigger.interaction ||
      LibrarySyncTrigger.reconnect ||
      LibrarySyncTrigger.resume => true,
      _ => false,
    };
    final circuitOpen =
        persisted.failureStreak >= 3 &&
        persisted.nextEligibleAt?.isAfter(_now()) == true;
    if (circuitOpen && !canProbeCircuitEarly) {
      final state = LibrarySyncState(
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        completedAt: _now(),
        lastSyncedAt: config.lastSynced,
        freshness: LibrarySyncFreshness.verificationPending,
        planKind: LibrarySyncPlanKind.probe,
        planReason: 'endpointCircuitOpen',
        pendingWorkCount: await _database.librarySyncDao.countPendingWork(
          serverId,
        ),
        failureCategory: 'transport',
        nextRetryAt: persisted.nextEligibleAt,
      );
      onProgress?.call(state);
      return state;
    }
    final localPendingHydration = await _database.libraryDao
        .countPendingHydrationAlbums();
    final pendingWork = await _database.librarySyncDao.countPendingWork(
      serverId,
    );
    final timestamp = _now();
    final lastChecked = persisted.lastCheckedAt ?? config.lastSynced;
    final isDue =
        lastChecked == null || timestamp.difference(lastChecked) >= staleAfter;
    final auxiliaryDue =
        persisted.lastAuxiliarySyncedAt == null ||
        timestamp.difference(persisted.lastAuxiliarySyncedAt!) >=
            const Duration(hours: 12);
    final auditInterval = persisted.conditionalIndexesMode == 'unsupported'
        ? const Duration(days: 1)
        : const Duration(days: 7);
    final auditDue =
        persisted.lastAuditAt == null ||
        timestamp.difference(persisted.lastAuditAt!) >= auditInterval;
    final policy = _syncPolicy;
    final runnableBeforePlanning = await _database.librarySyncDao
        .getRunnableWork(serverId: serverId, now: timestamp, limit: 8);
    final resumedWork =
        request.target.kind == LibrarySyncTargetKind.catalog &&
            request.intent != LibrarySyncIntent.repair
        ? _firstAllowedWork(runnableBeforePlanning, policy, request)
        : null;
    final resumedPlan = resumedWork == null
        ? null
        : _planFromWork(resumedWork, policy, request);
    final plan =
        resumedPlan ??
        _planner.plan(
          LibrarySyncPlannerContext(
            request: request,
            networkType: policy.networkType,
            restrictsBackgroundSync:
                !policy.allowsBackgroundSync &&
                !request.allowMeteredBroadOverride,
            hasAuthoritativeBaseline:
                persisted.currentGeneration > 0 || config.lastSynced != null,
            isCatalogCheckDue: isDue,
            pendingHydrationCount: localPendingHydration,
            pendingWorkCount: pendingWork,
            indexesMode: _capabilityMode(persisted.conditionalIndexesMode),
            indexChanged: null,
            changeIsExplainable: false,
            auxiliaryDue: auxiliaryDue,
            auditDue: auditDue,
            repairRequired:
                request.trigger == LibrarySyncTrigger.migration ||
                request.trigger == LibrarySyncTrigger.invariant,
            isForeground: _readIsForeground(),
            hasActivePlayback: _readHasActivePlayback(),
            isBackgroundExecutor: _isBackgroundExecution,
          ),
        );

    final effectiveTarget = resumedWork == null
        ? request.target
        : _targetFromWork(resumedWork);
    final effectiveRequest = resumedWork == null
        ? request
        : LibrarySyncRequest(
            trigger: request.trigger,
            intent: request.intent,
            target: effectiveTarget,
            allowMeteredBroadOverride: request.allowMeteredBroadOverride,
            allowMeteredLimitedDiscovery: request.allowMeteredLimitedDiscovery,
          );
    final targetId = effectiveTarget.entityId?.trim() ?? '';
    final targetWorkKey = librarySyncTargetWorkKey(effectiveTarget);
    final workClass = _workClassFor(request, plan);
    if (resumedWork == null && (plan.shouldExecute || plan.deferred)) {
      await _database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
        priority: _priorityFor(request),
        workClass: workClass,
        checkpointJson: request.target.kind == LibrarySyncTargetKind.catalog
            ? null
            : jsonEncode(<String, String>{
                'targetKind': request.target.kind.name,
              }),
        releaseCooldown: canProbeCircuitEarly,
        reactivateTerminal: request.intent != LibrarySyncIntent.automatic,
        now: timestamp,
      );
    }
    await _writePlanState(
      serverId: serverId,
      persisted: persisted,
      plan: plan,
    );

    if (!plan.shouldExecute) {
      final state = LibrarySyncState(
        status: plan.deferred
            ? LibrarySyncStatus.deferred
            : LibrarySyncStatus.skipped,
        stage: LibrarySyncStage.completed,
        mode: _legacyMode(plan.kind),
        completedAt: timestamp,
        lastSyncedAt: config.lastSynced,
        lastCheckedAt: persisted.lastCheckedAt,
        lastCatalogUpdatedAt: persisted.lastCatalogSyncedAt,
        lastAuxiliarySyncedAt: persisted.lastAuxiliarySyncedAt,
        lastGenresSyncedAt: persisted.lastGenresSyncedAt,
        freshness: _freshnessForDeferred(plan),
        planKind: plan.kind,
        planReason: plan.reason,
        pendingHydrationCount: localPendingHydration,
        pendingWorkCount: await _database.librarySyncDao.countPendingWork(
          serverId,
        ),
        updatesAvailable:
            plan.deferred &&
            (plan.kind == LibrarySyncPlanKind.catalogSnapshot ||
                plan.kind == LibrarySyncPlanKind.fullRepair ||
                plan.kind == LibrarySyncPlanKind.deltaReconcile ||
                plan.kind == LibrarySyncPlanKind.compatibilityAudit),
      );
      onProgress?.call(state);
      return state;
    }

    if (!_workAllowed(workClass, policy, request, planKind: plan.kind)) {
      final state = LibrarySyncState(
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        mode: _legacyMode(plan.kind),
        completedAt: timestamp,
        lastSyncedAt: config.lastSynced,
        freshness: _freshnessForDeferred(plan),
        planKind: plan.kind,
        planReason: 'networkPolicyDeferred',
        pendingHydrationCount: localPendingHydration,
        pendingWorkCount: await _database.librarySyncDao.countPendingWork(
          serverId,
        ),
        updatesAvailable: true,
      );
      onProgress?.call(state);
      return state;
    }

    final running = _inFlight;
    if (running != null) {
      await running;
      return requestSync(
        request,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    }
    final future = _executePlanned(
      serverId: serverId,
      request: effectiveRequest,
      plan: plan,
      targetId: targetId,
      targetWorkKey: targetWorkKey,
      workClass: workClass,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<LibrarySyncState> _executePlanned({
    required int serverId,
    required LibrarySyncRequest request,
    required LibrarySyncPlan plan,
    required String targetId,
    required String targetWorkKey,
    required String workClass,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final startedAt = _now();
    final livePolicy = _syncPolicy;
    if (!_workAllowed(
      workClass,
      livePolicy,
      request,
      planKind: plan.kind,
    )) {
      return LibrarySyncState(
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        completedAt: startedAt,
        planKind: plan.kind,
        planReason: 'networkPolicyDeferred',
        updatesAvailable: true,
      );
    }

    final needsLease = request.target.kind == LibrarySyncTargetKind.catalog;
    final ownerToken = needsLease ? _newLeaseToken() : null;
    Timer? leaseHeartbeat;
    if (needsLease) {
      final acquired = await _database.librarySyncDao.acquireExecutionLease(
        serverId: serverId,
        ownerToken: ownerToken!,
        ownerKind: _executionOwnerKind,
        now: startedAt,
        ttl: _executionLeaseTtl,
      );
      if (!acquired) {
        return LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planKind: plan.kind,
          planReason: 'leaseHeld',
          pendingWorkCount: await _database.librarySyncDao.countPendingWork(
            serverId,
          ),
        );
      }
      leaseHeartbeat = Timer.periodic(_executionLeaseHeartbeatInterval, (_) {
        unawaited(
          _database.librarySyncDao
              .heartbeatExecutionLease(
                serverId: serverId,
                ownerToken: ownerToken,
                now: _now(),
                ttl: _executionLeaseTtl,
              )
              .catchError((Object _) => false),
        );
      });
    }

    try {
      final runnable = await _database.librarySyncDao.getRunnableWork(
        serverId: serverId,
        now: startedAt,
      );
      final work = runnable.where(
        (row) => row.kind == plan.kind.name && row.entityId == targetWorkKey,
      );
      final activeWork = work.isEmpty ? null : work.first;
      if (activeWork != null) {
        await _database.librarySyncDao.markRunning(
          activeWork.id,
          now: startedAt,
        );
      }

      final driftExecutor = switch (_executor) {
        final DriftLibrarySyncEngine engine => engine,
        _ => null,
      };
      final previousOverride = driftExecutor?.allowMeteredBackgroundOverride;
      final previousLimitedDiscovery =
          driftExecutor?.allowMeteredManualDiscovery;
      if (driftExecutor != null) {
        driftExecutor.allowMeteredBackgroundOverride =
            request.allowMeteredBroadOverride;
        driftExecutor.allowMeteredManualDiscovery =
            request.allowMeteredLimitedDiscovery && _syncPolicy.isMetered;
      }

      LibrarySyncState result;
      try {
        result = await _executeDelegate(
          request: request,
          plan: plan,
          targetId: targetId,
          priorityAlbumIds: priorityAlbumIds,
          onProgress: (progress) {
            onProgress?.call(
              progress.copyWith(planKind: plan.kind, planReason: plan.reason),
            );
          },
        );
      } on Object catch (error) {
        if (activeWork != null && !(await _workIsCompleted(activeWork))) {
          await _markWorkFailure(activeWork, error.runtimeType.toString());
        }
        rethrow;
      } finally {
        if (driftExecutor != null) {
          driftExecutor.allowMeteredBackgroundOverride =
              previousOverride ?? false;
          driftExecutor.allowMeteredManualDiscovery =
              previousLimitedDiscovery ?? false;
        }
      }

      if (plan.kind == LibrarySyncPlanKind.probe &&
          result.status == LibrarySyncStatus.succeeded) {
        await _enqueueProbeFollowUp(
          serverId: serverId,
          result: result,
          now: startedAt,
        );
      }

      final usage = await _database.networkUsageDao.getCategoryTotalSince(
        category: 'library_sync',
        since: startedAt,
      );
      final cancelled =
          result.errorMessage == 'Sync cancelled.' ||
          result.errorMessage?.startsWith('Sync cancelled') == true;
      final deferred = result.status == LibrarySyncStatus.deferred;
      final hasPending =
          (result.pendingHydrationCount ?? 0) > 0 ||
          result.remainingVerificationCount > 0;
      final status = cancelled
          ? LibrarySyncStatus.cancelled
          : deferred
          ? LibrarySyncStatus.deferred
          : result.status == LibrarySyncStatus.succeeded && hasPending
          ? LibrarySyncStatus.partial
          : result.status;
      final failed =
          status == LibrarySyncStatus.failed ||
          (status == LibrarySyncStatus.skipped && result.errorMessage != null);

      if (activeWork != null && !(await _workIsCompleted(activeWork))) {
        if (cancelled) {
          await _database.librarySyncDao.markCancelled(activeWork.id);
        } else if (deferred) {
          // Preserve checkpoints; return the row to the queue for later.
          await _database.librarySyncDao.requeue(activeWork.id, now: _now());
        } else if (failed) {
          await _markWorkFailure(activeWork, 'sync');
        } else if (status == LibrarySyncStatus.partial &&
            !_didCommitCatalogCandidate(plan, result)) {
          if (result.candidateStatus == 'awaitingDeletionConfirmation') {
            await _database.librarySyncDao.markAwaitingConfirmation(
              activeWork.id,
              now: _now(),
            );
          } else {
            await _database.librarySyncDao.markCancelled(activeWork.id);
          }
        } else {
          await _database.librarySyncDao.markCompleted(activeWork.id);
        }
      }
      final pendingCount = await _database.librarySyncDao.countPendingWork(
        serverId,
      );
      try {
        await _refreshProviderProfile(serverId, result);
      } on Object {
        // The compatibility profile is advisory. A malformed legacy capability
        // value must never turn a successfully committed catalog pass into a
        // failed run.
      }
      final persisted = await _database.librarySyncDao.getOrCreateState(
        serverId,
      );
      final completedAt = result.completedAt ?? _now();
      final catalogUpdated =
          status == LibrarySyncStatus.succeeded &&
          !hasPending &&
          (plan.kind == LibrarySyncPlanKind.deltaReconcile ||
              plan.kind == LibrarySyncPlanKind.catalogSnapshot ||
              plan.kind == LibrarySyncPlanKind.fullRepair);
      final catalogChecked =
          request.target.kind == LibrarySyncTargetKind.catalog &&
          (plan.kind == LibrarySyncPlanKind.probe ||
              plan.kind == LibrarySyncPlanKind.deltaReconcile ||
              plan.kind == LibrarySyncPlanKind.catalogSnapshot ||
              plan.kind == LibrarySyncPlanKind.fullRepair ||
              plan.kind == LibrarySyncPlanKind.compatibilityAudit);
      final circuitRelevant =
          request.target.kind == LibrarySyncTargetKind.catalog && !deferred;
      final auxiliaryUpdated =
          result.status == LibrarySyncStatus.succeeded &&
          result.starredSynchronized &&
          result.playlistHeadersSynchronized;
      final genresUpdated =
          result.status == LibrarySyncStatus.succeeded &&
          result.genresSynchronized;
      final nextRetryAt = circuitRelevant && failed
          ? _cooldownUntil(persisted.failureStreak + 1)
          : circuitRelevant
          ? null
          : persisted.nextEligibleAt;
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          lastCheckedAt: Value(
            catalogChecked ? completedAt : persisted.lastCheckedAt,
          ),
          lastCatalogSyncedAt: Value(
            catalogUpdated ? completedAt : persisted.lastCatalogSyncedAt,
          ),
          lastAuxiliarySyncedAt: Value(
            auxiliaryUpdated ? completedAt : persisted.lastAuxiliarySyncedAt,
          ),
          lastGenresSyncedAt: Value(
            genresUpdated ? completedAt : persisted.lastGenresSyncedAt,
          ),
          failureStreak: Value(
            circuitRelevant
                ? failed
                      ? persisted.failureStreak + 1
                      : 0
                : persisted.failureStreak,
          ),
          nextEligibleAt: Value(nextRetryAt),
          lastPlanKind: Value(plan.kind.name),
          lastPlanReason: Value(plan.reason),
          lastRunBytes: Value(usage.bytes),
          lastRunRequests: Value(usage.requestCount),
        ),
      );
      await _database.librarySyncDao.pruneCompletedBefore(
        completedAt.subtract(const Duration(days: 7)),
      );
      final finalState = result.copyWith(
        status: status,
        planKind: plan.kind,
        planReason: plan.reason,
        pendingWorkCount: pendingCount,
        lastRunBytes: usage.bytes,
        apiRequests: usage.requestCount > 0
            ? usage.requestCount
            : result.apiRequests,
        lastCheckedAt: catalogChecked ? completedAt : persisted.lastCheckedAt,
        lastCatalogUpdatedAt: catalogUpdated
            ? completedAt
            : persisted.lastCatalogSyncedAt,
        lastAuxiliarySyncedAt: auxiliaryUpdated
            ? completedAt
            : persisted.lastAuxiliarySyncedAt,
        lastGenresSyncedAt: genresUpdated
            ? completedAt
            : persisted.lastGenresSyncedAt,
        failureCategory: failed ? 'sync' : null,
        clearFailureCategory: !failed,
        nextRetryAt: nextRetryAt,
        clearNextRetryAt: nextRetryAt == null,
        candidateGeneration:
            result.candidateGeneration ?? persisted.candidateGeneration,
        candidateStatus: result.candidateStatus ?? persisted.candidateStatus,
        deletionCandidateCount: persisted.deletionCandidateCount,
        carriedForwardEntityCount: result.carriedForwardEntityCount > 0
            ? result.carriedForwardEntityCount
            : persisted.candidateCarriedForwardCount,
        lastApplyDurationMs: persisted.lastApplyDurationMs,
        updatesAvailable:
            result.updatesAvailable ||
            deferred ||
            (result.probeIndexChanged == true) ||
            result.probeIndexesUnsupported,
      );
      onProgress?.call(finalState);
      return finalState;
    } finally {
      leaseHeartbeat?.cancel();
      if (ownerToken != null) {
        await _database.librarySyncDao.releaseExecutionLease(
          serverId: serverId,
          ownerToken: ownerToken,
        );
      }
    }
  }

  Future<void> _enqueueProbeFollowUp({
    required int serverId,
    required LibrarySyncState result,
    required DateTime now,
  }) async {
    if (result.probeIndexesUnsupported) {
      await _database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.compatibilityAudit.name,
        entityId: '',
        priority: 40,
        workClass: 'background',
        releaseCooldown: true,
        now: now,
      );
      return;
    }
    if (result.probeIndexChanged == true) {
      await _database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.deltaReconcile.name,
        entityId: '',
        priority: 50,
        workClass: 'background',
        releaseCooldown: true,
        now: now,
      );
    }
  }

  Future<LibrarySyncState> _executeDelegate({
    required LibrarySyncRequest request,
    required LibrarySyncPlan plan,
    required String targetId,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) {
    final priorities = <String>{
      ...priorityAlbumIds,
      if (request.target.kind == LibrarySyncTargetKind.album &&
          targetId.isNotEmpty)
        targetId,
    };
    final targetedExecutor = switch (_executor) {
      final TargetedLibrarySyncExecutor executor => executor,
      _ => null,
    };
    final driftExecutor = switch (_executor) {
      final DriftLibrarySyncEngine engine => engine,
      _ => null,
    };
    return switch (plan.kind) {
      LibrarySyncPlanKind.fullRepair ||
      LibrarySyncPlanKind.catalogSnapshot => _executor.forceFullSync(
        priorityAlbumIds: priorities,
        onProgress: onProgress,
      ),
      LibrarySyncPlanKind.targetedHydration => switch (request.target.kind) {
        LibrarySyncTargetKind.album
            when targetId.isNotEmpty && targetedExecutor != null =>
          targetedExecutor.hydrateAlbum(targetId, onProgress: onProgress),
        LibrarySyncTargetKind.artist
            when targetId.isNotEmpty && targetedExecutor != null =>
          targetedExecutor.hydrateArtist(targetId, onProgress: onProgress),
        LibrarySyncTargetKind.playlist
            when targetId.isNotEmpty && targetedExecutor != null =>
          targetedExecutor.hydratePlaylist(targetId, onProgress: onProgress),
        LibrarySyncTargetKind.playlistHeaders when targetedExecutor != null =>
          targetedExecutor.syncPlaylistHeaders(onProgress: onProgress),
        LibrarySyncTargetKind.starred when targetedExecutor != null =>
          targetedExecutor.syncStarredContent(onProgress: onProgress),
        LibrarySyncTargetKind.genres when targetedExecutor != null =>
          targetedExecutor.syncGenres(onProgress: onProgress),
        _ => _executor.continueVerification(
          priorityAlbumIds: priorities,
          onProgress: onProgress,
        ),
      },
      LibrarySyncPlanKind.compatibilityAudit when driftExecutor != null =>
        driftExecutor.runCompatibilityAudit(
          priorityAlbumIds: priorities,
          onProgress: onProgress,
        ),
      LibrarySyncPlanKind.deltaReconcile ||
      LibrarySyncPlanKind.compatibilityAudit => _executor.syncNow(
        priorityAlbumIds: priorities,
        onProgress: onProgress,
      ),
      LibrarySyncPlanKind.probe => _executor.probeCatalog(
        onProgress: onProgress,
      ),
    };
  }

  bool _didCommitCatalogCandidate(
    LibrarySyncPlan plan,
    LibrarySyncState result,
  ) {
    final isCatalogPlan =
        plan.kind == LibrarySyncPlanKind.catalogSnapshot ||
        plan.kind == LibrarySyncPlanKind.fullRepair;
    return isCatalogPlan &&
        result.metadataReady &&
        result.candidateGeneration == null &&
        result.candidateStatus == null;
  }

  Future<void> _markWorkFailure(
    LibrarySyncWorkTableData work,
    String errorType,
  ) {
    return _database.librarySyncDao.markFailed(
      work.id,
      errorType: errorType,
      notBefore: _cooldownUntil(work.attemptCount + 1),
    );
  }

  Future<bool> _workIsCompleted(LibrarySyncWorkTableData work) async {
    final current = await _database.librarySyncDao.getWork(
      serverId: work.serverId,
      kind: work.kind,
      entityId: work.entityId,
    );
    return current?.status == 'completed';
  }

  Future<void> _refreshProviderProfile(
    int serverId,
    LibrarySyncState result,
  ) async {
    final config = await _serverConfigRepository.getActiveServer();
    final navis = _readNavisCapabilities(config?.capabilitiesJson);
    final unsupported = navis['libraryIndexesUnsupportedAt'] != null;
    final cursor = _parseDate(navis['libraryIndexesCursor']);
    final bulkQuery = navis['bulkSongSearchWildcardQuery'];
    await _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        conditionalIndexesMode: Value(
          unsupported
              ? 'unsupported'
              : cursor != null
              ? 'reliable'
              : 'unknown',
        ),
        bulkSearchMode: Value(
          bulkQuery is String ? 'supported' : 'unknown',
        ),
        bulkSearchQuery: Value(bulkQuery is String ? bulkQuery : null),
        catalogCursor: Value(cursor),
        catalogFingerprint: Value(
          navis['libraryIndexesFingerprint'] is String
              ? navis['libraryIndexesFingerprint'] as String
              : null,
        ),
        averageLatencyMs: Value(result.averageLatencyMs),
        lastAuxiliarySyncedAt: Value(
          _parseDate(navis['auxiliarySyncLastSyncedAt']),
        ),
        lastGenresSyncedAt: Value(
          _parseDate(navis['genresSyncLastSyncedAt']),
        ),
        detailConcurrency: Value(_preferredDetailConcurrency()),
        // The executor persists stage/endpoint/entity failure diagnostics.
        // Do not erase those safe details when its returned state has no
        // coarse failure category; callers otherwise see only a generic failed
        // sync and the durable retry record cannot explain what happened.
        endpointFailureJson: result.failureCategory != null
            ? Value(
                jsonEncode(<String, Object?>{
                  'category': result.failureCategory,
                  'at': _now().toUtc().toIso8601String(),
                }),
              )
            : result.status == LibrarySyncStatus.succeeded
            ? const Value(null)
            : const Value.absent(),
      ),
    );
  }

  Map<String, Object?> _readNavisCapabilities(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final root = jsonDecode(raw);
      if (root is Map<String, dynamic> &&
          root['navis'] is Map<String, dynamic>) {
        return Map<String, Object?>.from(
          root['navis'] as Map<String, dynamic>,
        );
      }
    } on FormatException {
      return const <String, Object?>{};
    }
    return const <String, Object?>{};
  }

  DateTime? _parseDate(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toLocal();
  }

  int _preferredDetailConcurrency() {
    if (_readHasActivePlayback()) {
      return 2;
    }
    return switch (networkType) {
      NetworkType.wifi => 8,
      NetworkType.other => 4,
      NetworkType.cellular => 1,
      NetworkType.offline => 1,
    };
  }

  DateTime _cooldownUntil(int attempt) {
    final multiplier = 1 << (attempt - 1).clamp(0, 5);
    final minutes = (15 * multiplier).clamp(15, 360);
    return _now().add(Duration(minutes: minutes));
  }

  Future<void> _writePlanState({
    required int serverId,
    required LibrarySyncStateTableData persisted,
    required LibrarySyncPlan plan,
  }) {
    return _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        lastPlanKind: Value(plan.kind.name),
        lastPlanReason: Value(plan.reason),
        // Planning a target operation must not consume a catalog failure
        // cooldown. Only the terminal catalog result may clear or advance it;
        // otherwise startup hydration can erase the user-visible retry time
        // before an eligible catalog retry has actually happened.
        nextEligibleAt: Value(persisted.nextEligibleAt),
      ),
    );
  }

  SyncCapabilityMode _capabilityMode(String value) {
    return switch (value) {
      'reliable' => SyncCapabilityMode.reliable,
      'unsupported' => SyncCapabilityMode.unsupported,
      _ => SyncCapabilityMode.unknown,
    };
  }

  int _priorityFor(LibrarySyncRequest request) {
    if (request.trigger == LibrarySyncTrigger.interaction) {
      return 100;
    }
    return switch (request.intent) {
      LibrarySyncIntent.repair => 80,
      LibrarySyncIntent.checkForUpdates => 60,
      LibrarySyncIntent.automatic => 20,
    };
  }

  String _workClassFor(LibrarySyncRequest request, LibrarySyncPlan plan) {
    final isInteractiveEntity =
        request.trigger == LibrarySyncTrigger.interaction &&
        (request.target.kind == LibrarySyncTargetKind.artist ||
            request.target.kind == LibrarySyncTargetKind.album ||
            request.target.kind == LibrarySyncTargetKind.playlist);
    if (isInteractiveEntity &&
        plan.kind == LibrarySyncPlanKind.targetedHydration) {
      return 'interactive';
    }
    return 'background';
  }

  bool _workAllowed(
    String workClass,
    SyncNetworkPolicy policy,
    LibrarySyncRequest request, {
    LibrarySyncPlanKind? planKind,
  }) {
    if (policy.isOffline) {
      return false;
    }
    if (request.allowMeteredBroadOverride) {
      return true;
    }
    if (planKind == LibrarySyncPlanKind.deltaReconcile &&
        request.allowMeteredLimitedDiscovery &&
        policy.isMetered) {
      return true;
    }
    if (planKind == LibrarySyncPlanKind.probe) {
      return policy.allowsHardProbe;
    }
    if (workClass == 'interactive') {
      return policy.allowsInteractiveHydration;
    }
    return policy.allowsBackgroundSync;
  }

  LibrarySyncWorkTableData? _firstAllowedWork(
    List<LibrarySyncWorkTableData> runnable,
    SyncNetworkPolicy policy,
    LibrarySyncRequest request,
  ) {
    for (final work in runnable) {
      final kind = LibrarySyncPlanKind.values.where(
        (candidate) => candidate.name == work.kind,
      );
      if (kind.isEmpty) {
        continue;
      }
      final planKind = kind.first;
      if (planKind == LibrarySyncPlanKind.fullRepair &&
          request.intent == LibrarySyncIntent.automatic) {
        // Repair is an explicit, potentially expensive and destructive
        // operation. A queued or interrupted user repair stays resumable, but
        // opening the app or reaching the periodic interval must never restart
        // it without a new Repair Library action.
        continue;
      }
      if (planKind == LibrarySyncPlanKind.probe) {
        if (policy.allowsHardProbe) {
          return work;
        }
        continue;
      }
      if (work.workClass == 'interactive') {
        if (policy.allowsInteractiveHydration) {
          return work;
        }
        continue;
      }
      if (policy.allowsBackgroundSync) {
        return work;
      }
    }
    return null;
  }

  LibrarySyncMode _legacyMode(LibrarySyncPlanKind kind) {
    return switch (kind) {
      LibrarySyncPlanKind.fullRepair => LibrarySyncMode.forceFull,
      LibrarySyncPlanKind.catalogSnapshot => LibrarySyncMode.fullInitial,
      _ => LibrarySyncMode.incremental,
    };
  }

  LibrarySyncFreshness _freshnessForDeferred(LibrarySyncPlan plan) {
    return plan.kind == LibrarySyncPlanKind.fullRepair
        ? LibrarySyncFreshness.repairRecommended
        : LibrarySyncFreshness.verificationPending;
  }

  LibrarySyncPlan? _planFromWork(
    LibrarySyncWorkTableData work,
    SyncNetworkPolicy policy,
    LibrarySyncRequest request,
  ) {
    final kinds = LibrarySyncPlanKind.values.where(
      (candidate) => candidate.name == work.kind,
    );
    if (kinds.isEmpty) {
      return null;
    }
    final kind = kinds.first;
    final isBroad =
        kind == LibrarySyncPlanKind.catalogSnapshot ||
        kind == LibrarySyncPlanKind.compatibilityAudit ||
        kind == LibrarySyncPlanKind.deltaReconcile ||
        kind == LibrarySyncPlanKind.fullRepair;
    final isProbe = kind == LibrarySyncPlanKind.probe;
    final interactive = work.workClass == 'interactive';
    final mustDefer =
        policy.isOffline ||
        (isProbe && !policy.allowsHardProbe) ||
        (interactive && !policy.allowsInteractiveHydration) ||
        (!interactive && !isProbe && !policy.allowsBackgroundSync) ||
        (isBroad &&
            policy.allowsBackgroundSync &&
            request.intent == LibrarySyncIntent.automatic &&
            (!_readIsForeground() || _readHasActivePlayback()));
    return LibrarySyncPlan(
      kind: kind,
      reason: 'resume${kind.name}',
      shouldExecute: !mustDefer,
      deferred: mustDefer,
    );
  }

  LibrarySyncTarget _targetFromWork(LibrarySyncWorkTableData work) {
    final raw = work.checkpointJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['targetKind'] is String) {
          final kindName = decoded['targetKind'] as String;
          final kind = LibrarySyncTargetKind.values.where(
            (candidate) => candidate.name == kindName,
          );
          if (kind.isNotEmpty) {
            final targetKind = kind.first;
            return LibrarySyncTarget(
              targetKind,
              entityId: _requiresEntityId(targetKind)
                  ? librarySyncTargetEntityIdFromWorkKey(
                      targetKind,
                      work.entityId,
                    )
                  : null,
            );
          }
        }
      } on FormatException {
        // Legacy queued work is conservatively treated as album hydration.
      }
    }
    if (work.kind == LibrarySyncPlanKind.targetedHydration.name &&
        work.entityId.isNotEmpty) {
      return LibrarySyncTarget.album(
        librarySyncTargetEntityIdFromWorkKey(
          LibrarySyncTargetKind.album,
          work.entityId,
        ),
      );
    }
    return const LibrarySyncTarget.catalog();
  }

  bool _requiresEntityId(LibrarySyncTargetKind kind) {
    return kind == LibrarySyncTargetKind.artist ||
        kind == LibrarySyncTargetKind.album ||
        kind == LibrarySyncTargetKind.playlist;
  }

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return requestSync(
      const LibrarySyncRequest.automatic(),
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
    bool allowMeteredBroadOverride = false,
  }) async {
    final request = LibrarySyncRequest.checkForUpdates(
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
    return requestSync(
      request,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return requestSync(
      const LibrarySyncRequest.automatic(trigger: LibrarySyncTrigger.resume),
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
    bool allowMeteredBroadOverride = false,
  }) {
    return requestSync(
      LibrarySyncRequest.repair(
        allowMeteredBroadOverride: allowMeteredBroadOverride,
      ),
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) {
    return requestSync(
      const LibrarySyncRequest.checkForUpdates(
        allowMeteredLimitedDiscovery: false,
      ),
      onProgress: onProgress,
    );
  }

  void cancelSync() {
    final executor = _executor;
    if (executor is DriftLibrarySyncEngine) {
      executor.cancelSync();
    }
  }

  Future<void> cancelAndWait() async {
    cancelSync();
    final running = _inFlight;
    if (running != null) {
      await running;
    }
  }
}
