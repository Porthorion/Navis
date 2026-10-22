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

/// The player's own buffered range in milliseconds, drawn apart from the
/// cached one after a seek past it. Keyed and clamped like
/// [resolveBufferedSeekValue]; null when the ranges are not detached.
({double start, double end})? resolveAheadSeekRange({
  required String? currentSongId,
  required PlaybackBufferState bufferState,
  required Duration duration,
}) {
  final durationMs = duration.inMilliseconds;
  final start = bufferState.aheadStart;
  final end = bufferState.aheadEnd;
  if (currentSongId == null ||
      currentSongId != bufferState.songId ||
      durationMs <= 0 ||
      start == null ||
      end == null) {
    return null;
  }
  final startMs = start.inMilliseconds.clamp(0, durationMs).toDouble();
  final endMs = end.inMilliseconds.clamp(0, durationMs).toDouble();
  return endMs > startMs ? (start: startMs, end: endMs) : null;
}

/// The track shape that draws the ahead range for a seek bar, or null (keep
/// the theme's own shape) when there is none. It wraps the effective shape, so
/// it suits any slider style.
SliderTrackShape? resolveAheadTrackShape(
  BuildContext context, {
  required String? currentSongId,
  required PlaybackBufferState bufferState,
  required Duration duration,
  required double max,
}) {
  final range = resolveAheadSeekRange(
    currentSongId: currentSongId,
    bufferState: bufferState,
    duration: duration,
  );
  if (range == null) return null;
  return AheadRangeTrackShape(
    delegate:
        SliderTheme.of(context).trackShape ??
        const RoundedRectSliderTrackShape(),
    start: range.start,
    end: range.end,
    max: max,
  );
}

/// Paints [delegate]'s track, then the ahead range [start] to [end] (of [max])
/// in the secondary track colour, from the thumb on when the thumb is inside
/// it.
@immutable
class AheadRangeTrackShape extends SliderTrackShape {
  const AheadRangeTrackShape({
    required this.delegate,
    required this.start,
    required this.end,
    required this.max,
  });

  final SliderTrackShape delegate;
  final double start;
  final double end;
  final double max;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => delegate.getPreferredRect(
    parentBox: parentBox,
    offset: offset,
    sliderTheme: sliderTheme,
    isEnabled: isEnabled,
    isDiscrete: isDiscrete,
  );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    delegate.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );
    final color = sliderTheme.secondaryActiveTrackColor;
    if (color == null || max <= 0) return;
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final ltr = textDirection == TextDirection.ltr;
    double x(double value) => ltr
        ? track.left + track.width * value / max
        : track.right - track.width * value / max;
    var left = ltr ? x(start) : x(end);
    var right = ltr ? x(end) : x(start);
    // The part before the thumb is what the thumb has already passed.
    if (ltr) {
      left = left < thumbCenter.dx ? thumbCenter.dx : left;
    } else {
      right = right > thumbCenter.dx ? thumbCenter.dx : right;
    }
    if (right <= left) return;
    context.canvas.drawRRect(
      RRect.fromLTRBR(
        left,
        track.top,
        right,
        track.bottom,
        Radius.circular(track.height / 2),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AheadRangeTrackShape &&
      other.delegate == delegate &&
      other.start == start &&
      other.end == end &&
      other.max == max;

  @override
  int get hashCode => Object.hash(delegate, start, end, max);
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
