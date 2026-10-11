part of 'app_shell.dart';

class _QueueOverlay extends StatefulWidget {
  const new({
    super.key,
    required this.onDismiss,
    this.fullscreen = false,
    this.floatingWindow = false,
  });

  final VoidCallback onDismiss;
  final bool fullscreen;
  final bool floatingWindow;

  @override
  State<_QueueOverlay> createState() => _QueueOverlayState();
}

class _QueueOverlayState extends State<_QueueOverlay>
    with SingleTickerProviderStateMixin {
  static const double _sheetHeightFactor = 0.95;
  static const Duration _openDuration = Duration(milliseconds: 230);
  static const Duration _closeDuration = Duration(milliseconds: 220);
  static const double _flingVelocityThreshold = 300;
  static const double _scrollDismissDistance = 96;
  static const Duration _scrollPullSettleDelay = Duration(milliseconds: 150);

  late final AnimationController _controller;

  // Scroll controller shared with the queue list so we know when the list
  // is at the top and a downward drag should move the sheet instead.
  final ScrollController _scrollController = ScrollController();

  // Raw-pointer drag tracking — uses Listener (not GestureDetector) so it
  // fires alongside the list's scroll recognizer without competing in the
  // gesture arena.
  VelocityTracker? _velocityTracker;
  int? _activePointer;
  Offset _pointerDownPosition = Offset.zero;
  bool _draggingSheet = false;
  bool _dismissing = false;
  bool _queueReorderActive = false;
  bool _queueItemSwiping = false;
  bool _opened = false;
  double _scrollPullDistance = 0;
  Timer? _scrollPullSettleTimer;

  // Cumulative displacement tracking — distinguishes horizontal swipes
  // (e.g. Dismissible swipe-to-delete) from vertical sheet drags.
  double _cumulativeDx = 0;
  double _cumulativeDy = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _openDuration,
      reverseDuration: _closeDuration,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = MotionPolicy.of(context).surface;
    _controller
      ..duration = duration
      ..reverseDuration = duration;
    if (!_opened) {
      _opened = true;
      if (duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.animateTo(1, curve: Curves.easeOutCubic);
      }
    } else if (duration == Duration.zero && !_dismissing) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _scrollPullSettleTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissing) return;
    _scrollPullSettleTimer?.cancel();
    _dismissing = true;
    if (MotionPolicy.of(context).reduceMotion) {
      _controller.value = 0;
      widget.onDismiss();
      return;
    }
    unawaited(
      _controller
          .animateBack(0, duration: _closeDuration, curve: Curves.easeInCubic)
          .whenComplete(widget.onDismiss),
    );
  }

  void dismissAnimated() => _dismiss();

  bool get isDismissing => _dismissing;

  void _setDraggingSheet(bool value) {
    if (_draggingSheet == value || !mounted) {
      _draggingSheet = value;
      return;
    }
    setState(() => _draggingSheet = value);
  }

  void _setQueueReorderActive(bool value) {
    if (_queueReorderActive == value) return;
    if (!mounted) {
      _queueReorderActive = value;
      return;
    }
    setState(() => _queueReorderActive = value);

    // Lock sheet-dismiss gestures while list reordering is active.
    if (value) {
      _activePointer = null;
      _velocityTracker = null;
      _resetScrollPull(animateBack: true);
      _setDraggingSheet(false);
    }
  }

  void _setQueueItemSwiping(bool value) {
    if (_queueItemSwiping == value) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _queueItemSwiping = value;
          return;
        }
        _setQueueItemSwiping(value);
      });
      return;
    }
    // If an item swipe starts while the sheet was tracking a drag, reset it.
    if (value) {
      _activePointer = null;
      _velocityTracker = null;
      _setDraggingSheet(false);
    }
    if (!mounted) {
      _queueItemSwiping = value;
      return;
    }
    setState(() => _queueItemSwiping = value);
  }

  void _resetScrollPull({bool animateBack = false}) {
    _scrollPullSettleTimer?.cancel();
    _scrollPullDistance = 0;
    if (animateBack && !_dismissing && _controller.value < 0.999) {
      _settleOpen();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _dismissing ||
        _queueReorderActive ||
        _draggingSheet) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if (dy >= -1) {
      if (_scrollPullDistance > 0) {
        _resetScrollPull(animateBack: true);
      }
      return;
    }

    if (!_listAtTopAt(event.position)) {
      return;
    }

    final effectiveHeightFactor = widget.fullscreen ? 1.0 : _sheetHeightFactor;
    final sheetHeight =
        MediaQuery.of(context).size.height * effectiveHeightFactor;
    final dragDistance = -dy;
    _scrollPullDistance += dragDistance;
    _controller.value = (_controller.value - dragDistance / sheetHeight).clamp(
      0.0,
      1.0,
    );

    if (_scrollPullDistance >= _scrollDismissDistance ||
        _controller.value < 0.72) {
      _dismiss();
      return;
    }

    _scrollPullSettleTimer?.cancel();
    _scrollPullSettleTimer = Timer(_scrollPullSettleDelay, () {
      if (!mounted || _dismissing || _queueReorderActive || _draggingSheet) {
        return;
      }
      _resetScrollPull(animateBack: true);
    });
  }

  /// Whether a downward drag at [globalPosition] should move the sheet: the
  /// list is at its top, or the pointer is outside the list (header and drag
  /// handle), since the queue opens scrolled to the playing song.
  bool _listAtTopAt(Offset globalPosition) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    if (position.pixels <= 0.0) return true;
    final box = position.context.storageContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return true;
    return !(Offset.zero & box.size).contains(
      box.globalToLocal(globalPosition),
    );
  }

  // ---- Raw pointer handlers -----------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (_dismissing || _queueReorderActive) return;
    _activePointer = event.pointer;
    _pointerDownPosition = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind);
    _velocityTracker!.addPosition(event.timeStamp, event.position);
    _resetScrollPull();
    _setDraggingSheet(false);
    _cumulativeDx = 0.0;
    _cumulativeDy = 0.0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dismissing || _queueReorderActive || event.pointer != _activePointer) {
      return;
    }
    if (_queueItemSwiping) return; // item swipe has claimed this gesture
    _velocityTracker?.addPosition(event.timeStamp, event.position);

    final dx = event.delta.dx;
    final dy = event.delta.dy;

    _cumulativeDx += dx.abs();
    _cumulativeDy += dy.abs();

    if (!_draggingSheet) {
      // Capture the sheet only when the list is already at the top and the
      // gesture is clearly vertical. Once captured, keep control until
      // pointer-up so the user can reverse direction mid-swipe.
      if (_cumulativeDx > _cumulativeDy * 1.5 && _cumulativeDx > 10) {
        // Horizontal movement dominates — let the child handle it.
        return;
      }
      if (dy <= 0) {
        return;
      }
      if (!_listAtTopAt(_pointerDownPosition)) return;
      _setDraggingSheet(true);
    }

    final effectiveHeightFactor = widget.fullscreen ? 1.0 : _sheetHeightFactor;
    final sheetHeight =
        MediaQuery.of(context).size.height * effectiveHeightFactor;
    _controller.value = (_controller.value - dy / sheetHeight).clamp(0.0, 1.0);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_queueReorderActive) return;
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _resetScrollPull();
    final wasDragging = _draggingSheet;
    _setDraggingSheet(false);
    if (_dismissing || !wasDragging) return;

    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0.0;
    if (velocity > _flingVelocityThreshold || _controller.value < 0.7) {
      _dismiss();
    } else {
      _settleOpen();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_queueReorderActive) return;
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _resetScrollPull();
    final wasDragging = _draggingSheet;
    _setDraggingSheet(false);
    if (_dismissing) return;
    // If the sheet was being dragged and is already partially down, dismiss.
    if (wasDragging && _controller.value < 0.85) {
      _dismiss();
    } else if (_controller.value < 0.99) {
      _settleOpen();
    }
  }

  void _settleOpen() {
    if (MotionPolicy.of(context).reduceMotion) {
      _controller.value = 1;
      return;
    }
    _controller.fling(velocity: 2.5);
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = _controller.value;
        final scrimOpacity = Curves.easeOutCubic.transform(progress) * 0.45;
        final useFloatingWindow = widget.floatingWindow && !widget.fullscreen;
        final heightFactor = widget.fullscreen
            ? 1.0
            : (useFloatingWindow ? 0.72 : _sheetHeightFactor);

        final queueContent = widget.fullscreen
            ? SafeArea(
                child: QueueSheet(
                  scrollController: _scrollController,
                  sheetDragActive: _draggingSheet,
                  onReorderDragChanged: _setQueueReorderActive,
                  onItemSwipeActiveChanged: _setQueueItemSwiping,
                  onClose: _dismiss,
                ),
              )
            : QueueSheet(
                scrollController: _scrollController,
                sheetDragActive: _draggingSheet,
                onReorderDragChanged: _setQueueReorderActive,
                onItemSwipeActiveChanged: _setQueueItemSwiping,
                onClose: _dismiss,
                embeddedMode: useFloatingWindow,
              );

        final queueSurface = useFloatingWindow
            ? Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 14,
                borderRadius: NavisShapeData.of(context).xlAll,
                clipBehavior: Clip.antiAlias,
                child: queueContent,
              )
            : _QueueArtworkSurface(
                fullscreen: widget.fullscreen,
                child: queueContent,
              );

        return FocusScope(
          autofocus: true,
          child: Stack(
            children: <Widget>[
              if (!widget.fullscreen)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: progress < 0.01,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _dismiss,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: scrimOpacity),
                      ),
                    ),
                  ),
                ),
              // Sheet — slides up from the bottom with 1:1 finger tracking.
              if (useFloatingWindow)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: 320,
                        maxWidth: math.min(
                          560,
                          MediaQuery.sizeOf(context).width * 0.46,
                        ),
                      ),
                      child: FractionallySizedBox(
                        heightFactor: heightFactor,
                        widthFactor: 1,
                        child: FractionalTranslation(
                          key: const ValueKey<String>(
                            'queueOverlayTranslation',
                          ),
                          translation: Offset(0, 1 - progress),
                          child: IgnorePointer(
                            ignoring: _dismissing,
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: _onPointerDown,
                              onPointerMove: _onPointerMove,
                              onPointerUp: _onPointerUp,
                              onPointerCancel: _onPointerCancel,
                              onPointerSignal: _onPointerSignal,
                              child: queueSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: heightFactor,
                    widthFactor: 1,
                    child: FractionalTranslation(
                      key: const ValueKey<String>('queueOverlayTranslation'),
                      translation: Offset(0, 1 - progress),
                      child: IgnorePointer(
                        ignoring: _dismissing,
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: _onPointerDown,
                          onPointerMove: _onPointerMove,
                          onPointerUp: _onPointerUp,
                          onPointerCancel: _onPointerCancel,
                          onPointerSignal: _onPointerSignal,
                          child: queueSurface,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Surface of the phone queue overlay.
///
/// Opaque `surface` normally. While Now Playing is expanded and showing its
/// Artwork layer, it paints the same blurred cover (published by
/// [NowPlayingBackdrop]) underneath and marks the content with
/// [NowPlayingArtworkLayerScope], so the queue's translucent panel fill
/// applies and the cover stays visible through it.
class _QueueArtworkSurface extends ConsumerWidget {
  const new({required this.fullscreen, required this.child});

  final bool fullscreen;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final nowPlayingExpanded = ref.watch(playerSheetExpandedProvider);
    final published = ref.watch(nowPlayingPublishedBackdropProvider);
    final backdrop = nowPlayingExpanded ? published : null;
    final show = backdrop != null;
    final surface = Material(
      color: show
          ? Colors.transparent
          : (fullscreen ? colors.surface : Colors.transparent),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: show
                ? NowPlayingArtworkBackground(
                    key: const ValueKey<String>('queueArtworkBackground'),
                    imageKey: backdrop.imageKey,
                    image: backdrop.image,
                    coverAverage: backdrop.coverAverage,
                    useCoverAverage: backdrop.useCoverAverage,
                    colorStyle: NavisColorStyleData.of(context),
                    surfaceColor: colors.surface,
                    onSurfaceColor: colors.onSurface,
                    accentColor: colors.primary,
                    onSurfaceVariantColor: colors.onSurfaceVariant,
                    fadeDuration: Duration.zero,
                  )
                : const SizedBox.shrink(),
          ),
          NowPlayingArtworkLayerScope(active: show, child: child),
        ],
      ),
    );
    return fullscreen
        ? surface
        : SafeArea(
            top: show,
            left: show,
            right: show,
            bottom: false,
            child: ClipRRect(
              borderRadius: show
                  ? NavisShapeData.of(context).sheetTop
                  : BorderRadius.zero,
              child: surface,
            ),
          );
  }
}
