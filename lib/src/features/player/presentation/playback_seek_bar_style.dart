import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playbackPositionProvider, playerStateProvider;

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

/// The position a seek bar shows: a seek in flight, else the live position.
///
/// Both providers are watched on every build. A `pending ?? watch(stream)`
/// chain skipped the stream while a seek was pending, so Riverpod dropped the
/// subscription, and a parent that does not rebuild for the cleared seek left
/// the bar frozen on the seek target (most visibly with Repeat One, where no
/// song change rebuilds it).
Duration watchDisplayedPlaybackPosition(
  WidgetRef ref,
  PlaybackSnapshot playback,
) {
  final streamed = ref.watch(playbackPositionProvider).asData?.value;
  final pendingSeek = ref.watch(
    playerStateProvider.select((snapshot) => snapshot.pendingSeekPosition),
  );
  return pendingSeek ?? streamed ?? playback.position;
}
