part of 'now_playing_screen.dart';

class _TransportControls extends ConsumerWidget {
  const _TransportControls({
    required this.playback,
    required this.isExternalSource,
    this.isRadio = false,
    this.compact = false,
    this.showVolumeControl = false,
    this.showMiniPlayerToggle = false,
    this.onSkipPrevious,
    this.onSkipNext,
  });

  final PlaybackSnapshot playback;
  final bool isExternalSource;
  final bool isRadio;
  final bool compact;
  final bool showVolumeControl;
  final bool showMiniPlayerToggle;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;
    final showLoading = shouldShowRemotePlaybackLoading(
      playback: playback,
      currentIsExternal: isExternalSource,
    );
    final loadingColor = Theme.of(context).colorScheme.onPrimary;

    if (isRadio) {
      // Simplified radio transport: just play/pause and stop.
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
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
              child: _playPauseChild(
                showLoading: showLoading,
                isPlaying: isPlaying,
                size: compact ? 30 : 36,
                loadingColor: loadingColor,
                loadingLabel: l10n.commonLoading,
              ),
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
      final resolved = await volumeNotifier.setVolume(
        rawValue,
        persistImmediately: logChange,
      );
      if (logChange) {
        AppLogger.debug(
          '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
        );
      }
    }

    Future<void> toggleMute({required String source}) async {
      final resolved = await ref
          .read(playbackVolumeProvider.notifier)
          .toggleMute();
      AppLogger.debug(
        '[ACP_INPUT] volume source=$source value=${resolved.toStringAsFixed(2)}',
      );
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
    // Below these widths the EQ and Speed quick actions are dropped so the
    // core transport keeps full-size targets; both stay in the settings sheet.
    // The desktop volume slider keeps priority when both cannot fit.
    final transportQuickActionsMinWidth = compact ? 340.0 : 440.0;
    const transportQuickActionsExtraWidth = 112.0;

    final row = LayoutBuilder(
      builder: (context, constraints) {
        final effectiveShowVolume =
            showVolumeControl &&
            constraints.maxWidth >= transportVolumeMinWidth;
        final showQuickActions =
            constraints.maxWidth >= transportQuickActionsMinWidth &&
            (!effectiveShowVolume ||
                constraints.maxWidth >=
                    transportVolumeMinWidth + transportQuickActionsExtraWidth);
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (showQuickActions)
              EqualizerQuickButton(
                key: const ValueKey<String>('nowPlayingEqualizerButton'),
                visualDensity: compact ? VisualDensity.compact : null,
              ),
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
                child: _playPauseChild(
                  showLoading: showLoading,
                  isPlaying: isPlaying,
                  size: compact ? 30 : 36,
                  loadingColor: loadingColor,
                  loadingLabel: l10n.commonLoading,
                ),
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
            if (showQuickActions)
              PlaybackSpeedQuickButton(
                key: const ValueKey<String>('nowPlayingSpeedButton'),
                visualDensity: compact ? VisualDensity.compact : null,
              ),
            if (showMiniPlayerToggle) ...<Widget>[
              SizedBox(width: compact ? 4 : 8),
              Consumer(
                builder: (context, ref, _) {
                  final miniPlayerMode = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isMiniPlayerMode,
                    ),
                  );
                  final busy = ref.watch(
                    desktopWindowControllerProvider.select(
                      (value) => value.isApplyingMode,
                    ),
                  );
                  final controller = ref.read(desktopWindowControllerProvider);
                  return IconButton(
                    key: const ValueKey<String>(
                      'desktopNowPlayingMiniPlayerButton',
                    ),
                    visualDensity: compact ? VisualDensity.compact : null,
                    tooltip: miniPlayerMode
                        ? l10n.desktopReturnToView
                        : l10n.desktopMiniPlayerOpen,
                    onPressed: busy
                        ? null
                        : () => unawaited(controller.toggleMiniPlayerMode()),
                    icon: Icon(
                      miniPlayerMode
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
                semanticLabel: l10n.playbackVolumeSemanticLabel,
                muteTooltip: l10n.playbackMuteTooltip,
                unmuteTooltip: l10n.playbackUnmuteTooltip,
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

Widget _playPauseChild({
  required bool showLoading,
  required bool isPlaying,
  required double size,
  required Color loadingColor,
  required String loadingLabel,
}) {
  if (showLoading) {
    return Semantics(
      label: loadingLabel,
      child: SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          key: const ValueKey<String>('remote-playback-loading-indicator'),
          color: loadingColor,
          strokeWidth: 2.4,
        ),
      ),
    );
  }
  return Icon(isPlaying ? Icons.pause : Icons.play_arrow, size: size);
}
