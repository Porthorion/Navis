part of 'app_shell.dart';

class _DesktopWorkspace extends StatefulWidget {
  const new({
    required this.sidebarWidth,
    required this.navbarStyle,
    required this.navbarAutohide,
    required this.expandRequestNotifier,
    required this.selectedIndex,
    required this.destinations,
    required this.showPlayer,
    required this.showQueueOverlay,
    required this.hasPlayerOverlay,
    required this.navigationShell,
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.artistId,
    required this.albumId,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.isExternalSource,
    required this.onDestinationSelected,
    required this.showLibrarySubNavigation,
    required this.librarySectionsFit,
    required this.allowScrollableRail,
    required this.selectedLibrarySection,
    required this.visibleLibrarySections,
    required this.onLibrarySectionSelected,
    required this.onOpenPlayer,
    required this.onToggleQueue,
    required this.onDismissQueue,
    required this.queueToggleFocusNode,
    required this.queueOverlayKey,
    required this.showLyricsOverlay,
    required this.onToggleLyrics,
    this.onToggleAutohide,
    this.onSystemBack,
  });

  final double sidebarWidth;
  final String navbarStyle;
  final bool navbarAutohide;
  final ValueNotifier<int> expandRequestNotifier;
  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final bool showPlayer;
  final bool showQueueOverlay;
  final bool hasPlayerOverlay;
  final StatefulNavigationShell navigationShell;
  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final ValueChanged<int> onDestinationSelected;
  final bool showLibrarySubNavigation;
  final ValueNotifier<bool> librarySectionsFit;
  final bool allowScrollableRail;
  final LibrarySection? selectedLibrarySection;
  final List<LibrarySection> visibleLibrarySections;
  final ValueChanged<LibrarySection> onLibrarySectionSelected;
  final VoidCallback onOpenPlayer;
  final VoidCallback onToggleQueue;
  final VoidCallback onDismissQueue;
  final FocusNode queueToggleFocusNode;
  final GlobalKey<_QueueOverlayState> queueOverlayKey;
  final bool showLyricsOverlay;
  final VoidCallback onToggleLyrics;
  final VoidCallback? onToggleAutohide;
  final VoidCallback? onSystemBack;

  @override
  State<_DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<_DesktopWorkspace> {
  // Opening is a little slower than closing; both ease out.
  static const Duration _openDuration = Duration(milliseconds: 220);
  static const Duration _closeDuration = Duration(milliseconds: 180);
  static const Duration _animDuration = Duration(milliseconds: 280);
  static const Curve _animCurve = Curves.easeOutCubic;
  // Hover intent: the pointer must rest on the strip this long before the
  // rail opens, so crossing it on the way elsewhere does nothing.
  static const Duration _openDelay = Duration(milliseconds: 120);
  static const double _collapsedWidth = 64;
  static const Duration _collapseDelay = Duration(milliseconds: 500);
  static const Duration _navExpandHoldDuration = Duration(milliseconds: 1600);

  bool _sidebarVisible = true;
  bool _mouseIsOverSidebar = false;
  Timer? _collapseTimer;
  Timer? _openTimer;
  int _lastExpandRequest = 0;

  @override
  void initState() {
    super.initState();
    _sidebarVisible = !widget.navbarAutohide;
    _lastExpandRequest = widget.expandRequestNotifier.value;
    widget.expandRequestNotifier.addListener(_onExpandRequest);
  }

  @override
  void didUpdateWidget(_DesktopWorkspace old) {
    super.didUpdateWidget(old);
    if (old.expandRequestNotifier != widget.expandRequestNotifier) {
      old.expandRequestNotifier.removeListener(_onExpandRequest);
      widget.expandRequestNotifier.addListener(_onExpandRequest);
      _lastExpandRequest = widget.expandRequestNotifier.value;
    }
    if (!widget.navbarAutohide) {
      _collapseTimer?.cancel();
      _openTimer?.cancel();
      // The overlay's MouseRegion unmounts without an exit event; forget the
      // pointer so turning auto-hide on again collapses the rail.
      _mouseIsOverSidebar = false;
      if (!_sidebarVisible) {
        _setSidebarVisible(true);
      }
    } else if (!old.navbarAutohide && widget.navbarAutohide) {
      if (!_mouseIsOverSidebar) {
        _scheduleCollapse();
      }
    }
  }

  @override
  void dispose() {
    widget.expandRequestNotifier.removeListener(_onExpandRequest);
    _collapseTimer?.cancel();
    _openTimer?.cancel();
    super.dispose();
  }

  void _onExpandRequest() {
    if (!widget.navbarAutohide) return;
    final current = widget.expandRequestNotifier.value;
    if (current == _lastExpandRequest) return;
    _lastExpandRequest = current;
    _collapseTimer?.cancel();
    if (!mounted) return;
    _setSidebarVisible(true);
    _collapseTimer = Timer(_navExpandHoldDuration, () {
      if (!mounted || _mouseIsOverSidebar) return;
      _setSidebarVisible(false);
    });
  }

  void _setSidebarVisible(bool visible) {
    _openTimer?.cancel();
    setState(() => _sidebarVisible = visible);
  }

  /// Auto-hide closes the overlay as soon as a destination or library section
  /// is chosen, even while the pointer is still over it.
  void _closeAfterSelection() {
    if (!widget.navbarAutohide) return;
    _collapseTimer?.cancel();
    _mouseIsOverSidebar = false;
    if (_sidebarVisible) _setSidebarVisible(false);
  }

  void _onMouseEnterSidebar(PointerEnterEvent _) {
    if (!widget.navbarAutohide) return;
    _collapseTimer?.cancel();
    _mouseIsOverSidebar = true;
    if (!mounted || _sidebarVisible) return;
    _openTimer?.cancel();
    _openTimer = Timer(_openDelay, () {
      if (mounted && _mouseIsOverSidebar) _setSidebarVisible(true);
    });
  }

  void _onMouseExitSidebar(PointerExitEvent _) {
    if (!widget.navbarAutohide) return;
    _mouseIsOverSidebar = false;
    _openTimer?.cancel();
    _scheduleCollapse();
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_collapseDelay, () {
      if (!mounted || _mouseIsOverSidebar) return;
      _setSidebarVisible(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final autohide = widget.navbarAutohide;
    // Under auto-hide the rail is always laid out expanded and clipped to the
    // 64 px strip while closed, so icons never move between the two states.
    final sidebarIconsOnly = widget.navbarStyle == 'icons';
    final peekStrip = autohide && !sidebarIconsOnly;
    final effectiveNavbarStyle = sidebarIconsOnly
        ? 'icons'
        : widget.navbarStyle;
    final effectiveSidebarWidth = sidebarIconsOnly
        ? _collapsedWidth
        : widget.sidebarWidth;
    // Pages only ever see the collapsed rail under auto-hide, so hovering it
    // open never reflows them.
    final pagesIconsOnly = widget.navbarStyle == 'icons' || autohide;

    final oled = NavisColorStyleData.of(context).oled;
    final sidebarContent = Material(
      // OLED chrome is true black; the separator below carries the edge.
      color: oled ? colors.surface : colors.surfaceContainerLow,
      child: SafeArea(
        child: SizedBox(
          key: const ValueKey<String>('desktopSidebarRegion'),
          width: effectiveSidebarWidth,
          child: Padding(
            padding: sidebarIconsOnly || peekStrip
                ? const EdgeInsets.fromLTRB(4, 12, 4, 12)
                : const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: _RailSidebar(
              navbarStyle: effectiveNavbarStyle,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: (index) {
                widget.onDestinationSelected(index);
                // After the callback: it also raises the expand request
                // that keyboard navigation uses to flash the rail open.
                _closeAfterSelection();
              },
              destinations: widget.destinations,
              // Auto-hide leaves the section links to the Library page, so
              // the tiles below them never move.
              showLibrarySubNavigation:
                  widget.showLibrarySubNavigation && !autohide,
              peekStrip: peekStrip,
              peekCollapsed: !_sidebarVisible,
              largeTiles: widget.navbarStyle == 'comfortable',
              allowScrollableRail: widget.allowScrollableRail,
              selectedLibrarySection: widget.selectedLibrarySection,
              visibleLibrarySections: widget.visibleLibrarySections,
              onLibrarySectionSelected: (section) {
                widget.onLibrarySectionSelected(section);
                _closeAfterSelection();
              },
              showPlayer: false,
              playback: widget.playback,
              songTitle: widget.songTitle,
              songArtist: widget.songArtist,
              coverArtId: widget.coverArtId,
              coverArtUrl: widget.coverArtUrl,
              isExternalSource: widget.isExternalSource,
              isRadio: widget.playback.isRadioMode,
              radioArtUrl: widget.playback.radioStation?.nowPlayingArtUrl,
              onOpenPlayer: widget.onOpenPlayer,
              navbarAutohide: widget.navbarAutohide,
              onToggleAutohide: widget.onToggleAutohide,
              librarySectionsFit: widget.librarySectionsFit,
              showHistoryControls: true,
            ),
          ),
        ),
      ),
    );

    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Row(
                  children: <Widget>[
                    if (autohide)
                      const SizedBox(width: _collapsedWidth)
                    else
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(10),
                        child: AnimatedContainer(
                          duration: _animDuration,
                          curve: _animCurve,
                          width: effectiveSidebarWidth,
                          child: sidebarContent,
                        ),
                      ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: colors.outlineVariant.withValues(alpha: 0.35),
                    ),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(20),
                        child: SafeArea(
                          left: false,
                          top: false,
                          right: false,
                          child: ShellOfflineBannerFrame(
                            child: NavigatorPopHandler<Object?>(
                              enabled: true,
                              onPopWithResult: (result) {
                                if (widget.hasPlayerOverlay) {
                                  widget.onSystemBack?.call();
                                  return;
                                }
                                final router = GoRouter.of(context);
                                if (!router.canPop()) {
                                  return;
                                }
                                NavService.clearExitPrompt();
                                router.pop(result);
                              },
                              child: Stack(
                                children: <Widget>[
                                  Positioned.fill(
                                    child: DesktopNavigationPresentationScope(
                                      iconsOnly: pagesIconsOnly,
                                      child: widget.navigationShell,
                                    ),
                                  ),
                                  if (widget.showLyricsOverlay)
                                    Positioned.fill(
                                      child: _DesktopLyricsOverlay(
                                        onClose: widget.onToggleLyrics,
                                        songTitle: widget.songTitle,
                                        songArtist: widget.songArtist,
                                      ),
                                    ),
                                  if (widget.showPlayer &&
                                      widget.showQueueOverlay)
                                    Positioned.fill(
                                      child: FocusTraversalOrder(
                                        order: const NumericFocusOrder(5),
                                        child: _QueueOverlay(
                                          key: widget.queueOverlayKey,
                                          fullscreen: false,
                                          floatingWindow: true,
                                          onDismiss: widget.onDismissQueue,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (autohide)
                // The one rail instance floats over the page; the Row above
                // only reserves its collapsed slot.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(10),
                    child: MouseRegion(
                      onEnter: _onMouseEnterSidebar,
                      onExit: _onMouseExitSidebar,
                      child: AnimatedContainer(
                        key: const ValueKey<String>('desktopAutohideRail'),
                        duration: _sidebarVisible
                            ? _openDuration
                            : _closeDuration,
                        curve: _animCurve,
                        width: _sidebarVisible
                            ? effectiveSidebarWidth
                            : _collapsedWidth,
                        decoration: BoxDecoration(
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: colors.shadow.withValues(
                                alpha: _sidebarVisible ? 0.32 : 0,
                              ),
                              blurRadius: 24,
                              offset: const Offset(6, 0),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.hardEdge,
                        // Laid out at the full width the whole time: the
                        // animated width only clips it, so the rail slides in
                        // and out instead of squeezing its labels.
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: effectiveSidebarWidth,
                          maxWidth: effectiveSidebarWidth,
                          child: sidebarContent,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        FocusTraversalOrder(
          order: const NumericFocusOrder(30),
          child: _DesktopPlayerBar(
            playback: widget.playback,
            songTitle: widget.songTitle,
            songArtist: widget.songArtist,
            artistId: widget.artistId,
            albumId: widget.albumId,
            coverArtId: widget.coverArtId,
            coverArtUrl: widget.playback.isRadioMode
                ? widget.playback.radioStation?.nowPlayingArtUrl
                : widget.coverArtUrl,
            isExternalSource: widget.isExternalSource,
            onToggleQueue: widget.onToggleQueue,
            queueToggleFocusNode: widget.queueToggleFocusNode,
            lyricsActive: widget.showLyricsOverlay,
            onToggleLyrics: widget.onToggleLyrics,
          ),
        ),
      ],
    );
  }
}
