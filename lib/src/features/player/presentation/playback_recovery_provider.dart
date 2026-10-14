import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:navis/src/utils/app_logger.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';

/// Coordinates the user-visible escape hatches for unavailable playback.
///
/// The service deliberately starts a new bootstrap attempt without awaiting
/// it: a platform initializer may be the failure being recovered from.
abstract interface class PlaybackRecoveryService {
  void retryPlayback();
  Future<void> restartNavis();
  Future<void> copyDetails();
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
    navigateToLibraryRebuild: () => ref
        .read(appRouterProvider)
        .go(
          requiredLibraryRebuildRoute(
            RequiredLibraryRebuildReason.playbackRecovery,
          ),
        ),
    signOut: (wipeLocalData) =>
        ref.read(signOutServiceProvider).signOut(wipeLocalData: wipeLocalData),
    refreshServerConfig: () =>
        ref.read(serverConfigProvider.notifier).refresh(),
  );
});

class _PlaybackRecoveryService implements PlaybackRecoveryService {
  new({
    required this._abortBootstrap,
    required this._startBootstrapRetry,
    required this._navigateToLibraryRebuild,
    required this._signOut,
    required this._refreshServerConfig,
  });

  final Future<void> Function() _abortBootstrap;
  final Future<void> Function() _startBootstrapRetry;
  final void Function() _navigateToLibraryRebuild;
  // Keep the existing method and callback call contract for callers.
  // ignore: avoid_positional_boolean_parameters
  final Future<void> Function(bool wipeLocalData) _signOut;
  final Future<void> Function() _refreshServerConfig;

  @override
  void retryPlayback() {
    unawaited(_startBootstrapRetry());
  }

  @override
  Future<void> restartNavis() async {
    if (!Platform.isAndroid) {
      retryPlayback();
      return;
    }
    AppLogger.startup(StartupEvent.restart);
    await AppLogger.startupDetails(); // Flush evidence before process death.
    await const MethodChannel('com.navis.app/device')
        .invokeMethod<void>('restartNavis');
  }

  @override
  Future<void> copyDetails() async {
    await Clipboard.setData(
      ClipboardData(text: await AppLogger.startupDetails()),
    );
  }

  @override
  Future<void> resetLibraryCacheAndRetry() async {
    await _abortBootstrap();
    _navigateToLibraryRebuild();
  }

  @override
  Future<void> signOut({required bool wipeLocalData}) async {
    await _signOut(wipeLocalData);
    await _refreshServerConfig();
  }
}
