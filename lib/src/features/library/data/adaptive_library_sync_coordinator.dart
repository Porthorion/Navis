import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';
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

  final SyncPlanExecutor _executor;
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
  bool _repairSessionMeteredGrant = false;

  /// Opens a repair session with its mobile-data grant.
  ///
  /// The session owns the mobile-data grant for all retry and reconnect
  /// attempts until [endRepairSession] clears it, so a consented repair never
  /// loses its grant to an automatic resume that re-enters without the
  /// original flag.
  void beginRepairSession({required int serverId, bool allowMetered = false}) {
    _repairSessionServerId = serverId;
    _repairSessionMeteredGrant = allowMetered;
  }

  /// Clears the session and its grant. Safe to call for any server.
  void endRepairSession({int? serverId}) {
    if (serverId != null && _repairSessionServerId != serverId) {
      return;
    }
    _repairSessionServerId = null;
    _repairSessionMeteredGrant = false;
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
    if (sessionGrant && request.grant != SyncNetworkGrant.broadMeteredOnce) {
      effective = LibrarySyncRequest(
        origin: request.origin,
        intent: request.intent,
        target: request.target,
        grant: SyncNetworkGrant.broadMeteredOnce,
      );
    }
    final consented =
        effective.grant == SyncNetworkGrant.broadMeteredOnce ||
        !policy.isMetered;
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
    return hex.encode(bytes);
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
    final LibrarySyncState result;
    try {
      result = await _requestSync(
        request,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    } on Object catch (error) {
      // Another engine's long transaction (a worker promotion) held the writer
      // lock past the busy wait on any write of this request: contention, not
      // a sync failure.
      if (!isDatabaseLockTimeout(error)) rethrow;
      return LibrarySyncState(
        status: LibrarySyncStatus.deferred,
        stage: LibrarySyncStage.completed,
        completedAt: _now(),
        planReason: 'leaseHeld',
      );
    }
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
        _now().difference(work.updatedAt) >= librarySyncAuxiliaryInterval;
  }

  Future<void> _refreshAuxiliary(
    int serverId,
    int cancellationGeneration, {
    required LibrarySyncRequest sourceRequest,
  }) async {
    final isExplicit =
        sourceRequest.intent != SyncRunIntent.automaticCatalogCheck;
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
            origin: isExplicit ? sourceRequest.origin : SyncRunOrigin.timer,
            intent: isExplicit
                ? SyncRunIntent.manualCatalogCheck
                : SyncRunIntent.automaticCatalogCheck,
            target: target,
            grant:
                isExplicit &&
                    sourceRequest.grant == SyncNetworkGrant.broadMeteredOnce
                ? SyncNetworkGrant.broadMeteredOnce
                : SyncNetworkGrant.none,
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
      final failed = LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.completed,
        startedAt: _now(),
        completedAt: _now(),
        errorMessage: 'No authenticated server session.',
      );
      onProgress?.call(failed);
      return failed;
    }

    var capabilitiesJson = config.capabilitiesJson;

    // Resolve the repair-session consent before any planning, durable run, or
    // queued work is joined, so a consented request can never be satisfied by
    // a weaker deferred one and an automatic start cannot race the consent
    // dialog. A session bound to another server is stale by definition.
    if (_repairSessionServerId != null && _repairSessionServerId != serverId) {
      endRepairSession();
    }
    final policy = _syncPolicy;
    var request = requestInput;
    if (requestInput.intent == SyncRunIntent.repairLibrary) {
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
      try {
        final recovered = await _withLease(
          serverId: serverId,
          unavailable: () async => false,
          action: () async {
            if (!_recoveredServers.contains(serverId)) {
              await _database.librarySyncDao.resetInterruptedWork(serverId);
              await _database.librarySyncDao.recoverInterruptedSyncRuns(
                serverId,
              );
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
            // initialized or replaced the backend fingerprint before this lease.
            persisted = await _database.librarySyncDao.getOrCreateState(
              serverId,
            );
            if (persisted.providerFingerprint != providerFingerprint) {
              final backendChanged = persisted.providerFingerprint != null;
              if (backendChanged) {
                await _database.librarySyncCandidateDao.clearAll();
                await _database.librarySyncDao.clearWorkForServer(serverId);
                final backend = await (_database.select(
                  _database.serverConfigTable,
                )..where((row) => row.id.equals(serverId))).getSingleOrNull();
                String? capabilities;
                try {
                  final root = jsonDecode(backend?.capabilities ?? '');
                  if (root is Map<String, dynamic>) {
                    root.remove('navis');
                    capabilities = root.isEmpty ? null : jsonEncode(root);
                  }
                } on FormatException {
                  // Invalid legacy JSON has no capability evidence to retain.
                }
                await _database.serverDao.updateRetainedServer(
                  serverId,
                  ServerConfigTableCompanion(capabilities: Value(capabilities)),
                );
                capabilitiesJson = capabilities;
              }
              await _database.librarySyncDao.writeState(
                LibrarySyncStateTableCompanion(
                  serverId: Value(serverId),
                  providerFingerprint: Value(providerFingerprint),
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
            return true;
          },
        );
        if (!recovered) {
          return LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.completed,
            completedAt: _now(),
            planReason: 'leaseHeld',
          );
        }
        _recoveredServers.add(serverId);
      } on SyncLeaseLostException {
        return LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planReason: 'leaseHeld',
        );
      }
      persisted = await _database.librarySyncDao.getOrCreateState(serverId);
    }
    final canProbeCircuitEarly = request.canProbeCircuitEarly;
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
      final executionPlan = _executionPlanFor(
        request: request,
        plan: deferredPlan,
        policy: _syncPolicy,
        capabilitiesJson: capabilitiesJson,
      );
      final durableRun = await _database.librarySyncDao.enqueueSyncRun(
        serverId: serverId,
        plan: executionPlan,
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
      return await _finish(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.cooldown,
        ),
        now: _now(),
        state: state,
        onProgress: onProgress,
      );
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
    final indexesMode = _indexesModeFromCapabilities(capabilitiesJson);
    final auditInterval = indexesMode == SyncCapabilityMode.unsupported
        ? const Duration(days: 1)
        : const Duration(days: 7);
    final auditDue =
        persisted.lastAuditAt == null ||
        timestamp.difference(persisted.lastAuditAt!) >= auditInterval;
    final runnableBeforePlanning = await _database.librarySyncDao
        .getRunnableWork(serverId: serverId, now: timestamp, limit: 8);
    final resumedWork =
        request.target.kind == LibrarySyncTargetKind.catalog &&
            request.intent != SyncRunIntent.repairLibrary
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
                request.intent == SyncRunIntent.manualCatalogCheck ||
                (request.intent == SyncRunIntent.automaticCatalogCheck &&
                    isDue),
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
            networkPolicy: policy,
            hasAuthoritativeBaseline:
                persisted.currentGeneration > 0 || config.lastSynced != null,
            isCatalogCheckDue: isDue,
            pendingHydrationCount: localPendingHydration,
            pendingWorkCount: pendingWork,
            indexesMode: indexesMode,
            auxiliaryDue: auxiliaryDue,
            auditDue: auditDue,
            isForeground: _readIsForeground(),
            hasActivePlayback: _readHasActivePlayback(),
            isBackgroundExecutor: _isBackgroundExecution,
          ),
        );

    final targetWorkKey = librarySyncTargetWorkKey(resumedRequest.target);
    final workClass =
        resumedWork?.workClass ?? _workClassFor(resumedRequest, plan);
    final executionPlan = _executionPlanFor(
      request: resumedRequest,
      plan: plan,
      policy: policy,
      capabilitiesJson: capabilitiesJson,
    );
    final durableRun = await _database.librarySyncDao.enqueueSyncRun(
      serverId: serverId,
      plan: executionPlan,
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
      if (request.intent == SyncRunIntent.automaticCatalogCheck &&
          cancelledObservationIsFresh) {
        return await _finish(
          requestId: durableRun.id,
          outcome: const SyncRunOutcome(
            kind: SyncRunOutcomeKind.cancelled,
            reason: SyncSafeReason.cancellation,
          ),
          now: timestamp,

          state: LibrarySyncState(
            status: LibrarySyncStatus.cancelled,
            stage: LibrarySyncStage.completed,
            completedAt: timestamp,
            planKind: plan.kind,
            planReason: 'cancelledObservation',
          ),
        );
      }
      await _database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
        priority: request.priority,
        workClass: workClass,
        checkpointJson: _workCheckpoint(request),
        releaseCooldown: canProbeCircuitEarly,
        reactivateTerminal:
            request.intent != SyncRunIntent.automaticCatalogCheck ||
            ((previousWork?.status == 'completed' ||
                    previousWork?.status == 'cancelled') &&
                ((isAuxiliary && auxiliaryDue) ||
                    (resumedRequest.target.kind ==
                            LibrarySyncTargetKind.catalog &&
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
      return await _finish(
        requestId: durableRun.id,
        outcome: SyncRunOutcome(
          kind: plan.deferred
              ? SyncRunOutcomeKind.deferred
              : SyncRunOutcomeKind.skipped,
          reason: _safeReasonForPlan(plan, policy),
        ),
        now: timestamp,
        state: state,
        onProgress: onProgress,
      );
    }

    if (!_workAllowed(workClass, policy, resumedRequest, planKind: plan.kind)) {
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
      return await _finish(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.meteredPolicy,
        ),
        now: timestamp,
        state: state,
        onProgress: onProgress,
      );
    }

    Future<LibrarySyncState> cancelledBeforeExecution() async {
      await _database.librarySyncDao.cancelQueuedWork(
        serverId: serverId,
        kind: plan.kind.name,
        entityId: targetWorkKey,
        now: _now(),
      );
      return await _finish(
        requestId: durableRun.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.cancelled,
          reason: SyncSafeReason.cancellation,
        ),
        now: _now(),
        state: LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planKind: plan.kind,
          planReason: 'cancelledBeforeExecution',
        ),
      );
    }

    if (cancellationGeneration != _cancellationGeneration) {
      return await cancelledBeforeExecution();
    }
    final running = _inFlight;
    if (running != null) {
      int? resumedRequestId;
      try {
        await running;
        if (cancellationGeneration != _cancellationGeneration) {
          return await cancelledBeforeExecution();
        }
        final resumed = await _requestSync(
          request,
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        );
        resumedRequestId = resumed.runRequestId;
        return resumed;
      } finally {
        if (resumedRequestId != durableRun.id) {
          await _database.librarySyncDao.completeSyncRun(
            requestId: durableRun.id,
            outcome: const SyncRunOutcome(
              kind: SyncRunOutcomeKind.skipped,
              reason: SyncSafeReason.none,
            ),
            now: _now(),
          );
        }
      }
    }
    final future = _executePlanned(
      serverId: serverId,
      request: resumedRequest,
      plan: plan,
      executionPlan: executionPlan,
      durableRunId: durableRun.id,
      targetWorkKey: targetWorkKey,
      workClass: workClass,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
    _inFlight = future;
    return await future.whenComplete(() => _inFlight = null);
  }

  Future<LibrarySyncState> _executePlanned({
    required int serverId,
    required LibrarySyncRequest request,
    required LibrarySyncPlan plan,
    required SyncExecutionPlan executionPlan,
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
      return await _finish(
        requestId: durableRunId,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.meteredPolicy,
        ),
        now: startedAt,

        state: LibrarySyncState(
          runRequestId: durableRunId,
          runAttemptId: activeAttemptId,
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: startedAt,
          planKind: plan.kind,
          planReason: 'networkPolicyDeferred',
          updatesAvailable: true,
        ),
      );
    }

    Future<LibrarySyncState> leaseHeld() async {
      return await _finish(
        requestId: durableRunId,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.leaseHeld,
        ),
        now: _now(),

        state: LibrarySyncState(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planKind: plan.kind,
          planReason: 'leaseHeld',
          pendingWorkCount: await _database.librarySyncDao.countPendingWork(
            serverId,
          ),
        ),
      );
    }

    try {
      return await _withLease(
        serverId: serverId,
        heartbeat: true,
        unavailable: leaseHeld,
        action: () async {
          final durableAttempt = await _database.librarySyncDao
              .beginSyncRunAttempt(
                requestId: durableRunId,
                androidWorker: _isBackgroundExecution,
                now: startedAt,
              );
          // A sharing engine already finished this request: do not run it
          // again. The deferral is then a no-op for a terminal request.
          if (durableAttempt == null) return await leaseHeld();
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
            allowedEndpoints: {
              for (final endpoint in executionPlan.budget.allowedEndpoints)
                ...endpoint.requestNames,
            },
            maxRequests: executionPlan.budget.maxRequests,
            maxNewestPages: executionPlan.budget.maxNewestPages,
            maxAlbumHydrations: executionPlan.budget.maxAlbumHydrations,
            maxResponseBytes: executionPlan.budget.maxResponseBytes,
            maxTotalBytes: executionPlan.budget.maxTotalBytes,
            maxConcurrency: executionPlan.budget.maxConcurrency,
            maxDuration: executionPlan.budget.maxDuration,
            now: _now,
            canRequest: () => _workAllowed(
              workClass,
              _syncPolicy,
              request,
              planKind: plan.kind,
            ),
            onStop: _executor.cancelSync,
          );
          final recorder = SyncAttemptRecorder(
            requestId: durableRunId,
            attemptId: durableAttempt.id,
            scope: scope,
            now: _now,
            write: (telemetry) => _database.librarySyncDao
                .writeAttemptTelemetry(durableAttempt.id, telemetry),
          );
          try {
            LibrarySyncState result;
            var explicitBudgetPartial = false;
            try {
              result = await scope.run(
                () => _executeDelegate(
                  executionPlan: executionPlan,
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
                  request.intent == SyncRunIntent.manualCatalogCheck &&
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
                await _markWorkFailure(
                  activeWork,
                  error.runtimeType.toString(),
                );
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
                result.hasBlockingPendingAlbums ||
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
            final pendingCount = await _database.librarySyncDao
                .countPendingWork(serverId);
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
              entityId: librarySyncTargetWorkKey(
                const LibrarySyncTarget.starred(),
              ),
            );
            final playlistsWork = await _database.librarySyncDao.getWork(
              serverId: serverId,
              kind: LibrarySyncPlanKind.targetedHydration.name,
              entityId: librarySyncTargetWorkKey(
                const LibrarySyncTarget.playlistHeaders(),
              ),
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
              await _enqueueCatalogFollowUp(
                serverId: serverId,
                result: result,
                now: startedAt,
              );
            }
            await recorder.finish(finalState);
            final finished = await _finish(
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
              state: finalState,
            );
            await _database.librarySyncDao.pruneSyncRunHistoryBefore(
              completedAt.subtract(const Duration(days: 90)),
            );
            await _database.librarySyncDao.pruneAttemptTelemetryBefore(
              completedAt.subtract(const Duration(days: 7)),
            );
            onProgress?.call(finished);
            return finished;
          } finally {
            await recorder.close();
          }
        },
      );
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
      return await _finish(
        requestId: durableRunId,
        attemptId: activeAttemptId,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.deferred,
          reason: SyncSafeReason.leaseHeld,
        ),
        state: LibrarySyncState(
          runRequestId: durableRunId,
          runAttemptId: activeAttemptId,
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: _now(),
          planKind: plan.kind,
          planReason: 'leaseHeld',
        ),
      );
    }
  }

  Future<T> _withLease<T>({
    required int serverId,
    required Future<T> Function() action,
    required Future<T> Function() unavailable,
    bool heartbeat = false,
  }) async {
    final ownerToken = _newLeaseToken();
    final bool acquired;
    try {
      acquired = await _database.librarySyncDao.acquireExecutionLease(
        serverId: serverId,
        ownerToken: ownerToken,
        ownerKind: _executionOwnerKind,
        now: _now(),
        ttl: _executionLeaseTtl,
      );
    } on Object catch (error) {
      // Another engine's long transaction (a worker promotion) holds the
      // writer lock: that is lease contention, not a sync failure.
      if (!isDatabaseLockTimeout(error)) rethrow;
      return await unavailable();
    }
    if (!acquired) return await unavailable();
    var leaseActive = true;
    final timer = heartbeat
        ? Timer.periodic(_executionLeaseHeartbeatInterval, (_) {
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
          })
        : null;
    try {
      return await SyncWriteFence(
        serverId: serverId,
        ownerToken: ownerToken,
        now: _now,
        renewalTtl: _executionLeaseTtl,
      ).run(action);
    } finally {
      leaseActive = false;
      timer?.cancel();
      await _database.librarySyncDao.releaseExecutionLease(
        serverId: serverId,
        ownerToken: ownerToken,
      );
    }
  }

  Future<LibrarySyncState> _finish({
    required int requestId,
    required SyncRunOutcome outcome,
    required LibrarySyncState state,
    int? attemptId,
    DateTime? now,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    await _database.librarySyncDao.completeSyncRun(
      requestId: requestId,
      attemptId: attemptId,
      outcome: outcome,
      now: now ?? _now(),
    );
    onProgress?.call(state);
    return state;
  }

  SyncExecutionPlan _executionPlanFor({
    required LibrarySyncRequest request,
    required LibrarySyncPlan plan,
    required SyncNetworkPolicy policy,
    required String? capabilitiesJson,
  }) {
    final kind = plan.kind;
    return SyncExecutionPlan(
      request: request,
      kind: kind,
      reason: _safeReasonForPlan(plan, policy),
      budget: executionBudgetFor(
        request: request,
        kind: kind,
        policy: policy,
        capabilitiesJson: capabilitiesJson,
      ),
    );
  }

  @visibleForTesting
  static SyncExecutionBudget executionBudgetFor({
    required LibrarySyncRequest request,
    required LibrarySyncPlanKind kind,
    required SyncNetworkPolicy policy,
    String? capabilitiesJson,
  }) {
    final meteredManual =
        kind == LibrarySyncPlanKind.deltaReconcile &&
        policy.isMetered &&
        request.grant == SyncNetworkGrant.boundedMeteredDiscovery;
    final endpoints = switch (kind) {
      LibrarySyncPlanKind.probe => const <SyncEndpoint>{SyncEndpoint.indexes},
      LibrarySyncPlanKind.deltaReconcile => const <SyncEndpoint>{
        SyncEndpoint.indexes,
        SyncEndpoint.newestAlbums,
        SyncEndpoint.artist,
        SyncEndpoint.album,
      },
      LibrarySyncPlanKind.fullRepair ||
      LibrarySyncPlanKind.catalogSnapshot => const <SyncEndpoint>{
        SyncEndpoint.catalogAlbums,
        SyncEndpoint.indexes,
        SyncEndpoint.newestAlbums,
        SyncEndpoint.artists,
        SyncEndpoint.artist,
        SyncEndpoint.album,
        SyncEndpoint.bulkSongs,
      },
      LibrarySyncPlanKind.compatibilityAudit => const <SyncEndpoint>{
        SyncEndpoint.newestAlbums,
        SyncEndpoint.indexes,
        SyncEndpoint.artists,
        SyncEndpoint.artist,
        SyncEndpoint.album,
      },
      LibrarySyncPlanKind.targetedHydration => switch (request.target.kind) {
        LibrarySyncTargetKind.starred => const <SyncEndpoint>{
          SyncEndpoint.starred,
        },
        LibrarySyncTargetKind.playlistHeaders => const <SyncEndpoint>{
          SyncEndpoint.playlists,
        },
        _ => const <SyncEndpoint>{
          SyncEndpoint.artist,
          SyncEndpoint.album,
          SyncEndpoint.playlists,
        },
      },
    };
    // Target and auxiliary operations retain their own execution budgets.
    final automatic =
        request.runHistoryIntent == SyncRunIntent.automaticCatalogCheck;
    var hasDiscoveryDebt = false;
    if (automatic && kind == LibrarySyncPlanKind.deltaReconcile) {
      try {
        final root = jsonDecode(capabilitiesJson ?? '');
        if (root is Map && root['navis'] is Map) {
          final debt = (root['navis'] as Map)['libraryDiscoveryDebtStreak'];
          hasDiscoveryDebt = debt is String && (int.tryParse(debt) ?? 0) > 0;
        }
      } on FormatException {
        // Missing or malformed evidence retains the ordinary page window.
      }
    }
    final boundedAlbums = automatic ? 32 : 64;
    final boundedRequests = automatic ? 96 : 200;
    final boundedBytes = automatic
        ? kMeteredSyncMaxInteractionBytes
        : 64 * 1024 * 1024;
    final boundedDuration = automatic
        ? const Duration(seconds: 30)
        : const Duration(minutes: 1);
    final limits = switch (kind) {
      LibrarySyncPlanKind.probe => (
        pages: 0,
        albums: boundedAlbums,
        responseBytes: 16 * 1024 * 1024,
        totalBytes: boundedBytes,
        requests: 1,
        duration: boundedDuration,
      ),
      LibrarySyncPlanKind.deltaReconcile => (
        pages: automatic && !hasDiscoveryDebt ? 2 : 5,
        albums: boundedAlbums,
        responseBytes: 16 * 1024 * 1024,
        totalBytes: boundedBytes,
        requests: boundedRequests,
        duration: boundedDuration,
      ),
      LibrarySyncPlanKind.catalogSnapshot || LibrarySyncPlanKind.fullRepair => (
        pages: 0,
        albums: 10000,
        responseBytes: 64 * 1024 * 1024,
        totalBytes: 512 * 1024 * 1024,
        requests: 10000,
        duration: const Duration(minutes: 10),
      ),
      LibrarySyncPlanKind.compatibilityAudit => (
        pages: 2,
        albums: boundedAlbums,
        responseBytes: 16 * 1024 * 1024,
        totalBytes: boundedBytes,
        requests: boundedRequests,
        duration: boundedDuration,
      ),
      LibrarySyncPlanKind.targetedHydration => (
        pages: 0,
        albums: boundedAlbums,
        responseBytes: 16 * 1024 * 1024,
        totalBytes: boundedBytes,
        requests: boundedRequests,
        duration: boundedDuration,
      ),
    };
    final broad =
        kind == LibrarySyncPlanKind.catalogSnapshot ||
        kind == LibrarySyncPlanKind.fullRepair;
    return SyncExecutionBudget(
      allowedEndpoints: endpoints,
      maxNewestPages: meteredManual ? 1 : limits.pages,
      maxAlbumHydrations: meteredManual ? 3 : limits.albums,
      maxResponseBytes: policy.isMetered
          ? kMeteredSyncMaxResponseBytes
          : limits.responseBytes,
      maxTotalBytes: policy.isMetered && !broad
          ? kMeteredSyncMaxInteractionBytes
          : limits.totalBytes,
      maxConcurrency: policy.isMetered
          ? 1
          : automatic
          ? 3
          : 6,
      maxRequests: limits.requests,
      maxDuration: limits.duration,
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

  Future<void> _enqueueCatalogFollowUp({
    required int serverId,
    required LibrarySyncState result,
    required DateTime now,
    LibrarySyncPlanKind kind = LibrarySyncPlanKind.deltaReconcile,
  }) async {
    final previous = await _database.librarySyncDao.getWork(
      serverId: serverId,
      kind: kind.name,
    );
    await _database.librarySyncDao.enqueueWork(
      serverId: serverId,
      kind: kind.name,
      entityId: '',
      evidenceVersion: result.probeEvidenceVersion,
      reactivateTerminal: previous?.status == 'completed',
      priority: kind == LibrarySyncPlanKind.deltaReconcile ? 50 : 40,
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
    if (result.probeIndexesUnsupported || result.probeIndexChanged == true) {
      await _enqueueCatalogFollowUp(
        serverId: serverId,
        result: result,
        now: now,
        kind: result.probeIndexesUnsupported
            ? LibrarySyncPlanKind.compatibilityAudit
            : LibrarySyncPlanKind.deltaReconcile,
      );
    }
  }

  Future<LibrarySyncState> _executeDelegate({
    required SyncExecutionPlan executionPlan,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) {
    final priorities = <String>{
      ...priorityAlbumIds,
      if (executionPlan.request.target.kind == LibrarySyncTargetKind.album &&
          executionPlan.request.target.entityId?.isNotEmpty == true)
        executionPlan.request.target.entityId!,
    };
    return _executor.executeSyncPlan(
      executionPlan,
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

  SyncCapabilityMode _indexesModeFromCapabilities(String? raw) {
    try {
      final root = jsonDecode(raw ?? '');
      if (root is Map && root['navis'] is Map) {
        final navis = root['navis'] as Map;
        if (navis['libraryIndexesUnsupportedAt'] != null) {
          return SyncCapabilityMode.unsupported;
        }
        final cursor = navis['libraryIndexesCursor'];
        if (cursor is String && DateTime.tryParse(cursor) != null) {
          return SyncCapabilityMode.reliable;
        }
      }
    } on FormatException {
      // Missing or malformed capability evidence leaves the mode unknown.
    }
    return SyncCapabilityMode.unknown;
  }

  String _workClassFor(LibrarySyncRequest request, LibrarySyncPlan plan) {
    final isInteractiveEntity =
        request.isInteraction && request.target.kind.requiresEntityId;
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
    required LibrarySyncPlanKind planKind,
  }) => librarySyncWorkAllowed(
    kind: planKind,
    workClass: workClass,
    request: request,
    policy: policy,
    isForeground: _readIsForeground(),
    hasActivePlayback: _readHasActivePlayback(),
    isBackgroundExecutor: _isBackgroundExecution,
  );

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
              (request.intent == SyncRunIntent.manualCatalogCheck &&
                  planKind == LibrarySyncPlanKind.probe))) {
        continue;
      }
      final workRequest = _requestFromWork(work, fallback: request);
      if (_workAllowed(
        work.workClass,
        policy,
        workRequest,
        planKind: planKind,
      )) {
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
    final mustDefer = !_workAllowed(
      work.workClass,
      policy,
      request,
      planKind: kind,
    );
    return LibrarySyncPlan(
      kind: kind,
      reason: 'resume${kind.name[0].toUpperCase()}${kind.name.substring(1)}',
      shouldExecute: !mustDefer,
      deferred: mustDefer,
    );
  }

  String? _workCheckpoint(LibrarySyncRequest request) {
    if (request.target.kind == LibrarySyncTargetKind.catalog &&
        request.intent != SyncRunIntent.manualCatalogCheck) {
      return null;
    }
    return jsonEncode(<String, String>{
      if (request.target.kind != LibrarySyncTargetKind.catalog)
        'targetKind': request.target.kind.name,
      if (request.intent == SyncRunIntent.manualCatalogCheck)
        'intent': 'checkForUpdates',
    });
  }

  LibrarySyncRequest _requestFromWork(
    LibrarySyncWorkTableData work, {
    required LibrarySyncRequest fallback,
  }) {
    Map<dynamic, dynamic>? checkpoint;
    try {
      final decoded = jsonDecode(work.checkpointJson ?? '');
      if (decoded is Map) checkpoint = decoded;
    } on FormatException {
      // Legacy work has no request provenance and retains the caller policy.
    }
    final manualDiscovery = checkpoint?['intent'] == 'checkForUpdates';
    return LibrarySyncRequest(
      origin: manualDiscovery
          ? SyncRunOrigin.libraryPullToRefresh
          : fallback.origin,
      intent: manualDiscovery
          ? SyncRunIntent.manualCatalogCheck
          : fallback.intent,
      target: _targetFromWork(work, checkpoint),
      grant: fallback.grant,
    );
  }

  LibrarySyncTarget _targetFromWork(
    LibrarySyncWorkTableData work,
    Map<dynamic, dynamic>? checkpoint,
  ) {
    final kindName = checkpoint?['targetKind'];
    if (kindName is String) {
      final kind = LibrarySyncTargetKind.values.where(
        (candidate) => candidate.name == kindName,
      );
      if (kind.isNotEmpty) {
        final targetKind = kind.first;
        return LibrarySyncTarget(
          targetKind,
          entityId: targetKind.requiresEntityId
              ? librarySyncTargetEntityIdFromWorkKey(targetKind, work.entityId)
              : null,
        );
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

  void cancelSync() {
    _cancellationGeneration++;
    _executor.cancelSync();
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
