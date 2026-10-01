import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/unavailable_review_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';

class SyncSettingsScreen extends ConsumerWidget {
  const new({super.key});

  /// Supported interval choices in minutes. 0 = manual only.
  static const List<int> _intervalChoices = [0, 15, 30, 60, 120, 360, 720];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final syncState = ref.watch(librarySyncControllerProvider);
    final syncPolicy = ref.watch(syncNetworkPolicyProvider);
    final backgroundUnmeteredOnly = ref.watch(
      backgroundSyncUnmeteredOnlyProvider,
    );
    final serverConfig = ref.watch(serverConfigStateProvider).asData?.value;
    final lastCatalogUpdate =
        syncState.lastCatalogUpdatedAt ??
        syncState.lastSyncedAt ??
        serverConfig?.lastSynced;
    final lastChecked = syncState.lastCheckedAt ?? syncState.completedAt;
    final isRunning = syncState.isRunning;
    final hasFailure = syncState.status == LibrarySyncStatus.failed;
    final currentInterval = ref.watch(syncIntervalMinutesProvider);
    final showUpdatesMessaging = _showUpdatesMessaging(syncState);
    final showMobileDataAction =
        syncPolicy.isMetered && showUpdatesMessaging && !isRunning;
    final awaitingDeletionConfirmation =
        syncState.candidateStatus == 'awaitingDeletionConfirmation' &&
        syncState.deletionCandidateCount > 0;
    final destructiveOperation = _lastDestructiveOperation(
      l10n,
      ref.watch(librarySyncOperationLedgerProvider).asData?.value ??
          const <LibrarySyncOperationLedgerTableData>[],
    );
    final androidBackgroundState = ref
        .watch(androidBackgroundSyncStatusProvider)
        .asData
        ?.value;
    final androidBackgroundAvailable = ref.watch(
      androidBackgroundSyncAvailableProvider,
    );
    final sectionGap = desktopMode
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          )
        : const SizedBox(height: 12);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !desktopMode,
        leading: desktopMode
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.settings),
              )
            : null,
        title: Text(l10n.syncSettingsTitle),
      ),
      body: Theme(
        data: desktopMode
            ? Theme.of(context).copyWith(
                cardTheme: const CardThemeData(
                  color: Colors.transparent,
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(),
                ),
              )
            : Theme.of(context),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                desktopMode ? 24 : 16,
                desktopMode ? 24 : 16,
                desktopMode ? 24 : 16,
                16,
              ),
              children: <Widget>[
                // ---- Sync status card ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.syncSettingsStatusLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _statusLabel(l10n, syncState),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (showUpdatesMessaging) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            syncPolicy.isMetered
                                ? l10n.syncSettingsUpdatesAvailableMetered
                                : l10n.syncSettingsUpdatesAvailable,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (hasFailure &&
                            syncState.errorMessage != null &&
                            syncState.errorMessage!
                                .trim()
                                .isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsFailureDescription,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (syncState.remainingVerificationCount >
                            0) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsRemainingVerification(
                              syncState.remainingVerificationCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (desktopMode)
                          _DesktopSyncStatusMetrics(
                            plan: syncState.planKind == null
                                ? null
                                : '${_humanize(syncState.planKind!.name)}\n'
                                      '${_humanize(syncState.planReason ?? 'selected by planner')}',
                            pendingWork: syncState.pendingWorkCount > 0
                                ? l10n.syncSettingsPendingWorkValue(
                                    syncState.pendingWorkCount,
                                  )
                                : null,
                            catalogApply: syncState.lastApplyDurationMs == null
                                ? null
                                : l10n.syncSettingsCatalogUpdateValue(
                                    syncState.lastApplyDurationMs!,
                                  ),
                            lastRun:
                                syncState.apiRequests > 0 ||
                                    syncState.lastRunBytes > 0
                                ? l10n.syncSettingsLastRunValue(
                                    syncState.apiRequests,
                                    _formatBytes(syncState.lastRunBytes),
                                  )
                                : null,
                            l10n: l10n,
                          )
                        else ...<Widget>[
                          if (syncState.planKind != null) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              l10n.syncSettingsStrategy(
                                _humanize(syncState.planKind!.name),
                                _humanize(
                                  syncState.planReason ?? 'selected by planner',
                                ),
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          if (syncState.pendingWorkCount > 0) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              l10n.syncSettingsPendingWork(
                                syncState.pendingWorkCount,
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                        if (syncState.candidateGeneration != null &&
                            syncState.candidateStatus != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsCandidate(
                              syncState.candidateGeneration!,
                              _humanize(syncState.candidateStatus!),
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (awaitingDeletionConfirmation) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsRepairDeletionConfirmationPending(
                              syncState.deletionCandidateCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (syncState.carriedForwardEntityCount >
                            0) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsCarriedForward(
                              syncState.carriedForwardEntityCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (!desktopMode &&
                            syncState.lastApplyDurationMs != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsApplyDuration(
                              syncState.lastApplyDurationMs!,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (syncState.failureCategory != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsDegradation(
                              _humanize(syncState.failureCategory!),
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (!desktopMode &&
                            (syncState.apiRequests > 0 ||
                                syncState.lastRunBytes > 0)) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsUsage(
                              syncState.apiRequests,
                              _formatBytes(syncState.lastRunBytes),
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (syncState.canonicalizedSongCount > 0 ||
                            syncState.ambiguousMatchCount > 0) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsIdentitySummary(
                              syncState.canonicalizedSongCount,
                              syncState.ambiguousMatchCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (destructiveOperation != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsLastLibraryChangeLabel,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            destructiveOperation.summary,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            _formatTimestamp(
                              context,
                              l10n,
                              destructiveOperation.occurredAt,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                sectionGap,

                // ---- Domain freshness card ----
                Card(
                  child: Column(
                    children: <Widget>[
                      ListTile(
                        title: Text(l10n.syncSettingsLastCheckedLabel),
                        subtitle: Text(
                          _formatTimestamp(context, l10n, lastChecked),
                        ),
                      ),
                      ListTile(
                        title: Text(l10n.syncSettingsNextAutomaticCheckLabel),
                        subtitle: Text(
                          currentInterval <= 0
                              ? l10n.syncSettingsIntervalManual
                              : syncState.nextAutomaticCheckAt == null
                              ? l10n.syncSettingsNextAutomaticCheckScheduling
                              : _formatTimestamp(
                                  context,
                                  l10n,
                                  syncState.nextAutomaticCheckAt,
                                ),
                        ),
                      ),
                      if (syncState.nextRetryAt != null)
                        ListTile(
                          title: Text(l10n.syncSettingsNextRetryLabel),
                          subtitle: Text(
                            _formatTimestamp(
                              context,
                              l10n,
                              syncState.nextRetryAt,
                            ),
                          ),
                        ),
                      ListTile(
                        title: Text(l10n.syncSettingsLastCatalogUpdateLabel),
                        subtitle: Text(
                          '${_formatTimestamp(context, l10n, lastCatalogUpdate)}'
                          ' • ${_freshnessLabel(l10n, syncState.freshness)}',
                        ),
                      ),
                      ListTile(
                        title: Text(l10n.syncSettingsLastAuxiliaryUpdateLabel),
                        subtitle: Text(
                          _formatTimestamp(
                            context,
                            l10n,
                            syncState.lastAuxiliarySyncedAt,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                sectionGap,

                if (androidBackgroundAvailable &&
                    serverConfig != null) ...<Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.syncSettingsAndroidBackgroundTitle,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (androidBackgroundState
                                  ?.androidBackgroundSyncEnabled !=
                              true)
                            Text(
                              l10n.syncSettingsAndroidBackgroundDisabled,
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          else if (currentInterval <= 0)
                            Text(
                              l10n.syncSettingsAndroidBackgroundManual,
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          else
                            Text(
                              l10n.syncSettingsAndroidBackgroundCadence(
                                androidBackgroundState
                                        ?.androidRequestedIntervalMinutes ??
                                    currentInterval,
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (androidBackgroundState?.androidWorkState ==
                                  'blocked' &&
                              backgroundUnmeteredOnly) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              l10n.syncSettingsAndroidBackgroundWaitingUnmetered,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            l10n.syncSettingsAndroidBackgroundLastAttempt,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            androidBackgroundState?.androidWorkerCompletedAt ==
                                    null
                                ? l10n.syncSettingsAndroidBackgroundNoAttempt
                                : _formatTimestamp(
                                    context,
                                    l10n,
                                    androidBackgroundState!
                                        .androidWorkerCompletedAt,
                                  ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (androidBackgroundState?.androidWorkerResult !=
                              null) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              l10n.syncSettingsAndroidBackgroundOutcome(
                                _humanize(
                                  androidBackgroundState!.androidWorkerResult!,
                                ),
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  sectionGap,
                ],

                // ---- Mobile sync guardrails ----
                Card(
                  child: SwitchListTile(
                    value: backgroundUnmeteredOnly,
                    onChanged: (enabled) async {
                      final dao = ref
                          .read(navisDatabaseProvider)
                          .appSettingsDao;
                      await dao.updateBackgroundSyncUnmeteredOnly(
                        enabled: enabled,
                      );
                    },
                    title: Text(l10n.syncSettingsBackgroundUnmeteredOnlyLabel),
                    subtitle: Text(
                      l10n.syncSettingsBackgroundUnmeteredOnlyDescription,
                    ),
                  ),
                ),
                sectionGap,

                // ---- Sync interval picker ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.syncSettingsIntervalLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.syncSettingsIntervalDescription,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        sectionGap,
                        DropdownButtonFormField<int>(
                          initialValue:
                              _intervalChoices.contains(currentInterval)
                              ? currentInterval
                              : 60,
                          decoration: const InputDecoration(isDense: true),
                          items: _intervalChoices
                              .map(
                                (minutes) => DropdownMenuItem<int>(
                                  value: minutes,
                                  child: Text(_intervalLabel(l10n, minutes)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) async {
                            if (value == null) return;
                            final dao = ref
                                .read(navisDatabaseProvider)
                                .appSettingsDao;
                            await dao.updateSyncIntervalMinutes(value);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                OutlinedButton.icon(
                  onPressed: isRunning
                      ? null
                      : () => ref
                            .read(librarySyncControllerProvider.notifier)
                            .syncNow(),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.syncSettingsCheckForUpdates),
                ),
                if (showMobileDataAction) ...<Widget>[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      await ref
                          .read(librarySyncControllerProvider.notifier)
                          .syncUsingMobileData();
                    },
                    icon: const Icon(Icons.signal_cellular_alt),
                    label: Text(l10n.syncSettingsSyncUsingMobileData),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: isRunning
                      ? null
                      : () =>
                            _repairLibrary(context, ref, syncPolicy.isMetered),
                  icon: const Icon(Icons.sync),
                  label: Text(
                    isRunning
                        ? l10n.syncSettingsRepairLibraryMetadataRunning
                        : l10n.syncSettingsRepairLibraryMetadata,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.syncSettingsRepairLibraryMetadataDescription,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (awaitingDeletionConfirmation) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: isRunning
                        ? null
                        : () => _discardRepairCandidate(context, ref),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.syncSettingsRepairDiscardCandidate),
                  ),
                ],
                if (isRunning) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => ref
                        .read(librarySyncControllerProvider.notifier)
                        .cancelSync(),
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(l10n.commonCancel),
                  ),
                ],
                if (hasFailure) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: isRunning
                        ? null
                        : () async {
                            await ref
                                .read(librarySyncControllerProvider.notifier)
                                .syncNow();
                          },
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.commonRetry),
                  ),
                ],
                const SizedBox(height: 8),
                UnavailableReviewEntry(serverId: serverConfig?.id),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _repairLibrary(
    BuildContext context,
    WidgetRef ref,
    bool isMetered,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final syncState = ref.read(librarySyncControllerProvider);
    final awaitingDeletionConfirmation =
        syncState.candidateStatus == 'awaitingDeletionConfirmation' &&
        syncState.deletionCandidateCount > 0;
    if (awaitingDeletionConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.syncSettingsRepairDeletionConfirmationTitle),
          content: Text(
            l10n.syncSettingsRepairDeletionConfirmationBody(
              syncState.deletionCandidateCount,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.syncSettingsRepairDeletionConfirmationAction),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      if (!context.mounted) {
        return;
      }
    }
    var allowMeteredBroadOverride = false;
    if (isMetered) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.syncSettingsRepairMeteredConfirmTitle),
          content: Text(l10n.syncSettingsRepairMeteredConfirmBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.syncSettingsRepairMeteredConfirmAction),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      allowMeteredBroadOverride = true;
    }
    if (!context.mounted) return;
    // Ordinary repair runs in the background from here: the persistent status
    // card below reports progress and offers Retry/Cancel, so the user stays
    // in control and is never forced out to a blocking rebuild screen.
    unawaited(
      ref
          .read(librarySyncControllerProvider.notifier)
          .repairLibrary(allowMeteredBroadOverride: allowMeteredBroadOverride),
    );
  }

  Future<void> _discardRepairCandidate(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.syncSettingsRepairDiscardCandidateTitle),
        content: Text(l10n.syncSettingsRepairDiscardCandidateBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.syncSettingsRepairDiscardCandidate),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await ref
          .read(librarySyncControllerProvider.notifier)
          .discardAwaitingRepairCandidate();
    }
  }

  static bool _showUpdatesMessaging(LibrarySyncState state) {
    return state.updatesAvailable || _hasDeferredBroadWork(state);
  }

  static bool _hasDeferredBroadWork(LibrarySyncState state) {
    if (state.status != LibrarySyncStatus.deferred) {
      return false;
    }
    final planKind = state.planKind;
    if (planKind == null) {
      return false;
    }
    return switch (planKind) {
      LibrarySyncPlanKind.catalogSnapshot ||
      LibrarySyncPlanKind.fullRepair ||
      LibrarySyncPlanKind.deltaReconcile ||
      LibrarySyncPlanKind.compatibilityAudit => true,
      _ => false,
    };
  }

  String _statusLabel(AppLocalizations l10n, LibrarySyncState state) {
    return switch (state.status) {
      LibrarySyncStatus.running => l10n.librarySyncRunning,
      LibrarySyncStatus.succeeded => l10n.syncSettingsStatusSucceeded,
      LibrarySyncStatus.partial => l10n.syncSettingsStatusPartial,
      LibrarySyncStatus.failed => l10n.syncSettingsStatusFailed,
      LibrarySyncStatus.skipped => l10n.syncSettingsStatusIdle,
      LibrarySyncStatus.deferred => l10n.syncSettingsStatusDeferred,
      LibrarySyncStatus.cancelled => l10n.syncSettingsStatusCancelled,
      LibrarySyncStatus.idle => l10n.syncSettingsStatusIdle,
    };
  }

  String _freshnessLabel(
    AppLocalizations l10n,
    LibrarySyncFreshness freshness,
  ) {
    return switch (freshness) {
      LibrarySyncFreshness.current => l10n.syncSettingsFreshnessCurrent,
      LibrarySyncFreshness.verificationPending =>
        l10n.syncSettingsFreshnessPending,
      LibrarySyncFreshness.repairRecommended =>
        l10n.syncSettingsFreshnessRepair,
    };
  }

  String _intervalLabel(AppLocalizations l10n, int minutes) {
    if (minutes <= 0) return l10n.syncSettingsIntervalManual;
    if (minutes < 60) return l10n.syncSettingsIntervalMinutes(minutes);
    final hours = minutes ~/ 60;
    return l10n.syncSettingsIntervalHours(hours);
  }

  String _formatTimestamp(
    BuildContext context,
    AppLocalizations l10n,
    DateTime? value,
  ) {
    if (value == null) {
      return l10n.syncSettingsNeverSynced;
    }
    final material = MaterialLocalizations.of(context);
    return '${material.formatFullDate(value)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  String _humanize(String value) {
    for (final kind in LibrarySyncPlanKind.values) {
      // Older persisted resume reasons combined the prefix and enum value
      // without a camel-case boundary (for example, `resumetargetedHydration`).
      // Keep those statuses readable after the write-side format is corrected.
      if (value == 'resume${kind.name}') {
        return 'resume ${_humanize(kind.name)}';
      }
    }
    return value
        .replaceAllMapped(
          RegExp('([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)} ${match.group(2)}',
        )
        .replaceAll('_', ' ')
        .toLowerCase();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  _DestructiveOperation? _lastDestructiveOperation(
    AppLocalizations l10n,
    List<LibrarySyncOperationLedgerTableData> operations,
  ) {
    for (final operation in operations) {
      final removed = _removedCounts(operation.detailsJson);
      if (removed == null || removed.total == 0) {
        continue;
      }
      final summary = switch (operation.operation) {
        'catalogPromotion' => l10n.syncSettingsCatalogPromotionRemovalSummary(
          removed.artists,
          removed.albums,
          removed.songs,
        ),
        'starredReconciliation' =>
          l10n.syncSettingsStarredReconciliationRemovalSummary(
            removed.artists,
            removed.albums,
            removed.songs,
          ),
        _ => null,
      };
      if (summary != null) {
        return _DestructiveOperation(
          summary: summary,
          occurredAt: operation.occurredAt,
        );
      }
    }
    return null;
  }

  _OperationCounts? _removedCounts(String detailsJson) {
    try {
      final decoded = jsonDecode(detailsJson);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final removed = decoded['removed'];
      if (removed is! Map<String, Object?>) {
        return null;
      }
      return _OperationCounts(
        artists: _asCount(removed['artists']),
        albums: _asCount(removed['albums']),
        songs: _asCount(removed['songs']),
      );
    } on FormatException {
      return null;
    }
  }

  int _asCount(Object? value) {
    if (value is int) {
      return value < 0 ? 0 : value;
    }
    if (value is num) {
      return value < 0 ? 0 : value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }
}

class _DesktopSyncStatusMetrics extends StatelessWidget {
  const new({
    required this.l10n,
    this.plan,
    this.pendingWork,
    this.catalogApply,
    this.lastRun,
  });

  final AppLocalizations l10n;
  final String? plan;
  final String? pendingWork;
  final String? catalogApply;
  final String? lastRun;

  @override
  Widget build(BuildContext context) {
    final metrics = <({String label, String value})>[
      if (plan != null) (label: l10n.syncSettingsPlanLabel, value: plan!),
      if (pendingWork != null)
        (label: l10n.syncSettingsPendingWorkLabel, value: pendingWork!),
      if (catalogApply != null)
        (label: l10n.syncSettingsCatalogUpdateLabel, value: catalogApply!),
      if (lastRun != null)
        (label: l10n.syncSettingsLastRunLabel, value: lastRun!),
    ];
    if (metrics.isEmpty) {
      return const SizedBox.shrink();
    }

    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columnCount = constraints.maxWidth >= 840 ? 4 : 2;
          const gap = 24.0;
          final itemWidth =
              (constraints.maxWidth - gap * (columnCount - 1)) / columnCount;
          return Wrap(
            spacing: gap,
            runSpacing: 16,
            children: metrics
                .map(
                  (metric) => SizedBox(
                    width: itemWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          metric.label,
                          style: textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(metric.value, style: textTheme.bodyMedium),
                      ],
                    ),
                  ),
                )
                .toList(growable: false),
          );
        },
      ),
    );
  }
}

class _DestructiveOperation {
  const new({required this.summary, required this.occurredAt});

  final String summary;
  final DateTime occurredAt;
}

class _OperationCounts {
  const new({required this.artists, required this.albums, required this.songs});

  final int artists;
  final int albums;
  final int songs;

  int get total => artists + albums + songs;
}

/// Entry point for the unavailable-items review list with a live count.
class UnavailableReviewEntry extends ConsumerWidget {
  const new({super.key, required this.serverId});

  final int? serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final pendingCount = ref
        .watch(pendingUnavailableCountProvider)
        .asData
        ?.value;
    return TextButton.icon(
      onPressed: serverId == null
          ? null
          : () => NavService.openUnavailableItems(context, ref),
      icon: const Icon(Icons.playlist_remove),
      label: Text(
        pendingCount != null && pendingCount > 0
            ? l10n.unavailableReviewEntryWithCount(pendingCount)
            : l10n.unavailableReviewEntry,
      ),
    );
  }
}
