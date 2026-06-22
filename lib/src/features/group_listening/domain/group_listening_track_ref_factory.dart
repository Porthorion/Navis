import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/utils/song_id_utils.dart';

GroupListeningTrackRef buildTrackRefForSong(Song song) {
  if (isServerAddressableSongId(song.id)) {
    return GroupListeningTrackRef(
      kind: GroupListeningTrackRefKind.libraryId,
      librarySongId: song.id,
      source: GroupListeningTrackRefSource.navidrome,
    );
  }
  return GroupListeningTrackRef(
    kind: GroupListeningTrackRefKind.searchFingerprint,
    searchFingerprint: GroupListeningSearchFingerprint(
      title: song.title,
      artist: song.artist ?? '',
      album: song.album,
      durationSeconds: song.duration ?? 0,
    ),
    source: GroupListeningTrackRefSource.search3Remote,
  );
}

GroupListeningPlayability playabilityForSongId(String songId) {
  return isServerAddressableSongId(songId)
      ? GroupListeningPlayability.serverAddressable
      : GroupListeningPlayability.requiresResolution;
}
