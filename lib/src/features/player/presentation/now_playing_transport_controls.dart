part of 'now_playing_screen.dart';

class _TransportControls extends ConsumerWidget {
  const _TransportControls({
    required this.playback,
    this.isRadio = false,
    this.compact = false,
    this.showVolumeControl = false,
    this.showFocusPlayerToggle = false,
    this.onSkipPrevious,
    this.onSkipNext,
  });

  final PlaybackSnapshot playback;
  final bool isRadio;
  final bool compact;
  final bool showVolumeControl;
  final bool showFocusPlayerToggle;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;

    if (isRadio) {
      // Simplified radio transport: just play/pause and stop.
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (isDesktopRuntime)
            Tooltip(
              message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.all(compact ? 12 : 16),
                ),
                onPressed: () {
                  final handler = ref.read(audioHandlerProvider);
                  if (isPlaying) {
                    unawaited(handler?.pause());
                  } else {
                    unawaited(handler?.play());
                  }
                },
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: compact ? 30 : 36,
                ),
              ),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.all(compact ? 12 : 16),
              ),
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                if (isPlaying) {
                  unawaited(handler?.pause());
                } else {
                  unawaited(handler?.play());
                }
              },
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: compact ? 30 : 36,
              ),
            ),
          SizedBox(width: compact ? 10 : 16),
          IconButton(
            icon: Icon(Icons.stop, size: compact ? 28 : 32),
            tooltip: l10n.radioStopStation,
            onPressed: () {
              final handler = ref.read(audioHandlerProvider);
              unawaited(handler?.stopRadio());
            },
          ),
        ],
      );
    }

    final shuffleOn = playback.shuffleMode == AudioServiceShuffleMode.all;
    final repeatMode = playback.repeatMode;
    final volume = ref.watch(playbackVolumeProvider);

    Future<void> setPlaybackVolume(
      double rawValue, {
      required String source,
      bool logChange = false,
    }) async {
      final volumeNotifier = ref.read(playbackVolumeProvider.notifier);
      final resolved = volumeNotifier.setVolume(rawValue);
      if (logChange) {
        AppLogger.debug(
          '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
        );
      }
      await ref.read(audioHandlerProvider)?.setVolume(resolved);
    }

    Future<void> toggleMute({required String source}) async {
      final resolved = ref.read(playbackVolumeProvider.notifier).toggleMute();
      AppLogger.debug(
        '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
      );
      await ref.read(audioHandlerProvider)?.setVolume(resolved);
    }

    String repeatTooltip;
    IconData repeatIcon;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        repeatTooltip = l10n.nowPlayingRepeatOne;
        repeatIcon = Icons.repeat_one;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        repeatTooltip = l10n.nowPlayingRepeatAll;
        repeatIcon = Icons.repeat;
      case AudioServiceRepeatMode.none:
        repeatTooltip = l10n.nowPlayingRepeatOff;
        repeatIcon = Icons.repeat;
    }

    final isRepeatActive = repeatMode != AudioServiceRepeatMode.none;

    // Minimum width required to display all transport buttons + volume slider.
    // Below this threshold the volume slider overflows the Row and is moved to
    // the settings modal instead.
    const transportVolumeMinWidth = 480.0;

    final row = LayoutBuilder(
      builder: (context, constraints) {
        final effectiveShowVolume =
            showVolumeControl &&
            constraints.maxWidth >= transportVolumeMinWidth;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              icon: Icon(
                Icons.shuffle,
                color: shuffleOn ? Theme.of(context).colorScheme.primary : null,
              ),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: shuffleOn
                  ? l10n.nowPlayingShuffle
                  : l10n.nowPlayingShuffleOff,
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                final next = shuffleOn
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all;
                unawaited(handler?.setShuffleMode(next));
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(Icons.skip_previous, size: compact ? 28 : 32),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingPrevious,
              onPressed: () {
                if (onSkipPrevious != null) {
                  onSkipPrevious!.call();
                  return;
                }
                HapticFeedback.mediumImpact();
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToPrevious());
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            if (isDesktopRuntime)
              Tooltip(
                message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.all(compact ? 12 : 16),
                  ),
                  onPressed: () {
                    final handler = ref.read(audioHandlerProvider);
                    if (isPlaying) {
                      unawaited(handler?.pause());
                    } else {
                      unawaited(handler?.play());
                    }
                  },
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    size: compact ? 30 : 36,
                  ),
                ),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.all(compact ? 12 : 16),
                ),
                onPressed: () {
                  final handler = ref.read(audioHandlerProvider);
                  if (isPlaying) {
                    unawaited(handler?.pause());
                  } else {
                    unawaited(handler?.play());
                  }
                },
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: compact ? 30 : 36,
                ),
              ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(Icons.skip_next, size: compact ? 28 : 32),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingNext,
              onPressed: () {
                if (onSkipNext != null) {
                  onSkipNext!.call();
                  return;
                }
                HapticFeedback.mediumImpact();
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToNext());
              },
            ),
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              icon: Icon(
                repeatIcon,
                color: isRepeatActive
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: repeatTooltip,
              onPressed: () {
                final handler = ref.read(audioHandlerProvider);
                final next = switch (repeatMode) {
                  AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                  AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                  AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
                  AudioServiceRepeatMode.group => AudioServiceRepeatMode.none,
                };
                unawaited(handler?.setRepeatMode(next));
              },
            ),
            if (showFocusPlayerToggle) ...<Widget>[
              SizedBox(width: compact ? 4 : 8),
              Consumer(
                builder: (context, ref, _) {
                  final focusMode = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isFocusPlayerMode,
                    ),
                  );
                  final busy = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isApplyingMode,
                    ),
                  );
                  final controller = ref.read(desktopWindowControllerProvider);
                  return IconButton(
                    key: const ValueKey<String>('desktopNowPlayingFocusButton'),
                    visualDensity: compact ? VisualDensity.compact : null,
                    tooltip: focusMode
                        ? 'Return to normal window'
                        : 'Enter Focus Player Mode',
                    onPressed: busy
                        ? null
                        : () => unawaited(controller.toggleFocusPlayerMode()),
                    icon: Icon(
                      focusMode
                          ? Icons.close_fullscreen_rounded
                          : Icons.fit_screen_rounded,
                    ),
                  );
                },
              ),
            ],
            if (effectiveShowVolume) ...<Widget>[
              SizedBox(width: compact ? 6 : 10),
              DesktopVolumeSlider(
                key: const ValueKey<String>('nowPlayingDesktopVolumeSlider'),
                volume: volume,
                compact: compact,
                onChanged: (value) => unawaited(
                  setPlaybackVolume(value, source: 'desktop_now_playing_live'),
                ),
                onChangeEnd: (value) => unawaited(
                  setPlaybackVolume(
                    value,
                    source: 'desktop_now_playing_settle',
                    logChange: true,
                  ),
                ),
                onMuteToggle: () =>
                    unawaited(toggleMute(source: 'desktop_now_playing_icon')),
              ),
            ],
          ],
        );
      },
    );
    return row;
  }
}
