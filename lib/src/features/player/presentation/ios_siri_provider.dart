import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/ios_siri_bridge.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Siri "Play `X` in Navis" on iOS (#530); a no-op elsewhere. Read once from
/// the root container in `main.dart` next to audio bootstrap, because a
/// background launch for an intent may never build a widget.
final iosSiriProvider = Provider<void>((ref) {
  if (kIsWeb || !Platform.isIOS) return;
  final database = ref.watch(navisDatabaseProvider);
  final phases = StreamController<SessionRoutePhase>.broadcast();
  final changes = StreamController<void>.broadcast();
  ref
    ..listen(sessionRoutePhaseProvider, (_, next) => phases.add(next))
    // A finished sync (full or partial) is the library-changed signal; the
    // same transition `artistTopTrackMatchSyncBridgeProvider` reacts to.
    ..listen(librarySyncControllerProvider, (previous, next) {
      final finished =
          next.status == LibrarySyncStatus.succeeded ||
          next.status == LibrarySyncStatus.partial;
      if (finished && previous?.status != next.status) changes.add(null);
    });
  final playlistWatch = database.playlistDao.watchPlaylists().listen(
    (_) => changes.add(null),
    onError: (Object _) {},
  );
  final bridge = IosSiriBridge(
    readPhase: () => ref.read(sessionRoutePhaseProvider),
    phases: phases.stream,
    awaitHandler: (timeout) async {
      final existing = ref.read(audioHandlerProvider);
      if (existing != null) {
        await existing.waitUntilReady();
        return existing;
      }
      final arrived = Completer<NavisPlaybackHandler?>();
      final subscription = ref.listen(audioHandlerProvider, (_, next) {
        if (next != null && !arrived.isCompleted) arrived.complete(next);
      });
      try {
        final handler = await arrived.future.timeout(
          timeout,
          onTimeout: () => null,
        );
        await handler?.waitUntilReady();
        return handler;
      } finally {
        subscription.close();
      }
    },
    canStream: ref.read(canStreamProvider),
    hasDownloadedSongs: () async =>
        (await database.cacheDao.getPermanentlyCachedSongIds()).isNotEmpty,
    artistNames: () async => [
      for (final artist in await database.libraryDao.getArtistsByLibraryWeight(
        limit: 500,
      ))
        artist.name,
    ],
    playlistNames: () async => [
      for (final playlist in await database.playlistDao.watchPlaylists().first)
        playlist.name,
    ],
    vocabularyChanges: changes.stream,
  );
  ref.onDispose(() {
    unawaited(bridge.dispose());
    unawaited(playlistWatch.cancel());
    unawaited(phases.close());
    unawaited(changes.close());
  });
});
