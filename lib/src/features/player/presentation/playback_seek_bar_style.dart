import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

double? resolveBufferedSeekValue({
  required String? currentSongId,
  required PlaybackBufferState bufferState,
  required Duration duration,
}) {
  final durationMs = duration.inMilliseconds;
  if (currentSongId == null ||
      currentSongId != bufferState.songId ||
      durationMs <= 0 ||
      bufferState.bufferedPosition <= Duration.zero) {
    return null;
  }
  return bufferState.bufferedPosition.inMilliseconds
      .clamp(0, durationMs)
      .toDouble();
}

Color resolveBufferedSeekColor(BuildContext context) {
  final sliderTheme = SliderTheme.of(context);
  final colorScheme = Theme.of(context).colorScheme;
  final inactive =
      sliderTheme.inactiveTrackColor ?? colorScheme.surfaceContainerHighest;
  final active = sliderTheme.activeTrackColor ?? colorScheme.primary;
  return Color.alphaBlend(active.withValues(alpha: 0.16), inactive);
}
