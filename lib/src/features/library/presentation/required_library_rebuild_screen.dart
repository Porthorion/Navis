import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/routing/app_routes.dart';

class RequiredLibraryRebuildScreen extends ConsumerStatefulWidget {
  const new({
    required this.reason,
    this.allowMeteredBroadOverride = false,
    this.homeWarmupEligible = false,
    super.key,
  });

  final RequiredLibraryRebuildReason reason;
  final bool allowMeteredBroadOverride;
  final bool homeWarmupEligible;

  @override
  ConsumerState<RequiredLibraryRebuildScreen> createState() =>
      _RequiredLibraryRebuildScreenState();
}

class _RequiredLibraryRebuildScreenState
    extends ConsumerState<RequiredLibraryRebuildScreen> {
  bool _navigatedHome = false;

  @override
  void initState() {
    super.initState();
    if (widget.allowMeteredBroadOverride) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          ref
              .read(
                requiredLibraryRebuildControllerProvider(widget.reason)
                    .notifier,
              )
              .startUsingMobileData(),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rebuild = ref.watch(
      requiredLibraryRebuildControllerProvider(widget.reason),
    );
    final sync = ref.watch(librarySyncControllerProvider);
    final controller = ref.read(
      requiredLibraryRebuildControllerProvider(widget.reason).notifier,
    );
    final warmupEligible =
        widget.reason == RequiredLibraryRebuildReason.cacheUpgrade ||
        widget.reason == RequiredLibraryRebuildReason.initialLogin;
    final onboardingRequired = warmupEligible
        ? ref.watch(onboardingRequiredProvider)
        : false;
    if (rebuild.status == RequiredLibraryRebuildStatus.complete &&
        onboardingRequired != null &&
        !_navigatedHome) {
      _navigatedHome = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final shouldWarmHome =
              warmupEligible && onboardingRequired && widget.homeWarmupEligible;
          context.go(
            onboardingRequired
                ? (shouldWarmHome
                      ? '${AppRoutes.onboarding}?homeWarmup=1'
                      : AppRoutes.onboarding)
                : AppRoutes.home,
          );
        }
      });
    }

    final running = rebuild.status == RequiredLibraryRebuildStatus.syncing;
    final total = sync.total;
    final processed = sync.processed;
    final progress = running && total != null && total > 0 && processed != null
        ? (processed / total).clamp(0.0, 1.0)
        : null;
    final status = _statusText(l10n, rebuild, sync);
    final isInitial =
        widget.reason == RequiredLibraryRebuildReason.initialLogin;
    final isRepair =
        widget.reason == RequiredLibraryRebuildReason.repairLibrary;

    return PopScope<void>(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Semantics(
                    key: const ValueKey<String>(
                      'requiredSyncProgressSemantics',
                    ),
                    liveRegion: true,
                    label: status,
                    value: total != null && processed != null
                        ? '$processed / $total'
                        : null,
                    child: SizedBox.square(
                      dimension: 144,
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          SizedBox.square(
                            key: const ValueKey<String>(
                              'requiredSyncProgressRing',
                            ),
                            dimension: 128,
                            child: CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 7,
                            ),
                          ),
                          const NavisIcon(size: 132),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    isInitial
                        ? l10n.requiredSyncInitialTitle
                        : isRepair
                        ? l10n.requiredSyncRepairTitle
                        : l10n.requiredSyncRebuildTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isInitial
                        ? l10n.requiredSyncInitialBody
                        : isRepair
                        ? l10n.requiredSyncRepairBody
                        : l10n.requiredSyncRebuildBody,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  Text(
                    status,
                    key: const ValueKey<String>('requiredSyncStatusText'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_failureDetail(l10n, rebuild)
                      case final error?) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  if (rebuild.status ==
                      RequiredLibraryRebuildStatus.waitingForMobileConsent)
                    FilledButton(
                      key: const ValueKey<String>('requiredSyncUseMobileData'),
                      onPressed: controller.startUsingMobileData,
                      child: Text(l10n.initialSyncUseMobileData),
                    )
                  else if (rebuild.status ==
                          RequiredLibraryRebuildStatus.failed ||
                      rebuild.status ==
                          RequiredLibraryRebuildStatus.waitingForNetwork)
                    FilledButton(
                      key: const ValueKey<String>('requiredSyncRetry'),
                      onPressed: controller.retry,
                      child: Text(l10n.commonRetry),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey<String>('requiredSyncSignOut'),
                    onPressed:
                        rebuild.status ==
                            RequiredLibraryRebuildStatus.cancelling
                        ? null
                        : controller.cancelAndSignOut,
                    child: Text(
                      isInitial
                          ? l10n.requiredSyncCancelAndSignOut
                          : l10n.requiredSyncSignOut,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The server's own explanation, or why the rebuild could not finish when
  /// that is more than "it did not complete" (which the status already says).
  String? _failureDetail(
    AppLocalizations l10n,
    RequiredLibraryRebuildState rebuild,
  ) {
    if (rebuild.status != RequiredLibraryRebuildStatus.failed) return null;
    return rebuild.errorMessage ??
        switch (rebuild.failure) {
          RequiredLibraryRebuildFailure.cacheResetFailed =>
            l10n.requiredSyncFailureCacheReset,
          RequiredLibraryRebuildFailure.cacheRenewalPending =>
            l10n.requiredSyncFailureCacheRenewal,
          RequiredLibraryRebuildFailure.signOutFailed =>
            l10n.requiredSyncFailureSignOut,
          RequiredLibraryRebuildFailure.incomplete || null => null,
        };
  }

  String _statusText(
    AppLocalizations l10n,
    RequiredLibraryRebuildState rebuild,
    LibrarySyncState sync,
  ) {
    return switch (rebuild.status) {
      RequiredLibraryRebuildStatus.waitingForNetwork =>
        l10n.initialSyncWaitingForNetwork,
      RequiredLibraryRebuildStatus.waitingForMobileConsent =>
        l10n.initialSyncMobileDataRequired,
      RequiredLibraryRebuildStatus.clearingCache =>
        l10n.requiredSyncClearingCache,
      RequiredLibraryRebuildStatus.failed =>
        widget.reason == RequiredLibraryRebuildReason.initialLogin
            ? l10n.initialSyncFailed
            : l10n.requiredSyncRebuildFailed,
      RequiredLibraryRebuildStatus.cancelling => l10n.initialSyncCancelling,
      RequiredLibraryRebuildStatus.complete => l10n.initialSyncComplete,
      RequiredLibraryRebuildStatus.idle => l10n.requiredSyncStagePreparing,
      RequiredLibraryRebuildStatus.syncing => switch (sync.stage) {
        LibrarySyncStage.fetchingArtists => l10n.requiredSyncStageArtistIndex,
        LibrarySyncStage.fetchingSongs => l10n.requiredSyncStageSongIndex,
        LibrarySyncStage.fetchingAlbums ||
        LibrarySyncStage.persistingMetadata ||
        LibrarySyncStage.collectingCandidate => l10n.requiredSyncStageAlbums,
        LibrarySyncStage.validatingCandidate ||
        LibrarySyncStage.applyingCandidate ||
        LibrarySyncStage.cleaningCandidate ||
        LibrarySyncStage.finalizing => l10n.requiredSyncStageFinalizing,
        LibrarySyncStage.fetchingStarred ||
        LibrarySyncStage.fetchingPlaylists => l10n.requiredSyncStageSongs,
        _ => l10n.requiredSyncStagePreparing,
      },
    };
  }
}
