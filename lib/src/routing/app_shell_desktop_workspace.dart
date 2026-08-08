part of 'app_shell.dart';

class _DesktopWorkspace extends StatefulWidget {
  const _DesktopWorkspace({
    required this.desktopLayoutClass,
    required this.sidebarWidth,
    required this.navbarStyle,
    required this.navbarAutohide,
    required this.expandRequestNotifier,
    required this.selectedIndex,
    required this.destinations,
    required this.showOfflineBanner,
    required this.offlineBannerText,
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

  final DesktopLayoutClass desktopLayoutClass;
  final double sidebarWidth;
  final String navbarStyle;
  final bool navbarAutohide;
  final ValueNotifier<int> expandRequestNotifier;
  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final bool showOfflineBanner;
  final String offlineBannerText;
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
  final bool allowScrollableRail;
  final LibrarySection selectedLibrarySection;
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
  static const Duration _animDuration = Duration(milliseconds: 280);
  static const Curve _animCurve = Curves.easeOutCubic;
  static const double _collapsedWidth = 4.0;
  static const double _magnetZoneWidth = 40.0;
  static const Duration _collapseDelay = Duration(milliseconds: 500);
  static const Duration _navExpandHoldDuration = Duration(milliseconds: 1600);

  bool _sidebarVisible = true;
  bool _mouseIsOverSidebar = false;
  Timer? _collapseTimer;
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
      if (!_sidebarVisible) {
        setState(() => _sidebarVisible = true);
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
    super.dispose();
  }

  void _onExpandRequest() {
    if (!widget.navbarAutohide) return;
    final current = widget.expandRequestNotifier.value;
    if (current == _lastExpandRequest) return;
    _lastExpandRequest = current;
    _collapseTimer?.cancel();
    if (!mounted) return;
    setState(() => _sidebarVisible = true);
    _collapseTimer = Timer(_navExpandHoldDuration, () {
      if (!mounted || _mouseIsOverSidebar) return;
      setState(() => _sidebarVisible = false);
    });
  }

  void _onMouseEnterSidebar(PointerEnterEvent _) {
    if (!widget.navbarAutohide) return;
    _collapseTimer?.cancel();
    _mouseIsOverSidebar = true;
    if (!mounted) return;
    setState(() => _sidebarVisible = true);
  }

  void _onMouseExitSidebar(PointerExitEvent _) {
    if (!widget.navbarAutohide) return;
    _mouseIsOverSidebar = false;
    _scheduleCollapse();
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_collapseDelay, () {
      if (!mounted || _mouseIsOverSidebar) return;
      setState(() => _sidebarVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final effectiveSidebarWidth = widget.navbarAutohide && !_sidebarVisible
        ? _collapsedWidth
        : widget.sidebarWidth;

    final sidebarContent = Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        child: widget.navbarAutohide && !_sidebarVisible
            ? const SizedBox.expand()
            : SizedBox(
                key: const ValueKey<String>('desktopSidebarRegion'),
                width: widget.sidebarWidth,
                child: Padding(
                  padding: widget.navbarStyle == 'icons'
                      ? const EdgeInsets.fromLTRB(4, 12, 4, 12)
                      : const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: _RailSidebar(
                    navbarStyle: widget.navbarStyle,
                    selectedIndex: widget.selectedIndex,
                    onDestinationSelected: widget.onDestinationSelected,
                    destinations: widget.destinations,
                    showLibrarySubNavigation: widget.showLibrarySubNavigation,
                    allowScrollableRail: widget.allowScrollableRail,
                    selectedLibrarySection: widget.selectedLibrarySection,
                    visibleLibrarySections: widget.visibleLibrarySections,
                    onLibrarySectionSelected: widget.onLibrarySectionSelected,
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
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(10),
                      child: AnimatedContainer(
                        duration: _animDuration,
                        curve: _animCurve,
                        width: effectiveSidebarWidth,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: widget.sidebarWidth,
                            maxWidth: widget.sidebarWidth,
                            child: sidebarContent,
                          ),
                        ),
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
                          child: Column(
                            children: <Widget>[
                              if (widget.showOfflineBanner)
                                Material(
                                  color: colors.errorContainer,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        Icon(
                                          Icons.cloud_off_outlined,
                                          color: colors.onErrorContainer,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            widget.offlineBannerText,
                                            style: TextStyle(
                                              color: colors.onErrorContainer,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final width = constraints.maxWidth;
                                    final horizontalInset = switch (widget
                                        .desktopLayoutClass) {
                                      DesktopLayoutClass.compactDesktop => 12.0,
                                      DesktopLayoutClass.standardDesktop =>
                                        (width * 0.018).clamp(14.0, 30.0),
                                      DesktopLayoutClass.ultraWideDesktop =>
                                        (width * 0.022).clamp(18.0, 44.0),
                                    };
                                    const verticalInset = 20.0;

                                    return NavigatorPopHandler<Object?>(
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
                                            child: Padding(
                                              padding: EdgeInsets.fromLTRB(
                                                horizontalInset,
                                                verticalInset,
                                                horizontalInset,
                                                verticalInset,
                                              ),
                                              child: Stack(
                                                children: <Widget>[
                                                  Positioned.fill(
                                                    child:
                                                        widget.navigationShell,
                                                  ),
                                                  if (widget.showLyricsOverlay)
                                                    Positioned.fill(
                                                      child:
                                                          _DesktopLyricsOverlay(
                                                            onClose: widget
                                                                .onToggleLyrics,
                                                          ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (widget.showPlayer &&
                                              widget.showQueueOverlay)
                                            Positioned.fill(
                                              child: FocusTraversalOrder(
                                                order: const NumericFocusOrder(
                                                  5,
                                                ),
                                                child: _QueueOverlay(
                                                  key: widget.queueOverlayKey,
                                                  fullscreen: false,
                                                  floatingWindow: true,
                                                  onDismiss:
                                                      widget.onDismissQueue,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.navbarAutohide)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _sidebarVisible
                      ? widget.sidebarWidth
                      : _magnetZoneWidth,
                  child: MouseRegion(
                    opaque: false,
                    onEnter: _onMouseEnterSidebar,
                    onExit: _onMouseExitSidebar,
                  ),
                ),
            ],
          ),
        ),
        if (widget.showPlayer)
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
              onOpenPlayer: widget.onOpenPlayer,
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
