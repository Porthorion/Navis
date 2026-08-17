import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Coordinates the user-visible escape hatches for unavailable playback.
///
/// The service deliberately starts a new bootstrap attempt without awaiting
/// it: a platform initializer may be the failure being recovered from.
abstract interface class PlaybackRecoveryService {
  void retryPlayback();
  Future<void> resetLibraryCacheAndRetry();
  Future<void> signOut({required bool wipeLocalData});
}

final playbackRecoveryServiceProvider = Provider<PlaybackRecoveryService>((
  ref,
) {
  return _PlaybackRecoveryService(
    abortBootstrap: () => ref
        .read(audioBootstrapControllerProvider.notifier)
        .abortForSessionTeardown(),
    startBootstrapRetry: () =>
        ref.read(audioBootstrapControllerProvider.notifier).retry(),
    resetLibraryCache: () => ref.read(libraryCacheResetServiceProvider).reset(),
    requestFullSync: () =>
        ref.read(librarySyncControllerProvider.notifier).forceFullSync(),
    signOut: (wipeLocalData) =>
        ref.read(signOutServiceProvider).signOut(wipeLocalData: wipeLocalData),
    refreshServerConfig: () =>
        ref.read(serverConfigProvider.notifier).refresh(),
  );
});

class _PlaybackRecoveryService implements PlaybackRecoveryService {
  _PlaybackRecoveryService({
    required Future<void> Function() abortBootstrap,
    required Future<void> Function() startBootstrapRetry,
    required Future<void> Function() resetLibraryCache,
    required Future<void> Function() requestFullSync,
    required Future<void> Function(bool wipeLocalData) signOut,
    required Future<void> Function() refreshServerConfig,
  }) : _abortBootstrap = abortBootstrap,
       _startBootstrapRetry = startBootstrapRetry,
       _resetLibraryCache = resetLibraryCache,
       _requestFullSync = requestFullSync,
       _signOut = signOut,
       _refreshServerConfig = refreshServerConfig;

  final Future<void> Function() _abortBootstrap;
  final Future<void> Function() _startBootstrapRetry;
  final Future<void> Function() _resetLibraryCache;
  final Future<void> Function() _requestFullSync;
  final Future<void> Function(bool wipeLocalData) _signOut;
  final Future<void> Function() _refreshServerConfig;

  @override
  void retryPlayback() {
    unawaited(_startBootstrapRetry());
  }

  @override
  Future<void> resetLibraryCacheAndRetry() async {
    await _abortBootstrap();
    await _resetLibraryCache();
    unawaited(
      _requestFullSync().catchError((Object error, StackTrace stack) {
        AppLogger.warning(
          'Library refresh request after playback recovery failed: '
          '$error\n$stack',
        );
      }),
    );
    retryPlayback();
  }

  @override
  Future<void> signOut({required bool wipeLocalData}) async {
    await _signOut(wipeLocalData);
    await _refreshServerConfig();
  }
}
