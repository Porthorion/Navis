part of 'now_playing_screen.dart';

enum _WideNowPlayingPanel { none, settings, mix, queue }

enum _NowPlayingLayoutMode { compact, standard, split }

class _NowPlayingSplitMetrics {
  const new({
    required this.outerPadding,
    required this.gap,
    required this.leftPaneWidth,
    required this.rightPaneWidth,
    required this.artSize,
  });

  final double outerPadding;
  final double gap;
  final double leftPaneWidth;
  final double rightPaneWidth;
  final double artSize;
}

class _EmbeddedRightPaneBottomSheet extends StatelessWidget {
  const new({
    required this.heightFactor,
    required this.useHeader,
    required this.onClose,
    required this.child,
    this.title,
    this.subtitle,
    super.key,
  });

  final double heightFactor;
  final bool useHeader;
  final VoidCallback onClose;
  final Widget child;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.26)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: heightFactor.clamp(0.42, 0.84),
            widthFactor: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 280) {
                  onClose();
                }
              },
              child: Material(
                color: colorScheme.surfaceContainerHigh,
                elevation: 14,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(NavisRadius.xl),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: useHeader
                    ? Column(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  width: 34,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          if (title != null &&
                                              title!.isNotEmpty)
                                            Text(
                                              title!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  theme.textTheme.titleMedium,
                                            ),
                                          if (subtitle != null &&
                                              subtitle!.isNotEmpty)
                                            Text(
                                              subtitle!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: MaterialLocalizations.of(context)
                                          .closeButtonTooltip,
                                      onPressed: onClose,
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(child: child),
                        ],
                      )
                    : child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmbeddedNowPlayingPanelScaffold extends StatefulWidget {
  const new({
    required this.title,
    required this.onBack,
    required this.child,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final Widget child;

  @override
  State<_EmbeddedNowPlayingPanelScaffold> createState() =>
      _EmbeddedNowPlayingPanelScaffoldState();
}

class _EmbeddedNowPlayingPanelScaffoldState
    extends State<_EmbeddedNowPlayingPanelScaffold>
    with SingleTickerProviderStateMixin {
  static const double _dismissThreshold = 0.74;
  static const double _dismissFlingVelocity = 700;

  late final AnimationController _transitionController;
  bool _dismissRequested = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(
      vsync: this,
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      value: 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (_reduceMotion) {
          _transitionController.value = 1;
        } else {
          unawaited(
            _transitionController.animateTo(1, curve: Curves.easeOutCubic),
          );
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = MotionPolicy.of(context);
    _reduceMotion = motion.reduceMotion;
    _transitionController.duration = motion.navigationReverse;
    _transitionController.reverseDuration = motion.surface;
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  double _viewportHeight() {
    final size = context.size;
    if (size != null && size.height > 0) {
      return size.height;
    }
    final media = MediaQuery.maybeOf(context);
    return media == null ? 1 : math.max(1, media.size.height);
  }

  void _applyDragDelta(double delta) {
    if (_dismissRequested) {
      return;
    }
    final height = _viewportHeight();
    final change = delta / height;
    _transitionController.value = (_transitionController.value - change).clamp(
      0,
      1,
    );
  }

  Future<void> _requestDismiss() async {
    if (_dismissRequested) {
      return;
    }
    _dismissRequested = true;
    if (_reduceMotion) {
      _transitionController.value = 0;
      widget.onBack();
      return;
    }
    await _transitionController.animateBack(0, curve: Curves.easeInCubic);
    if (!mounted) {
      return;
    }
    widget.onBack();
  }

  void _settleAfterGesture({double velocity = 0}) {
    if (_dismissRequested) {
      return;
    }
    if (_reduceMotion) {
      _transitionController.value = 1;
      return;
    }
    final shouldDismiss =
        velocity > _dismissFlingVelocity ||
        _transitionController.value < _dismissThreshold;
    if (shouldDismiss) {
      unawaited(_requestDismiss());
      return;
    }
    unawaited(
      _transitionController.animateTo(
        1,
        duration: MotionPolicy.of(context).surface,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_dismissRequested) {
      return false;
    }
    if (notification is OverscrollNotification && notification.overscroll < 0) {
      _applyDragDelta(-notification.overscroll);
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels >
            notification.metrics.minScrollExtent + 0.5 &&
        _transitionController.value < 0.995) {
      if (_reduceMotion) {
        _transitionController.value = 1;
      } else {
        unawaited(
          _transitionController.animateTo(
            1,
            duration: MotionPolicy.of(context).feedback,
            curve: Curves.easeOut,
          ),
        );
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      _settleAfterGesture();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panel = KeyedSubtree(
      key: const ValueKey<String>('embedded-now-playing-panel'),
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          top: true,
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              final delta = details.primaryDelta;
              if (delta == null) {
                return;
              }
              _applyDragDelta(delta);
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              _settleAfterGesture(velocity: math.max(0, velocity));
            },
            onVerticalDragCancel: _settleAfterGesture,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .backButtonTooltip,
                        onPressed: () {
                          unawaited(_requestDismiss());
                        },
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              widget.title,
                              style: theme.textTheme.titleMedium,
                            ),
                            if (widget.subtitle != null &&
                                widget.subtitle!.isNotEmpty)
                              Text(
                                widget.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (_reduceMotion) {
      return panel;
    }
    return AnimatedBuilder(
      animation: _transitionController,
      builder: (context, child) {
        final progress = _transitionController.value.clamp(0, 1).toDouble();
        final eased = Curves.easeOutCubic.transform(progress);
        final opacity = Curves.easeOut.transform(progress);
        final translateY = (1 - eased) * 52;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: child,
          ),
        );
      },
      child: panel,
    );
  }
}

/// Full-height gesture-tracked slide-up overlay panel for compact-wide
/// landscape mode.
///
/// Slides in from the bottom with 1:1 finger tracking on the drag-handle
/// area, matching the gesture feel of [ExpandablePlayerSheet]. Dismisses via
/// downward swipe, fling, or the back-arrow button. Scroll-integrated dismiss
/// is also supported for panels whose [child] is a scrollable list.
class _CompactWideOverlaySheet extends StatefulWidget {
  const new({
    required this.title,
    required this.onDismiss,
    required this.child,
    this.dismissRequested = false,
    this.showTopBar = true,
    super.key,
  });

  /// Velocity (px/s) that triggers an immediate fling-dismiss.
  static const double _flingThreshold = 300;

  /// Progress value (0–1) below which releasing the drag dismisses the panel.
  /// Lower value = more lenient (panel must be dragged >75% down to auto-dismiss).
  static const double _snapDismissThreshold = 0.25;

  final String title;
  final VoidCallback onDismiss;
  final Widget child;
  final bool dismissRequested;
  final bool showTopBar;

  @override
  State<_CompactWideOverlaySheet> createState() =>
      _CompactWideOverlaySheetState();
}

class _CompactWideOverlaySheetState extends State<_CompactWideOverlaySheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _dismissing = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      value: 0,
    );
    _controller.addStatusListener(_onAnimationStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (_reduceMotion) {
          _controller.value = 1;
        } else {
          unawaited(_controller.animateTo(1, curve: Curves.easeOutCubic));
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = MotionPolicy.of(context);
    _reduceMotion = motion.reduceMotion;
    _controller.duration = motion.navigationForward;
    _controller.reverseDuration = motion.navigationReverse;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CompactWideOverlaySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.dismissRequested && widget.dismissRequested) {
      _startDismiss();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _dismissing) {
      // A programmatic dismissal can be requested while the parent is
      // rebuilding this sheet. Remove it on the following frame so the host
      // never receives setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _dismissing) {
          widget.onDismiss();
        }
      });
    }
  }

  double _viewportHeight() {
    final size = context.size;
    if (size != null && size.height > 0) return size.height;
    final media = MediaQuery.maybeOf(context);
    return media == null ? 1.0 : math.max(1.0, media.size.height);
  }

  void _applyDragDelta(double delta) {
    if (_dismissing) return;
    final height = _viewportHeight();
    _controller.value = (_controller.value - delta / height).clamp(0.0, 1.0);
  }

  void _settleAfterDrag({double velocity = 0}) {
    if (_dismissing) return;
    if (_reduceMotion) {
      if (velocity > _CompactWideOverlaySheet._flingThreshold ||
          _controller.value < _CompactWideOverlaySheet._snapDismissThreshold) {
        _startDismiss();
      } else {
        _controller.value = 1;
      }
      return;
    }
    final absVelocity = velocity.abs();
    final height = _viewportHeight();
    if (absVelocity > _CompactWideOverlaySheet._flingThreshold) {
      final v = (absVelocity / height).clamp(1.0, 6.0);
      if (velocity > 0) {
        // Fling downward — dismiss.
        _startDismiss(flingVelocity: v);
      } else {
        // Fling upward — snap open.
        _controller.fling(velocity: v);
      }
    } else {
      // Low velocity — snap to nearest edge.
      if (_controller.value < _CompactWideOverlaySheet._snapDismissThreshold) {
        _startDismiss();
      } else {
        unawaited(
          _controller.animateTo(
            1,
            duration: MotionPolicy.of(context).surface,
            curve: Curves.easeOutCubic,
          ),
        );
      }
    }
  }

  void _startDismiss({double? flingVelocity}) {
    if (_dismissing) return;
    _dismissing = true;
    if (_reduceMotion) {
      _controller.value = 0;
      return;
    }
    if (flingVelocity != null) {
      // Keep a real swipe tied to its gesture velocity.
      _controller.fling(velocity: -flingVelocity);
      return;
    }
    // Buttons, Back, and other programmatic closes should retrace the
    // entrance at a readable speed instead of disappearing in one tick.
    unawaited(
      _controller.animateBack(
        0,
        duration: _controller.reverseDuration,
        curve: Curves.easeInCubic,
      ),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_dismissing) return false;
    if (notification is OverscrollNotification && notification.overscroll < 0) {
      _applyDragDelta(-notification.overscroll);
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels >
            notification.metrics.minScrollExtent + 0.5 &&
        _controller.value < 0.995) {
      // Scrolling down into content — snap back to fully open.
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        unawaited(
          _controller.animateTo(
            1,
            duration: MotionPolicy.of(context).feedback,
            curve: Curves.easeOut,
          ),
        );
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      // Use the gesture's final velocity so a fast downward fling on the
      // list (when already at the top) triggers a dismiss even though the
      // position-based threshold hasn't been crossed.
      final velocity = notification.dragDetails?.primaryVelocity ?? 0;
      _settleAfterDrag(velocity: velocity);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final panel = KeyedSubtree(
      key: const ValueKey<String>('compact-wide-now-playing-panel'),
      child: Material(
        color: cs.surface,
        child: SafeArea(
          top: true,
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (details) {
              final delta = details.primaryDelta;
              if (delta == null) return;
              _applyDragDelta(delta);
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              _settleAfterDrag(velocity: velocity);
            },
            onVerticalDragCancel: _settleAfterDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (widget.showTopBar) ...<Widget>[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .backButtonTooltip,
                          onPressed: _startDismiss,
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ] else
                  const SizedBox(height: 4),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (_reduceMotion) {
      return panel;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        // Fade in quickly (complete by 50% of the slide) then stay fully
        // opaque, and fade out symmetrically when dragging back down.
        final opacity = Curves.easeOut.transform(
          (progress / 0.5).clamp(0.0, 1.0),
        );
        return Opacity(
          opacity: opacity,
          child: FractionalTranslation(
            translation: Offset(0, 1.0 - progress),
            child: child,
          ),
        );
      },
      child: panel,
    );
  }
}

class _NowPlayingSettingsPanel extends ConsumerWidget {
  const new({
    required this.song,
    this.onCollapse,
    this.fullscreenLyricsSongId,
    this.fullscreenLyricsTitle,
    this.onOpenFullscreenLyrics,
  });

  final SongsTableData? song;
  final VoidCallback? onCollapse;
  final String? fullscreenLyricsSongId;
  final String? fullscreenLyricsTitle;
  final VoidCallback? onOpenFullscreenLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentSongRating = song == null
        ? null
        : ref.watch(songRatingProvider(song!.id)).asData?.value;
    final isRemote = song != null && !isServerAddressableSongId(song!.id);
    final songDownloadState = song == null
        ? SongDownloadState.none
        : ref.watch(songDownloadStateProvider(song!.id));
    final disabledColor = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.38);

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: <Widget>[
        _NowPlayingSoundSectionLabel(label: l10n.nowPlayingSoundSection),
        Builder(
          builder: (tileContext) => ListTile(
            key: const ValueKey('playbackAdjustmentEntryPoint'),
            leading: const Icon(Icons.speed),
            title: Text(l10n.playbackSpeedPitchTitle),
            subtitle: const PlaybackAdjustmentSummary(),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                unawaited(showPlaybackAdjustmentQuickPanel(tileContext)),
          ),
        ),
        if (ref.watch(eqCapabilitiesProvider).supported)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: EqQuickCard(),
          )
        else
          const EqualizerEntry(),
        const Divider(height: 1),
        if (song != null)
          ListTile(
            iconColor: isRemote ? disabledColor : null,
            textColor: isRemote ? disabledColor : null,
            leading: const Icon(Icons.star_outline),
            title: Text(l10n.ratingTitle),
            subtitle: Text(l10n.ratingHint),
            trailing: isRemote
                ? IgnorePointer(
                    child: Opacity(
                      opacity: 0.38,
                      child: RatingWidget(
                        rating: currentSongRating,
                        compact: true,
                        onChanged: (_) {},
                      ),
                    ),
                  )
                : RatingWidget(
                    rating: currentSongRating,
                    compact: true,
                    onChanged: (next) {
                      unawaited(
                        setSongRating(song!.id, next, ref).catchError((_) {
                          if (context.mounted) {
                            showAppNotice(
                              context,
                              message: l10n.ratingUpdateFailed,
                              level: AppNoticeLevel.error,
                            );
                          }
                        }),
                      );
                    },
                  ),
            onTap: isRemote
                ? () => showAppNotice(
                    context,
                    message: l10n.remoteSourceActionUnavailable,
                    level: AppNoticeLevel.error,
                  )
                : null,
          ),
        if (fullscreenLyricsSongId != null &&
            fullscreenLyricsTitle != null &&
            onOpenFullscreenLyrics != null)
          ListTile(
            leading: const Icon(Icons.fullscreen),
            title: Text(l10n.nowPlayingLyrics),
            onTap: onOpenFullscreenLyrics,
          ),
        if (song != null &&
            ((song!.albumId ?? '').trim().isNotEmpty ||
                (song!.albumName ?? '').trim().isNotEmpty))
          ListTile(
            leading: const Icon(Icons.album_outlined),
            title: Text(l10n.nowPlayingGoToAlbum),
            onTap: () {
              onCollapse?.call();
              unawaited(
                NormalPlaybackMetadataNavigator.goToAlbum(
                  context,
                  ref,
                  song: song,
                ),
              );
            },
          ),
        if (song != null &&
            ((song!.artistId ?? '').trim().isNotEmpty ||
                (song!.artistName ?? '').trim().isNotEmpty))
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(l10n.nowPlayingGoToArtist),
            onTap: () {
              onCollapse?.call();
              unawaited(
                NormalPlaybackMetadataNavigator.goToArtist(
                  context,
                  ref,
                  song: song,
                ),
              );
            },
          ),
        if (song != null)
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: Text(l10n.librarySongMenuAddToPlaylist),
            onTap: () => showAddToPlaylistSheet(context, ref, [song!.id]),
          ),
        if (song != null &&
            songDownloadState.status == SongDownloadStatus.downloaded)
          ListTile(
            leading: Icon(
              Icons.delete_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              l10n.deleteDownloadAction,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () =>
                unawaited(confirmAndDeleteDownload(context, ref, song!.id)),
          )
        else if (song != null &&
            songDownloadState.status != SongDownloadStatus.queued &&
            songDownloadState.status != SongDownloadStatus.downloading)
          ListTile(
            iconColor: isRemote ? disabledColor : null,
            textColor: isRemote ? disabledColor : null,
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.downloadAction),
            onTap: () async {
              if (isRemote) {
                showAppNotice(
                  context,
                  message: l10n.remoteSourceActionUnavailable,
                  level: AppNoticeLevel.error,
                );
                return;
              }
              final choice = await showDownloadQualitySheet(context);
              if (choice == null || !context.mounted) return;
              final service = ref.read(downloadServiceProvider);
              await service.enqueueSong(
                song!.id,
                quality: choice.quality,
                format: choice.format,
              );
              if (context.mounted) {
                showAppNotice(
                  context,
                  message: l10n.downloadSongQueued,
                  level: AppNoticeLevel.success,
                );
              }
            },
          ),
      ],
    );
  }
}

class _EmbeddedMixPanel extends ConsumerWidget {
  const new({required this.seedSongId});

  final String seedSongId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final instantMix = ref.watch(instantMixProvider);
    final sameVibes = ref.watch(sameVibesProvider);
    final preferredMixMode = ref.watch(preferredMixModeProvider);
    final useLegacy = preferredMixMode == PreferredMixMode.legacyInstantMix;
    final active = useLegacy ? instantMix.active : sameVibes.active;
    final loading = useLegacy
        ? (instantMix.refilling && instantMix.active)
        : (sameVibes.refilling && sameVibes.active);
    final title = useLegacy
        ? l10n.nowPlayingInstantMixLabel
        : l10n.nowPlayingSameVibesLabel;
    final subtitle = useLegacy
        ? l10n.nowPlayingInstantMixDescription
        : l10n.nowPlayingSameVibesDescription;
    final isRemote = !isServerAddressableSongId(seedSongId);
    final legacyMixUnavailable = isRemote && useLegacy;
    final disabledColor = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.38);
    final cards = <Widget>[
      Card(
        child: ListTile(
          iconColor: legacyMixUnavailable ? disabledColor : null,
          textColor: legacyMixUnavailable ? disabledColor : null,
          leading: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.explore_outlined),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: active ? const Icon(Icons.check_circle) : null,
          onTap: legacyMixUnavailable
              ? () => showAppNotice(
                  context,
                  message: l10n.remoteSourceInstantMixUnavailable,
                  level: AppNoticeLevel.error,
                )
              : () async {
                  await togglePreferredMixMode(ref, seedSongId: seedSongId);
                },
        ),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: cards,
    );
  }
}
