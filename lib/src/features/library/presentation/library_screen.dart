import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_density_scope.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/artist_grid_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/home/presentation/trending_detail_screen.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show quickSearchOverlayVisibleProvider;
import 'package:navis/src/features/library/presentation/unavailable_review_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/library_section_navigation_scope.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:navis/src/features/library/presentation/liked_playback_provider.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/artwork_shape.dart';

part 'library_support_widgets.dart';
part 'library_tabs.dart';

enum _AlbumSort { recentlyAdded, newest, name, artist, byYear }

bool _likedSongMatchesTypeFilter(SongsTableData song, String queryLower) {
  return song.title.toLowerCase().contains(queryLower) ||
      (song.artistName?.toLowerCase().contains(queryLower) ?? false) ||
      (song.albumName?.toLowerCase().contains(queryLower) ?? false);
}

List<SongsTableData> _filterLikedSongs(
  List<SongsTableData> songs, {
  Set<String>? downloadedSongIds,
  String typeFilterQuery = '',
}) {
  final downloadFiltered = downloadedSongIds == null
      ? songs
      : songs
            .where((song) => downloadedSongIds.contains(song.id))
            .toList(growable: false);
  if (typeFilterQuery.isEmpty) {
    return downloadFiltered;
  }

  final queryLower = typeFilterQuery.toLowerCase();
  return downloadFiltered
      .where((song) => _likedSongMatchesTypeFilter(song, queryLower))
      .toList(growable: false);
}

class LibraryScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with TickerProviderStateMixin {
  _AlbumSort _albumSort = _AlbumSort.recentlyAdded;
  bool _downloadedOnly = false;
  bool _artistsLikedOnly = false;
  final ScrollController _albumsScrollController = ScrollController();
  final ScrollController _likedScrollController = ScrollController();
  final ScrollController _playlistsScrollController = ScrollController();
  final ScrollController _radioScrollController = ScrollController();
  final ScrollController _artistsGridScrollController = ScrollController();
  final ItemScrollController _artistsItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _artistsItemPositionsListener =
      ItemPositionsListener.create();
  final ItemScrollController _yearItemScrollController = ItemScrollController();
  final ItemPositionsListener _yearItemPositionsListener =
      ItemPositionsListener.create();
  List<ArtistsTableData>? _cachedArtists;
  List<_ArtistListItem> _artistListItems = const <_ArtistListItem>[];
  Map<String, int> _artistLetterStartIndex = const <String, int>{};
  Map<String, GlobalKey> _artistGridSectionKeys = const <String, GlobalKey>{};
  String? _activeArtistLetter;
  bool _isArtistRailScrubbing = false;
  int _loadedAlbumPages = 1;
  String _lastVisibleAlbumSignature = '';
  List<AlbumsTableData>? _cachedAlbums;
  List<_YearListItem> _yearListItems = const <_YearListItem>[];
  List<AlbumYearSection>? _cachedYearSectionsSource;
  Map<String, int> _yearDecadeStartIndex = const <String, int>{};
  String? _activeYearDecade;
  bool _isYearRailScrubbing = false;
  TabController? _tabController;
  bool _synchronizingTabControllerFromSection = false;
  LibrarySection? _pendingSectionSync;
  late final ProviderSubscription<int> _libraryScrollSubscription;
  late final ProviderSubscription<bool> _downloadedOnlySubscription;
  late final ProviderSubscription<String?> _typeFilterDiagnosticsSubscription;
  late final ProviderSubscription<LibraryScrollDiagnosticsRequest?>
  _scrollDiagnosticsSubscription;
  int _lastLibraryScrollRequest = 0;

  // ── Type-to-filter (keyboard-driven inline search) ──────────────────────
  String _typeFilterQuery = '';
  bool _typeFilterOverlayVisible = false;
  Timer? _typeFilterFadeTimer;

  @override
  void initState() {
    super.initState();
    _downloadedOnly = ref.read(downloadedOnlyFilterProvider);
    _albumsScrollController.addListener(_onAlbumsScroll);
    _artistsItemPositionsListener.itemPositions.addListener(
      _onArtistsViewportChanged,
    );
    _artistsGridScrollController.addListener(_onArtistsGridScrolled);
    _yearItemPositionsListener.itemPositions.addListener(
      _onYearViewportChanged,
    );
    _lastLibraryScrollRequest = ref.read(libraryScrollToTopRequestProvider);
    _libraryScrollSubscription = ref.listenManual<int>(
      libraryScrollToTopRequestProvider,
      (previous, next) {
        if (!mounted || next == _lastLibraryScrollRequest) {
          return;
        }
        _lastLibraryScrollRequest = next;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _scrollCurrentTabToTop();
        });
      },
    );
    _downloadedOnlySubscription = ref.listenManual<bool>(
      downloadedOnlyFilterProvider,
      (previous, next) {
        if (!mounted || next == _downloadedOnly) {
          return;
        }
        setState(() {
          _downloadedOnly = next;
          _loadedAlbumPages = 1;
          _cachedAlbums = null;
          _yearListItems = const <_YearListItem>[];
          _cachedYearSectionsSource = null;
        });
      },
    );
    _typeFilterDiagnosticsSubscription = ref.listenManual<String?>(
      libraryTypeFilterDiagnosticsProvider,
      (previous, next) {
        if (!mounted || next == null) {
          return;
        }
        _updateTypeFilter(next);
      },
    );
    _scrollDiagnosticsSubscription = ref.listenManual(
      libraryScrollDiagnosticsProvider,
      (previous, request) async {
        if (request == null) return;
        final controller = switch (ref.read(librarySectionProvider)) {
          LibrarySection.albums => _albumsScrollController,
          LibrarySection.liked => _likedScrollController,
          _ => null,
        };
        if (!mounted || controller == null || !controller.hasClients) {
          request.completed.completeError(
            StateError('Selected collection scroll view is not mounted'),
          );
          return;
        }
        try {
          final target = request.pixels.clamp(
            0.0,
            controller.position.maxScrollExtent,
          );
          await controller.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.linear,
          );
          if (!mounted || !controller.hasClients) {
            throw StateError('Albums scroll view detached');
          }
          request.completed.complete(controller.offset);
        } on Object catch (error, stack) {
          request.completed.completeError(error, stack);
        }
      },
    );
    HardwareKeyboard.instance.addHandler(_onLibraryKeyEvent);
  }

  @override
  void dispose() {
    _libraryScrollSubscription.close();
    _downloadedOnlySubscription.close();
    _typeFilterDiagnosticsSubscription.close();
    _scrollDiagnosticsSubscription.close();
    _tabController?.removeListener(_handleTabControllerTick);
    _tabController?.dispose();
    _albumsScrollController
      ..removeListener(_onAlbumsScroll)
      ..dispose();
    _likedScrollController.dispose();
    _artistsGridScrollController
      ..removeListener(_onArtistsGridScrolled)
      ..dispose();
    _playlistsScrollController.dispose();
    _radioScrollController.dispose();
    _artistsItemPositionsListener.itemPositions.removeListener(
      _onArtistsViewportChanged,
    );
    _yearItemPositionsListener.itemPositions.removeListener(
      _onYearViewportChanged,
    );
    HardwareKeyboard.instance.removeHandler(_onLibraryKeyEvent);
    _typeFilterFadeTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLibrary() => triggerLibrarySyncFromPull(ref);

  void _updateDownloadedOnly(bool value) {
    if (ref.read(downloadedOnlyFilterProvider) == value) {
      return;
    }
    ref.read(downloadedOnlyFilterProvider.notifier).enabled = value;
  }

  /// Gives an empty, filtered Library result a direct path back to content.
  /// A filter should never strand people on an otherwise indistinguishable
  /// empty state.
  Widget? _buildClearFiltersAction({bool includesLikedOnly = false}) {
    final hasActiveFilters =
        _downloadedOnly ||
        _typeFilterQuery.isNotEmpty ||
        (includesLikedOnly && _artistsLikedOnly);
    if (!hasActiveFilters) {
      return null;
    }
    final l10n = AppLocalizations.of(context)!;
    return FilledButton.tonalIcon(
      style: NavisColorStyleData.tonalStyleOf(context),
      key: const ValueKey<String>('libraryClearFiltersAction'),
      onPressed: () {
        _typeFilterFadeTimer?.cancel();
        setState(() {
          _typeFilterQuery = '';
          _typeFilterOverlayVisible = false;
          if (includesLikedOnly) {
            _artistsLikedOnly = false;
          }
        });
        _updateDownloadedOnly(false);
      },
      icon: const Icon(Icons.filter_alt_off_outlined),
      label: Text(l10n.libraryClearFiltersAction),
    );
  }

  // ---------------------------------------------------------------------------
  // Type-to-filter — keyboard handler & state helpers
  // ---------------------------------------------------------------------------

  bool _onLibraryKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // The shell keeps this branch mounted behind other tabs; only the visible
    // Library tab may take keystrokes.
    if (!TickerMode.valuesOf(context).enabled) return false;
    // Don't intercept when the quick-search overlay is visible.
    if (ref.read(quickSearchOverlayVisibleProvider)) return false;
    // Only when library root is the active screen (not inside album/artist detail)
    final nav = Navigator.maybeOf(context, rootNavigator: false);
    if (nav != null && nav.canPop()) return false;
    // Don't intercept modifier combos (shortcuts)
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    // Don't intercept when a text field is being edited
    final focusWidget = FocusManager.instance.primaryFocus?.context?.widget;
    if (focusWidget is EditableText) return false;
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      if (_typeFilterQuery.isEmpty) return false;
      _updateTypeFilter(
        _typeFilterQuery.substring(0, _typeFilterQuery.length - 1),
      );
      return true;
    }
    if (key == LogicalKeyboardKey.escape && _typeFilterQuery.isNotEmpty) {
      _clearTypeFilter();
      return true;
    }
    final char = event.character;
    if (char != null && char.isNotEmpty && !_isLibraryFilterControlChar(char)) {
      // Don't start a new filter with a space — only add spaces to an
      // existing query so play/pause isn't swallowed before typing begins.
      if (char == ' ' && _typeFilterQuery.isEmpty) return false;
      _updateTypeFilter(_typeFilterQuery + char);
      return true;
    }
    return false;
  }

  bool _isLibraryFilterControlChar(String s) {
    if (s.isEmpty) return true;
    final code = s.codeUnitAt(0);
    return code < 32 || code == 127;
  }

  void _updateTypeFilter(String query) {
    if (query.isEmpty) {
      _clearTypeFilter();
      return;
    }
    _typeFilterFadeTimer?.cancel();
    setState(() {
      _typeFilterQuery = query;
      _typeFilterOverlayVisible = true;
      _cachedArtists = null; // invalidate artist cache so grouping rebuilds
      _cachedYearSectionsSource = null; // invalidate year cache
    });
    ref.read(libraryTypeFilterActiveProvider.notifier).active = true;
    _typeFilterFadeTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _typeFilterOverlayVisible = false);
        ref.read(libraryTypeFilterActiveProvider.notifier).active = false;
      }
    });
  }

  void _clearTypeFilter() {
    _typeFilterFadeTimer?.cancel();
    setState(() {
      _typeFilterQuery = '';
      _typeFilterOverlayVisible = false;
      _cachedArtists = null;
      _cachedAlbums = null;
      _yearListItems = const <_YearListItem>[];
      _cachedYearSectionsSource = null;
    });
    ref.read(libraryTypeFilterActiveProvider.notifier).active = false;
  }

  void _animateScrollControllerToTop(ScrollController controller) {
    if (!controller.hasClients) {
      return;
    }

    final position = controller.position;
    if (!position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _animateScrollControllerToTop(controller);
      });
      return;
    }

    if (position.pixels <= position.minScrollExtent) {
      return;
    }

    controller.animateTo(
      position.minScrollExtent,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  /// Scrolls whichever tab is currently selected back to the top.
  void _scrollCurrentTabToTop() {
    final sections = ref.read(visibleLibrarySectionsProvider);
    if (sections.isEmpty) {
      return;
    }
    final tab = (_tabController?.index ?? 0).clamp(0, sections.length - 1);
    _scrollSectionToTop(sections[tab]);
  }

  void _scrollSectionToTop(LibrarySection section) {
    switch (section) {
      case LibrarySection.albums:
        if (_albumSort == _AlbumSort.byYear) {
          if (_yearItemScrollController.isAttached) {
            unawaited(
              _yearItemScrollController.scrollTo(
                index: 0,
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
              ),
            );
          }
        } else {
          _animateScrollControllerToTop(_albumsScrollController);
        }
        return;
      case LibrarySection.liked:
        _animateScrollControllerToTop(_likedScrollController);
        return;
      case LibrarySection.artists:
        if (_artistsItemScrollController.isAttached) {
          unawaited(
            _artistsItemScrollController.scrollTo(
              index: 0,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        return;
      case LibrarySection.playlists:
        _animateScrollControllerToTop(_playlistsScrollController);
        return;
      case LibrarySection.radio:
        _animateScrollControllerToTop(_radioScrollController);
        return;
    }
  }

  int _tabIndexForSection(
    LibrarySection section,
    List<LibrarySection> visibleSections,
  ) {
    final index = visibleSections.indexOf(section);
    if (index >= 0) {
      return index;
    }
    return 0;
  }

  LibrarySection _sectionForTabIndex(
    int tabIndex,
    List<LibrarySection> visibleSections,
  ) {
    if (tabIndex >= 0 && tabIndex < visibleSections.length) {
      return visibleSections[tabIndex];
    }
    return LibrarySection.albums;
  }

  Widget _tabForSection(AppLocalizations l10n, LibrarySection section) {
    return Tab(text: _sectionTitle(l10n, section));
  }

  Widget _viewForSection(
    BuildContext context,
    LibrarySection section, {
    required bool desktopMode,
  }) {
    return switch (section) {
      LibrarySection.albums => _buildAlbumsTab(context),
      LibrarySection.liked => _buildLikedTab(context, desktopMode: desktopMode),
      LibrarySection.artists => _buildArtistsTab(context),
      LibrarySection.playlists => _LibraryPlaylistsTab(
        scrollController: _playlistsScrollController,
      ),
      LibrarySection.radio => RadioTabContent(
        scrollController: _radioScrollController,
        typeFilterQuery: _typeFilterQuery,
        onClearTypeFilter: _clearTypeFilter,
      ),
    };
  }

  String _sectionTitle(AppLocalizations l10n, LibrarySection section) {
    return switch (section) {
      LibrarySection.albums => l10n.libraryTabAlbums,
      LibrarySection.liked => l10n.libraryTabLiked,
      LibrarySection.artists => l10n.libraryTabArtists,
      LibrarySection.playlists => l10n.navPlaylists,
      LibrarySection.radio => l10n.navRadio,
    };
  }

  void _handleTabControllerTick() {
    final controller = _tabController;
    if (controller == null ||
        controller.indexIsChanging ||
        _synchronizingTabControllerFromSection) {
      return;
    }
    final sections = ref.read(visibleLibrarySectionsProvider);
    if (sections.isEmpty) {
      return;
    }
    final section = _sectionForTabIndex(controller.index, sections);
    _scheduleSectionSync(section);
  }

  void _scheduleSectionSync(LibrarySection section) {
    if (!mounted || _pendingSectionSync == section) {
      return;
    }
    _pendingSectionSync = section;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final pending = _pendingSectionSync;
      _pendingSectionSync = null;
      if (pending == null || ref.read(librarySectionProvider) == pending) {
        return;
      }
      ref.read(librarySectionProvider.notifier).setSection(pending);
      NavService.recordLibrarySection(context, pending);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final visibleSections = ref.watch(visibleLibrarySectionsProvider);
    if (visibleSections.isEmpty) {
      _disposeTabController();
      return _buildNoLibraryPagesScaffold(context, adaptiveContext);
    }
    final tabCount = visibleSections.length;
    final desktopMode = adaptiveContext.useDesktopShell;
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final selectedSection = ref.watch(librarySectionProvider);
    final tabletMode =
        !desktopMode && adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    // The shell reports whether its sidebar shows the section links; when it
    // does not, this page shows its own section bar.
    final useWideLibraryNavigation =
        LibrarySectionNavigationScope.sidebarShowsSections(context);
    final tabController = _ensureTabController(tabCount);
    final desiredTabIndex = _tabIndexForSection(
      selectedSection,
      visibleSections,
    );
    if (tabController.index != desiredTabIndex &&
        !tabController.indexIsChanging) {
      _synchronizingTabControllerFromSection = true;
      try {
        tabController.index = desiredTabIndex;
      } finally {
        _synchronizingTabControllerFromSection = false;
      }
    }
    final activeSection = _sectionForTabIndex(
      tabController.index,
      visibleSections,
    );
    if (selectedSection != activeSection) {
      _scheduleSectionSync(activeSection);
    }
    final wideHeaderTitle =
        '${l10n.libraryTitle} - ${_sectionTitle(l10n, activeSection)}';
    final tabLabels = visibleSections
        .map((section) => _sectionTitle(l10n, section))
        .toList(growable: false);
    final labelStyle =
        Theme.of(context).tabBarTheme.labelStyle ??
        Theme.of(context).textTheme.titleSmall ??
        const TextStyle();
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    var estimatedLabelsWidth = 0.0;
    for (final label in tabLabels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();
      estimatedLabelsWidth += painter.width;
    }
    final horizontalLabelPadding = tabletMode ? 40.0 : 32.0;
    final estimatedTabBarWidth =
        estimatedLabelsWidth + (tabCount * horizontalLabelPadding) + 16;
    final availableTabWidth = MediaQuery.sizeOf(context).width;
    final useScrollableTabs = estimatedTabBarWidth > availableTabWidth;
    final tabBar = TabBar(
      controller: tabController,
      isScrollable: useScrollableTabs,
      tabAlignment: useScrollableTabs ? TabAlignment.start : TabAlignment.fill,
      labelPadding: tabletMode
          ? const EdgeInsets.symmetric(horizontal: 20)
          : null,
      tabs: <Widget>[
        for (final section in visibleSections) _tabForSection(l10n, section),
      ],
    );
    final bodyContent = Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            // Only the banner follows sync progress, so progress updates do not
            // rebuild the active tab.
            Consumer(
              builder: (context, ref, _) => LibrarySyncStatusBanner(
                syncState: ref.watch(librarySyncControllerProvider),
                onRetry: _refreshLibrary,
                onCancel: () {
                  ref.read(librarySyncControllerProvider.notifier).cancelSync();
                },
              ),
            ),
            if (_typeFilterQuery.isNotEmpty)
              _TypeFilterBadge(
                query: _typeFilterQuery,
                onClear: _clearTypeFilter,
              ),
            Expanded(
              child: TabBarView(
                controller: tabController,
                physics: (_isArtistRailScrubbing || _isYearRailScrubbing)
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                children: <Widget>[
                  for (final section in visibleSections)
                    _viewForSection(context, section, desktopMode: desktopMode),
                ],
              ),
            ),
          ],
        ),
        // Type-to-filter: large typography overlay with dimming
        if (_typeFilterOverlayVisible && _typeFilterQuery.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _typeFilterOverlayVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _typeFilterQuery,
                        style: Theme.of(context).textTheme.displayLarge
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: Colors.white.withValues(alpha: 0.85),
                              letterSpacing: 2,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (desktopMode) {
      final colors = Theme.of(context).colorScheme;
      // With the sections in the sidebar the page is one continuous
      // workspace; otherwise a toolbar carries the title and section tabs.
      final toolbarTrailing = useWideLibraryNavigation
          ? (DesktopNavigationPresentationScope.iconsOnlyOf(context)
                ? Text(
                    _sectionTitle(l10n, activeSection),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: colors.onSurfaceVariant),
                  )
                : null)
          : TabBar(
              key: const ValueKey<String>('libraryDesktopSectionTabs'),
              controller: tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.transparent,
              tabs: <Widget>[
                for (final section in visibleSections)
                  _tabForSection(l10n, section),
              ],
            );
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: DesktopFrame(
            layoutClass: resolveDesktopLayoutClass(
              MediaQuery.sizeOf(context).width,
            ),
            padding: EdgeInsets.zero,
            child: toolbarTrailing == null
                ? bodyContent
                : Column(
                    children: <Widget>[
                      Material(
                        key: const ValueKey<String>(
                          'libraryDesktopWorkspaceToolbar',
                        ),
                        color: colors.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                          child: Row(
                            children: <Widget>[
                              Text(
                                l10n.libraryTitle,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(width: 16),
                              Flexible(child: toolbarTrailing),
                            ],
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: colors.outlineVariant.withValues(alpha: 0.35),
                      ),
                      Expanded(child: bodyContent),
                    ],
                  ),
          ),
        ),
      );
    }

    if (useWideLibraryNavigation) {
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                child: Text(
                  wideHeaderTitle,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: bodyContent),
            ],
          ),
        ),
      );
    }

    if (tabletMode) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.libraryTitle), bottom: tabBar),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(),
            child: bodyContent,
          ),
        ),
      );
    }

    final portraitPhone =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: portraitPhone ? 12 : null,
        automaticallyImplyLeading: !portraitPhone,
        title: portraitPhone ? null : Text(l10n.libraryTitle),
        bottom: tabBar,
      ),
      body: bodyContent,
    );
  }

  TabController _ensureTabController(int tabCount) {
    final existing = _tabController;
    if (existing == null) {
      final created = TabController(length: tabCount, vsync: this);
      created.addListener(_handleTabControllerTick);
      _tabController = created;
      return created;
    }
    if (existing.length == tabCount) {
      return existing;
    }
    final nextIndex = existing.index.clamp(0, tabCount - 1);
    existing.removeListener(_handleTabControllerTick);
    existing.dispose();
    final replaced = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: nextIndex,
    );
    replaced.addListener(_handleTabControllerTick);
    _tabController = replaced;
    return replaced;
  }

  void _disposeTabController() {
    final existing = _tabController;
    if (existing == null) {
      return;
    }
    existing.removeListener(_handleTabControllerTick);
    existing.dispose();
    _tabController = null;
  }

  Widget _buildNoLibraryPagesScaffold(
    BuildContext context,
    AdaptiveContext adaptiveContext,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = adaptiveContext.useDesktopShell;
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final tabletMode =
        !desktopMode && adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    final content = EmptyState(
      title: l10n.libraryNoPagesEnabledTitle,
      subtitle: l10n.libraryNoPagesEnabledSubtitle,
      icon: Icons.visibility_off_outlined,
      action: FilledButton.tonalIcon(
        style: NavisColorStyleData.tonalStyleOf(context),
        onPressed: () => NavService.openAppearanceSettings(context, ref),
        icon: const Icon(Icons.tune_outlined),
        label: Text(l10n.libraryNoPagesEnabledAction),
      ),
    );

    if (desktopMode) {
      final colors = Theme.of(context).colorScheme;
      final showDesktopWorkspaceHeader =
          DesktopNavigationPresentationScope.iconsOnlyOf(context);
      return Scaffold(
        body: SafeArea(
          child: DesktopFrame(
            layoutClass: resolveDesktopLayoutClass(
              MediaQuery.sizeOf(context).width,
            ),
            padding: EdgeInsets.zero,
            child: showDesktopWorkspaceHeader
                ? Column(
                    children: <Widget>[
                      Material(
                        color: colors.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                          child: Text(
                            l10n.libraryTitle,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: colors.outlineVariant.withValues(alpha: 0.35),
                      ),
                      Expanded(child: content),
                    ],
                  )
                : content,
          ),
        ),
      );
    }

    if (tabletMode) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.libraryTitle)),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(),
            child: content,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryTitle)),
      body: content,
    );
  }

  Widget _buildArtistsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artists = ref.watch(
      _artistsLikedOnly ? likedArtistsProvider : artistsProvider,
    );
    final isGridMode = ref.watch(artistViewModeProvider) == 'grid';
    // Watch downloaded content IDs so filter updates reactively.
    if (_downloadedOnly) {
      ref.watch(downloadedContentIdsProvider);
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilterChip(
                      label: Text(l10n.libraryDownloadedOnlyFilter),
                      selected: _downloadedOnly,
                      onSelected: _updateDownloadedOnly,
                      avatar: Icon(
                        _downloadedOnly
                            ? Icons.download_done
                            : Icons.download_outlined,
                        size: 18,
                      ),
                    ),
                    FilterChip(
                      label: Text(l10n.libraryLikedOnlyFilter),
                      selected: _artistsLikedOnly,
                      onSelected: (value) =>
                          setState(() => _artistsLikedOnly = value),
                      avatar: Icon(
                        _artistsLikedOnly
                            ? Icons.favorite
                            : Icons.favorite_border_outlined,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(isGridMode ? Icons.view_list : Icons.grid_view),
                tooltip: isGridMode
                    ? l10n.librarySwitchToArtistList
                    : l10n.librarySwitchToArtistGrid,
                onPressed: () async {
                  final repo = ref.read(settingsRepositoryProvider);
                  final settings = await repo.getSettings();
                  await repo.saveSettings(
                    settings.copyWith(
                      artistViewMode: isGridMode ? 'list' : 'grid',
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshLibrary,
            child: artists.when(
              data: (items) {
                final filteredItems = _downloadedOnly
                    ? _filterDownloadedArtists(items)
                    : items;
                final typeFiltered = _typeFilterQuery.isEmpty
                    ? filteredItems
                    : filteredItems
                          .where(
                            (a) => a.name.toLowerCase().contains(
                              _typeFilterQuery.toLowerCase(),
                            ),
                          )
                          .toList(growable: false);
                if (typeFiltered.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      EmptyState(
                        title: _typeFilterQuery.isNotEmpty
                            ? l10n.libraryFilterNoResults(_typeFilterQuery)
                            : _artistsLikedOnly
                            ? l10n.libraryLikedOnlyEmptyTitle
                            : _downloadedOnly
                            ? l10n.libraryDownloadedOnlyEmpty
                            : l10n.libraryArtistsEmptyTitle,
                        subtitle: _typeFilterQuery.isNotEmpty
                            ? null
                            : _artistsLikedOnly
                            ? l10n.libraryLikedOnlyEmptySubtitle
                            : _downloadedOnly
                            ? l10n.libraryDownloadedOnlyEmptySubtitle
                            : l10n.libraryArtistsEmptySubtitle,
                        icon: _typeFilterQuery.isNotEmpty
                            ? Icons.search_off
                            : _artistsLikedOnly
                            ? Icons.favorite_border_outlined
                            : _downloadedOnly
                            ? Icons.download_done_outlined
                            : Icons.person_outline,
                        action: _buildClearFiltersAction(
                          includesLikedOnly: true,
                        ),
                      ),
                    ],
                  );
                }

                _ensureArtistListCache(typeFiltered);
                // When a type-filter query is active, enhance the alphabet
                // rail to show the specific letters/prefixes available.
                final letters = _artistLetterStartIndex.keys.toList(
                  growable: false,
                );

                if (isGridMode) {
                  return Stack(
                    children: <Widget>[
                      _buildArtistsGrid(context, typeFiltered),
                      Positioned(
                        right: 0,
                        top: 8,
                        bottom: 8,
                        child: _SectionRail(
                          railKey: const Key('artistAlphabetRail'),
                          activeLabelKey: const Key('artistRailActiveLetter'),
                          labels: letters,
                          activeLabel: _activeArtistLetter,
                          onLabelSelected: _scrollToArtistLetter,
                          onInteractionStart: () {
                            if (_isArtistRailScrubbing) {
                              return;
                            }
                            setState(() => _isArtistRailScrubbing = true);
                          },
                          onInteractionEnd: () {
                            if (!_isArtistRailScrubbing) {
                              return;
                            }
                            setState(() => _isArtistRailScrubbing = false);
                          },
                        ),
                      ),
                      if (_isArtistRailScrubbing && _activeArtistLetter != null)
                        _RailOverlay(
                          overlayKey: const Key('artistAlphabetOverlay'),
                          label: _activeArtistLetter!,
                        ),
                    ],
                  );
                }

                return Stack(
                  children: <Widget>[
                    ScrollablePositionedList.builder(
                      itemCount: _artistListItems.length,
                      itemScrollController: _artistsItemScrollController,
                      itemPositionsListener: _artistsItemPositionsListener,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 16, right: 28),
                      itemBuilder: (context, index) {
                        final item = _artistListItems[index];
                        if (item.artist == null) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              item.letter,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          );
                        }
                        final artist = item.artist!;
                        return RepaintBoundary(
                          child: ArtistCard(
                            artist: artist,
                            onTap: () => NavService.openArtistDetail(
                              context,
                              ref,
                              artist.id,
                            ),
                            onLongPress: () =>
                                _showArtistActions(context, artist.id),
                            onMorePressed: (anchor) => _showArtistActions(
                              context,
                              artist.id,
                              anchor: anchor,
                            ),
                            onSecondaryTapDown: (details) => _showArtistActions(
                              context,
                              artist.id,
                              anchor: details.globalPosition,
                            ),
                            onStarToggled: () => _toggleArtistStar(artist),
                          ),
                        );
                      },
                    ),
                    Positioned(
                      right: 0,
                      top: 8,
                      bottom: 8,
                      child: _SectionRail(
                        railKey: const Key('artistAlphabetRail'),
                        activeLabelKey: const Key('artistRailActiveLetter'),
                        labels: letters,
                        activeLabel: _activeArtistLetter,
                        onLabelSelected: _scrollToArtistLetter,
                        onInteractionStart: () {
                          if (_isArtistRailScrubbing) {
                            return;
                          }
                          setState(() => _isArtistRailScrubbing = true);
                        },
                        onInteractionEnd: () {
                          if (!_isArtistRailScrubbing) {
                            return;
                          }
                          setState(() => _isArtistRailScrubbing = false);
                        },
                      ),
                    ),
                    if (_isArtistRailScrubbing && _activeArtistLetter != null)
                      _RailOverlay(
                        overlayKey: const Key('artistAlphabetOverlay'),
                        label: _activeArtistLetter!,
                      ),
                  ],
                );
              },
              loading: () => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[
                  _LoadingListPlaceholder(),
                  _LoadingListPlaceholder(),
                  _LoadingListPlaceholder(),
                ],
              ),
              error: (error, _) => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  ErrorState(
                    title: l10n.libraryArtistsErrorTitle,
                    onRetry: _refreshLibrary,
                    retryLabel: l10n.commonRetry,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_albumSort == _AlbumSort.byYear) {
      return _buildAlbumsByYearTab(context);
    }

    final pageSize = ref.watch(albumPageSizeProvider);
    final totalAlbumsAsync = ref.watch(albumCountProvider);
    final limit = pageSize * _loadedAlbumPages;
    // Watch downloaded content IDs so filter updates reactively.
    if (_downloadedOnly) {
      ref.watch(downloadedContentIdsProvider);
    }
    final sortOrder = _toAlbumSortOrder(_albumSort);
    final albumsAsync = ref.watch(
      _downloadedOnly || _typeFilterQuery.isNotEmpty
          ? sortedAlbumsProvider((sort: sortOrder, likedOnly: false))
          : pagedAlbumsProvider((sort: sortOrder, limit: limit)),
    );

    // Preserve previous album data while loading a new page to avoid
    // destroying the scroll position (provider key change → AsyncLoading).
    final items = albumsAsync.asData?.value ?? _cachedAlbums;
    if (albumsAsync.asData != null) {
      _cachedAlbums = albumsAsync.asData!.value;
    }

    if (items == null) {
      // First load — no cached data yet.
      return RefreshIndicator(
        onRefresh: _refreshLibrary,
        child: albumsAsync.when(
          data: (_) => const SizedBox.shrink(), // handled above
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const <Widget>[
              _LoadingListPlaceholder(),
              _LoadingListPlaceholder(),
              _LoadingListPlaceholder(),
            ],
          ),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              ErrorState(
                title: l10n.libraryAlbumsErrorTitle,
                onRetry: _refreshLibrary,
                retryLabel: l10n.commonRetry,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: Builder(
        builder: (context) {
          // Apply "Downloaded Only" filter if active.
          final filteredItems = _downloadedOnly
              ? _filterDownloadedAlbums(items)
              : items;
          // Apply type-to-filter query (client-side substring match).
          final typeFiltered = _typeFilterQuery.isEmpty
              ? filteredItems
              : filteredItems
                    .where((album) {
                      final q = _typeFilterQuery.toLowerCase();
                      return album.name.toLowerCase().contains(q) ||
                          (album.artistName?.toLowerCase().contains(q) ??
                              false);
                    })
                    .toList(growable: false);
          _reportVisibleAlbumPriority(typeFiltered);
          if (!albumsAsync.isLoading && !albumsAsync.hasError) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _onAlbumsScroll();
            });
          }
          final totalAlbums = _downloadedOnly || _typeFilterQuery.isNotEmpty
              ? typeFiltered.length
              : (totalAlbumsAsync.asData?.value ?? items.length);
          final hasMore =
              !_downloadedOnly &&
              _typeFilterQuery.isEmpty &&
              items.length < totalAlbums;
          return LayoutBuilder(
            builder: (context, constraints) {
              return Scrollbar(
                controller: _albumsScrollController,
                thumbVisibility: false,
                interactive: true,
                child: CustomScrollView(
                  controller: _albumsScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _SortFilterRow<_AlbumSort>(
                        sortLabel: l10n.libraryAlbumsSortLabel,
                        sortValue: _albumSort,
                        sortItems: <DropdownMenuItem<_AlbumSort>>[
                          DropdownMenuItem(
                            value: _AlbumSort.recentlyAdded,
                            child: Text(l10n.librarySortRecentlyAdded),
                          ),
                          DropdownMenuItem(
                            value: _AlbumSort.newest,
                            child: Text(l10n.librarySortNewest),
                          ),
                          DropdownMenuItem(
                            value: _AlbumSort.name,
                            child: Text(l10n.librarySortName),
                          ),
                          DropdownMenuItem(
                            value: _AlbumSort.artist,
                            child: Text(l10n.librarySortArtist),
                          ),
                          DropdownMenuItem(
                            value: _AlbumSort.byYear,
                            child: Text(l10n.librarySortByYear),
                          ),
                        ],
                        onSortChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _albumSort = value;
                              _loadedAlbumPages = 1;
                              _cachedAlbums = null;
                              _yearListItems = const <_YearListItem>[];
                              _cachedYearSectionsSource = null;
                            });
                            if (_albumsScrollController.hasClients) {
                              _albumsScrollController.jumpTo(0);
                            }
                          }
                        },
                        downloadedOnly: _downloadedOnly,
                        onDownloadedOnlyChanged: _updateDownloadedOnly,
                      ),
                    ),
                    if (typeFiltered.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          title: _typeFilterQuery.isNotEmpty
                              ? l10n.libraryFilterNoResults(_typeFilterQuery)
                              : _downloadedOnly
                              ? l10n.libraryDownloadedOnlyEmpty
                              : l10n.libraryAlbumsEmptyTitle,
                          subtitle: _typeFilterQuery.isNotEmpty
                              ? null
                              : _downloadedOnly
                              ? l10n.libraryDownloadedOnlyEmptySubtitle
                              : l10n.libraryAlbumsEmptySubtitle,
                          icon: _typeFilterQuery.isNotEmpty
                              ? Icons.search_off
                              : _downloadedOnly
                              ? Icons.download_done_outlined
                              : Icons.album_outlined,
                          action: _buildClearFiltersAction(),
                        ),
                      )
                    else
                      ResponsiveContentSliverGrid(
                        itemCount: typeFiltered.length,
                        itemBuilder: (context, index) {
                          final album = typeFiltered[index];
                          final heroTag = buildCoverArtHeroTag(
                            coverArtId: album.coverArt,
                            context: 'album',
                            entityId: album.id,
                          );
                          return RepaintBoundary(
                            child: AlbumCard(
                              key: ValueKey(album.id),
                              album: album,
                              size: AlbumCardSize.library,
                              heroTag: heroTag,
                              badge: AlbumDownloadBadge(albumId: album.id),
                              onTap: () {
                                ref
                                    .read(
                                      librarySyncControllerProvider.notifier,
                                    )
                                    .registerAlbumInteraction(album.id);
                                NavService.openAlbumDetail(
                                  context,
                                  ref,
                                  album.id,
                                  heroTag: heroTag,
                                );
                              },
                              onLongPress: () =>
                                  showAlbumContextMenu(context, ref, album.id),
                              onSecondaryTapDown: (details) =>
                                  showAlbumContextMenu(
                                    context,
                                    ref,
                                    album.id,
                                    anchor: details.globalPosition,
                                  ),
                            ),
                          );
                        },
                      ),
                    if (hasMore)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          child: Text(
                            l10n.libraryAlbumsPagingProgress(
                              items.length,
                              totalAlbums,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAlbumsByYearTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_downloadedOnly) {
      ref.watch(downloadedContentIdsProvider);
    }
    final sectionsAsync = ref.watch(
      albumYearSectionsProvider((
        likedOnly: false,
        downloadedOnly: _downloadedOnly,
      )),
    );
    if (sectionsAsync.asData != null) {
      var sections = sectionsAsync.asData!.value;
      // Apply type-to-filter to the year-based view.
      if (_typeFilterQuery.isNotEmpty) {
        final q = _typeFilterQuery.toLowerCase();
        sections = sections
            .map(
              (s) => AlbumYearSection(
                title: s.title,
                decadeStart: s.decadeStart,
                year: s.year,
                isUnknownYear: s.isUnknownYear,
                albums: s.albums
                    .where(
                      (a) =>
                          a.name.toLowerCase().contains(q) ||
                          (a.artistName?.toLowerCase().contains(q) ?? false),
                    )
                    .toList(growable: false),
              ),
            )
            .where((s) => s.albums.isNotEmpty)
            .toList(growable: false);
      }
      _ensureYearListCache(sections);
    }

    return Column(
      children: <Widget>[
        _SortFilterRow<_AlbumSort>(
          sortLabel: l10n.libraryAlbumsSortLabel,
          sortValue: _albumSort,
          sortItems: <DropdownMenuItem<_AlbumSort>>[
            DropdownMenuItem(
              value: _AlbumSort.recentlyAdded,
              child: Text(l10n.librarySortRecentlyAdded),
            ),
            DropdownMenuItem(
              value: _AlbumSort.newest,
              child: Text(l10n.librarySortNewest),
            ),
            DropdownMenuItem(
              value: _AlbumSort.name,
              child: Text(l10n.librarySortName),
            ),
            DropdownMenuItem(
              value: _AlbumSort.artist,
              child: Text(l10n.librarySortArtist),
            ),
            DropdownMenuItem(
              value: _AlbumSort.byYear,
              child: Text(l10n.librarySortByYear),
            ),
          ],
          onSortChanged: (value) {
            if (value == null) {
              return;
            }
            setState(() {
              _albumSort = value;
              _cachedAlbums = null;
              _yearListItems = const <_YearListItem>[];
              _cachedYearSectionsSource = null;
            });
          },
          downloadedOnly: _downloadedOnly,
          onDownloadedOnlyChanged: _updateDownloadedOnly,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshLibrary,
            child: _yearListItems.isEmpty && sectionsAsync.asData == null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const <Widget>[
                      _LoadingListPlaceholder(),
                      _LoadingListPlaceholder(),
                      _LoadingListPlaceholder(),
                    ],
                  )
                : _yearListItems.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      EmptyState(
                        title: _typeFilterQuery.isNotEmpty
                            ? l10n.libraryFilterNoResults(_typeFilterQuery)
                            : l10n.libraryAlbumsByYearEmptyTitle,
                        subtitle: _typeFilterQuery.isNotEmpty
                            ? l10n.libraryFilterNoResultsSubtitle
                            : l10n.libraryAlbumsByYearEmptySubtitle,
                        icon: _typeFilterQuery.isNotEmpty
                            ? Icons.search_off_rounded
                            : Icons.calendar_today_outlined,
                        action: _buildClearFiltersAction(),
                      ),
                    ],
                  )
                : Stack(
                    children: <Widget>[
                      ScrollablePositionedList.builder(
                        itemCount: _yearListItems.length,
                        itemScrollController: _yearItemScrollController,
                        itemPositionsListener: _yearItemPositionsListener,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 0, 52, 12),
                        itemBuilder: (context, index) {
                          final item = _yearListItems[index];
                          if (item.isHeader) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                              child: Text(
                                item.isUnknownYear
                                    ? l10n.libraryUnknownYear
                                    : item.label,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            );
                          }
                          // Album pair row.
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Expanded(
                                  child: _buildYearAlbumCard(
                                    context,
                                    item.albums[0],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: item.albums.length > 1
                                      ? _buildYearAlbumCard(
                                          context,
                                          item.albums[1],
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      Positioned(
                        right: 0,
                        top: 8,
                        bottom: 8,
                        child: _SectionRail(
                          railKey: const Key('albumYearRail'),
                          width: 52,
                          labels: _yearDecadeStartIndex.keys.toList(
                            growable: false,
                          ),
                          activeLabel: _activeYearDecade,
                          onLabelSelected: _scrollToYearDecade,
                          onInteractionStart: () {
                            if (_isYearRailScrubbing) {
                              return;
                            }
                            setState(() => _isYearRailScrubbing = true);
                          },
                          onInteractionEnd: () {
                            if (!_isYearRailScrubbing) {
                              return;
                            }
                            setState(() => _isYearRailScrubbing = false);
                          },
                        ),
                      ),
                      if (_isYearRailScrubbing && _activeYearDecade != null)
                        _RailOverlay(
                          overlayKey: const Key('albumYearOverlay'),
                          label: _activeYearDecade!,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildYearAlbumCard(BuildContext context, AlbumsTableData album) {
    final heroTag = buildCoverArtHeroTag(
      coverArtId: album.coverArt,
      context: 'year_album',
      entityId: album.id,
    );
    return RepaintBoundary(
      child: AlbumCard(
        key: ValueKey('year-album-${album.id}'),
        album: album,
        size: AlbumCardSize.library,
        heroTag: heroTag,
        badge: AlbumDownloadBadge(albumId: album.id),
        onTap: () {
          ref
              .read(librarySyncControllerProvider.notifier)
              .registerAlbumInteraction(album.id);
          NavService.openAlbumDetail(context, ref, album.id, heroTag: heroTag);
        },
        onLongPress: () => showAlbumContextMenu(context, ref, album.id),
        onSecondaryTapDown: (details) => showAlbumContextMenu(
          context,
          ref,
          album.id,
          anchor: details.globalPosition,
        ),
      ),
    );
  }

  Widget _buildLikedTab(BuildContext context, {required bool desktopMode}) {
    final l10n = AppLocalizations.of(context)!;
    // Filter the full recent order before deriving a pane-sized preview.
    final likedAlbumsRecentAsync = ref.watch(likedAlbumsRecentProvider);

    final likedAlbumSongsAsync = ref.watch(likedAlbumSongsProvider);
    final likedArtistsAsync = ref.watch(likedArtistsProvider);
    final likedSongsAsync = ref.watch(likedSongsProvider);
    final likedPlaybackSongs = ref.watch(likedPlaybackSongsProvider);
    final downloadedContentIds = _downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;
    final downloadedSongIds = _downloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value
        : null;

    final isLoading =
        likedAlbumsRecentAsync.isLoading ||
        likedAlbumSongsAsync.isLoading ||
        likedArtistsAsync.isLoading ||
        likedSongsAsync.isLoading;
    final albums = _downloadedOnly
        ? (likedAlbumsRecentAsync.asData?.value ?? const <AlbumsTableData>[])
              .where(
                (album) =>
                    downloadedContentIds?.albumIds.contains(album.id) ?? false,
              )
              .toList(growable: false)
        : likedAlbumsRecentAsync.asData?.value ?? const <AlbumsTableData>[];
    final songs = _filterLikedSongs(
      likedSongsAsync.asData?.value ?? const <SongsTableData>[],
      downloadedSongIds: _downloadedOnly ? downloadedSongIds : null,
    );
    final filteredPlaybackSongs = _filterLikedSongs(
      likedPlaybackSongs,
      downloadedSongIds: _downloadedOnly ? downloadedSongIds : null,
      typeFilterQuery: _typeFilterQuery,
    );
    final artists = _downloadedOnly
        ? (likedArtistsAsync.asData?.value ?? const <ArtistsTableData>[])
              .where(
                (artist) =>
                    downloadedContentIds?.artistIds.contains(artist.id) ??
                    false,
              )
              .toList(growable: false)
        : likedArtistsAsync.asData?.value ?? const <ArtistsTableData>[];
    // Apply type-to-filter if active.
    final filteredAlbums = _typeFilterQuery.isEmpty
        ? albums
        : albums
              .where(
                (a) =>
                    a.name.toLowerCase().contains(
                      _typeFilterQuery.toLowerCase(),
                    ) ||
                    (a.artistName?.toLowerCase().contains(
                          _typeFilterQuery.toLowerCase(),
                        ) ??
                        false),
              )
              .toList(growable: false);
    final filteredArtists = _typeFilterQuery.isEmpty
        ? artists
        : artists
              .where(
                (a) => a.name.toLowerCase().contains(
                  _typeFilterQuery.toLowerCase(),
                ),
              )
              .toList(growable: false);
    final filteredSongs = _filterLikedSongs(
      likedSongsAsync.asData?.value ?? const <SongsTableData>[],
      downloadedSongIds: _downloadedOnly ? downloadedSongIds : null,
      typeFilterQuery: _typeFilterQuery,
    );
    final error =
        likedAlbumsRecentAsync.error ??
        likedAlbumSongsAsync.error ??
        likedArtistsAsync.error ??
        likedSongsAsync.error;

    if (error != null && albums.isEmpty && artists.isEmpty && songs.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshLibrary,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            ErrorState(
              title: l10n.libraryAlbumsErrorTitle,
              onRetry: _refreshLibrary,
              retryLabel: l10n.commonRetry,
            ),
          ],
        ),
      );
    }

    if (isLoading && albums.isEmpty && artists.isEmpty && songs.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshLibrary,
        child: ListView(
          controller: _likedScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            _LoadingListPlaceholder(),
            _LoadingListPlaceholder(),
            _LoadingListPlaceholder(),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final padding = ContentLayout.padding(constraints.maxWidth);
          final width = (constraints.maxWidth - padding * 2).clamp(
            0.0,
            double.infinity,
          );
          final gap = ContentLayout.gap(width);
          final compactTitles = width < 600;
          final titleStyle = compactTitles
              ? Theme.of(context).textTheme.titleMedium
              : Theme.of(context).textTheme.titleLarge;
          // Liked sections share one inset; See all buttons carry their own
          // padding, so the end inset is smaller.
          const sectionHeaderPadding = EdgeInsetsDirectional.fromSTEB(
            16,
            8,
            8,
            4,
          );
          final albumExtent = width < 600 ? 128.0 : 148.0;
          final artistExtent = width < 600 ? 56.0 : 64.0;
          final artistWidth = width < 600 ? 80.0 : 88.0;
          final artistPreview = filteredArtists
              .take(ContentLayout.shelfLimit(width, artistWidth))
              .toList(growable: false);
          final albumPreview = filteredAlbums
              .take(ContentLayout.shelfLimit(width, albumExtent))
              .toList(growable: false);
          return CustomScrollView(
            controller: _likedScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              if (filteredAlbums.isEmpty &&
                  filteredArtists.isEmpty &&
                  filteredSongs.isEmpty &&
                  filteredPlaybackSongs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: _typeFilterQuery.isNotEmpty
                        ? l10n.libraryFilterNoResults(_typeFilterQuery)
                        : _downloadedOnly
                        ? l10n.libraryDownloadedOnlyEmpty
                        : l10n.libraryLikedEmptyTitle,
                    subtitle: _typeFilterQuery.isNotEmpty
                        ? l10n.libraryFilterNoResultsSubtitle
                        : _downloadedOnly
                        ? l10n.libraryDownloadedOnlyEmptySubtitle
                        : l10n.libraryLikedEmptySubtitle,
                    icon: _typeFilterQuery.isNotEmpty
                        ? Icons.search_off_rounded
                        : _downloadedOnly
                        ? Icons.download_done_outlined
                        : Icons.favorite_border_outlined,
                    action: _buildClearFiltersAction(),
                  ),
                )
              else ...<Widget>[
                if (filteredArtists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: NavisSectionHeader(
                      title: l10n.libraryLikedArtistsSectionTitle,
                      compact: compactTitles,
                      padding: sectionHeaderPadding,
                      onSeeAll: _openLikedArtistsAll,
                    ),
                  ),
                if (filteredArtists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: padding),
                      child: ContentShelf(
                        key: const ValueKey('liked-artists-shelf'),
                        extent: artistWidth,
                        height:
                            artistTileHeight(context, artistWidth) -
                            artistWidth +
                            artistExtent +
                            8,
                        gap: gap,
                        itemCount: artistPreview.length,
                        itemBuilder: (context, index) {
                          final artist = artistPreview[index];
                          return SizedBox(
                            width: artistWidth,
                            child: _LikedArtistStripTile(
                              artist: artist,
                              artworkExtent: artistExtent,
                              onTap: () => NavService.openArtistDetail(
                                context,
                                ref,
                                artist.id,
                              ),
                              onLongPress: () =>
                                  _showArtistActions(context, artist.id),
                              onSecondaryTapDown: (details) =>
                                  _showArtistActions(
                                    context,
                                    artist.id,
                                    anchor: details.globalPosition,
                                  ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                if (filteredAlbums.isNotEmpty)
                  SliverToBoxAdapter(
                    child: NavisSectionHeader(
                      title: l10n.libraryLikedAlbumsSectionTitle,
                      compact: compactTitles,
                      padding: sectionHeaderPadding,
                      onSeeAll: () => NavService.openLikedAlbums(context, ref),
                    ),
                  ),
                if (filteredAlbums.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
                      child: ContentShelf(
                        key: const ValueKey('liked-albums-shelf'),
                        showNextTooltip: false,
                        extent: albumExtent,
                        height: albumExtent + albumCardExtraHeight(context),
                        gap: gap,
                        itemCount: albumPreview.length,
                        itemBuilder: (context, index) {
                          final album = albumPreview[index];
                          final heroTag = buildCoverArtHeroTag(
                            coverArtId: album.coverArt,
                            context: 'liked_album',
                            entityId: album.id,
                          );
                          return RepaintBoundary(
                            child: AlbumCard(
                              key: ValueKey('liked-album-${album.id}'),
                              album: album,
                              size: AlbumCardSize.compact,
                              extent: albumExtent,
                              heroTag: heroTag,
                              badge: AlbumDownloadBadge(albumId: album.id),
                              onTap: () {
                                ref
                                    .read(
                                      librarySyncControllerProvider.notifier,
                                    )
                                    .registerAlbumInteraction(album.id);
                                NavService.openAlbumDetail(
                                  context,
                                  ref,
                                  album.id,
                                  heroTag: heroTag,
                                );
                              },
                              onLongPress: () =>
                                  showAlbumContextMenu(context, ref, album.id),
                              onSecondaryTapDown: (details) =>
                                  showAlbumContextMenu(
                                    context,
                                    ref,
                                    album.id,
                                    anchor: details.globalPosition,
                                  ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                if (filteredSongs.isNotEmpty ||
                    filteredPlaybackSongs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        16,
                        12,
                        16,
                        8,
                      ),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              l10n.libraryLikedSongsSectionTitle,
                              style: titleStyle,
                            ),
                          ),
                          if (filteredPlaybackSongs.isNotEmpty)
                            EntityActionBar(
                              compact: width < 600,
                              onPlay: () => unawaited(
                                _queueLikedSongs(filteredPlaybackSongs),
                              ),
                              onShuffle: () => unawaited(
                                _queueLikedSongs(
                                  filteredPlaybackSongs,
                                  shuffle: true,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (filteredSongs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: AdaptiveTrackHeader(
                      actionExtent: desktopMode ? null : 96,
                    ),
                  ),
                if (filteredSongs.isNotEmpty)
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final song = filteredSongs[index];
                      return TrackListTile(
                        song: song,
                        showAlbumArt: true,
                        actionExtent: desktopMode ? null : 96,
                        trailing: desktopMode
                            ? DesktopSongActions(
                                song: song,
                                keyPrefix: 'liked-song',
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: SongDownloadStatusIcon(
                                      songId: song.id,
                                      onDownload: () =>
                                          unawaited(_downloadLikedSong(song)),
                                    ),
                                  ),
                                  Builder(
                                    builder: (buttonContext) => IconButton(
                                      tooltip: MaterialLocalizations.of(
                                        buttonContext,
                                      ).showMenuTooltip,
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: () => showSongContextMenu(
                                        this.context,
                                        ref,
                                        song,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                        onTap: () {
                          _handleLikedSongTap(
                            song,
                            playbackSongs: filteredPlaybackSongs,
                          );
                        },
                        onLongPress: () =>
                            showSongContextMenu(this.context, ref, song),
                      );
                    }, childCount: filteredSongs.length),
                  ),
                _UnavailableReviewSliver(),
              ],
            ],
          );
        },
      ),
    );
  }

  void _handleLikedSongTap(
    SongsTableData song, {
    required List<SongsTableData> playbackSongs,
  }) {
    if (shouldQueueLikedPlayback(
      albumQueueEnabled: ref.read(albumQueueEnabledProvider),
      likedQueueEnabled: ref.read(likedQueueEnabledProvider),
      eligibleSongCount: playbackSongs.length,
    )) {
      final startIndex = playbackSongs.indexWhere(
        (candidate) => candidate.id == song.id,
      );
      ref
          .read(queueProvider.notifier)
          .replaceWithTableData(
            playbackSongs,
            startIndex: startIndex < 0 ? 0 : startIndex,
            autoPlay: true,
          )
          .ignore();
      return;
    }

    ref.read(queueProvider.notifier).replaceWithTableData(<SongsTableData>[
      song,
    ], autoPlay: true).ignore();
  }

  /// "See all" opens the liked artists page, like liked albums does.
  void _openLikedArtistsAll() {
    NavService.openLikedArtists(context, ref);
  }

  Future<void> _downloadLikedSong(SongsTableData song) async {
    final choice = await requestDownloadQuality(context, ref);
    if (choice == null || !mounted) return;
    final service = ref.read(downloadServiceProvider);
    unawaited(
      service.enqueueSong(
        song.id,
        quality: choice.quality,
        format: choice.format,
      ),
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppNotice(
      context,
      message: downloadQueuedNotice(l10n, l10n.downloadSongQueued, choice),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _queueLikedSongs(
    List<SongsTableData> songs, {
    bool shuffle = false,
  }) async {
    if (songs.isEmpty) {
      return;
    }
    final songsToQueue = List<SongsTableData>.of(songs);
    if (shuffle) {
      songsToQueue.shuffle();
    }
    try {
      await ref
          .read(queueProvider.notifier)
          .replaceWithTableData(
            songsToQueue,
            autoPlay: true,
            originalOrder: shuffle
                ? songs.map((song) => song.id).toList()
                : null,
          );
    } on Object {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.playbackActionFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  void _onAlbumsScroll() {
    if (_albumSort == _AlbumSort.byYear ||
        _downloadedOnly ||
        _typeFilterQuery.isNotEmpty ||
        !_albumsScrollController.hasClients) {
      return;
    }
    final metrics = _albumsScrollController.position;
    if (!metrics.hasContentDimensions ||
        metrics.extentAfter >= metrics.viewportDimension) {
      return;
    }
    final sort = _toAlbumSortOrder(_albumSort);
    final pageSize = ref.read(albumPageSizeProvider);
    final current = ref.read(
      pagedAlbumsProvider((sort: sort, limit: pageSize * _loadedAlbumPages)),
    );
    final items = current.asData?.value;
    final total = ref.read(albumCountProvider).asData?.value;
    // A partial or failed response must not spin through additional page keys.
    if (current.isLoading ||
        current.hasError ||
        items == null ||
        total == null ||
        items.length < pageSize * _loadedAlbumPages ||
        items.length >= total) {
      return;
    }
    setState(() => _loadedAlbumPages += 1);
  }

  void _reportVisibleAlbumPriority(List<AlbumsTableData> albums) {
    if (_albumSort == _AlbumSort.byYear) {
      return;
    }
    if (albums.isEmpty) {
      return;
    }
    final ids = albums
        .take(24)
        .map((album) => album.id)
        .where((id) => id.trim().isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    final signature = ids.join('|');
    if (signature == _lastVisibleAlbumSignature) {
      return;
    }
    _lastVisibleAlbumSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(librarySyncControllerProvider.notifier).setVisibleAlbumIds(ids);
    });
  }

  AlbumSortOrder _toAlbumSortOrder(_AlbumSort sort) {
    return switch (sort) {
      _AlbumSort.recentlyAdded => AlbumSortOrder.recentlyAdded,
      _AlbumSort.newest => AlbumSortOrder.newest,
      _AlbumSort.name => AlbumSortOrder.name,
      _AlbumSort.artist => AlbumSortOrder.artist,
      _AlbumSort.byYear => AlbumSortOrder.newest,
    };
  }

  List<AlbumsTableData> _filterDownloadedAlbums(List<AlbumsTableData> albums) {
    final contentIds = ref.read(downloadedContentIdsProvider).asData?.value;
    if (contentIds == null) return const [];
    return albums
        .where((album) => contentIds.albumIds.contains(album.id))
        .toList();
  }

  List<ArtistsTableData> _filterDownloadedArtists(
    List<ArtistsTableData> artists,
  ) {
    final contentIds = ref.read(downloadedContentIdsProvider).asData?.value;
    if (contentIds == null) return const [];
    return artists
        .where((artist) => contentIds.artistIds.contains(artist.id))
        .toList();
  }

  Map<String, List<ArtistsTableData>> _groupArtistsByInitial(
    List<ArtistsTableData> artists,
  ) {
    final grouped = <String, List<ArtistsTableData>>{};
    for (final artist in artists) {
      final first = artist.name.isEmpty ? '#' : artist.name.substring(0, 1);
      final initial = RegExp('[A-Za-z]').hasMatch(first.toUpperCase())
          ? first.toUpperCase()
          : '#';
      grouped.putIfAbsent(initial, () => <ArtistsTableData>[]).add(artist);
    }
    for (final entry in grouped.entries) {
      entry.value.sort((a, b) => a.name.compareTo(b.name));
    }
    return grouped;
  }

  List<_ArtistListItem> _buildArtistListItems(
    Map<String, List<ArtistsTableData>> grouped,
    List<String> letters,
  ) {
    final items = <_ArtistListItem>[];
    for (final letter in letters) {
      items.add(_ArtistListItem.header(letter));
      for (final artist in grouped[letter] ?? const <ArtistsTableData>[]) {
        items.add(_ArtistListItem.artist(letter, artist));
      }
    }
    return items;
  }

  Map<String, int> _buildArtistLetterStartIndex(List<_ArtistListItem> items) {
    final indexByLetter = <String, int>{};
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.artist == null) {
        indexByLetter[item.letter] ??= i;
      }
    }
    return indexByLetter;
  }

  Widget _buildArtistsGrid(
    BuildContext context,
    List<ArtistsTableData> artists,
  ) {
    final grouped = _groupArtistsByInitial(artists);
    final letters = grouped.keys.toList(growable: false)..sort();
    _artistGridSectionKeys = <String, GlobalKey>{
      for (final letter in letters)
        letter: _artistGridSectionKeys[letter] ?? GlobalKey(),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomScrollView(
          controller: _artistsGridScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            for (final letter in letters) ...<Widget>[
              SliverToBoxAdapter(
                key: _artistGridSectionKeys[letter],
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Text(
                    letter,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              ResponsiveContentSliverGrid(
                itemCount: grouped[letter]?.length ?? 0,
                artists: true,
                trailingInset: 28,
                itemBuilder: (context, index) {
                  final byLetter =
                      grouped[letter] ?? const <ArtistsTableData>[];
                  final artist = byLetter[index];
                  return RepaintBoundary(
                    child: ArtistGridCard(
                      key: ValueKey(artist.id),
                      artist: artist,
                      onTap: () =>
                          NavService.openArtistDetail(context, ref, artist.id),
                      onLongPress: () => _showArtistActions(context, artist.id),
                      onSecondaryTapDown: (details) => _showArtistActions(
                        context,
                        artist.id,
                        anchor: details.globalPosition,
                      ),
                    ),
                  );
                },
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 72)),
          ],
        );
      },
    );
  }

  void _onArtistsGridScrolled() {
    if (!_artistsGridScrollController.hasClients || _isArtistRailScrubbing) {
      return;
    }
    final entries = _artistGridSectionKeys.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) {
      return;
    }

    String? nextActive;
    for (final entry in entries) {
      final context = entry.value.currentContext;
      if (context == null) {
        continue;
      }
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        continue;
      }
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= 140) {
        nextActive = entry.key;
      }
    }
    nextActive ??= entries.first.key;

    if (nextActive != _activeArtistLetter && mounted) {
      setState(() => _activeArtistLetter = nextActive);
    }
  }

  void _ensureArtistListCache(List<ArtistsTableData> artists) {
    if (identical(_cachedArtists, artists) && _artistListItems.isNotEmpty) {
      return;
    }
    final grouped = _groupArtistsByInitial(artists);
    final letters = grouped.keys.toList(growable: false)..sort();
    _artistListItems = _buildArtistListItems(grouped, letters);
    _artistLetterStartIndex = _buildArtistLetterStartIndex(_artistListItems);
    if (_artistLetterStartIndex.isEmpty) {
      _activeArtistLetter = null;
    } else if (_activeArtistLetter == null ||
        !_artistLetterStartIndex.containsKey(_activeArtistLetter)) {
      _activeArtistLetter = _artistLetterStartIndex.keys.first;
    }
    _cachedArtists = artists;
  }

  void _onArtistsViewportChanged() {
    if (_artistListItems.isEmpty || _isArtistRailScrubbing) {
      return;
    }
    final positions = _artistsItemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return;
    }
    final visible = positions
        .where(
          (position) =>
              position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
        )
        .toList(growable: false);
    if (visible.isEmpty) {
      return;
    }
    final candidates = visible
        .where((position) => position.itemLeadingEdge >= 0)
        .toList(growable: false);
    final targetSet = candidates.isEmpty ? visible : candidates;
    targetSet.sort((a, b) {
      final byEdge = a.itemLeadingEdge.compareTo(b.itemLeadingEdge);
      if (byEdge != 0) {
        return byEdge;
      }
      return a.index.compareTo(b.index);
    });
    final topIndex = targetSet.first.index.clamp(
      0,
      _artistListItems.length - 1,
    );
    final topLetter = _artistListItems[topIndex].letter;
    if (topLetter == _activeArtistLetter || !mounted) {
      return;
    }
    setState(() => _activeArtistLetter = topLetter);
  }

  void _ensureYearListCache(List<AlbumYearSection> sections) {
    if (identical(_cachedYearSectionsSource, sections) &&
        _yearListItems.isNotEmpty) {
      return;
    }
    _cachedYearSectionsSource = sections;
    final items = <_YearListItem>[];
    final decadeIndex = <String, int>{};
    for (final section in sections) {
      final headerIndex = items.length;
      items.add(
        _YearListItem.header(
          label: section.title,
          isUnknownYear: section.isUnknownYear,
          decadeStart: section.decadeStart,
        ),
      );
      if (section.decadeStart != null) {
        final key = '${section.decadeStart}s';
        decadeIndex.putIfAbsent(key, () => headerIndex);
      }
      for (var i = 0; i < section.albums.length; i += 2) {
        final left = section.albums[i];
        final right = (i + 1 < section.albums.length)
            ? section.albums[i + 1]
            : null;
        items.add(_YearListItem.albumRow(left, right));
      }
    }
    _yearListItems = items;
    _yearDecadeStartIndex = decadeIndex;
    if (_yearDecadeStartIndex.isEmpty) {
      _activeYearDecade = null;
    } else if (_activeYearDecade == null ||
        !_yearDecadeStartIndex.containsKey(_activeYearDecade)) {
      _activeYearDecade = _yearDecadeStartIndex.keys.first;
    }
  }

  void _onYearViewportChanged() {
    if (_yearListItems.isEmpty || _isYearRailScrubbing) {
      return;
    }
    final positions = _yearItemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return;
    }
    final visible = positions
        .where(
          (position) =>
              position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
        )
        .toList(growable: false);
    if (visible.isEmpty) {
      return;
    }
    final candidates = visible
        .where((position) => position.itemLeadingEdge >= 0)
        .toList(growable: false);
    final targetSet = candidates.isEmpty ? visible : candidates;
    targetSet.sort((a, b) {
      final byEdge = a.itemLeadingEdge.compareTo(b.itemLeadingEdge);
      if (byEdge != 0) {
        return byEdge;
      }
      return a.index.compareTo(b.index);
    });
    final topIndex = targetSet.first.index.clamp(0, _yearListItems.length - 1);
    // Walk back through the flat list to find the nearest section header.
    String? label;
    for (var i = topIndex; i >= 0; i--) {
      final item = _yearListItems[i];
      if (item.isHeader && item.decadeStart != null) {
        label = '${item.decadeStart}s';
        break;
      }
    }
    if (label == null || label == _activeYearDecade || !mounted) {
      return;
    }
    setState(() => _activeYearDecade = label);
  }

  void _scrollToArtistLetter(String letter, {required bool animate}) {
    if (_activeArtistLetter == letter) {
      return;
    }
    if (mounted) {
      setState(() => _activeArtistLetter = letter);
    }
    final isGridMode = ref.read(artistViewModeProvider) == 'grid';
    if (isGridMode) {
      final targetContext = _artistGridSectionKeys[letter]?.currentContext;
      if (targetContext == null) {
        return;
      }

      Scrollable.ensureVisible(
        targetContext,
        duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
        curve: Curves.easeOut,
        alignment: 0,
      );
      return;
    }

    final sectionIndex = _artistLetterStartIndex[letter];
    if (sectionIndex == null || !_artistsItemScrollController.isAttached) {
      return;
    }
    if (animate) {
      unawaited(
        _artistsItemScrollController.scrollTo(
          index: sectionIndex,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    _artistsItemScrollController.jumpTo(index: sectionIndex);
  }

  void _scrollToYearDecade(String label, {required bool animate}) {
    if (_activeYearDecade != label) {
      setState(() => _activeYearDecade = label);
    }
    final sectionIndex = _yearDecadeStartIndex[label];
    if (sectionIndex == null || !_yearItemScrollController.isAttached) {
      return;
    }
    if (animate) {
      unawaited(
        _yearItemScrollController.scrollTo(
          index: sectionIndex,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    _yearItemScrollController.jumpTo(index: sectionIndex);
  }

  Future<void> _toggleArtistStar(ArtistsTableData artist) =>
      _saveStarred(artist.id, 'artist', artist.starred == null);

  Future<void> _saveStarred(String id, String type, bool liked) async {
    try {
      await ref
          .read(navisDatabaseProvider)
          .starSyncDao
          .setStarred(itemId: id, itemType: type, liked: liked);
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.albumDetailStarFailure,
        level: AppNoticeLevel.error,
      );
    }
  }

  void _showArtistActions(
    BuildContext context,
    String artistId, {
    Offset? anchor,
  }) {
    unawaited(showArtistContextMenu(context, ref, artistId, anchor: anchor));
  }
}

/// Liked-tab entry to the unavailable-items review list, shown only when at
/// least one item is awaiting review.
class _UnavailableReviewSliver extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingCount = ref
        .watch(pendingUnavailableCountProvider)
        .asData
        ?.value;
    if (pendingCount == null || pendingCount == 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final l10n = AppLocalizations.of(context)!;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: ActionChip(
          avatar: const Icon(Icons.playlist_remove),
          label: Text(l10n.unavailableReviewEntryWithCount(pendingCount)),
          onPressed: () => NavService.openUnavailableItems(context, ref),
        ),
      ),
    );
  }
}
