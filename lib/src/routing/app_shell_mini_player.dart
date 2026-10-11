part of 'app_shell.dart';

Widget _remoteLoadingPlayPauseIcon({
  required bool isExternalSource,
  required PlaybackSnapshot playback,
  required bool isPlaying,
  required Color loadingColor,
  double? size,
}) {
  if (shouldShowRemotePlaybackLoading(
    playback: playback,
    currentIsExternal: isExternalSource,
  )) {
    final dimension = size ?? 22.0;
    return SizedBox.square(
      dimension: dimension,
      child: CircularProgressIndicator(color: loadingColor, strokeWidth: 2.4),
    );
  }
  return Icon(
    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
    size: size,
  );
}

/// Cover art for the mini players: radio station art, remote/non-library
/// fallback art or the library cover.
Widget _miniPlayerArtwork({
  required bool isRadio,
  required String? radioArtUrl,
  required String? coverArtId,
  required String? coverArtUrl,
  required bool isExternalSource,
  required double size,
  required ColorScheme colorScheme,
  double? placeholderSize,
}) {
  // The compact-wide strip draws a 64 px cover but keeps 48 px radio/remote
  // art, so the placeholder extent is separate.
  final fallbackSize = placeholderSize ?? size;
  if (isRadio) {
    return _MiniRadioArt(
      artUrl: radioArtUrl,
      colorScheme: colorScheme,
      size: fallbackSize,
    );
  }
  if (coverArtId == null || coverArtId.trim().isEmpty) {
    return _MiniRemoteArt(
      artUrl: coverArtUrl,
      colorScheme: colorScheme,
      size: fallbackSize,
    );
  }
  return CoverArtImage(
    coverArtId: coverArtId,
    size: kCoverArtStandardSize,
    width: size,
    height: size,
    shape: ArtworkShapeRole.cover,
    loadPriority: CoverArtLoadPriority.critical,
    isExternalSource: isExternalSource,
    remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
  );
}

/// Title and artist lines of the plain (non-navigating) mini player strip.
/// [large] selects the compact-wide landscape typography and spacing.
Widget _miniPlayerTrackText(
  BuildContext context, {
  required String? title,
  required String? artist,
  required bool isExternalSource,
  required bool large,
}) {
  final l10n = AppLocalizations.of(context)!;
  final textTheme = Theme.of(context).textTheme;
  final cs = Theme.of(context).colorScheme;
  return Column(
    mainAxisAlignment: large
        ? MainAxisAlignment.center
        : MainAxisAlignment.start,
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: large ? MainAxisSize.max : MainAxisSize.min,
    children: <Widget>[
      Text(
        (title == null || title.trim().isEmpty)
            ? l10n.miniPlayerUnknownTrack
            : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (large ? textTheme.bodyLarge : textTheme.bodyMedium)?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      if (isExternalSource)
        const RemoteSourceIndicator(
          variant: RemoteSourceIndicatorVariant.inline,
        ),
      SizedBox(height: large ? 3 : 2),
      Text(
        (artist == null || artist.trim().isEmpty)
            ? l10n.miniPlayerUnknownArtist
            : artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (large ? textTheme.bodyMedium : textTheme.bodySmall)?.copyWith(
          color: cs.onSurface.withValues(alpha: large ? 0.58 : 0.6),
        ),
      ),
    ],
  );
}

void _miniSkipPrevious(WidgetRef ref) {
  final handler = ref.read(audioHandlerProvider);
  if (handler == null) {
    return;
  }
  unawaited(HapticFeedback.lightImpact());
  unawaited(handler.skipToPrevious());
}

void _miniSkipNext(WidgetRef ref) {
  final handler = ref.read(audioHandlerProvider);
  if (handler == null) {
    return;
  }
  unawaited(HapticFeedback.lightImpact());
  unawaited(handler.skipToNext());
}

Future<void> _miniStopRadio(WidgetRef ref) async {
  await ref.read(audioHandlerProvider)?.stopRadio();
}

void _miniToggleLike(WidgetRef ref) {
  unawaited(HapticFeedback.lightImpact());
  unawaited(ref.read(audioHandlerProvider)?.toggleLike());
}

class _RailMiniPlayer extends ConsumerStatefulWidget {
  const new({
    required this.playback,
    required this.onOpenPlayer,
    this.songTitle,
    this.songArtist,
    this.artistId,
    this.albumId,
    this.coverArtId,
    this.coverArtUrl,
    this.isExternalSource = false,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onOpenPlayer;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final bool isRadio;
  final String? radioArtUrl;

  @override
  ConsumerState<_RailMiniPlayer> createState() => _RailMiniPlayerState();
}

class _RailMiniPlayerState extends ConsumerState<_RailMiniPlayer> {
  double? _dragSliderValue;
  double _lastSeekPreviewMs = 0;
  bool _isSeeking = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final colorStyle = NavisColorStyleData.of(context);
    final playFill = colorStyle.playButtonFill(cs);
    final onPlayFill = colorStyle.onPlayButtonFill(cs);
    final playback = widget.playback;
    // Position and buffer ticks arrive 5-10 times a second. Only the slider
    // and progress leaves below watch them, so the rest of the player is not
    // rebuilt on every tick.
    final isPlaying = playback.playing;
    final duration = playback.duration;
    final durationMs = duration.inMilliseconds;
    final canSeek = !widget.isRadio && durationMs > 0;
    final sliderMax = canSeek ? durationMs.toDouble() : 1.0;
    final seekPreviewPosition = Duration(
      milliseconds: (_dragSliderValue ?? _lastSeekPreviewMs).round(),
    );
    final seekPreviewText = Text(
      '${formatDuration(seekPreviewPosition, showHours: true)} / '
      '${formatDuration(duration, showHours: true)}',
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
    // Flat drops the blur: the preview sits on an opaque container fill.
    final seekPreview = NavisColorStyleData.of(context).flatNowPlaying
        ? ColoredBox(
            color: cs.surfaceContainerHigh,
            child: Center(child: seekPreviewText),
          )
        : BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              color: cs.surface.withValues(alpha: 0.24),
              alignment: Alignment.center,
              child: seekPreviewText,
            ),
          );
    final artistDisplay =
        (widget.songArtist == null || widget.songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : widget.songArtist!;
    final resolvedArtistId = (widget.artistId ?? '').trim();
    final resolvedAlbumId = (widget.albumId ?? '').trim();
    final canNavigateArtist =
        !widget.isRadio &&
        (resolvedArtistId.isNotEmpty ||
            (widget.songArtist ?? '').trim().isNotEmpty);
    final canNavigateTitle =
        !widget.isRadio && (widget.songTitle ?? '').trim().isNotEmpty;
    final canNavigateAlbum = !widget.isRadio && resolvedAlbumId.isNotEmpty;
    const compactButtonConstraints = BoxConstraints(
      minWidth: 46,
      minHeight: 46,
    );

    final fullMiniPlayer = KeyedSubtree(
      key: const ValueKey<String>('railMiniPlayer'),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Material(
                color: Colors.transparent,
                borderRadius: NavisShapeData.of(context).xlAll,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onOpenPlayer,
                  borderRadius: NavisShapeData.of(context).xlAll,
                  child: Stack(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Builder(
                                  builder: (context) {
                                    final art = _miniPlayerArtwork(
                                      isRadio: widget.isRadio,
                                      radioArtUrl: widget.radioArtUrl,
                                      coverArtId: widget.coverArtId,
                                      coverArtUrl: widget.coverArtUrl,
                                      isExternalSource: widget.isExternalSource,
                                      size: 44,
                                      colorScheme: cs,
                                    );
                                    if (!canNavigateAlbum) {
                                      return art;
                                    }
                                    return MouseRegion(
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
                                        child: art,
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (canNavigateTitle)
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
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
                                          child: MouseRegion(
                                            cursor: SystemMouseCursors.click,
                                            child: Text(
                                              widget.songTitle!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              softWrap: false,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    color: cs.primary,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 17,
                                                    height: 1.15,
                                                  ),
                                            ),
                                          ),
                                        )
                                      else
                                        Text(
                                          (widget.songTitle == null ||
                                                  widget.songTitle!
                                                      .trim()
                                                      .isEmpty)
                                              ? l10n.miniPlayerUnknownTrack
                                              : widget.songTitle!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 17,
                                                height: 1.15,
                                              ),
                                        ),
                                      if (widget.isExternalSource)
                                        const RemoteSourceIndicator(
                                          variant: RemoteSourceIndicatorVariant
                                              .inline,
                                        ),
                                      const SizedBox(height: 1),
                                      if (canNavigateArtist)
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => unawaited(
                                            NormalPlaybackMetadataNavigator.goToArtist(
                                              context,
                                              ref,
                                              artistId: widget.artistId,
                                              artistName: widget.songArtist,
                                            ),
                                          ),
                                          child: MouseRegion(
                                            cursor: SystemMouseCursors.click,
                                            child: Text(
                                              artistDisplay,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: cs.primary,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                            ),
                                          ),
                                        )
                                      else
                                        Text(
                                          artistDisplay,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: cs.onSurfaceVariant,
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            LayoutBuilder(
                              builder: (context, controlsConstraints) {
                                final ultraCompact =
                                    controlsConstraints.maxWidth < 150;
                                final controls = <Widget>[
                                  IconButton(
                                    tooltip: l10n.nowPlayingPrevious,
                                    constraints: compactButtonConstraints,
                                    padding: EdgeInsets.zero,
                                    iconSize: 24,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: widget.isRadio
                                        ? null
                                        : () => _miniSkipPrevious(ref),
                                    icon: const Icon(
                                      Icons.skip_previous_rounded,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: isPlaying
                                        ? l10n.miniPlayerPause
                                        : l10n.miniPlayerPlay,
                                    constraints: compactButtonConstraints,
                                    style: IconButton.styleFrom(
                                      backgroundColor: playFill,
                                      foregroundColor: onPlayFill,
                                      side: colorStyle.controlEdgeSide,
                                      shape: const CircleBorder(),
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(46, 46),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () => togglePlayPause(
                                      ref,
                                      isPlaying: isPlaying,
                                    ),
                                    icon: _remoteLoadingPlayPauseIcon(
                                      isExternalSource: widget.isExternalSource,
                                      playback: playback,
                                      isPlaying: isPlaying,
                                      loadingColor: onPlayFill,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: widget.isRadio
                                        ? l10n.radioStopStation
                                        : l10n.miniPlayerSkipNext,
                                    constraints: compactButtonConstraints,
                                    padding: EdgeInsets.zero,
                                    iconSize: 24,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      final handler = ref.read(
                                        audioHandlerProvider,
                                      );
                                      if (handler == null) {
                                        return;
                                      }
                                      unawaited(HapticFeedback.lightImpact());
                                      if (widget.isRadio) {
                                        await handler.stopRadio();
                                      } else {
                                        unawaited(handler.skipToNext());
                                      }
                                    },
                                    icon: Icon(
                                      widget.isRadio
                                          ? Icons.stop_rounded
                                          : Icons.skip_next_rounded,
                                    ),
                                  ),
                                  if (!ultraCompact)
                                    IconButton(
                                      tooltip: playback.isCurrentSongLiked
                                          ? l10n.actionLiked
                                          : l10n.actionLike,
                                      constraints: compactButtonConstraints,
                                      padding: EdgeInsets.zero,
                                      iconSize: 24,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: widget.isRadio
                                          ? null
                                          : () => _miniToggleLike(ref),
                                      icon: Icon(
                                        playback.isCurrentSongLiked
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: playback.isCurrentSongLiked
                                            ? cs.primary
                                            : null,
                                      ),
                                    ),
                                ];
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: controls,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            curve: Curves.easeOut,
                            opacity: _isSeeking && canSeek ? 1 : 0,
                            child: ClipRRect(
                              borderRadius: NavisShapeData.of(context).xlAll,
                              child: seekPreview,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (canSeek)
                RepaintBoundary(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final position = watchDisplayedPlaybackPosition(
                        ref,
                        playback,
                      );
                      final bufferState =
                          ref
                              .watch(playbackBufferStateProvider)
                              .asData
                              ?.value ??
                          const PlaybackBufferState.idle();
                      final positionMs = position.inMilliseconds
                          .clamp(0, durationMs)
                          .toDouble();
                      final sliderValue = (_dragSliderValue ?? positionMs)
                          .clamp(0.0, sliderMax);
                      final bufferedValue = resolveBufferedSeekValue(
                        currentSongId: playback.currentSongId,
                        bufferState: bufferState,
                        duration: duration,
                      );
                      return SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: Slider(
                          value: sliderValue,
                          secondaryTrackValue: bufferedValue,
                          secondaryActiveColor: resolveBufferedSeekColor(
                            context,
                          ),
                          max: sliderMax,
                          onChangeStart: (value) {
                            setState(() {
                              _isSeeking = true;
                              _dragSliderValue = value;
                              _lastSeekPreviewMs = value;
                            });
                          },
                          onChanged: (value) {
                            setState(() {
                              _dragSliderValue = value;
                              _lastSeekPreviewMs = value;
                            });
                          },
                          onChangeEnd: (value) {
                            setState(() {
                              _isSeeking = false;
                              _dragSliderValue = null;
                            });
                            unawaited(
                              ref
                                  .read(audioHandlerProvider)
                                  ?.seek(Duration(milliseconds: value.round())),
                            );
                          },
                        ),
                      );
                    },
                  ),
                )
              else
                _LivePlaybackProgressBar(
                  playback: playback,
                  isRadio: widget.isRadio,
                ),
            ],
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tightHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight < 150;
        if (!tightHeight) {
          return fullMiniPlayer;
        }
        return ClipRect(
          child: SingleChildScrollView(
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 150),
              child: fullMiniPlayer,
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayerStrip extends ConsumerStatefulWidget {
  const new({
    required this.playback,
    required this.onTap,
    this.flattenWideStyle = false,
    this.compactWideLandscapeMode = false,
    this.enableVerticalExpandGesture = true,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
    this.coverArtUrl,
    this.isExternalSource = false,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onTap;
  final bool flattenWideStyle;
  final bool compactWideLandscapeMode;
  final bool enableVerticalExpandGesture;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final bool isRadio;
  final String? radioArtUrl;

  @override
  ConsumerState<_MiniPlayerStrip> createState() => _MiniPlayerStripState();
}

class _MiniPlayerStripState extends ConsumerState<_MiniPlayerStrip> {
  static const double _expandSwipeDistance = 56;
  double _verticalDragDistance = 0;
  bool _expandedFromDrag = false;

  void _resetVerticalDragState() {
    _verticalDragDistance = 0;
    _expandedFromDrag = false;
  }

  void _triggerExpandFromDrag() {
    if (_expandedFromDrag) {
      return;
    }
    _expandedFromDrag = true;
    unawaited(HapticFeedback.selectionClick());
    widget.onTap();
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    _resetVerticalDragState();
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_expandedFromDrag) {
      return;
    }
    final delta = details.primaryDelta;
    if (delta == null) {
      return;
    }
    _verticalDragDistance += delta;
    if (_verticalDragDistance <= -_expandSwipeDistance) {
      _triggerExpandFromDrag();
    }
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (!_expandedFromDrag) {
      final velocity = details.primaryVelocity ?? 0;
      if (velocity < -220 || _verticalDragDistance <= -_expandSwipeDistance) {
        _triggerExpandFromDrag();
      }
    }
    _resetVerticalDragState();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final onTap = widget.onTap;
    final flattenWideStyle = widget.flattenWideStyle;
    final compactWideLandscapeMode = widget.compactWideLandscapeMode;
    final enableVerticalExpandGesture = widget.enableVerticalExpandGesture;
    final songTitle = widget.songTitle;
    final songArtist = widget.songArtist;
    final coverArtId = widget.coverArtId;
    final coverArtUrl = widget.coverArtUrl;
    final isRadio = widget.isRadio;
    final radioArtUrl = widget.radioArtUrl;

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final oled = NavisColorStyleData.of(context).oled;
    final colorStyle = NavisColorStyleData.of(context);
    final playFill = colorStyle.playButtonFill(cs);
    final onPlayFill = colorStyle.onPlayButtonFill(cs);
    final miniPlayerColor = oled ? cs.surface : cs.surfaceContainerHigh;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final compactControls = viewportWidth < 380;
    final isPlaying = playback.playing;

    return GestureDetector(
      onHorizontalDragEnd: isRadio
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 300) {
                return;
              }
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              if (velocity < 0) {
                unawaited(HapticFeedback.mediumImpact());
                unawaited(handler.skipToNext());
              } else {
                unawaited(HapticFeedback.mediumImpact());
                unawaited(handler.skipToPrevious());
              }
            },
      onVerticalDragStart: enableVerticalExpandGesture
          ? _handleVerticalDragStart
          : null,
      onVerticalDragUpdate: enableVerticalExpandGesture
          ? _handleVerticalDragUpdate
          : null,
      onVerticalDragEnd: enableVerticalExpandGesture
          ? _handleVerticalDragEnd
          : null,
      onVerticalDragCancel: enableVerticalExpandGesture
          ? _resetVerticalDragState
          : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: (flattenWideStyle && !compactWideLandscapeMode && !oled)
              ? null
              : Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
        ),
        child: Material(
          color: compactWideLandscapeMode
              ? miniPlayerColor
              : (flattenWideStyle ? Colors.transparent : miniPlayerColor),
          child: InkWell(
            onTap: onTap,
            child: compactWideLandscapeMode
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                    child: Row(
                      children: <Widget>[
                        _miniPlayerArtwork(
                          isRadio: isRadio,
                          radioArtUrl: radioArtUrl,
                          coverArtId: coverArtId,
                          coverArtUrl: coverArtUrl,
                          isExternalSource: widget.isExternalSource,
                          size: 64,
                          placeholderSize: 48,
                          colorScheme: cs,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _miniPlayerTrackText(
                            context,
                            title: songTitle,
                            artist: songArtist,
                            isExternalSource: widget.isExternalSource,
                            large: true,
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.nowPlayingPrevious,
                            onPressed: () => _miniSkipPrevious(ref),
                            icon: const Icon(
                              Icons.skip_previous_rounded,
                              size: 28,
                            ),
                          ),
                        IconButton(
                          tooltip: isPlaying
                              ? l10n.miniPlayerPause
                              : l10n.miniPlayerPlay,
                          style: IconButton.styleFrom(
                            backgroundColor: playFill,
                            foregroundColor: onPlayFill,
                            side: colorStyle.controlEdgeSide,
                            shape: const CircleBorder(),
                            minimumSize: const Size(52, 52),
                            padding: const EdgeInsets.all(8),
                          ),
                          onPressed: () =>
                              togglePlayPause(ref, isPlaying: isPlaying),
                          icon: _remoteLoadingPlayPauseIcon(
                            isExternalSource: widget.isExternalSource,
                            playback: playback,
                            isPlaying: isPlaying,
                            loadingColor: onPlayFill,
                            size: 28,
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.miniPlayerSkipNext,
                            onPressed: () => _miniSkipNext(ref),
                            icon: const Icon(Icons.skip_next_rounded, size: 28),
                          )
                        else
                          IconButton(
                            tooltip: l10n.radioStopStation,
                            onPressed: () => _miniStopRadio(ref),
                            icon: const Icon(Icons.stop_rounded, size: 28),
                          ),
                        if (!isRadio)
                          IconButton(
                            tooltip: playback.isCurrentSongLiked
                                ? l10n.actionLiked
                                : l10n.actionLike,
                            onPressed: () => _miniToggleLike(ref),
                            icon: Icon(
                              playback.isCurrentSongLiked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 26,
                              color: playback.isCurrentSongLiked
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 4,
                          top: 7,
                          bottom: 6,
                        ),
                        child: Row(
                          children: <Widget>[
                            _miniPlayerArtwork(
                              isRadio: isRadio,
                              radioArtUrl: radioArtUrl,
                              coverArtId: coverArtId,
                              coverArtUrl: coverArtUrl,
                              isExternalSource: widget.isExternalSource,
                              size: 48,
                              colorScheme: cs,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _miniPlayerTrackText(
                                context,
                                title: songTitle,
                                artist: songArtist,
                                isExternalSource: widget.isExternalSource,
                                large: false,
                              ),
                            ),
                            if (!isRadio)
                              IconButton(
                                tooltip: l10n.nowPlayingPrevious,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _miniSkipPrevious(ref),
                                icon: const Icon(
                                  Icons.skip_previous_rounded,
                                  size: 19,
                                ),
                              ),
                            IconButton(
                              tooltip: isPlaying
                                  ? l10n.miniPlayerPause
                                  : l10n.miniPlayerPlay,
                              style: IconButton.styleFrom(
                                backgroundColor: playFill,
                                foregroundColor: onPlayFill,
                                side: colorStyle.controlEdgeSide,
                                shape: const CircleBorder(),
                                minimumSize: Size(
                                  compactControls ? 40 : 46,
                                  compactControls ? 40 : 46,
                                ),
                                padding: const EdgeInsets.all(6),
                              ),
                              onPressed: () =>
                                  togglePlayPause(ref, isPlaying: isPlaying),
                              icon: _remoteLoadingPlayPauseIcon(
                                isExternalSource: widget.isExternalSource,
                                playback: playback,
                                isPlaying: isPlaying,
                                loadingColor: onPlayFill,
                                size: 22,
                              ),
                            ),
                            if (!isRadio)
                              IconButton(
                                tooltip: l10n.miniPlayerSkipNext,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _miniSkipNext(ref),
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  size: 19,
                                ),
                              )
                            else
                              IconButton(
                                tooltip: l10n.radioStopStation,
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                                onPressed: () => _miniStopRadio(ref),
                                icon: const Icon(Icons.stop_rounded, size: 20),
                              ),
                            if (!isRadio)
                              IconButton(
                                tooltip: playback.isCurrentSongLiked
                                    ? l10n.actionLiked
                                    : l10n.actionLike,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _miniToggleLike(ref),
                                icon: Icon(
                                  playback.isCurrentSongLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 19,
                                  color: playback.isCurrentSongLiked
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            SizedBox(width: compactControls ? 0 : 4),
                          ],
                        ),
                      ),
                      if (!flattenWideStyle)
                        _LivePlaybackProgressBar(
                          playback: playback,
                          isRadio: isRadio,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// The mini players' thin progress bar. It alone watches the playback
/// position, so position ticks repaint the bar rather than the player.
class _LivePlaybackProgressBar extends ConsumerWidget {
  const new({required this.playback, required this.isRadio});

  final PlaybackSnapshot playback;
  final bool isRadio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final double? value;
    if (isRadio) {
      value =
          playback.processingState == AudioProcessingState.loading ||
              playback.processingState == AudioProcessingState.buffering
          ? null
          : 0.0;
    } else {
      final position =
          ref.watch(playbackPositionProvider).asData?.value ??
          playback.position;
      final durationMs = playback.duration.inMilliseconds;
      value = durationMs > 0
          ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
          : 0.0;
    }
    return RepaintBoundary(
      child: LinearProgressIndicator(
        value: value,
        minHeight: 3,
        color: cs.primary,
        backgroundColor: cs.primary.withValues(alpha: 0.12),
      ),
    );
  }
}

/// Small square cover art for a radio station in the mini player.
class _MiniRadioArt extends ConsumerWidget {
  const new({required this.artUrl, required this.colorScheme, this.size = 48});

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: artworkBorderRadius(
        ref.watch(coverArtShapeProvider),
        extent: size,
      ),
      child: url != null && url.isNotEmpty
          ? ExternalArtworkImage(
              url: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              feature: IntegrationFeature.radioNowPlaying,
              fallbackBuilder: (_) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.radio,
        size: size * 0.5,
        color: colorScheme.onPrimaryContainer,
      ),
    );
  }
}

/// Remote/non-library fallback cover art in the mini player.
class _MiniRemoteArt extends ConsumerWidget {
  const new({required this.artUrl, required this.colorScheme, this.size = 48});

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: artworkBorderRadius(
        ref.watch(coverArtShapeProvider),
        extent: size,
      ),
      child: url != null && url.isNotEmpty
          ? ExternalArtworkImage(
              url: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              fallbackBuilder: (_) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: colorScheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
        color: colorScheme.onSecondaryContainer,
      ),
    );
  }
}

/// Fullscreen lyrics overlay shown inside the desktop content area (excluding
/// the sidebar and the bottom player bar).
