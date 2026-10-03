part of 'now_playing_screen.dart';

const _kSeekSemanticsStepMs = 10000;

class _SeekBar extends ConsumerStatefulWidget {
  const new({required this.playback});

  final PlaybackSnapshot playback;

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _draggingValue;

  @override
  Widget build(BuildContext context) {
    final position =
        widget.playback.pendingSeekPosition ??
        ref.watch(playbackPositionProvider).asData?.value ??
        widget.playback.position;
    final bufferState =
        ref.watch(playbackBufferStateProvider).asData?.value ??
        const PlaybackBufferState.idle();
    final duration = widget.playback.duration;
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;

    final sliderValue =
        _draggingValue ??
        (durationMs > 0
            ? positionMs.toDouble().clamp(0, durationMs.toDouble())
            : 0.0);
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final bufferedValue = resolveBufferedSeekValue(
      currentSongId: widget.playback.currentSongId,
      bufferState: bufferState,
      duration: duration,
    );
    final sliderCurrentMs = sliderValue.round();
    final increasedMs = (sliderCurrentMs + _kSeekSemanticsStepMs).clamp(
      0,
      durationMs,
    );
    final decreasedMs = (sliderCurrentMs - _kSeekSemanticsStepMs).clamp(
      0,
      durationMs,
    );

    return Column(
      children: <Widget>[
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Semantics(
            container: true,
            slider: true,
            value:
                '${formatDuration(Duration(milliseconds: sliderValue.round()))} of ${formatDuration(duration)}',
            increasedValue:
                '${formatDuration(Duration(milliseconds: increasedMs))} of ${formatDuration(duration)}',
            decreasedValue:
                '${formatDuration(Duration(milliseconds: decreasedMs))} of ${formatDuration(duration)}',
            onIncrease: () {
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              final currentMs = (_draggingValue ?? sliderValue).round();
              final targetMs = (currentMs + _kSeekSemanticsStepMs).clamp(
                0,
                durationMs,
              );
              setState(() => _draggingValue = null);
              unawaited(handler.seek(Duration(milliseconds: targetMs)));
            },
            onDecrease: () {
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              final currentMs = (_draggingValue ?? sliderValue).round();
              final targetMs = (currentMs - _kSeekSemanticsStepMs).clamp(
                0,
                durationMs,
              );
              setState(() => _draggingValue = null);
              unawaited(handler.seek(Duration(milliseconds: targetMs)));
            },
            child: ExcludeSemantics(
              child: Slider(
                value: sliderValue.clamp(0, sliderMax),
                secondaryTrackValue: bufferedValue,
                secondaryActiveColor: resolveBufferedSeekColor(context),
                max: sliderMax,
                semanticFormatterCallback: (value) {
                  final pos = Duration(milliseconds: value.round());
                  return '${formatDuration(pos)} of ${formatDuration(widget.playback.duration)}';
                },
                onChanged: (value) {
                  setState(() => _draggingValue = value);
                },
                onChangeEnd: (value) {
                  setState(() => _draggingValue = null);
                  final handler = ref.read(audioHandlerProvider);
                  unawaited(
                    handler?.seek(Duration(milliseconds: value.round())),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                formatDuration(
                  _draggingValue != null
                      ? Duration(milliseconds: _draggingValue!.round())
                      : position,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                formatDuration(duration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
