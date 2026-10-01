import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final listenBrainzFeedbackDispatchControllerProvider =
    NotifierProvider.autoDispose<ListenBrainzFeedbackDispatchController, int>(
      ListenBrainzFeedbackDispatchController.new,
    );

class ListenBrainzFeedbackDispatchController extends Notifier<int> {
  ServerReachabilityStatus? _lastReachabilityStatus;

  @override
  int build() {
    _lastReachabilityStatus = ref
        .read(serverReachabilityControllerProvider)
        .status;

    ref.listen<ServerReachabilityState>(serverReachabilityControllerProvider, (
      _,
      next,
    ) {
      final previous = _lastReachabilityStatus;
      _lastReachabilityStatus = next.status;
      if (next.status == ServerReachabilityStatus.online &&
          previous != ServerReachabilityStatus.online) {
        unawaited(ref.read(listenBrainzFeedbackServiceProvider).flush());
      }
    });

    unawaited(
      Future<void>.microtask(
        () => ref.read(listenBrainzFeedbackServiceProvider).flush(),
      ),
    );
    return 0;
  }
}
