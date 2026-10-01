import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/sync_write_fence.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/features/library/data/sync_attempt_recorder.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/library_sync_planner.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

class AdaptiveLibrarySyncCoordinator implements LibrarySyncEngine {
  new({
    required this._executor,
    required this._database,
    required this._serverConfigRepository,
    NetworkType? networkType,
    this._readSyncNetworkPolicy,
    required this.staleAfter,
    required this._readHasActivePlayback,
    bool Function()? readIsForeground,
    DateTime Function()? now,
    this._planner = const LibrarySyncPlanner(),
    String executionOwnerKind = 'foreground',
    this._isBackgroundExecution = false,
    Duration? executionLeaseTtl,
    Duration? executionLeaseHeartbeatInterval,
  }) : _legacyNetworkType = networkType,
       _readIsForeground = readIsForeground ?? _alwaysForeground,
       _now = now ?? DateTime.now,
       _executionOwnerKind = _validateOwnerKind(executionOwnerKind),
       _executionLeaseTtl = executionLeaseTtl ?? _defaultExecutionLeaseTtl,
       _executionLeaseHeartbeatInterval =
           executionLeaseHeartbeatInterval ??
           _defaultExecutionLeaseHeartbeatInterval {
    if (_executionLeaseTtl <= Duration.zero ||
        _executionLeaseHeartbeatInterval <= Duration.zero ||
        _executionLeaseHeartbeatInterval >= _executionLeaseTtl) {
      throw ArgumentError.value(
        _executionLeaseHeartbeatInterval,
        'executionLeaseHeartbeatInterval',
        'must be positive and shorter than executionLeaseTtl',
      );
    }
  }

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
  Future<void>? _auxiliaryDrain;
  int _cancellationGeneration = 0;

  // In-memory repair-session state. The mobile-data grant deliberately never
  // reaches persistence: a process restart, sign-out, account change, or
  // explicit cancel always starts from "no consent".
  int? _repairSessionServerId;
  String? _repairSessionId;
  bool _repairSessionMeteredGrant = false;

  /// Opens a repair session and returns its stable identity.
  ///
  /// The session owns the mobile-data grant for all retry and reconnect
  /// attempts until [endRepairSession] clears it, so a consented repair never
  /// loses its grant to an automatic resume that re-enters without the
  /// original flag.
  String beginRepairSession({
    required int serverId,
    bool allowMetered = false,
  }) {
    _repairSessionServerId = serverId;
    _repairSessionId = _newLeaseToken();
    _repairSessionMeteredGrant = allowMetered;
    return _repairSessionId!;
  }

  /// Clears the session and its grant. Safe to call for any server.
  void endRepairSession({int? serverId}) {
    if (serverId != null && _repairSessionServerId != serverId) {
      return;
    }
    _repairSessionServerId = null;
    _repairSessionId = null;
    _repairSessionMeteredGrant = false;
  }

  String? get repairSessionId {
    final serverId = _repairSessionServerId;
    if (serverId == null) {
      return null;
    }
    return _repairSessionId;
  }

  /// Applies the in-session mobile-data grant to [request] and reports whether
  /// the repair is admitted to start or join work at all.
  ///
  /// Consent is resolved here — before planning or durable work is joined — so
  /// an automatic controller startup cannot race the user's consent action.
  (LibrarySyncRequest, bool) _admitRepairConsent(
    LibrarySyncRequest request,
    int serverId,
    SyncNetworkPolicy policy,
  ) {
    final sessionGrant =
        _repairSessionServerId == serverId && _repairSessionMeteredGrant;
    var effective = request;
    if (sessionGrant && !request.allowMeteredBroadOverride) {
      effective = request.copyWithMeteredBroadOverride();
    }
    final consented = effective.allowMeteredBroadOverride || !policy.isMetered;
    return (effective, consented);
  }

  static const Duration _defaultExecutionLeaseTtl = Duration(minutes: 10);
  static const Duration _defaultExecutionLeaseHeartbeatInterval = Duration(
    minutes: 1,
  );
  final Duration _executionLeaseTtl;
  final Duration _executionLeaseHeartbeatInterval;

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
      nativeMetered: type == NetworkType.cellular,
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
    final cancellationGeneration = _cancellationGeneration;
    final result = await _requestSync(
      request,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
    if (request.target.kind != LibrarySyncTargetKind.catalog ||
        cancellationGeneration != _cancellationGeneration ||
        result.status == LibrarySyncStatus.cancelled ||
        result.planReason == 'leaseHeld') {
      return result;
    }
    final serverId = (await _serverConfigRepository.getActiveServer())?.id;
    if (serverId == null || cancellationGeneration != _cancellationGeneration) {
      return result;
    }
    final running = _auxiliaryDrain;
    if (running != null) {
      await running;
    } else {
      final drain = _refreshAuxiliary(
        serverId,
        cancellationGeneration,
        sourceRequest: request,
      );
      _auxiliaryDrain = drain;
      try {
        await drain;
      } finally {
        _auxiliaryDrain = null;
      }
    }
    final persisted = await _database.librarySyncDao.getOrCreateState(serverId);
    final completed = result.copyWith(
      pendingWorkCount: await _database.librarySyncDao.countPendingWork(
        serverId,
      ),
      lastAuxiliarySyncedAt: persisted.lastAuxiliarySyncedAt,
    );
    onProgress?.call(completed);
    return completed;
  }

  static const _auxiliaryTargets = <LibrarySyncTarget>[
    LibrarySyncTarget.starred(),
    LibrarySyncTarget.playlistHeaders(),
  ];

  Future<bool> _auxiliaryIsDue(int serverId, LibrarySyncTarget target) async {
    final work = await _database.librarySyncDao.getWork(
      serverId: serverId,
      kind: LibrarySyncPlanKind.targetedHydration.name,
      entityId: librarySyncTargetWorkKey(target),
    );
    if (work == null) return true;
    if (work.status == 'cancelled' || work.status == 'running') return false;
    if (work.notBefore?.isAfter(_now()) == true) return false;
    return work.status != 'completed' ||
        _now().difference(work.updatedAt) >= const Duration(hours: 12);
  }

  Future<void> _refreshAuxiliary(
    int serverId,
    int cancellationGeneration, {
    required LibrarySyncRequest sourceRequest,
  }) async {
    final isExplicit = sourceRequest.intent != LibrarySyncIntent.automatic;
    for (final target in _auxiliaryTargets) {
      if (cancellationGeneration != _cancellationGeneration ||
          (await _serverConfigRepository.getActiveServer())?.id != serverId) {
        return;
      }
      if (!isExplicit && !await _auxiliaryIsDue(serverId, target)) continue;
      if (cancellationGeneration != _cancellationGeneration) return;
      // Explicit catalog sync includes the user-facing companion domains.
      // Scheduled sync keeps their separate freshness interval, retry queue,
      // playback gate, and unmetered-only background policy.
      try {
        await _requestSync(
          LibrarySyncRequest(
            trigger: isExplicit
                ? sourceRequest.trigger
                : LibrarySyncTrigger.interval,
            intent: isExplicit
                ? LibrarySyncIntent.checkForUpdates
                : LibrarySyncIntent.automatic,
            target: target,
            allowMeteredBroadOverride:
                isExplicit && sourceRequest.allowMeteredBroadOverride,
            caller: isExplicit
                ? sourceRequest.caller
                : LibrarySyncRequestCaller.unspecified,
          ),
        );
      } on Object {
        // _executePlanned records the failed attempt and work backoff.
      }
    }
  }

  Future<LibrarySyncState> _requestSync(
    LibrarySyncRequest requestInput, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final cancellationGeneration = _cancellationGeneration;
    final config = await _serverConfigRepository.getActiveServer();
    final serverId = config?.id;
    if (config == null || serverId == null) {
      return _executor.requestSync(
        requestInput,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    }

    // Resolve the repair-session consent before any planning, durable run, or
    // queued work is joined, so a consented request can never be satisfied by
    // a weaker deferred one and an automatic start cannot race the consent
    // dialog. A session bound to another server is stale by definition.
    if (_repairSessionServerId != null && _repairSessionServerId != serverId) {
      endRepairSession();
    }
    final policy = _syncPolicy;
    var request = requestInput;
    if (requestInput.intent == LibrarySyncIntent.repair) {
      final (admittedRequest, consented) = _admitRepairConsent(
        requestInput,
        serverId,
        policy,
      );
      request = admittedRequest;
      if (!consented) {
        return LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planKind: LibrarySyncPlanKind.fullRepair,
          planReason: 'waitingForMobileConsent',
          failureCategory: 'consent',
        );
      }
    }

    var persisted = await _database.librarySyncDao.getOrCreateState(serverId);
    final providerFingerprint = '${config.url}|${config.apiVersion}';
    if (!_recoveredServers.contains(serverId) ||
        persisted.providerFingerprint != providerFingerprint) {
      final recoveryToken = _newLeaseToken();
      final acquired = await _database.librarySyncDao.acquireExecutionLease(
        serverId: serverId,
        ownerToken: recoveryToken,
        ownerKind: _executionOwnerKind,
        now: _now(),
        ttl: _executionLeaseTtl,
      );
      if (!acquired) {
        return LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planReason: 'leaseHeld',
        );
      }
      try {
        await SyncWriteFence(
          serverId: serverId,
          ownerToken: recoveryToken,
          now: _now,
          renewalTtl: _executionLeaseTtl,
        ).run(() async {
          if (!_recoveredServers.contains(serverId)) {
            await _database.librarySyncDao.migrateLegacySyncWork(serverId);
            await _database.librarySyncDao.resetInterruptedWork(serverId);
            await _database.librarySyncDao.recoverInterruptedSyncRuns(serverId);
            final recovered = await _database.librarySyncDao.getOrCreateState(
              serverId,
            );
            if (recovered.currentGeneration > 0) {
              await _database.librarySyncCandidateDao.clearThroughGeneration(
                serverId: serverId,
                generation: recovered.currentGeneration,
              );
            }
          }
          // Re-read under ownership: another admitted engine may have already
          // initialized or replaced the provider profile before this lease.
          persisted = await _database.librarySyncDao.getOrCreateState(serverId);
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
          }
        });
        _recoveredServers.add(serverId);
      } on SyncLeaseLostException {
        return LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planReason: 'leaseHeld',
        );
      } finally {
        await _database.librarySyncDao.releaseExecutionLease(
          serverId: serverId,
          ownerToken: recoveryToken,
        );
      }
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
    if (circuitOpen &&
        !canProbeCircuitEarly &&
        request.target.kind == LibrarySyncTargetKind.catalog) {
      final deferredPlan = LibrarySyncPlan(
        kind: LibrarySyncPlanKind.probe,
        reason: 'endpointCircuitOpen',
        shouldExecute: false,
        deferred: true,
      );
      final typedPlan = _typedPlanFor(
        request: syncRunRequestFromLegacy(request),
        plan: deferredPlan,
        policy: _syncPolicy,
      );
      final durableRun = await _database.librarySyncDao.enqueueSyncRun(
        serverId: serverId,
        plan: typedPlan,
        now: _now(),
      );
      await _database.librarySyncDao.completeSyncRun(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.cooldown,
        ),
        now: _now(),
      );
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
    final isAuxiliary = _auxiliaryTargets.any(
      (target) => target.kind == request.target.kind,
    );
    final auxiliaryDue =
        isAuxiliary && await _auxiliaryIsDue(serverId, request.target);
    final auditInterval = persisted.conditionalIndexesMode == 'unsupported'
        ? const Duration(days: 1)
        : const Duration(days: 7);
    final auditDue =
        persisted.lastAuditAt == null ||
        timestamp.difference(persisted.lastAuditAt!) >= auditInterval;
    final runnableBeforePlanning = await _database.librarySyncDao
        .getRunnableWork(serverId: serverId, now: timestamp, limit: 8);
    final resumedWork =
        request.target.kind == LibrarySyncTargetKind.catalog &&
            request.intent != LibrarySyncIntent.repair
        ? _firstAllowedWork(
            runnableBeforePlanning,
            policy,
            request,
            // A manual catalog refresh is an explicit discovery request. It
            // must not be consumed by a queued page/detail hydration merely
            // because that interaction work has a higher durable priority.
            // An automatic probe cannot replace manual discovery either;
            // it stays queued for a later automatic pass.
            catalogWorkOnly:
                request.intent == LibrarySyncIntent.checkForUpdates ||
                (request.intent == LibrarySyncIntent.automatic && isDue),
          )
        : null;
    final resumedRequest = resumedWork == null
        ? request
        : _requestFromWork(resumedWork, fallback: request);
    final resumedPlan = resumedWork == null
        ? null
        : _planFromWork(resumedWork, policy, resumedRequest);
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
            trigger: resumedRequest.trigger,
            intent: resumedRequest.intent,
            target: effectiveTarget,
            allowMeteredBroadOverride: resumedRequest.allowMeteredBroadOverride,
            allowMeteredLimitedDiscovery:
                resumedRequest.allowMeteredLimitedDiscovery,
            caller: resumedRequest.caller,
          );
    final targetWorkKey = librarySyncTargetWorkKey(effectiveTarget);
    final workClass = _workClassFor(request, plan);
    final typedPlan = _typedPlanFor(
      request: syncRunRequestFromLegacy(effectiveRequest),
      plan: plan,
      policy: policy,
    );
    final durableRun = await _database.librarySyncDao.enqueueSyncRun(
      serverId: serverId,
      plan: typedPlan,
      now: timestamp,
    );
    if (resumedWork == null && (plan.shouldExecute || plan.deferred)) {
      final previousWork = await _database.librarySyncDao.getWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
      );
      // Cancellation suppresses immediate automatic replay. A later due
      // observation can start a new operation; explicit manual intent can
      // always resume immediately.
      final cancelledObservationIsFresh =
          previousWork?.status == 'cancelled' &&
          timestamp.difference(previousWork!.updatedAt) < staleAfter;
      if (request.intent == LibrarySyncIntent.automatic &&
          cancelledObservationIsFresh) {
        await _database.librarySyncDao.completeSyncRun(
          requestId: durableRun.id,
          outcome: const SyncRunOutcome(
            kind: SyncRunOutcomeKind.cancelled,
            reason: SyncSafeReason.cancellation,
          ),
          now: timestamp,
        );
        return LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: timestamp,
          planKind: plan.kind,
          planReason: 'cancelledObservation',
        );
      }
      await _database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
        priority: _priorityFor(request),
        workClass: workClass,
        checkpointJson: _workCheckpoint(request),
        releaseCooldown: canProbeCircuitEarly,
        reactivateTerminal:
            request.intent != LibrarySyncIntent.automatic ||
            ((previousWork?.status == 'completed' ||
                    previousWork?.status == 'cancelled') &&
                ((isAuxiliary && auxiliaryDue) ||
                    (effectiveTarget.kind == LibrarySyncTargetKind.catalog &&
                        (isDue || auditDue || localPendingHydration > 0)))),
        now: timestamp,
      );
    }
    await _writePlanState(serverId: serverId, persisted: persisted, plan: plan);

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
      await _database.librarySyncDao.completeSyncRun(
        requestId: durableRun.id,
        outcome: SyncRunOutcome(
          kind: plan.deferred
              ? SyncRunOutcomeKind.deferred
              : SyncRunOutcomeKind.skipped,
          reason: _safeReasonForPlan(plan, policy),
        ),
        now: timestamp,
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
      await _database.librarySyncDao.completeSyncRun(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.meteredPolicy,
        ),
        now: timestamp,
      );
      onProgress?.call(state);
      return state;
    }

    Future<LibrarySyncState> cancelledBeforeExecution() async {
      await _database.librarySyncDao.cancelQueuedWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
        now: _now(),
      );
      await _database.librarySyncDao.completeSyncRun(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.cancelled,
          reason: SyncSafeReason.cancellation,
        ),
        now: _now(),
      );
      return LibrarySyncState(
        status: LibrarySyncStatus.cancelled,
        stage: LibrarySyncStage.completed,
        completedAt: _now(),
        planKind: plan.kind,
        planReason: 'cancelledBeforeExecution',
      );
    }

    if (cancellationGeneration != _cancellationGeneration) {
      return cancelledBeforeExecution();
    }
    final running = _inFlight;
    if (running != null) {
      await running;
      if (cancellationGeneration != _cancellationGeneration) {
        return cancelledBeforeExecution();
      }
      return _requestSync(
        request,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    }
    final future = _executePlanned(
      serverId: serverId,
      request: effectiveRequest,
      plan: plan,
      typedPlan: typedPlan,
      durableRunId: durableRun.id,
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
    required SyncExecutionPlan typedPlan,
    required int durableRunId,
    required String targetWorkKey,
    required String workClass,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    int? activeAttemptId;
    final startedAt = _now();
    final livePolicy = _syncPolicy;
    if (!_workAllowed(workClass, livePolicy, request, planKind: plan.kind)) {
      await _database.librarySyncDao.completeSyncRun(
        requestId: durableRunId,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.meteredPolicy,
        ),
        now: startedAt,
      );
      return LibrarySyncState(
        runRequestId: durableRunId,
        runAttemptId: activeAttemptId,
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        completedAt: startedAt,
        planKind: plan.kind,
        planReason: 'networkPolicyDeferred',
        updatesAvailable: true,
      );
    }

    final ownerToken = _newLeaseToken();
    Timer? leaseHeartbeat;
    var leaseActive = true;
    {
      final acquired = await _database.librarySyncDao.acquireExecutionLease(
        serverId: serverId,
        ownerToken: ownerToken,
        ownerKind: _executionOwnerKind,
        now: startedAt,
        ttl: _executionLeaseTtl,
      );
      if (!acquired) {
        await _database.librarySyncDao.completeSyncRun(
          requestId: durableRunId,
          outcome: const SyncRunOutcome(
            kind: SyncRunOutcomeKind.deferred,
            reason: SyncSafeReason.leaseHeld,
          ),
          now: _now(),
        );
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
              .catchError((Object _) => false)
              .then((owned) {
                if (!owned && leaseActive) cancelSync();
              }),
        );
      });
    }

    try {
      return await SyncWriteFence(
        serverId: serverId,
        ownerToken: ownerToken,
        now: _now,
        renewalTtl: _executionLeaseTtl,
      ).run(() async {
        final durableAttempt = await _database.librarySyncDao
            .beginSyncRunAttempt(
              requestId: durableRunId,
              androidWorker: _isBackgroundExecution,
              now: startedAt,
            );
        activeAttemptId = durableAttempt.id;
        final matchingWork = await _database.librarySyncDao.getWork(
          serverId: serverId,
          kind: plan.kind.name,
          entityId: targetWorkKey,
        );
        final activeWork =
            matchingWork != null &&
                (matchingWork.status == 'queued' ||
                    matchingWork.status == 'failed') &&
                matchingWork.notBefore?.isAfter(startedAt) != true
            ? matchingWork
            : null;
        if (activeWork != null) {
          await _database.librarySyncDao.markRunning(
            activeWork.id,
            now: startedAt,
          );
        }

        final scope = SyncRequestScope(
          allowedEndpoints: _endpointNames(typedPlan.budget.allowedEndpoints),
          maxRequests: typedPlan.budget.maxRequests,
          maxNewestPages: typedPlan.budget.maxNewestPages,
          maxAlbumHydrations: typedPlan.budget.maxAlbumHydrations,
          maxResponseBytes: typedPlan.budget.maxResponseBytes,
          maxTotalBytes: typedPlan.budget.maxTotalBytes,
          maxConcurrency: typedPlan.budget.maxConcurrency,
          maxDuration: typedPlan.budget.maxDuration,
          now: _now,
          canRequest: () =>
              _workAllowed(
                workClass,
                _syncPolicy,
                request,
                planKind: plan.kind,
              ) &&
              (request.intent != LibrarySyncIntent.automatic ||
                  plan.kind == LibrarySyncPlanKind.probe ||
                  ((!_readHasActivePlayback()) &&
                      (_isBackgroundExecution || _readIsForeground()))),
          onStop: driftExecutor?.cancelSync,
        );
        final recorder = SyncAttemptRecorder(
          requestId: durableRunId,
          attemptId: durableAttempt.id,
          scope: scope,
          now: _now,
          write: (telemetry) => _database.librarySyncDao.writeAttemptTelemetry(
            durableAttempt.id,
            telemetry,
          ),
        );
        try {
          LibrarySyncState result;
          var explicitBudgetPartial = false;
          try {
            result = await scope.run(
              () => _executeDelegate(
                typedPlan: typedPlan,
                priorityAlbumIds: priorityAlbumIds,
                onProgress: (progress) {
                  final correlated = progress.copyWith(
                    planKind: plan.kind,
                    planReason: plan.reason,
                    runRequestId: durableRunId,
                    runAttemptId: durableAttempt.id,
                  );
                  recorder.observe(correlated);
                  onProgress?.call(correlated);
                },
              ),
            );
            final stoppedReason = scope.stopped?.reason;
            // A user-initiated check can make useful, committed progress
            // before reaching its deliberately bounded discovery budget. Keep
            // the remaining work queued, but report that truth as a partial
            // completion instead of a policy deferral. The latter is reserved
            // for work that did not receive permission to run (offline,
            // backgrounded, metered, and so on), and was making an explicit
            // refresh look like it did nothing.
            explicitBudgetPartial =
                request.intent == LibrarySyncIntent.checkForUpdates &&
                _isResumableBudgetStop(stoppedReason);
            if (stoppedReason != null) {
              result = result.copyWith(
                status: explicitBudgetPartial
                    ? LibrarySyncStatus.partial
                    : LibrarySyncStatus.deferred,
                failureCategory: stoppedReason,
              );
            }
          } on Object catch (error) {
            if (activeWork != null && !(await _workIsCompleted(activeWork))) {
              await _markWorkFailure(activeWork, error.runtimeType.toString());
            }
            await recorder.fail();
            await _database.librarySyncDao.completeSyncRun(
              requestId: durableRunId,
              attemptId: durableAttempt.id,
              outcome: SyncRunOutcome(
                kind: SyncRunOutcomeKind.failed,
                reason: SyncSafeReason.unknownFailure,
                requestCount: scope.transportObserved
                    ? scope.requestCount
                    : scope.logicalRequests.values.fold<int>(
                        0,
                        (sum, value) => sum + value,
                      ),
                byteCount: scope.byteCount,
              ),
              now: _now(),
            );
            rethrow;
          }

          if (plan.kind == LibrarySyncPlanKind.probe &&
              result.status == LibrarySyncStatus.succeeded) {
            await _enqueueProbeFollowUp(
              serverId: serverId,
              result: result,
              now: startedAt,
            );
          }

          final runRequests = scope.transportObserved
              ? scope.requestCount
              : driftExecutor != null
              ? scope.logicalRequests.values.fold<int>(
                  0,
                  (sum, count) => sum + count,
                )
              : result.apiRequests;
          final runBytes = scope.byteCount;
          final cancelled = result.status == LibrarySyncStatus.cancelled;
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
          final failed = status == LibrarySyncStatus.failed;

          if (activeWork != null && !(await _workIsCompleted(activeWork))) {
            if (cancelled) {
              await _database.librarySyncDao.markCancelled(activeWork.id);
            } else if (deferred || explicitBudgetPartial) {
              // Preserve checkpoints; return the row to the queue for later.
              await _database.librarySyncDao.requeue(
                activeWork.id,
                now: _now(),
              );
            } else if (failed) {
              await _markWorkFailure(
                activeWork,
                'sync',
                retryAt: result.nextRetryAt,
              );
            } else if (status == LibrarySyncStatus.partial &&
                !_didCommitCatalogCandidate(plan, result)) {
              if (result.candidateStatus == 'awaitingDeletionConfirmation') {
                await _database.librarySyncDao.markAwaitingConfirmation(
                  activeWork.id,
                  now: _now(),
                );
              } else {
                await _markWorkFailure(activeWork, 'incompleteSnapshot');
              }
            } else {
              await _database.librarySyncDao.markCompleted(
                activeWork.id,
                now: _now(),
                preserveCheckpoint: true,
              );
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
          final successfulCheck =
              status == LibrarySyncStatus.succeeded ||
              status == LibrarySyncStatus.partial;
          final catalogChecked =
              successfulCheck &&
              request.target.kind == LibrarySyncTargetKind.catalog &&
              (plan.kind == LibrarySyncPlanKind.probe ||
                  plan.kind == LibrarySyncPlanKind.deltaReconcile ||
                  plan.kind == LibrarySyncPlanKind.catalogSnapshot ||
                  plan.kind == LibrarySyncPlanKind.fullRepair ||
                  plan.kind == LibrarySyncPlanKind.compatibilityAudit);
          final circuitRelevant =
              request.target.kind == LibrarySyncTargetKind.catalog &&
              (failed || successfulCheck);
          final starredWork = await _database.librarySyncDao.getWork(
            serverId: serverId,
            kind: LibrarySyncPlanKind.targetedHydration.name,
            entityId: '@starred',
          );
          final playlistsWork = await _database.librarySyncDao.getWork(
            serverId: serverId,
            kind: LibrarySyncPlanKind.targetedHydration.name,
            entityId: '@playlistHeaders',
          );
          final auxiliaryCompletedAt =
              starredWork?.status == 'completed' &&
                  playlistsWork?.status == 'completed'
              ? (starredWork!.updatedAt.isBefore(playlistsWork!.updatedAt)
                    ? starredWork.updatedAt
                    : playlistsWork.updatedAt)
              : persisted.lastAuxiliarySyncedAt;
          final nextRetryAt = circuitRelevant && failed
              ? _laterRetry(
                  _cooldownUntil(persisted.failureStreak + 1),
                  result.nextRetryAt,
                )
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
              lastAuxiliarySyncedAt: Value(auxiliaryCompletedAt),
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
              lastRunBytes: Value(runBytes),
              lastRunRequests: Value(runRequests),
            ),
          );
          final candidateGeneration =
              result.candidateGeneration ?? persisted.candidateGeneration;
          final candidateStatus =
              result.candidateStatus ?? persisted.candidateStatus;
          if (candidateGeneration != null && candidateStatus != null) {
            await _database.librarySyncDao.writeRepairSession(
              serverId: serverId,
              generation: candidateGeneration,
              phase: _repairPhaseFor(candidateStatus),
              deletionFingerprint: persisted.deletionCandidateFingerprint,
              deletionCount: persisted.deletionCandidateCount,
              startedAt: persisted.candidateStartedAt ?? startedAt,
              now: completedAt,
            );
          }
          await _database.librarySyncDao.pruneCompletedBefore(
            completedAt.subtract(const Duration(days: 7)),
          );
          final finalState = result.copyWith(
            runRequestId: durableRunId,
            runAttemptId: durableAttempt.id,
            status: status,
            planKind: plan.kind,
            planReason: plan.reason,
            pendingWorkCount: pendingCount,
            lastRunBytes: runBytes,
            apiRequests: runRequests,
            apiRetries: scope.transportObserved
                ? scope.retryCount
                : result.apiRetries,
            endpointRequests: scope.transportObserved
                ? Map<String, int>.unmodifiable(scope.endpointRequests)
                : driftExecutor != null
                ? Map<String, int>.unmodifiable(scope.logicalRequests)
                : result.endpointRequests,
            lastCheckedAt: catalogChecked
                ? completedAt
                : persisted.lastCheckedAt,
            lastCatalogUpdatedAt: catalogUpdated
                ? completedAt
                : persisted.lastCatalogSyncedAt,
            lastAuxiliarySyncedAt: auxiliaryCompletedAt,
            failureCategory: failed
                ? (result.failureCategory ?? 'sync')
                : deferred || explicitBudgetPartial
                ? result.failureCategory
                : null,
            clearFailureCategory:
                !failed && !deferred && !explicitBudgetPartial,
            nextRetryAt: nextRetryAt,
            clearNextRetryAt: nextRetryAt == null,
            candidateGeneration:
                result.candidateGeneration ?? persisted.candidateGeneration,
            candidateStatus:
                result.candidateStatus ?? persisted.candidateStatus,
            deletionCandidateCount: persisted.deletionCandidateCount,
            carriedForwardEntityCount: result.carriedForwardEntityCount > 0
                ? result.carriedForwardEntityCount
                : persisted.candidateCarriedForwardCount,
            lastApplyDurationMs: _didCommitCatalogCandidate(plan, result)
                ? persisted.lastApplyDurationMs
                : result.lastApplyDurationMs,
            updatesAvailable:
                result.updatesAvailable ||
                deferred ||
                (result.probeIndexChanged == true) ||
                result.probeIndexesUnsupported,
          );
          // Deep newest-feed discovery that keeps hitting its window cap is
          // escalated to broad catalog reconciliation so a large backlog
          // cannot stay invisible behind the bounded probe window.
          if (result.status == LibrarySyncStatus.succeeded &&
              (result.probeDiscoveryDebtStreak ?? 0) >=
                  discoveryDebtEscalationStreak) {
            await _enqueueDeltaReconcile(
              serverId: serverId,
              result: result,
              now: startedAt,
            );
          }
          await recorder.finish(finalState);
          await _database.librarySyncDao.completeSyncRun(
            requestId: durableRunId,
            attemptId: durableAttempt.id,
            outcome: _typedOutcomeFor(
              status: status,
              result: result,
              requestCount: runRequests,
              byteCount: runBytes,
              deferred: deferred,
            ),
            now: completedAt,
          );
          await _database.librarySyncDao.pruneSyncRunHistoryBefore(
            completedAt.subtract(const Duration(days: 90)),
          );
          await _database.librarySyncDao.pruneAttemptTelemetryBefore(
            completedAt.subtract(const Duration(days: 7)),
          );
          onProgress?.call(finalState);
          return finalState;
        } finally {
          await recorder.close();
        }
      });
    } on SyncLeaseLostException {
      // Capture who holds the execution lease now so certification can
      // explain the contention instead of only observing a safe rollback.
      final holder = await _database.librarySyncDao.getExecutionLease(serverId);
      await _database.librarySyncDao.recordOperationLedgerEntry(
        serverId: serverId,
        operation: 'executionLeaseLost',
        reason: plan.kind.name,
        details: <String, Object?>{
          'holder': holder == null
              ? null
              : <String, Object?>{
                  'ownerKind': holder.ownerKind,
                  'startedAt': holder.startedAt.toUtc().toIso8601String(),
                  'heartbeatAt': holder.heartbeatAt.toUtc().toIso8601String(),
                  'expiresAt': holder.expiresAt.toUtc().toIso8601String(),
                },
        },
      );
      AppLogger.warning(
        'Sync execution lease lost during ${plan.kind.name}: '
        '${holder == null ? 'lease row absent' : 'held by ${holder.ownerKind} '
                  'since ${holder.startedAt.toUtc().toIso8601String()} '
                  '(expires ${holder.expiresAt.toUtc().toIso8601String()})'}',
      );
      return LibrarySyncState(
        runRequestId: durableRunId,
        runAttemptId: activeAttemptId,
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        completedAt: _now(),
        planKind: plan.kind,
        planReason: 'leaseHeld',
      );
    } finally {
      leaseActive = false;
      leaseHeartbeat.cancel();
      await _database.librarySyncDao.releaseExecutionLease(
        serverId: serverId,
        ownerToken: ownerToken,
      );
    }
  }

  Set<String> _endpointNames(Set<SyncEndpoint> endpoints) => {
    for (final endpoint in endpoints)
      ...switch (endpoint) {
        SyncEndpoint.indexes => {'getIndexes'},
        SyncEndpoint.newestAlbums => {'getNewestAlbumList2'},
        SyncEndpoint.catalogAlbums => {'getAlbumList2', 'getAlbumListPage'},
        SyncEndpoint.artists => {'getArtists'},
        SyncEndpoint.artist => {'getArtist'},
        SyncEndpoint.album => {'getAlbum'},
        SyncEndpoint.playlists => {'getPlaylists', 'getPlaylist'},
        SyncEndpoint.starred => {'getStarredContent'},
        SyncEndpoint.bulkSongs => {'searchSongsPage'},
      },
  };

  SyncExecutionPlan _typedPlanFor({
    required SyncRunRequest request,
    required LibrarySyncPlan plan,
    required SyncNetworkPolicy policy,
  }) {
    final kind = syncExecutionPlanKindFromLegacy(plan.kind, request);
    final meteredManual =
        kind == SyncExecutionPlanKind.manualCatalogDiscovery &&
        policy.isMetered &&
        request.networkGrant == SyncNetworkGrant.boundedMeteredDiscovery;
    final endpoints = switch (kind) {
      SyncExecutionPlanKind.automaticProbe => const <SyncEndpoint>{
        SyncEndpoint.indexes,
      },
      SyncExecutionPlanKind.manualCatalogDiscovery => const <SyncEndpoint>{
        SyncEndpoint.indexes,
        SyncEndpoint.newestAlbums,
        SyncEndpoint.artist,
        SyncEndpoint.album,
      },
      SyncExecutionPlanKind.repairLibrary ||
      SyncExecutionPlanKind.catalogSnapshot => const <SyncEndpoint>{
        SyncEndpoint.catalogAlbums,
        SyncEndpoint.indexes,
        SyncEndpoint.newestAlbums,
        SyncEndpoint.artists,
        SyncEndpoint.artist,
        SyncEndpoint.album,
        SyncEndpoint.bulkSongs,
      },
      SyncExecutionPlanKind.compatibilityAudit => const <SyncEndpoint>{
        SyncEndpoint.newestAlbums,
        SyncEndpoint.indexes,
        SyncEndpoint.artists,
        SyncEndpoint.artist,
        SyncEndpoint.album,
      },
      SyncExecutionPlanKind.auxiliaryRefresh => switch (request.target.kind) {
        LibrarySyncTargetKind.starred => const <SyncEndpoint>{
          SyncEndpoint.starred,
        },
        LibrarySyncTargetKind.playlistHeaders => const <SyncEndpoint>{
          SyncEndpoint.playlists,
        },
        _ => const <SyncEndpoint>{},
      },
      SyncExecutionPlanKind.targetHydration => const <SyncEndpoint>{
        SyncEndpoint.artist,
        SyncEndpoint.album,
        SyncEndpoint.playlists,
      },
    };
    final broad =
        kind == SyncExecutionPlanKind.catalogSnapshot ||
        kind == SyncExecutionPlanKind.repairLibrary;
    final automatic = request.intent == SyncRunIntent.automaticCatalogCheck;
    return SyncExecutionPlan(
      request: request,
      kind: kind,
      reason: _safeReasonForPlan(plan, policy),
      budget: SyncExecutionBudget(
        allowedEndpoints: endpoints,
        maxNewestPages: meteredManual
            ? 1
            : kind == SyncExecutionPlanKind.manualCatalogDiscovery
            ? (request.intent == SyncRunIntent.automaticCatalogCheck ? 2 : 5)
            : kind == SyncExecutionPlanKind.compatibilityAudit
            ? 2
            : 0,
        maxAlbumHydrations: meteredManual
            ? 3
            : broad
            ? 10000
            : automatic
            ? 32
            : 64,
        maxResponseBytes: policy.isMetered
            ? kMeteredSyncMaxResponseBytes
            : broad
            ? 64 * 1024 * 1024
            : 16 * 1024 * 1024,
        maxTotalBytes: broad
            ? 512 * 1024 * 1024
            : automatic || policy.isMetered
            ? kMeteredSyncMaxInteractionBytes
            : 64 * 1024 * 1024,
        maxConcurrency: policy.isMetered
            ? 1
            : automatic
            ? 3
            : 6,
        maxRequests: kind == SyncExecutionPlanKind.automaticProbe
            ? 1
            : broad
            ? 10000
            : automatic
            ? 96
            : 200,
        maxDuration: broad
            ? const Duration(minutes: 10)
            : automatic
            ? const Duration(seconds: 30)
            : const Duration(minutes: 1),
      ),
    );
  }

  SyncSafeReason _safeReasonForPlan(
    LibrarySyncPlan plan,
    SyncNetworkPolicy policy,
  ) {
    if (policy.isOffline) {
      return SyncSafeReason.offline;
    }
    if (plan.deferred && policy.isMetered) {
      return SyncSafeReason.meteredPolicy;
    }
    if (plan.deferred && _readHasActivePlayback()) {
      return SyncSafeReason.activePlayback;
    }
    if (plan.deferred && !_readIsForeground()) {
      return SyncSafeReason.backgrounded;
    }
    return SyncSafeReason.none;
  }

  bool _isResumableBudgetStop(String? reason) {
    return switch (reason) {
      'byteBudget' ||
      'entityBudget' ||
      'pageBudget' ||
      'requestBudget' ||
      'timeBudget' => true,
      _ => false,
    };
  }

  SyncRunOutcome _typedOutcomeFor({
    required LibrarySyncStatus status,
    required LibrarySyncState result,
    required int requestCount,
    required int byteCount,
    required bool deferred,
  }) {
    final kind = switch (status) {
      LibrarySyncStatus.succeeded => SyncRunOutcomeKind.completed,
      LibrarySyncStatus.skipped => SyncRunOutcomeKind.skipped,
      LibrarySyncStatus.deferred => SyncRunOutcomeKind.deferred,
      LibrarySyncStatus.cancelled => SyncRunOutcomeKind.cancelled,
      LibrarySyncStatus.partial =>
        result.candidateStatus == 'awaitingDeletionConfirmation'
            ? SyncRunOutcomeKind.awaitingConfirmation
            : SyncRunOutcomeKind.partial,
      LibrarySyncStatus.failed => SyncRunOutcomeKind.failed,
      LibrarySyncStatus.idle ||
      LibrarySyncStatus.running => SyncRunOutcomeKind.failed,
    };
    final reason = switch (kind) {
      SyncRunOutcomeKind.deferred
          when result.failureCategory?.endsWith('Budget') == true =>
        SyncSafeReason.responseBudgetExceeded,
      SyncRunOutcomeKind.partial
          when result.failureCategory?.endsWith('Budget') == true =>
        SyncSafeReason.responseBudgetExceeded,
      SyncRunOutcomeKind.deferred when deferred && _syncPolicy.isOffline =>
        SyncSafeReason.offline,
      SyncRunOutcomeKind.deferred when deferred && _readHasActivePlayback() =>
        SyncSafeReason.activePlayback,
      SyncRunOutcomeKind.deferred
          when deferred && !_readIsForeground() && !_isBackgroundExecution =>
        SyncSafeReason.backgrounded,
      SyncRunOutcomeKind.deferred when deferred => SyncSafeReason.meteredPolicy,
      SyncRunOutcomeKind.cancelled => SyncSafeReason.cancellation,
      SyncRunOutcomeKind.awaitingConfirmation =>
        SyncSafeReason.confirmationRequired,
      SyncRunOutcomeKind.failed when result.failureCategory == 'transport' =>
        SyncSafeReason.networkFailure,
      SyncRunOutcomeKind.failed
          when result.failureCategory == 'authentication' =>
        SyncSafeReason.authenticationFailure,
      SyncRunOutcomeKind.failed => SyncSafeReason.unknownFailure,
      _ => SyncSafeReason.none,
    };
    return SyncRunOutcome(
      kind: kind,
      reason: reason,
      requestCount: requestCount,
      byteCount: byteCount,
    );
  }

  int _repairPhaseFor(String status) {
    return switch (status) {
      'collecting' => 0,
      'validating' => 1,
      'awaitingDeletionConfirmation' => 2,
      'ready' => 3,
      'applying' => 4,
      _ => 0,
    };
  }

  Future<void> _enqueueDeltaReconcile({
    required int serverId,
    required LibrarySyncState result,
    required DateTime now,
  }) async {
    await _database.librarySyncDao.enqueueWork(
      serverId: serverId,
      kind: LibrarySyncPlanKind.deltaReconcile.name,
      entityId: '',
      evidenceVersion: result.probeEvidenceVersion,
      reactivateTerminal:
          (await _database.librarySyncDao.getWork(
            serverId: serverId,
            kind: LibrarySyncPlanKind.deltaReconcile.name,
          ))?.status ==
          'completed',
      priority: 50,
      workClass: 'background',
      releaseCooldown: true,
      now: now,
    );
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
        evidenceVersion: result.probeEvidenceVersion,
        reactivateTerminal:
            (await _database.librarySyncDao.getWork(
              serverId: serverId,
              kind: LibrarySyncPlanKind.compatibilityAudit.name,
            ))?.status ==
            'completed',
        priority: 40,
        workClass: 'background',
        releaseCooldown: true,
        now: now,
      );
      return;
    }
    if (result.probeIndexChanged == true) {
      await _enqueueDeltaReconcile(
        serverId: serverId,
        result: result,
        now: now,
      );
    }
  }

  Future<LibrarySyncState> _executeDelegate({
    required SyncExecutionPlan typedPlan,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) {
    final priorities = <String>{
      ...priorityAlbumIds,
      if (typedPlan.request.target.kind == LibrarySyncTargetKind.album &&
          typedPlan.request.target.entityId?.isNotEmpty == true)
        typedPlan.request.target.entityId!,
    };
    return _executor.executeSyncPlan(
      typedPlan,
      priorityAlbumIds: priorities,
      onProgress: onProgress,
    );
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
    String errorType, {
    DateTime? retryAt,
  }) {
    return _database.librarySyncDao.markFailed(
      work.id,
      errorType: errorType,
      notBefore: _laterRetry(_cooldownUntil(work.attemptCount + 1), retryAt),
    );
  }

  DateTime _laterRetry(DateTime local, DateTime? server) =>
      server != null && server.isAfter(local) ? server : local;

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
        bulkSearchMode: Value(bulkQuery is String ? 'supported' : 'unknown'),
        bulkSearchQuery: Value(bulkQuery is String ? bulkQuery : null),
        catalogCursor: Value(cursor),
        catalogFingerprint: Value(
          navis['libraryIndexesFingerprint'] is String
              ? navis['libraryIndexesFingerprint'] as String
              : null,
        ),
        averageLatencyMs: Value(result.averageLatencyMs),
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
    await _database.librarySyncDao.writeSyncProviderProfile(
      serverId: serverId,
      providerFingerprint: config == null
          ? null
          : '${config.url}|${config.apiVersion}',
      conditionalIndexesMode: unsupported
          ? SyncCapabilityMode.unsupported.index
          : cursor != null
          ? SyncCapabilityMode.reliable.index
          : SyncCapabilityMode.unknown.index,
      bulkSongSearchMode: bulkQuery is String ? 1 : 0,
      safePageSize: 500,
      observedAt: _now(),
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
        return Map<String, Object?>.from(root['navis'] as Map<String, dynamic>);
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
    LibrarySyncRequest request, {
    bool catalogWorkOnly = false,
  }) {
    for (final work in runnable) {
      final kind = LibrarySyncPlanKind.values.where(
        (candidate) => candidate.name == work.kind,
      );
      if (kind.isEmpty) {
        continue;
      }
      final planKind = kind.first;
      if (catalogWorkOnly &&
          (planKind == LibrarySyncPlanKind.targetedHydration ||
              (request.intent == LibrarySyncIntent.checkForUpdates &&
                  planKind == LibrarySyncPlanKind.probe))) {
        continue;
      }
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
            ((!_readIsForeground() && !_isBackgroundExecution) ||
                _readHasActivePlayback()));
    return LibrarySyncPlan(
      kind: kind,
      reason: 'resume${kind.name[0].toUpperCase()}${kind.name.substring(1)}',
      shouldExecute: !mustDefer,
      deferred: mustDefer,
    );
  }

  String? _workCheckpoint(LibrarySyncRequest request) {
    if (request.target.kind == LibrarySyncTargetKind.catalog &&
        request.intent != LibrarySyncIntent.checkForUpdates) {
      return null;
    }
    return jsonEncode(<String, String>{
      if (request.target.kind != LibrarySyncTargetKind.catalog)
        'targetKind': request.target.kind.name,
      if (request.intent == LibrarySyncIntent.checkForUpdates)
        'intent': LibrarySyncIntent.checkForUpdates.name,
    });
  }

  LibrarySyncRequest _requestFromWork(
    LibrarySyncWorkTableData work, {
    required LibrarySyncRequest fallback,
  }) {
    try {
      final decoded = jsonDecode(work.checkpointJson ?? '');
      if (decoded is Map &&
          decoded['intent'] == LibrarySyncIntent.checkForUpdates.name) {
        return const LibrarySyncRequest.checkForUpdates();
      }
    } on FormatException {
      // Legacy work has no request provenance and retains the caller policy.
    }
    return fallback;
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
    _cancellationGeneration++;
    final executor = _executor;
    if (executor is DriftLibrarySyncEngine) {
      executor.cancelSync();
    }
  }

  Future<void> cancelAndWait() async {
    cancelSync();
    final running = _inFlight;
    final auxiliary = _auxiliaryDrain;
    if (running != null) {
      await running;
    }
    if (auxiliary != null) {
      await auxiliary;
    }
  }
}
