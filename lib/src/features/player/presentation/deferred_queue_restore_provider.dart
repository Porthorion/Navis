import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

final deferredQueueRestoreControllerProvider =
    NotifierProvider.autoDispose<DeferredQueueRestoreController, int>(
      DeferredQueueRestoreController.new,
    );

/// Retries a startup queue restore that was deferred for want of a playback
/// source once both the handler and a Subsonic client exist. The client is
/// rebuilt when credentials or the network type change, so coming online
/// after an offline start retries as well. The handler ignores the request
/// unless its startup restore is still deferred.
class DeferredQueueRestoreController extends Notifier<int> {
  @override
  int build() {
    void retry() {
      final handler = ref.read(audioHandlerProvider);
      if (handler == null || ref.read(subsonicApiProvider) == null) return;
      unawaited(
        handler.retryDeferredQueueRestore().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          AppLogger.warning(
            'Deferred queue restore retry failed: $error\n$stackTrace',
          );
        }),
      );
    }

    ref.listen<NavisPlaybackHandler?>(audioHandlerProvider, (_, _) => retry());
    ref.listen<SubsonicApiClient?>(subsonicApiProvider, (_, _) => retry());
    retry();
    return 0;
  }
}
