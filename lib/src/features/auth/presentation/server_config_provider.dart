import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/providers/app_providers.dart';

final secureCredentialStoreProvider = Provider<SecureCredentialStore>((ref) {
  return const FlutterSecureCredentialStore();
});

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
    _subscription ??= repository.watchActiveServer().listen((server) {
      state = AsyncData(server);
    });
    ref.onDispose(() => _subscription?.cancel());
    return repository.getActiveServer();
  }

  Future<void> refresh() async {
    final repository = ref.read(serverConfigRepositoryProvider);
    state = AsyncData(await repository.getActiveServer());
  }

  Future<void> save(ServerConfigModel config) async {
    final repository = ref.read(serverConfigRepositoryProvider);
    await repository.save(config);
    await refresh();
  }

  Future<void> clear() async {
    final repository = ref.read(serverConfigRepositoryProvider);
    await repository.clear();
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
