part of 'now_playing_screen.dart';

class _TransportControls extends ConsumerWidget {
  const new({
    required this.playback,
    required this.isExternalSource,
    this.isRadio = false,
    this.compact = false,
    this.large = false,
    this.showVolumeControl = false,
    this.quickActionsShown,
    this.onSkipPrevious,
    this.onSkipNext,
  });

  final PlaybackSnapshot playback;
  final bool isExternalSource;
  final bool isRadio;
  final bool compact;

  /// Tall phones: a slightly larger Play button and skip icons. Only the
  /// portrait phone layout sets it, so other layouts keep their sizes.
  final bool large;
  final bool showVolumeControl;

  /// Receives whether this row currently shows the EQ and Speed buttons. The
  /// settings sheet and panel read it to list those controls only when the
  /// row does not.
  final ValueNotifier<bool>? quickActionsShown;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;

  // The row's width is only known during layout, so the value is published
  // after the frame.
  void _reportQuickActionsShown(BuildContext context, bool shown) {
    final notifier = quickActionsShown;
    if (notifier == null || notifier.value == shown) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) notifier.value = shown;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;
    final showLoading = shouldShowRemotePlaybackLoading(
      playback: playback,
      currentIsExternal: isExternalSource,
    );
    final colorStyle = NavisColorStyleData.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The solid action role, shared with every other Play button.
    final playFill = colorStyle.playButtonFill(scheme);
    final onPlayFill = colorStyle.onPlayButtonFill(scheme);
    final loadingColor = onPlayFill;
    final playEdge = colorStyle.controlEdge;
    final playPadding = large ? 14.0 : (compact ? 12.0 : 16.0);
    final playIconSize = large ? 34.0 : (compact ? 30.0 : 36.0);
    final skipIconSize = large ? 32.0 : (compact ? 28.0 : 32.0);

    if (isRadio) {
      // Simplified radio transport: just play/pause and stop.
      _reportQuickActionsShown(context, false);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Tooltip(
            message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: playFill,
                foregroundColor: onPlayFill,
                side: playEdge == null ? null : BorderSide(color: playEdge),
                shape: const CircleBorder(),
                padding: EdgeInsets.all(playPadding),
              ),
              onPressed: () =>
                  unawaited(togglePlayPause(ref, isPlaying: isPlaying)),
              child: _playPauseChild(
                showLoading: showLoading,
                isPlaying: isPlaying,
                size: playIconSize,
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

    final repeat = repeatPresentation(repeatMode, l10n);
    final repeatTooltip = repeat.tooltip;
    final repeatIcon = repeat.icon;
    final isRepeatActive = repeat.active;

    // Minimum width required to display all transport buttons + volume slider.
    // Below this threshold the volume slider overflows the Row and is moved to
    // the settings modal instead.
    const transportVolumeMinWidth = 480.0;
    // Narrow phones (360 dp and below) tighten the row instead of losing the
    // EQ and Speed quick actions: flank slots shrink and inter-button gaps
    // close. Only below the tight minimum are the quick actions dropped (both
    // stay in the settings sheet). The desktop volume slider keeps priority
    // when both cannot fit.
    const transportQuickActionsRelaxedWidth = 360.0;
    final transportQuickActionsMinWidth = compact ? 296.0 : 440.0;
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
        _reportQuickActionsShown(context, showQuickActions);
        final tight =
            showQuickActions &&
            compact &&
            constraints.maxWidth < transportQuickActionsRelaxedWidth;
        final gap = SizedBox(width: tight ? 0 : (compact ? 4 : 8));
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (showQuickActions)
              EqualizerQuickButton(
                key: const ValueKey<String>('nowPlayingEqualizerButton'),
                visualDensity: compact ? VisualDensity.compact : null,
                placeholderWhenUnsupported: true,
                dense: tight,
              ),
            _NowPlayingMixButton(
              songId: playback.currentSongId,
              compact: compact,
            ),
            gap,
            IconButton(
              icon: Icon(Icons.skip_previous, size: skipIconSize),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingPrevious,
              onPressed: () {
                if (onSkipPrevious != null) {
                  onSkipPrevious!.call();
                  return;
                }
                unawaited(HapticFeedback.mediumImpact());
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToPrevious());
              },
            ),
            gap,
            Tooltip(
              message: isPlaying ? l10n.nowPlayingPause : l10n.nowPlayingPlay,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: playFill,
                  foregroundColor: onPlayFill,
                  side: playEdge == null ? null : BorderSide(color: playEdge),
                  shape: const CircleBorder(),
                  padding: EdgeInsets.all(playPadding),
                ),
                onPressed: () =>
                    unawaited(togglePlayPause(ref, isPlaying: isPlaying)),
                child: _playPauseChild(
                  showLoading: showLoading,
                  isPlaying: isPlaying,
                  size: playIconSize,
                  loadingColor: loadingColor,
                  loadingLabel: l10n.commonLoading,
                ),
              ),
            ),
            gap,
            IconButton(
              icon: Icon(Icons.skip_next, size: skipIconSize),
              visualDensity: compact ? VisualDensity.compact : null,
              tooltip: l10n.nowPlayingNext,
              onPressed: () {
                if (onSkipNext != null) {
                  onSkipNext!.call();
                  return;
                }
                unawaited(HapticFeedback.mediumImpact());
                final handler = ref.read(audioHandlerProvider);
                unawaited(handler?.skipToNext());
              },
            ),
            gap,
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
                unawaited(handler?.setRepeatMode(nextRepeatMode(repeatMode)));
              },
            ),
            if (showQuickActions)
              PlaybackSpeedQuickButton(
                key: const ValueKey<String>('nowPlayingSpeedButton'),
                visualDensity: compact ? VisualDensity.compact : null,
                dense: tight,
              ),
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
