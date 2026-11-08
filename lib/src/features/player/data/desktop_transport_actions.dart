import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

/// Desktop transport actions shared by the keyboard shortcuts and the macOS
/// Dock menu, so both follow the same radio-mode rules.
Future<void> desktopPlayPause(
  NavisPlaybackHandler handler,
  PlaybackSnapshot snapshot,
) => snapshot.playing ? handler.pause() : handler.play();

/// In radio mode there is no next track: the action leaves the station.
Future<void> desktopNextTrack(
  NavisPlaybackHandler handler,
  PlaybackSnapshot snapshot,
) => snapshot.isRadioMode ? handler.stopRadio() : handler.skipToNext();

/// A live station has no previous track, so radio mode ignores the action.
Future<void> desktopPreviousTrack(
  NavisPlaybackHandler handler,
  PlaybackSnapshot snapshot,
) async {
  if (snapshot.isRadioMode) return;
  await handler.skipToPrevious();
}
