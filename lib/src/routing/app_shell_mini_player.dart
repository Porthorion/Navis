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
      child: CircularProgressIndicator(
        color: loadingColor,
        strokeWidth: 2.4,
      ),
    );
  }
  return Icon(
    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
    size: size,
  );
}

class _RailMiniPlayer extends ConsumerStatefulWidget {
  const _RailMiniPlayer({
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
                borderRadius: NavisRadius.xlAll,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onOpenPlayer,
                  borderRadius: NavisRadius.xlAll,
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
                                    Widget art;
                                    if (widget.isRadio) {
                                      art = _MiniRadioArt(
                                        artUrl: widget.radioArtUrl,
                                        colorScheme: cs,
                                        size: 44,
                                      );
                                    } else if (widget.coverArtId == null ||
                                        widget.coverArtId!.trim().isEmpty) {
                                      art = _MiniRemoteArt(
                                        artUrl: widget.coverArtUrl,
                                        colorScheme: cs,
                                        size: 44,
                                      );
                                    } else {
                                      art = CoverArtImage(
                                        coverArtId: widget.coverArtId,
                                        size: kCoverArtStandardSize,
                                        width: 44,
                                        height: 44,
                                        borderRadius: BorderRadius.circular(9),
                                        loadPriority:
                                            CoverArtLoadPriority.critical,
                                        isExternalSource:
                                            widget.isExternalSource,
                                        remoteSourceIndicatorPolicy:
                                            RemoteSourceIndicatorPolicy.hidden,
                                      );
                                    }
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
                                      canNavigateTitle
                                          ? GestureDetector(
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
                                                cursor:
                                                    SystemMouseCursors.click,
                                                child: Text(
                                                  widget.songTitle!,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  softWrap: false,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color: cs.primary,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 17,
                                                        height: 1.15,
                                                      ),
                                                ),
                                              ),
                                            )
                                          : Text(
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
                                      canNavigateArtist
                                          ? GestureDetector(
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
                                                cursor:
                                                    SystemMouseCursors.click,
                                                child: Text(
                                                  artistDisplay,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: cs.primary,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                ),
                                              ),
                                            )
                                          : Text(
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
                                        : () {
                                            unawaited(
                                              HapticFeedback.lightImpact(),
                                            );
                                            unawaited(
                                              ref
                                                  .read(audioHandlerProvider)
                                                  ?.skipToPrevious(),
                                            );
                                          },
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
                                      backgroundColor: cs.primaryContainer,
                                      foregroundColor: cs.onPrimaryContainer,
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(46, 46),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () async {
                                      final handler = ref.read(
                                        audioHandlerProvider,
                                      );
                                      if (handler == null) {
                                        return;
                                      }
                                      if (isPlaying) {
                                        await handler.pause();
                                      } else {
                                        await handler.play();
                                      }
                                    },
                                    icon: _remoteLoadingPlayPauseIcon(
                                      isExternalSource: widget.isExternalSource,
                                      playback: playback,
                                      isPlaying: isPlaying,
                                      loadingColor: cs.onPrimaryContainer,
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
                                          : () {
                                              unawaited(
                                                HapticFeedback.lightImpact(),
                                              );
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
                              borderRadius: NavisRadius.xlAll,
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                                child: Container(
                                  color: cs.surface.withValues(alpha: 0.24),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${formatDuration(seekPreviewPosition, showHours: true)} / '
                                    '${formatDuration(duration, showHours: true)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
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
                      final position =
                          ref.watch(playbackPositionProvider).asData?.value ??
                          playback.position;
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
  const _MiniPlayerStrip({
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
    HapticFeedback.selectionClick();
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
                HapticFeedback.mediumImpact();
                handler.skipToNext();
              } else {
                HapticFeedback.mediumImpact();
                handler.skipToPrevious();
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
          border: (flattenWideStyle && !compactWideLandscapeMode)
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
              ? cs.surfaceContainerHigh
              : (flattenWideStyle
                    ? Colors.transparent
                    : cs.surfaceContainerHigh),
          child: InkWell(
            onTap: onTap,
            child: compactWideLandscapeMode
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                    child: Row(
                      children: <Widget>[
                        if (isRadio)
                          _MiniRadioArt(artUrl: radioArtUrl, colorScheme: cs)
                        else if (coverArtId == null ||
                            coverArtId.trim().isEmpty)
                          _MiniRemoteArt(artUrl: coverArtUrl, colorScheme: cs)
                        else
                          CoverArtImage(
                            coverArtId: coverArtId,
                            size: kCoverArtStandardSize,
                            width: 64,
                            height: 64,
                            borderRadius: BorderRadius.circular(10),
                            loadPriority: CoverArtLoadPriority.critical,
                            isExternalSource: widget.isExternalSource,
                            remoteSourceIndicatorPolicy:
                                RemoteSourceIndicatorPolicy.hidden,
                          ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                (songTitle == null || songTitle.trim().isEmpty)
                                    ? l10n.miniPlayerUnknownTrack
                                    : songTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              if (widget.isExternalSource)
                                const RemoteSourceIndicator(
                                  variant: RemoteSourceIndicatorVariant.inline,
                                ),
                              const SizedBox(height: 3),
                              Text(
                                (songArtist == null ||
                                        songArtist.trim().isEmpty)
                                    ? l10n.miniPlayerUnknownArtist
                                    : songArtist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: cs.onSurface.withValues(
                                        alpha: 0.58,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.nowPlayingPrevious,
                            onPressed: () {
                              final handler = ref.read(audioHandlerProvider);
                              if (handler == null) {
                                return;
                              }
                              HapticFeedback.lightImpact();
                              handler.skipToPrevious();
                            },
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
                            backgroundColor: cs.primaryContainer,
                            foregroundColor: cs.onPrimaryContainer,
                            minimumSize: const Size(52, 52),
                            padding: const EdgeInsets.all(8),
                          ),
                          onPressed: () async {
                            final handler = ref.read(audioHandlerProvider);
                            if (handler == null) {
                              return;
                            }
                            if (isPlaying) {
                              await handler.pause();
                            } else {
                              await handler.play();
                            }
                          },
                          icon: _remoteLoadingPlayPauseIcon(
                            isExternalSource: widget.isExternalSource,
                            playback: playback,
                            isPlaying: isPlaying,
                            loadingColor: cs.onPrimaryContainer,
                            size: 28,
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.miniPlayerSkipNext,
                            onPressed: () {
                              final handler = ref.read(audioHandlerProvider);
                              if (handler == null) {
                                return;
                              }
                              HapticFeedback.lightImpact();
                              handler.skipToNext();
                            },
                            icon: const Icon(Icons.skip_next_rounded, size: 28),
                          )
                        else
                          IconButton(
                            tooltip: l10n.radioStopStation,
                            onPressed: () async {
                              final handler = ref.read(audioHandlerProvider);
                              if (handler == null) {
                                return;
                              }
                              await handler.stopRadio();
                            },
                            icon: const Icon(Icons.stop_rounded, size: 28),
                          ),
                        if (!isRadio)
                          IconButton(
                            tooltip: playback.isCurrentSongLiked
                                ? l10n.actionLiked
                                : l10n.actionLike,
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              ref.read(audioHandlerProvider)?.toggleLike();
                            },
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
                            if (isRadio)
                              _MiniRadioArt(
                                artUrl: radioArtUrl,
                                colorScheme: cs,
                              )
                            else if (coverArtId == null ||
                                coverArtId.trim().isEmpty)
                              _MiniRemoteArt(
                                artUrl: coverArtUrl,
                                colorScheme: cs,
                              )
                            else
                              CoverArtImage(
                                coverArtId: coverArtId,
                                size: kCoverArtStandardSize,
                                width: 48,
                                height: 48,
                                borderRadius: NavisRadius.smAll,
                                loadPriority: CoverArtLoadPriority.critical,
                                isExternalSource: widget.isExternalSource,
                                remoteSourceIndicatorPolicy:
                                    RemoteSourceIndicatorPolicy.hidden,
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    (songTitle == null ||
                                            songTitle.trim().isEmpty)
                                        ? l10n.miniPlayerUnknownTrack
                                        : songTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  if (widget.isExternalSource)
                                    const RemoteSourceIndicator(
                                      variant:
                                          RemoteSourceIndicatorVariant.inline,
                                    ),
                                  const SizedBox(height: 2),
                                  Text(
                                    (songArtist == null ||
                                            songArtist.trim().isEmpty)
                                        ? l10n.miniPlayerUnknownArtist
                                        : songArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: cs.onSurface.withValues(
                                            alpha: 0.6,
                                          ),
                                        ),
                                  ),
                                ],
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
                                onPressed: () {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  HapticFeedback.lightImpact();
                                  handler.skipToPrevious();
                                },
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
                                backgroundColor: cs.primaryContainer,
                                foregroundColor: cs.onPrimaryContainer,
                                minimumSize: Size(
                                  compactControls ? 40 : 46,
                                  compactControls ? 40 : 46,
                                ),
                                padding: const EdgeInsets.all(6),
                              ),
                              onPressed: () async {
                                final handler = ref.read(audioHandlerProvider);
                                if (handler == null) {
                                  return;
                                }
                                if (isPlaying) {
                                  await handler.pause();
                                } else {
                                  await handler.play();
                                }
                              },
                              icon: _remoteLoadingPlayPauseIcon(
                                isExternalSource: widget.isExternalSource,
                                playback: playback,
                                isPlaying: isPlaying,
                                loadingColor: cs.onPrimaryContainer,
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
                                onPressed: () {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  HapticFeedback.lightImpact();
                                  handler.skipToNext();
                                },
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
                                onPressed: () async {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  await handler.stopRadio();
                                },
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
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  ref.read(audioHandlerProvider)?.toggleLike();
                                },
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
  const _LivePlaybackProgressBar({
    required this.playback,
    required this.isRadio,
  });

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
class _MiniRadioArt extends StatelessWidget {
  const _MiniRadioArt({
    required this.artUrl,
    required this.colorScheme,
    this.size = 48,
  });

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: NavisRadius.smAll,
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _placeholder(),
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
class _MiniRemoteArt extends StatelessWidget {
  const _MiniRemoteArt({
    required this.artUrl,
    required this.colorScheme,
    this.size = 48,
  });

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: NavisRadius.smAll,
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _placeholder(),
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
