import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final starSyncDispatchControllerProvider =
    NotifierProvider.autoDispose<StarSyncDispatchController, int>(
      StarSyncDispatchController.new,
    );

/// Flushes the star-sync queue when the server becomes reachable.
///
/// Mirrors the scrobble dispatch controller pattern: watches reachability
/// and flushes pending star/unstar operations on online transitions.
class StarSyncDispatchController extends Notifier<int> {
  ServerReachabilityStatus? _lastReachabilityStatus;

  @override
  int build() {
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
          unawaited(_flush());
        }
      },
    );

    ref.listen<AsyncValue<ServerConfigModel?>>(
      serverConfigStateProvider,
      (_, next) {
        final hasSession = next.asData?.value != null;
        if (hasSession) {
          unawaited(_flush());
        }
      },
    );

    Future<void>.microtask(_flush);
    return 0;
  }

  Future<void> _flush() async {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    final dao = ref.read(navisDatabaseProvider).starSyncDao;
    final pending = await dao.getPendingActions();
    if (pending.isEmpty) return;

    for (final entry in pending) {
      try {
        if (entry.action == 'star') {
          await api.star(entry.itemId);
        } else {
          await api.unstar(entry.itemId);
        }
        await dao.removeAction(entry.id);
      } on SubsonicConnectionException {
        // Still offline — stop flushing; reachability will trigger retry.
        return;
      } on Object catch (error) {
        debugPrint('Star sync flush failed for ${entry.itemId}: $error');
        // Non-connectivity error — remove to avoid infinite retries.
        await dao.removeAction(entry.id);
      }
    }
  }
}
