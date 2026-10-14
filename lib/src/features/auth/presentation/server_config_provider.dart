import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

final secureCredentialStoreProvider = Provider<SecureCredentialStore>((ref) {
  final backing = FlutterSecureCredentialStore();
  const diagnosticsEnabled = bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS');
  const diagnosticsMode = String.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS_MODE');
  if (diagnosticsEnabled && diagnosticsMode == 'clone') {
    // An explicitly isolated Android sidecar can exercise the real headless
    // worker, which reads platform secure storage in another Flutter engine.
    // Ordinary clone diagnostics continue to keep credentials in memory.
    if (Platform.isAndroid &&
        const bool.fromEnvironment(
          'NAVIS_DIAGNOSTICS_ANDROID_WORKER_FIXTURE',
        ) &&
        const String.fromEnvironment('NAVIS_APP_ID_SUFFIX').isNotEmpty) {
      return backing;
    }
    const credentialPath = String.fromEnvironment(
      'NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH',
    );
    return CloneDiagnosticsCredentialStore(
      backing,
      credentialPath: credentialPath,
    );
  }
  return backing;
});

/// The server profile kept on this device, signed in or not (address and
/// username; never the password). Login offers it after a keep-data sign-out
/// or when the saved password can no longer be read.
final retainedServerProvider = FutureProvider.autoDispose<ServerConfigModel?>(
  (ref) => ref.watch(serverConfigRepositoryProvider).getRetainedServer(),
);

final serverConfigRepositoryProvider = Provider<ServerConfigRepository>((ref) {
  final database = ref.watch(navisDatabaseProvider);
  final credentials = ref.watch(secureCredentialStoreProvider);
  return ServerConfigRepository(database, credentials: credentials);
});

class ServerConfigNotifier extends AsyncNotifier<ServerConfigModel?> {
  StreamSubscription<ServerConfigModel?>? _subscription;

  @override
  Future<ServerConfigModel?> build() async {
    final repository = ref.watch(serverConfigRepositoryProvider);
    _subscription ??= repository.watchActiveServer().listen(
      (server) => state = AsyncData(server),
      onError: (Object error, StackTrace stackTrace) {
        if (error is CredentialReadException && state.value != null) {
          AppLogger.warning(
            'Secure credential stream read failed; keeping the active session.',
          );
          return;
        }
        // During bootstrap, the getActiveServer future owns error reporting
        // and provider backoff. A stream error must not bypass those retries.
        if (!state.isLoading) {
          state = AsyncError(error, stackTrace);
        }
      },
    );
    ref.onDispose(() {
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    return await repository.getActiveServer();
  }

  Future<void> refresh() async {
    final repository = ref.read(serverConfigRepositoryProvider);
    state = AsyncData(await repository.getActiveServer());
  }

  Future<void> save(ServerConfigModel config) async {
    final repository = ref.read(serverConfigRepositoryProvider);
    await repository.save(config);
    await refresh();
    if (ref.exists(audioBootstrapControllerProvider)) {
      ref.read(audioBootstrapControllerProvider.notifier).ensureInitialized();
    }
  }

  Future<void> updateLastSynced(DateTime value) async {
    final repository = ref.read(serverConfigRepositoryProvider);
    await repository.updateLastSynced(value);
    await refresh();
  }

  Future<void> updateSyncTimestamps({
    required DateTime lastSynced,
    DateTime? lastFullSyncedAt,
  }) async {
    final repository = ref.read(serverConfigRepositoryProvider);
    await repository.updateSyncTimestamps(
      lastSynced: lastSynced,
      lastFullSyncedAt: lastFullSyncedAt,
    );
    await refresh();
  }
}

final serverConfigProvider =
    AsyncNotifierProvider<ServerConfigNotifier, ServerConfigModel?>(
      ServerConfigNotifier.new,
    );

final serverConfigStateProvider = Provider<AsyncValue<ServerConfigModel?>>((
  ref,
) {
  return ref.watch(serverConfigProvider);
});
