part of 'app_shell.dart';

class _ShellDestination {
  const new({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;

  /// Filled variant shown for the selected destination.
  final IconData selectedIcon;
  final String label;
}

class _CompactIconRail extends StatelessWidget {
  const new({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<_ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = destinations.length;
        final hitTargetWidth = constraints.maxWidth;
        // Keep rail width 20% wider than icon width in compact landscape.
        final iconSize = ((hitTargetWidth / 1.2) * 0.8).clamp(22.4, 38.4);

        return Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            for (var i = 0; i < count; i++)
              Expanded(
                child: SizedBox(
                  width: hitTargetWidth,
                  height: double.infinity,
                  child: Tooltip(
                    message: destinations[i].label,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Semantics(
                      key: ValueKey<String>('compactRailNavTile-$i'),
                      container: true,
                      button: true,
                      label: destinations[i].label,
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                      child: ExcludeSemantics(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onDestinationSelected(i),
                          child: Center(
                            child: Icon(
                              i == selectedIndex
                                  ? destinations[i].selectedIcon
                                  : destinations[i].icon,
                              size: iconSize,
                              color: i == selectedIndex
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RailSidebar extends ConsumerWidget {
  const new({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.showLibrarySubNavigation,
    this.allowScrollableRail = true,
    required this.selectedLibrarySection,
    required this.visibleLibrarySections,
    required this.onLibrarySectionSelected,
    required this.showPlayer,
    required this.playback,
    required this.onOpenPlayer,
    this.navbarStyle = 'comfortable',
    this.songTitle,
    this.songArtist,
    this.artistId,
    this.albumId,
    this.coverArtId,
    this.coverArtUrl,
    this.isExternalSource = false,
    this.isRadio = false,
    this.radioArtUrl,
    this.navbarAutohide = false,
    this.onToggleAutohide,
    this.librarySectionsFit,
    this.showHistoryControls = false,
  });

  final List<_ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool showLibrarySubNavigation;
  final bool allowScrollableRail;

  /// The Library section to highlight; null on Library detail pages, where
  /// only the Library destination is selected.
  final LibrarySection? selectedLibrarySection;
  final List<LibrarySection> visibleLibrarySections;
  final ValueChanged<LibrarySection> onLibrarySectionSelected;
  final bool showPlayer;
  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isExternalSource;
  final bool isRadio;
  final String? radioArtUrl;
  final VoidCallback onOpenPlayer;
  final String navbarStyle;
  final bool navbarAutohide;
  final VoidCallback? onToggleAutohide;

  /// Receives whether the Library section links fit this sidebar's height,
  /// so the Library page can show its own section bar when they do not.
  final ValueNotifier<bool>? librarySectionsFit;

  /// Shows desktop Back/Forward history buttons above the destinations.
  final bool showHistoryControls;

  Widget _autohideButton(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(
          navbarAutohide ? Icons.lock_open_rounded : Icons.lock_rounded,
          size: 16,
        ),
        tooltip: navbarAutohide
            ? AppLocalizations.of(context)!.desktopNavbarLockTooltip
            : AppLocalizations.of(context)!.desktopNavbarUnlockTooltip,
        onPressed: onToggleAutohide,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          maximumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iconsOnly = navbarStyle == 'icons';
    final compact = navbarStyle == 'compact';
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (iconsOnly)
            Column(
              children: <Widget>[
                if (showHistoryControls) const _HistoryButtons(vertical: true),
                if (onToggleAutohide != null) _autohideButton(context),
              ],
            )
          else if (showHistoryControls || onToggleAutohide != null)
            Row(
              children: <Widget>[
                if (showHistoryControls) const _HistoryButtons(),
                const Spacer(),
                if (onToggleAutohide != null) _autohideButton(context),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final navTileEstimatedHeight = compact ? 52.0 : 64.0;
                const subNavTileEstimatedHeight = 44.0;
                const subNavTrailingGap = 6.0;
                const reservedMiniPlayerHeight = 170.0;
                const railMiniPlayerGap = 6.0;
                const railCutoffSlack = 4.0;
                final librarySubSectionCount = visibleLibrarySections.length;
                final navViewportHeight =
                    (constraints.maxHeight -
                            (showPlayer
                                ? (reservedMiniPlayerHeight + railMiniPlayerGap)
                                : 0.0))
                        .clamp(0.0, double.infinity);
                final baseNavHeight =
                    destinations.length * navTileEstimatedHeight;
                final inlineLibraryNavHeight =
                    baseNavHeight +
                    (librarySubSectionCount * subNavTileEstimatedHeight) +
                    subNavTrailingGap;
                final librarySectionsFitHeight =
                    navViewportHeight >=
                    (inlineLibraryNavHeight + railCutoffSlack);
                final sectionsFit = librarySectionsFit;
                if (sectionsFit != null &&
                    sectionsFit.value != librarySectionsFitHeight) {
                  // Reported after layout; the notifier drives the Library
                  // page, which must not change while this sidebar lays out.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    sectionsFit.value = librarySectionsFitHeight;
                  });
                }
                final showLibrarySectionsInline =
                    !iconsOnly &&
                    showLibrarySubNavigation &&
                    librarySectionsFitHeight;
                final visibleNavContentHeight = showLibrarySectionsInline
                    ? inlineLibraryNavHeight
                    : baseNavHeight;
                final useScrollableRail =
                    allowScrollableRail &&
                    navViewportHeight <
                        (visibleNavContentHeight + (railCutoffSlack * 3));

                final navTiles = <Widget>[
                  for (var i = 0; i < destinations.length; i++) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RailNavTile(
                        key: ValueKey('railNavTile-$i'),
                        destination: destinations[i],
                        selected: i == selectedIndex,
                        onTap: () => onDestinationSelected(i),
                        iconsOnly: iconsOnly,
                        compact: compact,
                        showBadge: false,
                      ),
                    ),
                    if (showLibrarySectionsInline && i == 1) ...<Widget>[
                      for (final section in visibleLibrarySections)
                        _RailSubNavTile(
                          key: ValueKey<String>(
                            'railLibrarySection-${section.name}',
                          ),
                          label: _librarySectionShellLabel(context, section),
                          selected:
                              selectedIndex == ShellBranch.library.index &&
                              selectedLibrarySection == section,
                          onTap: () => onLibrarySectionSelected(section),
                        ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ];

                final player = showPlayer
                    ? _RailMiniPlayer(
                        playback: playback,
                        songTitle: songTitle,
                        songArtist: songArtist,
                        artistId: artistId,
                        albumId: albumId,
                        coverArtId: coverArtId,
                        coverArtUrl: coverArtUrl,
                        isExternalSource: isExternalSource,
                        isRadio: isRadio,
                        radioArtUrl: radioArtUrl,
                        onOpenPlayer: onOpenPlayer,
                      )
                    : const SizedBox.shrink();

                final navRegion = useScrollableRail
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: navTiles,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[...navTiles, const Spacer()],
                      );

                if (!showPlayer) {
                  return navRegion;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: navRegion),
                    const SizedBox(height: 6),
                    player,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _librarySectionShellLabel(BuildContext context, LibrarySection section) {
  final l10n = AppLocalizations.of(context)!;
  return switch (section) {
    LibrarySection.albums => l10n.libraryTabAlbums,
    LibrarySection.liked => l10n.libraryTabLiked,
    LibrarySection.artists => l10n.libraryTabArtists,
    LibrarySection.playlists => l10n.navPlaylists,
    LibrarySection.radio => l10n.navRadio,
  };
}

class _RailNavTile extends StatelessWidget {
  const new({
    super.key,
    required this.destination,
    required this.selected,
    required this.onTap,
    this.iconsOnly = false,
    this.compact = false,
    this.showBadge = false,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool iconsOnly;
  final bool compact;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      color: selected
          ? colorScheme.onSecondaryContainer
          : colorScheme.onSurfaceVariant,
    );
    final tilePadding = iconsOnly
        ? const EdgeInsets.symmetric(horizontal: 4, vertical: 12)
        : compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 14);

    return Material(
      color: selected
          ? colorScheme.secondaryContainer.withValues(alpha: 0.9)
          : Colors.transparent,
      borderRadius: NavisRadius.lgAll,
      child: InkWell(
        borderRadius: NavisRadius.lgAll,
        onTap: onTap,
        child: Padding(
          padding: tilePadding,
          child: Row(
            mainAxisAlignment: iconsOnly
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: <Widget>[
              Badge(
                isLabelVisible: showBadge,
                child: Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 24,
                  color: selected
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              if (!iconsOnly) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RailSubNavTile extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 6, bottom: 6),
      child: Material(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: NavisRadius.mdAll,
        child: InkWell(
          borderRadius: NavisRadius.mdAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop Back/Forward history buttons, enabled from history state.
class _HistoryButtons extends ConsumerWidget {
  const new({this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final (canGoBack, canGoForward) = ref.watch(
      navigationHistoryProvider.select(
        (history) => (history.canGoBack, history.canGoForward),
      ),
    );
    Widget button({
      required String key,
      required IconData icon,
      required String tooltip,
      required bool enabled,
      required bool forward,
    }) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: ValueKey<String>(key),
          icon: Icon(icon, size: 18),
          tooltip: tooltip,
          onPressed: enabled
              ? () =>
                    unawaited(NavService.navigateHistory(ref, forward: forward))
              : null,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            minimumSize: const Size(32, 32),
            maximumSize: const Size(32, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      );
    }

    final children = <Widget>[
      button(
        key: 'desktopHistoryBack',
        icon: Icons.arrow_back_rounded,
        tooltip: l10n.navigationBackTooltip,
        enabled: canGoBack,
        forward: false,
      ),
      button(
        key: 'desktopHistoryForward',
        icon: Icons.arrow_forward_rounded,
        tooltip: l10n.navigationForwardTooltip,
        enabled: canGoForward,
        forward: true,
      ),
    ];
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
