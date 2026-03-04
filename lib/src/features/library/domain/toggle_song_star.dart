import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Toggles the starred/liked state for [songId] using an optimistic update.
///
/// 1. Reads the current `starred` value from the DB.
/// 2. Optimistically flips it.
/// 3. Calls `star` / `unstar` on the API.
/// 4. On connectivity failure → queues for offline retry.
/// 5. On other errors → rolls back.
///
/// This is the shared DB+API+queue logic used by context menus. The audio
/// handler has its own version that also manages `MediaItem.extras`.
Future<void> toggleSongStar(String songId, WidgetRef ref) async {
  final db = ref.read(navisDatabaseProvider);
  final api = ref.read(subsonicApiProvider);
  final dao = db.libraryDao;

  final currentStarred = await dao.getSongStarred(songId);
  final wasLiked = currentStarred != null;

  // ── Optimistic update ──
  await dao.updateSongStarred(songId, wasLiked ? null : DateTime.now());

  if (api == null) {
    // No API client — queue for sync and keep the optimistic state.
    await db.starSyncDao.queueStarAction(
      itemId: songId,
      itemType: 'song',
      action: wasLiked ? 'unstar' : 'star',
    );
    return;
  }

  try {
    if (wasLiked) {
      await api.unstar(songId);
    } else {
      await api.star(songId);
    }
  } on SubsonicConnectionException {
    // Offline — queue for retry, keep the optimistic DB state.
    await db.starSyncDao.queueStarAction(
      itemId: songId,
      itemType: 'song',
      action: wasLiked ? 'unstar' : 'star',
    );
  } on Object {
    // API error — rollback to the previous state.
    await dao.updateSongStarred(songId, currentStarred);
    rethrow;
  }
}
