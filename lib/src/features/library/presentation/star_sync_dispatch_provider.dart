import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final starSyncDispatchControllerProvider =
    NotifierProvider.autoDispose<StarSyncDispatchController, int>(
      StarSyncDispatchController.new,
    );

/// UI lifecycle triggers share the same dispatcher as audio-only startup.
class StarSyncDispatchController extends Notifier<int> {
  @override
  int build() {
    if (const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS') &&
        !const bool.fromEnvironment('NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE')) {
      return 0;
    }
    final dispatcher = ref.watch(annotationSyncDispatcherProvider);
    ref.listen<ServerReachabilityState>(serverReachabilityControllerProvider, (
      previous,
      next,
    ) {
      if (next.status == ServerReachabilityStatus.online &&
          previous?.status != next.status) {
        unawaited(dispatcher.flush());
      }
    });
    ref.listen<AsyncValue<ServerConfigModel?>>(serverConfigStateProvider, (
      previous,
      next,
    ) {
      final before = previous?.asData?.value;
      final after = next.asData?.value;
      if (after != null &&
          (before?.id != after.id ||
              before?.url != after.url ||
              before?.username != after.username ||
              before?.password != after.password)) {
        unawaited(dispatcher.sessionChanged());
      }
    });
    return 0;
  }
}
