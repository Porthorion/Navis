import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final scrobbleDispatchControllerProvider =
    NotifierProvider.autoDispose<ScrobbleDispatchController, int>(
      ScrobbleDispatchController.new,
    );

class ScrobbleDispatchController extends Notifier<int> {
  ServerReachabilityStatus? _lastReachabilityStatus;

  @override
  int build() {
    final service = ref.watch(scrobbleServiceProvider);
    _lastReachabilityStatus = ref
        .read(serverReachabilityControllerProvider)
        .status;

    ref.listen<ServerReachabilityState>(
      serverReachabilityControllerProvider,
      (_, next) {
        final previous = _lastReachabilityStatus;
        _lastReachabilityStatus = next.status;
        if (next.status == ServerReachabilityStatus.online &&
            previous != ServerReachabilityStatus.online) {
          unawaited(service.flushDue());
        }
      },
    );

    ref.listen<AsyncValue<ServerConfigModel?>>(
      serverConfigStateProvider,
      (_, next) {
        final hasSession = next.asData?.value != null;
        if (hasSession) {
          unawaited(service.flushDue());
        }
      },
    );

    Future<void>.microtask(service.flushDue);
    return 0;
  }
}
