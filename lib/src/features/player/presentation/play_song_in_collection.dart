import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Plays the song at [index] of a song list the user tapped it in.
///
/// With Album Queue on, the whole list is queued and playback starts at that
/// song, like an album; with it off only that song plays. Liked lists retain
/// their additional Liked Queue rule. Play and Shuffle buttons, search results
/// and song menus keep their own behavior.
/// Match flows stay collapsed by default: the lists chose these songs.
void playSongInCollection(
  WidgetRef ref,
  List<Song> songs,
  int index, {
  bool expandMatchFlows = false,
}) => _play(
  ref,
  songs,
  index,
  (queue, items, start) => queue.replaceWithSongs(
    items,
    startIndex: start,
    expandMatchFlows: expandMatchFlows,
  ),
);

/// [playSongInCollection] for library rows ([SongsTableData]).
void playTableSongInCollection(
  WidgetRef ref,
  List<SongsTableData> songs,
  int index, {
  bool expandMatchFlows = false,
}) => _play(
  ref,
  songs,
  index,
  (queue, items, start) => queue.replaceWithTableData(
    items,
    startIndex: start,
    expandMatchFlows: expandMatchFlows,
  ),
);

/// [playSongInCollection] for a list known only by song ids.
void playSongIdInCollection(
  WidgetRef ref,
  List<String> songIds,
  int index, {
  bool expandMatchFlows = false,
}) => _play(
  ref,
  songIds,
  index,
  (queue, items, start) => queue.replace(
    items,
    startIndex: start,
    expandMatchFlows: expandMatchFlows,
  ),
);

void _play<T>(
  WidgetRef ref,
  List<T> items,
  int index,
  Future<void> Function(QueueController queue, List<T> items, int startIndex)
  replace,
) {
  if (index < 0 || index >= items.length) return;
  final queueAll = ref.read(albumQueueEnabledProvider) && items.length > 1;
  final queue = ref.read(queueProvider.notifier);
  queue.fireAndForget(
    () => replace(
      queue,
      queueAll ? items : <T>[items[index]],
      queueAll ? index : 0,
    ),
    label: 'playNow',
  );
}
