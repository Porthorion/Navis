import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

/// The complete playback source for liked content.
///
/// Directly liked songs take precedence over songs included through a liked
/// album. Keeping this policy outside either screen ensures every entry point
/// starts the same ordered, de-duplicated queue.
final likedPlaybackSongsProvider = Provider<List<SongsTableData>>((ref) {
  final likedSongs =
      ref.watch(likedSongsProvider).asData?.value ?? const <SongsTableData>[];
  final likedAlbumSongs =
      ref.watch(likedAlbumSongsProvider).asData?.value ??
      const <SongsTableData>[];
  return combineLikedPlaybackSongs(likedSongs, likedAlbumSongs);
});

List<SongsTableData> combineLikedPlaybackSongs(
  List<SongsTableData> likedSongs,
  List<SongsTableData> likedAlbumSongs,
) {
  final dedupedSongs = <String, SongsTableData>{};
  for (final song in <SongsTableData>[...likedSongs, ...likedAlbumSongs]) {
    dedupedSongs.putIfAbsent(song.id, () => song);
  }
  return List<SongsTableData>.unmodifiable(dedupedSongs.values);
}

bool shouldQueueLikedPlayback({
  required bool albumQueueEnabled,
  required bool likedQueueEnabled,
  required int eligibleSongCount,
}) => albumQueueEnabled && likedQueueEnabled && eligibleSongCount > 1;

List<SongsTableData> filterLikedPlaybackToDownloads(
  List<SongsTableData> songs,
  Set<String> downloadedSongIds,
) => List<SongsTableData>.unmodifiable(
  songs.where((song) => downloadedSongIds.contains(song.id)),
);
