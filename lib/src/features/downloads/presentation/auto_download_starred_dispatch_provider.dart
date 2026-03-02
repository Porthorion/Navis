import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/providers/app_providers.dart';

final autoDownloadStarredDispatchControllerProvider =
    NotifierProvider.autoDispose<AutoDownloadStarredDispatchController, int>(
      AutoDownloadStarredDispatchController.new,
    );

class AutoDownloadStarredDispatchController extends Notifier<int> {
  bool _wasEligible = false;
  bool _isDispatching = false;

  @override
  int build() {
    ref.listen<ServerReachabilityState>(
      serverReachabilityControllerProvider,
      (_, _) => unawaited(_triggerIfEligible()),
    );
    ref.listen<AsyncValue<ServerConfigModel?>>(
      serverConfigStateProvider,
      (_, _) => unawaited(_triggerIfEligible()),
    );
    ref.listen<NetworkType>(
      networkTypeProvider,
      (_, _) => unawaited(_triggerIfEligible()),
    );
    ref.listen<bool>(
      wifiOnlyDownloadsProvider,
      (_, _) => unawaited(_triggerIfEligible()),
    );
    ref.listen<bool>(
      autoDownloadStarredOnWifiProvider,
      (_, _) => unawaited(_triggerIfEligible()),
    );

    Future<void>.microtask(_triggerIfEligible);
    return 0;
  }

  Future<void> _triggerIfEligible() async {
    final hasSession =
        ref.read(serverConfigStateProvider).asData?.value != null;
    final reachability = ref.read(serverReachabilityControllerProvider);
    final networkType = ref.read(networkTypeProvider);
    final wifiOnlyDownloads = ref.read(wifiOnlyDownloadsProvider);
    final autoDownloadEnabled = ref.read(autoDownloadStarredOnWifiProvider);
    final eligible =
        hasSession &&
        autoDownloadEnabled &&
        wifiOnlyDownloads &&
        networkType == NetworkType.wifi &&
        reachability.status == ServerReachabilityStatus.online;

    if (!eligible) {
      _wasEligible = false;
      return;
    }
    if (_wasEligible || _isDispatching) {
      return;
    }

    _wasEligible = true;
    _isDispatching = true;
    try {
      final db = ref.read(navisDatabaseProvider);
      final service = ref.read(downloadServiceProvider);
      final likedAlbums = await db.libraryDao.getLikedAlbums();
      final likedSongs = await db.libraryDao.getAllStarredSongs();

      // Use batch enqueue — each call does a single bulk insert internally,
      // so sequential awaits here are fine (2 DB round-trips per album, not
      // 3n). This also avoids blocking the UI because the service only writes
      // to the DB; actual downloading is handled by the background loop.
      for (final album in likedAlbums) {
        await service.enqueueAlbum(album.id);
      }
      for (final song in likedSongs) {
        // Fire-and-forget individual songs — enqueueSong is lightweight.
        unawaited(service.enqueueSong(song.id));
      }
    } finally {
      _isDispatching = false;
    }
  }
}
