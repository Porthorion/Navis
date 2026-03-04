import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Toggles the starred/liked state for [songId] using an optimistic update.
///
/// 1. Reads the current `starred` value from the DB.
/// 2. Optimistically flips it in the DB and in the audio handler's queue
///    (so the now-playing heart updates immediately).
/// 3. Calls `star` / `unstar` on the API.
/// 4. On connectivity failure → queues for offline retry.
/// 5. On other errors → rolls back both the DB and the queue state.
///
/// This is the shared DB+API+queue logic used by context menus. The audio
/// handler has its own version that also manages `MediaItem.extras`.
Future<void> toggleSongStar(String songId, WidgetRef ref) async {
  final db = ref.read(navisDatabaseProvider);
  final api = ref.read(subsonicApiProvider);
  final audioHandler = ref.read(audioHandlerProvider);
  final dao = db.libraryDao;

  final currentStarred = await dao.getSongStarred(songId);
  final wasLiked = currentStarred != null;
  final newLiked = !wasLiked;

  // ── Optimistic update ──
  await dao.updateSongStarred(songId, newLiked ? DateTime.now() : null);
  // Keep the audio handler's in-memory queue in sync so the now-playing
  // heart reflects the change immediately if this song is currently queued.
  await audioHandler?.syncSongLikedState(songId, liked: newLiked);

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
    // API error — rollback to the previous state in both the DB and the queue.
    await dao.updateSongStarred(songId, currentStarred);
    await audioHandler?.syncSongLikedState(songId, liked: wasLiked);
    rethrow;
  }
}
