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
    final isPlaying = playback.playing;
    final title = (widget.songTitle == null || widget.songTitle!.trim().isEmpty)
        ? l10n.miniPlayerUnknownTrack
        : widget.songTitle!;
    final artist =
        (widget.songArtist == null || widget.songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : widget.songArtist!;
    final resolvedArtistId = (widget.artistId ?? '').trim();
    final canOpenArtist = resolvedArtistId.isNotEmpty && !playback.isRadioMode;

    final livePosition = ref.watch(playbackPositionProvider).asData?.value;
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
                final compactLayout = maxWidth < 980;
                final showQueueAction = maxWidth >= 720;
                final showVolumeControl = maxWidth >= 860;
                final showInlineLikeAction =
                    !playback.isRadioMode && maxWidth >= 760;
                final metadataWidth = compactLayout ? 292.0 : 352.0;
                final metadataTextWidth = compactLayout ? 156.0 : 208.0;
                const likeGapWidth = 8.0;
                const likeSlotWidth = 40.0;
                final controlRailMaxWidth = math
                    .min(760, math.max(280, maxWidth * 0.58))
                    .toDouble();
                final tightHeight = constraints.maxHeight <= 100;
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
                  final volume = volumeNotifier.setVolume(rawValue);
                  if (logChange) {
                    AppLogger.debug(
                      '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                    );
                  }
                  await ref.read(audioHandlerProvider)?.setVolume(volume);
                }

                Future<void> toggleMute({required String source}) async {
                  final volume = ref
                      .read(playbackVolumeProvider.notifier)
                      .toggleMute();
                  AppLogger.debug(
                    '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                  );
                  await ref.read(audioHandlerProvider)?.setVolume(volume);
                }

                final resolvedAlbumId = (widget.albumId ?? '').trim();
                final canOpenAlbum =
                    resolvedAlbumId.isNotEmpty && !playback.isRadioMode;

                Widget coverArtWidget;
                if (widget.coverArtId == null ||
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
                  );
                }

                if (canOpenAlbum) {
                  coverArtWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () =>
                          NavService.goToAlbum(context, ref, resolvedAlbumId),
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
                                    // Title — tappable for radio (search songs)
                                    if (playback.isRadioMode &&
                                        (widget.songTitle ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () {
                                            ref
                                                .read(
                                                  searchFilterProvider.notifier,
                                                )
                                                .select(SearchResultType.songs);
                                            NavService.goToSearch(
                                              context,
                                              ref,
                                              widget.songTitle!.trim(),
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
                                          onPressed: () =>
                                              NavService.goToArtist(
                                                context,
                                                ref,
                                                resolvedArtistId,
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
                                                  ref
                                                      .read(
                                                        searchFilterProvider
                                                            .notifier,
                                                      )
                                                      .select(
                                                        SearchResultType
                                                            .artists,
                                                      );
                                                  NavService.goToSearch(
                                                    context,
                                                    ref,
                                                    name,
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
                                  ],
                                ),
                              ),
                              const SizedBox(width: likeGapWidth),
                              SizedBox(
                                width: likeSlotWidth,
                                child: showInlineLikeAction
                                    ? IconButton(
                                        tooltip: playback.isCurrentSongLiked
                                            ? l10n.actionLiked
                                            : l10n.actionLike,
                                        visualDensity: VisualDensity.compact,
                                        style: IconButton.styleFrom(
                                          minimumSize: const Size(38, 38),
                                          padding: const EdgeInsets.all(4),
                                        ),
                                        onPressed: () {
                                          unawaited(
                                            ref
                                                .read(audioHandlerProvider)
                                                ?.toggleLike(),
                                          );
                                        },
                                        icon: Icon(
                                          playback.isCurrentSongLiked
                                              ? Icons.favorite
                                              : Icons.favorite_border,
                                          color: playback.isCurrentSongLiked
                                              ? colors.primary
                                              : null,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
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
                                          tooltip:
                                              l10n.nowPlayingInstantMixLabel,
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
                                          tooltip: l10n.nowPlayingPrevious,
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
                                          onPressed: skipBackward,
                                          icon: const Icon(
                                            Icons.skip_previous_rounded,
                                          ),
                                        ),
                                      IconButton.filledTonal(
                                        tooltip: isPlaying
                                            ? l10n.miniPlayerPause
                                            : l10n.miniPlayerPlay,
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
                                        onPressed: () =>
                                            unawaited(togglePlayPause()),
                                        icon: Icon(
                                          isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          size: primaryIconSize,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: playback.isRadioMode
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
                                        onPressed: () =>
                                            unawaited(skipForwardOrStopRadio()),
                                        icon: Icon(
                                          playback.isRadioMode
                                              ? Icons.stop_rounded
                                              : Icons.skip_next_rounded,
                                        ),
                                      ),
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          tooltip: repeatTooltip,
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
                                          onPressed: playback.isRadioMode
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
                        width: showVolumeControl ? 344 : 152,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            const GroupListeningSessionButton(),
                            if (!playback.isRadioMode)
                              IconButton(
                                tooltip: l10n.nowPlayingLyrics,
                                icon: Icon(
                                  Icons.lyrics_outlined,
                                  color: widget.lyricsActive
                                      ? colors.primary
                                      : null,
                                ),
                                onPressed: widget.onToggleLyrics,
                              ),
                            if (showVolumeControl) ...<Widget>[
                              DesktopVolumeSlider(
                                key: const ValueKey<String>(
                                  'desktopPlayerVolumeSlider',
                                ),
                                volume: playbackVolume,
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
                              const SizedBox(width: 6),
                            ],
                            if (showQueueAction && !playback.isRadioMode)
                              IconButton(
                                key: const ValueKey<String>(
                                  'desktopQueueButton',
                                ),
                                focusNode: widget.queueToggleFocusNode,
                                tooltip: l10n.queueTitle,
                                onPressed: widget.onToggleQueue,
                                icon: const Icon(Icons.queue_music_outlined),
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
