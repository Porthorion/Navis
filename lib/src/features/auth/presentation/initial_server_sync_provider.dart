import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class InitialSyncCompletionWarningController extends Notifier<bool> {
  @override
  bool build() => false;

  void show() => state = true;

  void consume() => state = false;
}

final initialSyncCompletionWarningProvider =
    NotifierProvider<InitialSyncCompletionWarningController, bool>(
      InitialSyncCompletionWarningController.new,
    );

/// Runs the catalog pass for first setup.
///
/// Waits for active catalog work before checking the committed generation.
/// Without a committed catalog the planner already schedules its first-catalog
/// snapshot. Once a catalog exists (for example after an interrupted setup
/// followed by a keep-data sign-out and sign-in) the same request plans
/// bounded incremental discovery instead. That pass never publishes a catalog
/// and stops at its per-run budgets, so it cannot produce the completion or
/// usable-partial evidence first setup requires, and every retry would stay on
/// the full-screen route. Setup then runs the explicit full scan used by cache
/// upgrade, which publishes the catalog in its own run.
Future<LibrarySyncState> runInitialCatalogSync(
  Ref ref, {
  required bool allowMeteredBroadOverride,
}) async {
  final sync = ref.read(librarySyncControllerProvider.notifier);
  await sync.waitForActiveCatalogSync();
  final config = ref.read(serverConfigStateProvider).asData?.value;
  final serverId = config?.id;
  final hasCommittedCatalog =
      config?.lastSynced != null ||
      (serverId != null &&
          (await ref
                      .read(navisDatabaseProvider)
                      .librarySyncDao
                      .getOrCreateState(serverId))
                  .currentGeneration >
              0);
  return await (hasCommittedCatalog
      ? sync.forceFullSync(allowMeteredBroadOverride: allowMeteredBroadOverride)
      : sync.syncNow(allowMeteredBroadOverride: allowMeteredBroadOverride));
}
