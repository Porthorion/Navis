import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

class InitialServerSyncScreen extends ConsumerWidget {
  const InitialServerSyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final setup = ref.watch(initialServerSyncControllerProvider);
    final sync = ref.watch(librarySyncControllerProvider);
    final controller = ref.read(initialServerSyncControllerProvider.notifier);
    final running = setup.status == InitialServerSyncStatus.running;
    final cancelling = setup.status == InitialServerSyncStatus.cancelling;
    final total = sync.total ?? 0;
    final processed = sync.processed ?? 0;
    final progress = running && total > 0
        ? (processed / total).clamp(0.0, 1.0)
        : null;

    return PopScope<void>(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Card(
                  key: const ValueKey<String>('initialSyncCard'),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Center(child: NavisIcon(size: 72)),
                        const SizedBox(height: 24),
                        Text(
                          l10n.initialSyncTitle,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.initialSyncDoNotClose,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),
                        Semantics(
                          key: const ValueKey<String>(
                            'initialSyncProgressSemantics',
                          ),
                          label: _statusText(l10n, setup, sync),
                          value: total > 0 ? '$processed / $total' : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              LinearProgressIndicator(
                                value: running ? progress : 0,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _statusText(l10n, setup, sync),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        if (setup.errorMessage case final error?) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            error,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        if (setup.status ==
                            InitialServerSyncStatus.waitingForMobileConsent)
                          FilledButton(
                            key: const ValueKey<String>(
                              'initialSyncUseMobileDataButton',
                            ),
                            onPressed: controller.startUsingMobileData,
                            child: Text(l10n.initialSyncUseMobileData),
                          )
                        else if (setup.status ==
                                InitialServerSyncStatus.failed ||
                            setup.status ==
                                InitialServerSyncStatus.waitingForNetwork)
                          FilledButton(
                            key: const ValueKey<String>(
                              'initialSyncRetryButton',
                            ),
                            onPressed: controller.retry,
                            child: Text(l10n.commonRetry),
                          ),
                        const SizedBox(height: 8),
                        TextButton(
                          key: const ValueKey<String>(
                            'initialSyncCancelButton',
                          ),
                          onPressed: cancelling
                              ? null
                              : controller.cancelAndLogOut,
                          child: Text(
                            cancelling
                                ? l10n.initialSyncCancelling
                                : l10n.initialSyncCancelAndLogout,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusText(
    AppLocalizations l10n,
    InitialServerSyncState setup,
    LibrarySyncState sync,
  ) {
    return switch (setup.status) {
      InitialServerSyncStatus.waitingForNetwork =>
        l10n.initialSyncWaitingForNetwork,
      InitialServerSyncStatus.waitingForMobileConsent =>
        l10n.initialSyncMobileDataRequired,
      InitialServerSyncStatus.failed => l10n.initialSyncFailed,
      InitialServerSyncStatus.cancelling => l10n.initialSyncCancelling,
      InitialServerSyncStatus.complete => l10n.initialSyncComplete,
      InitialServerSyncStatus.idle => l10n.librarySyncStagePreparing,
      InitialServerSyncStatus.running => switch (sync.stage) {
        LibrarySyncStage.fetchingArtists => l10n.librarySyncStageArtists,
        LibrarySyncStage.fetchingAlbums => l10n.librarySyncStageAlbums,
        LibrarySyncStage.persistingMetadata => l10n.librarySyncStagePersisting,
        LibrarySyncStage.fetchingSongs => l10n.librarySyncStageSongs,
        LibrarySyncStage.fetchingGenres => l10n.librarySyncStageGenres,
        LibrarySyncStage.fetchingPlaylists => l10n.librarySyncStagePlaylists,
        LibrarySyncStage.finalizing => l10n.librarySyncStageFinalizing,
        _ => l10n.librarySyncStagePreparing,
      },
    };
  }
}
