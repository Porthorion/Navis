part of 'app_shell.dart';

class _DesktopPlayerBar extends ConsumerStatefulWidget {
  const _DesktopPlayerBar({
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.artistId,
    required this.albumId,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.isExternalSource,
    required this.onOpenPlayer,
    required this.onToggleQueue,
    required this.queueToggleFocusNode,
    required this.lyricsActive,
    required this.onToggleLyrics,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final VoidCallback onOpenPlayer;
  final VoidCallback onToggleQueue;
  final FocusNode queueToggleFocusNode;
  final bool lyricsActive;
  final VoidCallback onToggleLyrics;

  @override
  ConsumerState<_DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<_DesktopPlayerBar> {
  double? _dragSliderValue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final playback = widget.playback;
    final playbackVolume = ref.watch(playbackVolumeProvider);
    final hasPlayback =
        playback.isRadioMode ||
        (playback.currentSongId ?? '').trim().isNotEmpty;
    final hasResumableQueue = playback.queueSongIds.isNotEmpty;
    final canOpenQueue = hasPlayback && hasResumableQueue;
    final isPlaying = playback.playing;
    final title = !hasPlayback
        ? l10n.desktopNothingPlaying
        : (widget.songTitle == null || widget.songTitle!.trim().isEmpty)
        ? l10n.miniPlayerUnknownTrack
        : widget.songTitle!;
    final artist = !hasPlayback
        ? l10n.desktopChooseSomething
        : (widget.songArtist == null || widget.songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : widget.songArtist!;
    final resolvedArtistId = (widget.artistId ?? '').trim();
    final canOpenArtist =
        !playback.isRadioMode &&
        (resolvedArtistId.isNotEmpty ||
            (widget.songArtist ?? '').trim().isNotEmpty);

    final livePosition = ref.watch(playbackPositionProvider).asData?.value;
    final bufferState =
        ref.watch(playbackBufferStateProvider).asData?.value ??
        const PlaybackBufferState.idle();
    final position = livePosition ?? playback.position;
    final duration = playback.duration;
    final durationMs = duration.inMilliseconds;
    final canSeek = !playback.isRadioMode && durationMs > 0;
    final sliderMax = canSeek ? durationMs.toDouble() : 1.0;
    final positionMs = canSeek
        ? position.inMilliseconds.clamp(0, durationMs).toDouble()
        : 0.0;
    final sliderValue = canSeek
        ? ((_dragSliderValue ?? positionMs).clamp(0.0, sliderMax))
        : 0.0;
    final bufferedValue = resolveBufferedSeekValue(
      currentSongId: playback.currentSongId,
      bufferState: bufferState,
      duration: duration,
    );
    final seekPreviewPosition = Duration(milliseconds: sliderValue.round());
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final preferredMixMode = ref.watch(preferredMixModeProvider);
    final instantMix = ref.watch(instantMixProvider);
    final sameVibes = ref.watch(sameVibesProvider);
    final mixActive = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? instantMix.active
        : sameVibes.active;
    final mixLoading = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? (instantMix.refilling && instantMix.active)
        : (sameVibes.refilling && sameVibes.active);
    final mixSeedSongId = playback.currentSongId;
    final canToggleMix =
        mixSeedSongId != null && mixSeedSongId.trim().isNotEmpty;
    final isRemoteSeedId =
        mixSeedSongId != null && !isServerAddressableSongId(mixSeedSongId);
    final canToggleLegacyMix =
        canToggleMix &&
        !(isRemoteSeedId &&
            preferredMixMode == PreferredMixMode.legacyInstantMix);

    final repeatMode = playback.repeatMode;
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
    final barColor = Color.alphaBlend(
      colors.primary.withValues(alpha: 0.024),
      colors.surfaceContainerLow,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Material(
        key: const ValueKey<String>('desktopPlayerBar'),
        color: barColor,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 116,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = constraints.maxWidth;
                if (maxWidth < 700) {
                  return const SizedBox.expand();
                }
                final compactLayout = maxWidth < 980;
                final metadataWidth = maxWidth < 900
                    ? 220.0
                    : (compactLayout ? 292.0 : 352.0);
                final metadataTextWidth = maxWidth < 900
                    ? 154.0
                    : (compactLayout ? 156.0 : 208.0);
                final controlRailMaxWidth = math
                    .min(760, math.max(280, maxWidth * 0.58))
                    .toDouble();
                final actionRegionWidth = (maxWidth * 0.20)
                    .clamp(184.0, 240.0)
                    .toDouble();
                final useCompactVolume = maxWidth < 1008;
                // The bar itself is fixed at 116 px. Measure against that
                // contract rather than waiting for an impossible <=100 px
                // outer constraint; otherwise the slider, labels, and
                // transport row can overflow vertically on tall/narrow
                // desktop windows.
                final tightHeight = constraints.maxHeight <= 120;
                final denseControls = maxWidth <= 820 || tightHeight;
                final controlButtonExtent = tightHeight
                    ? 36.0
                    : (denseControls ? 40.0 : 44.0);
                final primaryControlExtent = tightHeight
                    ? 44.0
                    : (denseControls ? 48.0 : 54.0);
                final controlIconSize = tightHeight
                    ? 20.0
                    : (denseControls ? 22.0 : 24.0);
                final primaryIconSize = tightHeight
                    ? 24.0
                    : (denseControls ? 26.0 : 28.0);
                final verticalInset = tightHeight
                    ? 4.0
                    : (denseControls ? 6.0 : 8.0);
                final sliderBottomSpacing = tightHeight
                    ? 1.0
                    : (denseControls ? 4.0 : 6.0);
                final timeBottomSpacing = tightHeight
                    ? 0.0
                    : (denseControls ? 2.0 : 4.0);
                final sliderTrackHeight = tightHeight ? 2.5 : 3.0;
                final sliderThumbRadius = tightHeight ? 4.0 : 5.0;
                final sliderOverlayRadius = tightHeight ? 8.0 : 11.0;
                final sliderAreaHeight = tightHeight ? 28.0 : null;
                final controlsAreaHeight = tightHeight
                    ? primaryControlExtent
                    : null;
                final showTimeLabels = !tightHeight;
                final timeStyle = Theme.of(context).textTheme.labelSmall
                    ?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontSize: tightHeight ? 10 : null,
                      height: tightHeight ? 1 : null,
                    );

                Future<void> togglePlayPause() async {
                  final handler = ref.read(audioHandlerProvider);
                  if (handler == null) {
                    return;
                  }
                  if (isPlaying) {
                    await handler.pause();
                  } else {
                    await handler.play();
                  }
                }

                Future<void> skipForwardOrStopRadio() async {
                  final handler = ref.read(audioHandlerProvider);
                  if (handler == null) {
                    return;
                  }
                  if (playback.isRadioMode) {
                    await handler.stopRadio();
                  } else {
                    await handler.skipToNext();
                  }
                }

                void skipBackward() {
                  if (playback.isRadioMode) {
                    return;
                  }
                  unawaited(ref.read(audioHandlerProvider)?.skipToPrevious());
                }

                Future<void> setPlaybackVolume(
                  double rawValue, {
                  required String source,
                  bool logChange = false,
                }) async {
                  final volumeNotifier = ref.read(
                    playbackVolumeProvider.notifier,
                  );
                  final volume = await volumeNotifier.setVolume(
                    rawValue,
                    persistImmediately: logChange,
                  );
                  if (logChange) {
                    AppLogger.debug(
                      '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                    );
                  }
                }

                Future<void> toggleMute({required String source}) async {
                  final volume = await ref
                      .read(playbackVolumeProvider.notifier)
                      .toggleMute();
                  AppLogger.debug(
                    '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                  );
                }

                Widget persistentActionButton({
                  required String keyName,
                  required String tooltip,
                  required IconData icon,
                  required VoidCallback? onPressed,
                  Color? iconColor,
                  FocusNode? focusNode,
                }) {
                  return Semantics(
                    key: ValueKey<String>(keyName),
                    container: true,
                    button: true,
                    enabled: onPressed != null,
                    label: tooltip,
                    onTap: onPressed,
                    excludeSemantics: true,
                    child: Tooltip(
                      message: tooltip,
                      child: IconButton(
                        focusNode: focusNode,
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(44),
                          maximumSize: const Size.square(44),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: onPressed,
                        icon: Icon(icon, color: iconColor),
                      ),
                    ),
                  );
                }

                final resolvedAlbumId = (widget.albumId ?? '').trim();
                final canOpenAlbum =
                    resolvedAlbumId.isNotEmpty && !playback.isRadioMode;

                Widget coverArtWidget;
                if (!hasPlayback) {
                  coverArtWidget = Container(
                    width: compactLayout ? 42 : 48,
                    height: compactLayout ? 42 : 48,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.music_note_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  );
                } else if (widget.coverArtId == null ||
                    widget.coverArtId!.trim().isEmpty) {
                  coverArtWidget = _MiniRemoteArt(
                    artUrl: widget.coverArtUrl,
                    colorScheme: colors,
                    size: compactLayout ? 42 : 48,
                  );
                } else {
                  coverArtWidget = CoverArtImage(
                    coverArtId: widget.coverArtId,
                    size: kCoverArtStandardSize,
                    width: compactLayout ? 42 : 48,
                    height: compactLayout ? 42 : 48,
                    borderRadius: BorderRadius.circular(8),
                    loadPriority: CoverArtLoadPriority.critical,
                    isExternalSource: widget.isExternalSource,
                    remoteSourceIndicatorPolicy:
                        RemoteSourceIndicatorPolicy.hidden,
                  );
                }

                if (canOpenAlbum) {
                  coverArtWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => unawaited(
                        NormalPlaybackMetadataNavigator.goToAlbum(
                          context,
                          ref,
                          albumId: resolvedAlbumId,
                          artistId: widget.artistId,
                          artistName: widget.songArtist,
                        ),
                      ),
                      child: coverArtWidget,
                    ),
                  );
                } else if (playback.isRadioMode &&
                    (widget.coverArtUrl ?? '').trim().isNotEmpty) {
                  coverArtWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => showRemoteArtViewer(
                        context,
                        artUrl: widget.coverArtUrl,
                      ),
                      child: coverArtWidget,
                    ),
                  );
                }

                final playerSurface = Padding(
                  padding: EdgeInsets.fromLTRB(
                    compactLayout ? 10 : 14,
                    verticalInset,
                    compactLayout ? 8 : 12,
                    verticalInset,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: metadataWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Row(
                            children: <Widget>[
                              coverArtWidget,
                              SizedBox(width: compactLayout ? 8 : 10),
                              SizedBox(
                                width: metadataTextWidth,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    // Title — tappable for radio search and normal cached metadata navigation.
                                    if (playback.isRadioMode &&
                                        (widget.songTitle ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () {
                                            NavService.openSearch(
                                              context,
                                              ref,
                                              widget.songTitle!.trim(),
                                              filter: SearchResultType.songs,
                                            );
                                          },
                                          child: Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                      )
                                    else if (!playback.isRadioMode &&
                                        (widget.songTitle ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () => unawaited(
                                            NormalPlaybackMetadataNavigator.goToTitle(
                                              context,
                                              ref,
                                              title: widget.songTitle,
                                              albumId: widget.albumId,
                                              artistId: widget.artistId,
                                              artistName: widget.songArtist,
                                            ),
                                          ),
                                          child: Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                      )
                                    else
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    if (canOpenArtist)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                            alignment: Alignment.centerLeft,
                                            foregroundColor: colors.primary,
                                          ),
                                          onPressed: () => unawaited(
                                            NormalPlaybackMetadataNavigator.goToArtist(
                                              context,
                                              ref,
                                              artistId: widget.artistId,
                                              artistName: widget.songArtist,
                                            ),
                                          ),
                                          child: Text(
                                            artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      )
                                    else if (playback.isRadioMode &&
                                        (widget.songArtist ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      Wrap(
                                        spacing: 0,
                                        runSpacing: 0,
                                        children: [
                                          for (final (i, name)
                                              in splitArtistNames(
                                                widget.songArtist!,
                                              ).indexed) ...<Widget>[
                                            if (i > 0)
                                              Text(
                                                ', ',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: colors
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            MouseRegion(
                                              cursor: SystemMouseCursors.click,
                                              child: GestureDetector(
                                                onTap: () {
                                                  NavService.openSearch(
                                                    context,
                                                    ref,
                                                    name,
                                                    filter: SearchResultType
                                                        .artists,
                                                  );
                                                },
                                                child: Text(
                                                  name,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: colors.primary,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      )
                                    else
                                      Text(
                                        artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    if (widget.isExternalSource)
                                      const RemoteSourceIndicator(
                                        variant:
                                            RemoteSourceIndicatorVariant.inline,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: controlRailMaxWidth,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                if (!playback.isRadioMode)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: sliderBottomSpacing,
                                    ),
                                    child: SizedBox(
                                      height: sliderAreaHeight,
                                      child: canSeek
                                          ? SliderTheme(
                                              data: SliderTheme.of(context)
                                                  .copyWith(
                                                    padding: EdgeInsets.zero,
                                                    trackHeight:
                                                        sliderTrackHeight,
                                                    thumbShape:
                                                        RoundSliderThumbShape(
                                                          enabledThumbRadius:
                                                              sliderThumbRadius,
                                                        ),
                                                    overlayShape:
                                                        RoundSliderOverlayShape(
                                                          overlayRadius:
                                                              sliderOverlayRadius,
                                                        ),
                                                  ),
                                              child: Slider(
                                                value: sliderValue,
                                                secondaryTrackValue:
                                                    bufferedValue,
                                                secondaryActiveColor:
                                                    resolveBufferedSeekColor(
                                                      context,
                                                    ),
                                                max: sliderMax,
                                                onChangeStart: (value) {
                                                  setState(() {
                                                    _dragSliderValue = value;
                                                  });
                                                },
                                                onChanged: (value) {
                                                  setState(() {
                                                    _dragSliderValue = value;
                                                  });
                                                },
                                                onChangeEnd: (value) {
                                                  setState(() {
                                                    _dragSliderValue = null;
                                                  });
                                                  unawaited(
                                                    ref
                                                        .read(
                                                          audioHandlerProvider,
                                                        )
                                                        ?.seek(
                                                          Duration(
                                                            milliseconds: value
                                                                .round(),
                                                          ),
                                                        ),
                                                  );
                                                },
                                              ),
                                            )
                                          : Align(
                                              alignment: Alignment.center,
                                              child: LinearProgressIndicator(
                                                value: playback.isRadioMode
                                                    ? (playback.processingState ==
                                                                  AudioProcessingState
                                                                      .loading ||
                                                              playback.processingState ==
                                                                  AudioProcessingState
                                                                      .buffering
                                                          ? null
                                                          : 0.0)
                                                    : progress,
                                                minHeight: 3,
                                                color: colors.primary,
                                                backgroundColor: colors.primary
                                                    .withValues(alpha: 0.12),
                                              ),
                                            ),
                                    ),
                                  ),
                                if (!playback.isRadioMode && showTimeLabels)
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      4,
                                      0,
                                      4,
                                      timeBottomSpacing,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: <Widget>[
                                        Text(
                                          formatDuration(
                                            seekPreviewPosition,
                                            showHours: true,
                                          ),
                                          style: timeStyle,
                                        ),
                                        Text(
                                          canSeek
                                              ? formatDuration(
                                                  duration,
                                                  showHours: true,
                                                )
                                              : '--:--',
                                          style: timeStyle,
                                        ),
                                      ],
                                    ),
                                  ),
                                SizedBox(
                                  height: controlsAreaHeight,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          key: const ValueKey<String>(
                                            'desktopPlayerPreviousButton',
                                          ),
                                          tooltip: canToggleLegacyMix
                                              ? l10n.nowPlayingInstantMixLabel
                                              : l10n.desktopPlaybackUnavailableTooltip,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed:
                                              !playback.isRadioMode &&
                                                  canToggleLegacyMix
                                              ? () => unawaited(
                                                  togglePreferredMixMode(
                                                    ref,
                                                    seedSongId: mixSeedSongId,
                                                  ),
                                                )
                                              : null,
                                          icon: mixLoading
                                              ? SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: mixActive
                                                        ? colors.primary
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                )
                                              : Icon(
                                                  mixActive
                                                      ? Icons.explore
                                                      : Icons.explore_outlined,
                                                  color: mixActive
                                                      ? colors.primary
                                                      : null,
                                                ),
                                        ),
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          tooltip: hasPlayback
                                              ? l10n.nowPlayingPrevious
                                              : l10n.desktopPlaybackUnavailableTooltip,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: hasPlayback
                                              ? skipBackward
                                              : null,
                                          icon: const Icon(
                                            Icons.skip_previous_rounded,
                                          ),
                                        ),
                                      IconButton.filledTonal(
                                        key: const ValueKey<String>(
                                          'desktopPlayerPlayPauseButton',
                                        ),
                                        tooltip:
                                            hasPlayback || hasResumableQueue
                                            ? (isPlaying
                                                  ? l10n.miniPlayerPause
                                                  : l10n.miniPlayerPlay)
                                            : l10n.desktopPlaybackUnavailableTooltip,
                                        style: IconButton.styleFrom(
                                          minimumSize: Size.square(
                                            primaryControlExtent,
                                          ),
                                          maximumSize: Size.square(
                                            primaryControlExtent,
                                          ),
                                          shape: const CircleBorder(),
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed:
                                            hasPlayback || hasResumableQueue
                                            ? () => unawaited(togglePlayPause())
                                            : null,
                                        icon: _remoteLoadingPlayPauseIcon(
                                          isExternalSource:
                                              widget.isExternalSource,
                                          playback: playback,
                                          isPlaying: isPlaying,
                                          loadingColor: Theme.of(context)
                                              .colorScheme
                                              .onSecondaryContainer,
                                          size: primaryIconSize,
                                        ),
                                      ),
                                      IconButton(
                                        key: const ValueKey<String>(
                                          'desktopPlayerNextButton',
                                        ),
                                        tooltip: !hasPlayback
                                            ? l10n.desktopPlaybackUnavailableTooltip
                                            : playback.isRadioMode
                                            ? l10n.radioStopStation
                                            : l10n.miniPlayerSkipNext,
                                        iconSize: controlIconSize,
                                        style: IconButton.styleFrom(
                                          minimumSize: Size.square(
                                            controlButtonExtent,
                                          ),
                                          maximumSize: Size.square(
                                            controlButtonExtent,
                                          ),
                                          shape: const CircleBorder(),
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: hasPlayback
                                            ? () => unawaited(
                                                skipForwardOrStopRadio(),
                                              )
                                            : null,
                                        icon: Icon(
                                          playback.isRadioMode
                                              ? Icons.stop_rounded
                                              : Icons.skip_next_rounded,
                                        ),
                                      ),
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          key: const ValueKey<String>(
                                            'desktopPlayerRepeatButton',
                                          ),
                                          tooltip: hasPlayback
                                              ? repeatTooltip
                                              : l10n.desktopPlaybackUnavailableTooltip,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed:
                                              playback.isRadioMode ||
                                                  !hasPlayback
                                              ? null
                                              : () {
                                                  final handler = ref.read(
                                                    audioHandlerProvider,
                                                  );
                                                  final next =
                                                      switch (repeatMode) {
                                                        AudioServiceRepeatMode
                                                            .none =>
                                                          AudioServiceRepeatMode
                                                              .all,
                                                        AudioServiceRepeatMode
                                                            .all =>
                                                          AudioServiceRepeatMode
                                                              .one,
                                                        AudioServiceRepeatMode
                                                            .one =>
                                                          AudioServiceRepeatMode
                                                              .none,
                                                        AudioServiceRepeatMode
                                                            .group =>
                                                          AudioServiceRepeatMode
                                                              .none,
                                                      };
                                                  unawaited(
                                                    handler?.setRepeatMode(
                                                      next,
                                                    ),
                                                  );
                                                },
                                          icon: Icon(
                                            repeatIcon,
                                            color: isRepeatActive
                                                ? colors.primary
                                                : null,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: actionRegionWidth,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            SizedBox(
                              height: 44,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: <Widget>[
                                  persistentActionButton(
                                    keyName: 'desktopPlayerFavoriteButton',
                                    tooltip: playback.isRadioMode
                                        ? l10n.desktopFavoriteUnavailableForRadio
                                        : hasPlayback
                                        ? (playback.isCurrentSongLiked
                                              ? l10n.actionLiked
                                              : l10n.actionLike)
                                        : l10n.desktopPlaybackUnavailableTooltip,
                                    onPressed:
                                        hasPlayback && !playback.isRadioMode
                                        ? () => unawaited(
                                            ref
                                                .read(audioHandlerProvider)
                                                ?.toggleLike(),
                                          )
                                        : null,
                                    icon: playback.isCurrentSongLiked
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    iconColor: playback.isCurrentSongLiked
                                        ? colors.primary
                                        : null,
                                  ),
                                  persistentActionButton(
                                    keyName: 'desktopPlayerLyricsButton',
                                    tooltip: playback.isRadioMode
                                        ? l10n.desktopLyricsUnavailableForRadio
                                        : hasPlayback
                                        ? l10n.nowPlayingLyrics
                                        : l10n.desktopPlaybackUnavailableTooltip,
                                    icon: Icons.lyrics_outlined,
                                    iconColor: widget.lyricsActive
                                        ? colors.primary
                                        : null,
                                    onPressed:
                                        hasPlayback && !playback.isRadioMode
                                        ? widget.onToggleLyrics
                                        : null,
                                  ),
                                  persistentActionButton(
                                    keyName: 'desktopQueueButton',
                                    focusNode: widget.queueToggleFocusNode,
                                    tooltip: playback.isRadioMode
                                        ? l10n.desktopQueueUnavailableForRadio
                                        : canOpenQueue
                                        ? l10n.queueTitle
                                        : l10n.desktopPlaybackUnavailableTooltip,
                                    onPressed: canOpenQueue
                                        ? widget.onToggleQueue
                                        : null,
                                    icon: Icons.queue_music_outlined,
                                  ),
                                  persistentActionButton(
                                    keyName: 'desktopPlayerMiniPlayerButton',
                                    tooltip: l10n.desktopMiniPlayerOpen,
                                    onPressed: () => unawaited(
                                      ref
                                          .read(
                                            desktopWindowControllerProvider,
                                          )
                                          .setMiniPlayerMode(true),
                                    ),
                                    icon: Icons.picture_in_picture_alt_rounded,
                                  ),
                                ],
                              ),
                            ),
                            DesktopVolumeSlider(
                              key: const ValueKey<String>(
                                'desktopPlayerVolumeSlider',
                              ),
                              volume: playbackVolume,
                              compact: useCompactVolume,
                              semanticLabel: l10n.playbackVolumeSemanticLabel,
                              muteTooltip: l10n.playbackMuteTooltip,
                              unmuteTooltip: l10n.playbackUnmuteTooltip,
                              onChanged: (value) => unawaited(
                                setPlaybackVolume(
                                  value,
                                  source: 'desktop_player_bar_live',
                                ),
                              ),
                              onChangeEnd: (value) => unawaited(
                                setPlaybackVolume(
                                  value,
                                  source: 'desktop_player_bar_settle',
                                  logChange: true,
                                ),
                              ),
                              onMuteToggle: () => unawaited(
                                toggleMute(source: 'desktop_player_icon'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );

                return playerSurface;
              },
            ),
          ),
        ),
      ),
    );
  }
}
