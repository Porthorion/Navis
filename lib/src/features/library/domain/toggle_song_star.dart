import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Commits the local favorite and durable delivery intent together, then updates
/// the current queue immediately. The annotation dispatcher owns all API writes.
///
/// Returns false, changing nothing, for a remote catalog copy (`ext-`): it
/// cannot be liked, so the caller shows `remoteSourceActionUnavailable`.
Future<bool> toggleSongStar(String songId, WidgetRef ref) async {
  final db = ref.read(navisDatabaseProvider);
  final audioHandler = ref.read(audioHandlerProvider);
  final liked = await db.starSyncDao.toggleSongStarred(songId);
  if (liked == null) return false;
  await audioHandler?.syncSongLikedState(songId, liked: liked);
  unawaited(
    ref
        .read(listenBrainzFeedbackServiceProvider)
        .enqueueSongFeedback(songId, liked: liked),
  );
  return true;
}
