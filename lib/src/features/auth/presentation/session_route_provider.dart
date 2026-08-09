import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

enum SessionRoutePhase { loading, unauthenticated, initialSyncRequired, ready }

final initialSyncRequiredProvider = FutureProvider<bool>((ref) async {
  final config = ref.watch(serverConfigStateProvider).asData?.value;
  if (config == null) {
    return false;
  }
  if (config.lastSynced != null) {
    return false;
  }
  final serverId = config.id;
  if (serverId == null) {
    return true;
  }
  final persisted = await ref
      .watch(navisDatabaseProvider)
      .librarySyncDao
      .getOrCreateState(serverId);
  return persisted.currentGeneration <= 0;
});

final sessionRoutePhaseProvider = Provider<SessionRoutePhase>((ref) {
  final config = ref.watch(serverConfigStateProvider);
  if (config.isLoading && !config.hasValue) {
    return SessionRoutePhase.loading;
  }
  if (config.asData?.value == null) {
    return SessionRoutePhase.unauthenticated;
  }
  final initialRequired = ref.watch(initialSyncRequiredProvider);
  return initialRequired.when(
    data: (required) => required
        ? SessionRoutePhase.initialSyncRequired
        : SessionRoutePhase.ready,
    loading: () => SessionRoutePhase.loading,
    error: (_, _) => SessionRoutePhase.initialSyncRequired,
  );
});
