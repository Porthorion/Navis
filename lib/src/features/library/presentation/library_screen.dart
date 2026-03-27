import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/artist_grid_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
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
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_browse_models.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show quickSearchOverlayVisibleProvider;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

enum _AlbumSort { recentlyAdded, newest, name, artist, byYear }

/// Computes the effective album grid column count.
///
/// When [densityOverride] is non-null, returns that value clamped to [1, 5].
/// Otherwise, auto-computes from [availableWidth] as `floor(width / 180)`
/// clamped to [1, 5].
int computeGridCrossAxisCount(int? densityOverride, double availableWidth) {
  if (densityOverride != null) {
    return densityOverride.clamp(1, 5);
  }
  return (availableWidth / 180).floor().clamp(1, 5);
}

/// Computes artist grid columns for circular cards.
///
/// Artist tiles must stay denser than album tiles so the view never degrades
/// to one oversized card per row on phones.
int computeArtistGridCrossAxisCount(double availableWidth) {
  final usableWidth = availableWidth - 52; // matches grid horizontal padding
  return (usableWidth / 150).floor().clamp(2, 6);
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

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
    HardwareKeyboard.instance.addHandler(_onLibraryKeyEvent);
  }

  @override
  void dispose() {
    _libraryScrollSubscription.close();
    _downloadedOnlySubscription.close();
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

  Future<void> _refreshLibrary() {
    return ref
        .read(librarySyncControllerProvider.notifier)
        .syncNow(preferIncremental: true);
  }

  void _updateDownloadedOnly(bool value) {
    if (ref.read(downloadedOnlyFilterProvider) == value) {
      return;
    }
    ref.read(downloadedOnlyFilterProvider.notifier).enabled = value;
  }

  // ---------------------------------------------------------------------------
  // Type-to-filter — keyboard handler & state helpers
  // ---------------------------------------------------------------------------

  bool _onLibraryKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // Don't intercept when the quick-search overlay is visible.
    if (ref.read(quickSearchOverlayVisibleProvider)) return false;
    // Only when library root is the active screen (not inside album/artist detail)
    final nav = Navigator.maybeOf(context, rootNavigator: false);
    if (nav != null && nav.canPop()) return false;
    // Don't intercept modifier combos (shortcuts)
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) return false;
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
    _typeFilterFadeTimer = Timer(
      const Duration(milliseconds: 900),
      () {
        if (mounted) {
          setState(() => _typeFilterOverlayVisible = false);
          ref.read(libraryTypeFilterActiveProvider.notifier).active = false;
        }
      },
    );
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

    unawaited(
      controller.animateTo(
        position.minScrollExtent,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Scrolls whichever tab is currently selected back to the top.
  void _scrollCurrentTabToTop() {
    final tab = _tabController?.index ?? 0;

    if (tab == 0) {
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
    }

    var offset = 1;

    if (ref.read(showLikedPageProvider)) {
      if (tab == offset) {
        _animateScrollControllerToTop(_likedScrollController);
        return;
      }
      offset++;
    }

    if (ref.read(showArtistsPageProvider)) {
      if (tab == offset) {
        // Artists
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
      }
      offset++;
    }

    if (ref.read(showPlaylistsPageProvider)) {
      if (tab == offset) {
        // Playlists
        _animateScrollControllerToTop(_playlistsScrollController);
        return;
      }
      offset++;
    }

    if (ref.read(showRadioPageProvider)) {
      if (tab == offset) {
        // Radio
        _animateScrollControllerToTop(_radioScrollController);
      }
    }
  }

  int _tabIndexForSection(
    LibrarySection section, {
    required bool showLikedTab,
    required bool showArtistsTab,
    required bool showPlaylistsTab,
    required bool showRadioTab,
  }) {
    var index = 0;
    if (section == LibrarySection.albums) {
      return index;
    }
    if (showLikedTab) {
      index++;
      if (section == LibrarySection.liked) {
        return index;
      }
    }
    if (showArtistsTab) {
      index++;
      if (section == LibrarySection.artists) {
        return index;
      }
    }
    if (showPlaylistsTab) {
      index++;
      if (section == LibrarySection.playlists) {
        return index;
      }
    }
    if (showRadioTab) {
      index++;
      if (section == LibrarySection.radio) {
        return index;
      }
    }
    return 0;
  }

  LibrarySection _sectionForTabIndex(
    int tabIndex, {
    required bool showLikedTab,
    required bool showArtistsTab,
    required bool showPlaylistsTab,
    required bool showRadioTab,
  }) {
    var cursor = 0;
    if (tabIndex == cursor) {
      return LibrarySection.albums;
    }
    if (showLikedTab) {
      cursor++;
      if (tabIndex == cursor) {
        return LibrarySection.liked;
      }
    }
    if (showArtistsTab) {
      cursor++;
      if (tabIndex == cursor) {
        return LibrarySection.artists;
      }
    }
    if (showPlaylistsTab) {
      cursor++;
      if (tabIndex == cursor) {
        return LibrarySection.playlists;
      }
    }
    if (showRadioTab) {
      cursor++;
      if (tabIndex == cursor) {
        return LibrarySection.radio;
      }
    }
    return LibrarySection.albums;
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
    final section = _sectionForTabIndex(
      controller.index,
      showLikedTab: ref.read(showLikedPageProvider),
      showArtistsTab: ref.read(showArtistsPageProvider),
      showPlaylistsTab: ref.read(showPlaylistsPageProvider),
      showRadioTab: ref.read(showRadioPageProvider),
    );
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final syncState = ref.watch(librarySyncControllerProvider);
    final showRadioTab = ref.watch(showRadioPageProvider);
    final showArtistsTab = ref.watch(showArtistsPageProvider);
    final showPlaylistsTab = ref.watch(showPlaylistsPageProvider);
    final showLikedTab = ref.watch(showLikedPageProvider);
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final tabCount =
        1 +
        (showLikedTab ? 1 : 0) +
        (showArtistsTab ? 1 : 0) +
        (showPlaylistsTab ? 1 : 0) +
        (showRadioTab ? 1 : 0);
    final desktopMode = adaptiveContext.useDesktopShell;
    final hasActivePlayback = ref.watch(
      playerStateProvider.select((state) => state.hasActivePlayback),
    );
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final viewport = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final isPhoneFormFactor = adaptiveContext.isPhoneFormFactor;
    const navTileEstimatedHeight = 64.0;
    const subNavTileEstimatedHeight = 44.0;
    const subNavTrailingGap = 6.0;
    const reservedMiniPlayerHeight = 170.0;
    const railMiniPlayerGap = 6.0;
    const railCutoffSlack = 4.0;
    final librarySubSectionCount =
        1 +
        (showLikedTab ? 1 : 0) +
        (showArtistsTab ? 1 : 0) +
        (showPlaylistsTab ? 1 : 0) +
        (showRadioTab ? 1 : 0);
    final inlineLibraryNavHeight =
        (4 * navTileEstimatedHeight) +
        (librarySubSectionCount * subNavTileEstimatedHeight) +
        subNavTrailingGap;
    final railHeightNeededForInlineLibrary =
        reservedMiniPlayerHeight +
        railMiniPlayerGap +
        inlineLibraryNavHeight +
        railCutoffSlack;
    // Mirrors the rail-side vertical budget in AppShell:
    // SafeArea + outer rail paddings consume ~44px before sidebar content.
    final estimatedRailHeight = viewport.height - safePadding.vertical - 44.0;
    final selectedSection = ref.watch(librarySectionProvider);
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final tabletMode =
        !desktopMode && adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    // On desktop the sidebar always shows library sub-navigation
    // (AppShell's showLibrarySubNavigation == useDesktopShell || useRailNavigation),
    // so the in-page TabBar must be suppressed for either condition.
    final baseWideLibraryNavigation =
        !isPhoneFormFactor &&
        (adaptiveContext.useRailNavigation || desktopMode);
    final forceTabbedLibraryNavigation =
        // On desktop, the sidebar always handles library section navigation —
        // never fall back to the in-page TabBar, which would duplicate it.
        !desktopMode &&
        (compactWideLandscapeMode ||
            (baseWideLibraryNavigation &&
                hasActivePlayback &&
                estimatedRailHeight < railHeightNeededForInlineLibrary));
    final useWideLibraryNavigation =
        baseWideLibraryNavigation && !forceTabbedLibraryNavigation;
    final tabController = _ensureTabController(tabCount);
    final desiredTabIndex = _tabIndexForSection(
      selectedSection,
      showLikedTab: showLikedTab,
      showArtistsTab: showArtistsTab,
      showPlaylistsTab: showPlaylistsTab,
      showRadioTab: showRadioTab,
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
      showLikedTab: showLikedTab,
      showArtistsTab: showArtistsTab,
      showPlaylistsTab: showPlaylistsTab,
      showRadioTab: showRadioTab,
    );
    if (selectedSection != activeSection) {
      _scheduleSectionSync(activeSection);
    }
    final wideHeaderTitle =
        '${l10n.libraryTitle} - ${_sectionTitle(l10n, activeSection)}';
    final tabLabels = <String>[
      l10n.libraryTabAlbums,
      if (showLikedTab) l10n.libraryTabLiked,
      if (showArtistsTab) l10n.libraryTabArtists,
      if (showPlaylistsTab) l10n.navPlaylists,
      if (showRadioTab) l10n.navRadio,
    ];
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
        Tab(text: l10n.libraryTabAlbums),
        if (showLikedTab) Tab(text: l10n.libraryTabLiked),
        if (showArtistsTab) Tab(text: l10n.libraryTabArtists),
        if (showPlaylistsTab) Tab(text: l10n.navPlaylists),
        if (showRadioTab) Tab(text: l10n.navRadio),
      ],
    );
    final bodyContent = Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            _SyncStatusBanner(
              syncState: syncState,
              onRetry: _refreshLibrary,
              onCancel: () {
                ref.read(librarySyncControllerProvider.notifier).cancelSync();
              },
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
                  _buildAlbumsTab(context),
                  if (showLikedTab)
                    _buildLikedTab(context, desktopMode: desktopMode),
                  if (showArtistsTab) _buildArtistsTab(context),
                  if (showPlaylistsTab)
                    _LibraryPlaylistsTab(
                      scrollController: _playlistsScrollController,
                    ),
                  if (showRadioTab)
                    RadioTabContent(
                      scrollController: _radioScrollController,
                      typeFilterQuery: _typeFilterQuery,
                    ),
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
                        style: Theme.of(context)
                            .textTheme
                            .displayLarge
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

    if (desktopMode && !useWideLibraryNavigation) {
      return Scaffold(
        body: SafeArea(
          child: DesktopFrame(
            layoutClass: resolveDesktopLayoutClass(
              MediaQuery.sizeOf(context).width,
            ),
            child: Column(
              children: <Widget>[
                DesktopPanel(child: tabBar),
                const SizedBox(height: 12),
                Expanded(
                  child: DesktopPanel(
                    padding: EdgeInsets.zero,
                    child: bodyContent,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (useWideLibraryNavigation) {
      if (desktopMode) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DesktopPanel(
                  padding: EdgeInsets.zero,
                  child: bodyContent,
                ),
              ),
            ),
          ),
        );
      }
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
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
      final maxWidth = adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded
          ? 1080.0
          : 920.0;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.libraryTitle),
          bottom: tabBar,
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: bodyContent,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.libraryTitle),
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
                icon: Icon(
                  isGridMode ? Icons.view_list : Icons.grid_view,
                ),
                tooltip: isGridMode
                    ? l10n.libraryTabArtists
                    : l10n.libraryTabArtists,
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
                            (a) => a.name
                                .toLowerCase()
                                .contains(_typeFilterQuery.toLowerCase()),
                          )
                          .toList(growable: false);
                if (typeFiltered.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      EmptyState(
                        title: _typeFilterQuery.isNotEmpty
                            ? 'No results for "$_typeFilterQuery"'
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
                            onTap: () =>
                                context.go('/library/artists/${artist.id}'),
                            onLongPress: () => _showArtistMenu(context, artist),
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
                    message: error.toString(),
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
                message: error.toString(),
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
              : filteredItems.where((album) {
                  final q = _typeFilterQuery.toLowerCase();
                  return album.name.toLowerCase().contains(q) ||
                      (album.artistName?.toLowerCase().contains(q) ?? false);
                }).toList(growable: false);
          _reportVisibleAlbumPriority(typeFiltered);
          final totalAlbums =
              _downloadedOnly || _typeFilterQuery.isNotEmpty
                  ? typeFiltered.length
                  : (totalAlbumsAsync.asData?.value ?? items.length);
          final hasMore = !_downloadedOnly &&
              _typeFilterQuery.isEmpty &&
              items.length < totalAlbums;
          return LayoutBuilder(
            builder: (context, constraints) {
              final gridWidth = (constraints.maxWidth - 24).clamp(
                240.0,
                2400.0,
              );
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
                              ? 'No results for "$_typeFilterQuery"'
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
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: computeGridCrossAxisCount(
                                  ref.watch(albumGridDensityProvider),
                                  gridWidth,
                                ),
                                childAspectRatio: 1,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final album = typeFiltered[index];
                            return RepaintBoundary(
                              child: AlbumCard(
                                key: ValueKey(album.id),
                                album: album,
                                size: AlbumCardSize.library,
                                heroTag: buildCoverArtHeroTag(
                                  coverArtId: album.coverArt,
                                  context: 'album',
                                  entityId: album.id,
                                ),
                                badge: AlbumDownloadBadge(albumId: album.id),
                                onTap: () {
                                  ref
                                      .read(
                                        librarySyncControllerProvider.notifier,
                                      )
                                      .registerAlbumInteraction(album.id);
                                  context.push('/library/albums/${album.id}');
                                },
                                onLongPress: () => showAlbumContextMenu(
                                  context,
                                  ref,
                                  album.id,
                                ),
                                onSecondaryTapDown: (details) =>
                                    showAlbumContextMenu(
                                      context,
                                      ref,
                                      album.id,
                                      anchor: details.globalPosition,
                                    ),
                              ),
                            );
                          }, childCount: typeFiltered.length),
                        ),
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
      albumYearSectionsProvider(
        (likedOnly: false, downloadedOnly: _downloadedOnly),
      ),
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
                            ? 'No results for "$_typeFilterQuery"'
                            : l10n.libraryAlbumsByYearEmptyTitle,
                        subtitle: _typeFilterQuery.isNotEmpty
                            ? 'Try a different search'
                            : l10n.libraryAlbumsByYearEmptySubtitle,
                        icon: _typeFilterQuery.isNotEmpty
                            ? Icons.search_off_rounded
                            : Icons.calendar_today_outlined,
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
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: _buildYearAlbumCard(
                                      context,
                                      item.albums[0],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: item.albums.length > 1
                                      ? AspectRatio(
                                          aspectRatio: 1,
                                          child: _buildYearAlbumCard(
                                            context,
                                            item.albums[1],
                                          ),
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
    return RepaintBoundary(
      child: AlbumCard(
        key: ValueKey('year-album-${album.id}'),
        album: album,
        size: AlbumCardSize.library,
        heroTag: buildCoverArtHeroTag(
          coverArtId: album.coverArt,
          context: 'year_album',
        ),
        badge: AlbumDownloadBadge(albumId: album.id),
        onTap: () {
          ref
              .read(librarySyncControllerProvider.notifier)
              .registerAlbumInteraction(album.id);
          context.push('/library/albums/${album.id}');
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
    // Recent 6 liked albums (ordered by starred desc) for the capped grid.
    final likedAlbumsRecentAsync = ref.watch(likedAlbumsRecentProvider);
    // Full list used only for the total count; data is not rendered directly.
    final likedAlbumsAllAsync = ref.watch(likedAlbumsProvider);
    final likedArtistsAsync = ref.watch(likedArtistsProvider);
    final likedSongsAsync = ref.watch(likedSongsProvider);
    final downloadedContentIds = _downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;
    final downloadedSongIds = _downloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value
        : null;

    final isLoading =
        likedAlbumsRecentAsync.isLoading ||
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
    final totalAlbumCount = _downloadedOnly
        ? (likedAlbumsAllAsync.asData?.value ?? const <AlbumsTableData>[])
              .where(
                (album) =>
                    downloadedContentIds?.albumIds.contains(album.id) ?? false,
              )
              .length
        : likedAlbumsAllAsync.asData?.value.length ?? albums.length;
    final songs = _downloadedOnly
        ? (likedSongsAsync.asData?.value ?? const <SongsTableData>[])
              .where((song) => downloadedSongIds?.contains(song.id) ?? false)
              .toList(growable: false)
        : likedSongsAsync.asData?.value ?? const <SongsTableData>[];
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
    final queryLower = _typeFilterQuery.toLowerCase();
    final filteredAlbums = _typeFilterQuery.isEmpty
        ? albums
        : albums
              .where(
                (a) =>
                    a.name.toLowerCase().contains(queryLower) ||
                    (a.artistName?.toLowerCase().contains(queryLower) ?? false),
              )
              .toList(growable: false);
    final filteredArtists = _typeFilterQuery.isEmpty
        ? artists
        : artists
              .where((a) => a.name.toLowerCase().contains(queryLower))
              .toList(growable: false);
    final filteredSongs = _typeFilterQuery.isEmpty
        ? songs
        : songs
              .where(
                (s) =>
                    s.title.toLowerCase().contains(queryLower) ||
                    (s.artistName?.toLowerCase().contains(queryLower) ??
                        false) ||
                    (s.albumName?.toLowerCase().contains(queryLower) ?? false),
              )
              .toList(growable: false);
    const likedArtistsPreviewLimit = 14;
    final artistPreview = filteredArtists
        .take(likedArtistsPreviewLimit)
        .toList(growable: false);
    final hasMoreLikedArtists = filteredArtists.length > artistPreview.length;
    final error =
        likedAlbumsRecentAsync.error ??
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
              message: error.toString(),
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
          final gridWidth = (constraints.maxWidth - 24).clamp(240.0, 2400.0);
          return CustomScrollView(
            controller: _likedScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              if (filteredAlbums.isEmpty && filteredArtists.isEmpty && filteredSongs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: _typeFilterQuery.isNotEmpty
                        ? 'No results for "$_typeFilterQuery"'
                        : _downloadedOnly
                            ? l10n.libraryDownloadedOnlyEmpty
                            : l10n.libraryLikedEmptyTitle,
                    subtitle: _typeFilterQuery.isNotEmpty
                        ? 'Try a different search'
                        : _downloadedOnly
                            ? l10n.libraryDownloadedOnlyEmptySubtitle
                            : l10n.libraryLikedEmptySubtitle,
                    icon: _typeFilterQuery.isNotEmpty
                        ? Icons.search_off_rounded
                        : _downloadedOnly
                            ? Icons.download_done_outlined
                            : Icons.favorite_border_outlined,
                  ),
                )
              else ...<Widget>[
                if (filteredArtists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${l10n.libraryLikedOnlyFilter} ${l10n.libraryTabArtists}',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          if (hasMoreLikedArtists)
                            TextButton(
                              onPressed: _openLikedArtistsAll,
                              child: Text(l10n.libraryLikedAlbumsSeeAll),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (filteredArtists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 118,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        itemCount: artistPreview.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final artist = artistPreview[index];
                          return SizedBox(
                            width: 88,
                            child: _LikedArtistStripTile(
                              artist: artist,
                              onTap: () =>
                                  context.go('/library/artists/${artist.id}'),
                              onLongPress: () =>
                                  _showArtistMenu(context, artist),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                if (filteredSongs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: () => unawaited(_queueLikedSongs(filteredSongs)),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(l10n.albumDetailPlayAction),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => unawaited(
                              _queueLikedSongs(filteredSongs, shuffle: true),
                            ),
                            icon: const Icon(Icons.shuffle_rounded),
                            label: Text(l10n.albumDetailShuffleAction),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (filteredAlbums.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              l10n.libraryLikedAlbumsSectionTitle,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          if (totalAlbumCount > 6)
                            TextButton(
                              onPressed: () =>
                                  context.push('/library/liked-albums'),
                              child: Text(l10n.libraryLikedAlbumsSeeAll),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (filteredAlbums.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: computeGridCrossAxisCount(
                          ref.watch(albumGridDensityProvider),
                          gridWidth,
                        ),
                        childAspectRatio: 1,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final album = filteredAlbums[index];
                        return RepaintBoundary(
                          child: AlbumCard(
                            key: ValueKey('liked-album-${album.id}'),
                            album: album,
                            size: AlbumCardSize.library,
                            heroTag: buildCoverArtHeroTag(
                              coverArtId: album.coverArt,
                              context: 'liked_album',
                            ),
                            badge: AlbumDownloadBadge(albumId: album.id),
                            onTap: () {
                              ref
                                  .read(librarySyncControllerProvider.notifier)
                                  .registerAlbumInteraction(album.id);
                              context.push('/library/albums/${album.id}');
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
                      }, childCount: filteredAlbums.length),
                    ),
                  ),
                if (filteredSongs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        l10n.libraryLikedSongsSectionTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                if (filteredSongs.isNotEmpty)
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final song = filteredSongs[index];
                      if (desktopMode) {
                        final subtitleParts = <String>[
                          if (song.artistName != null &&
                              song.artistName!.trim().isNotEmpty)
                            song.artistName!,
                          if (song.albumName != null &&
                              song.albumName!.trim().isNotEmpty)
                            song.albumName!,
                        ];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 2,
                          ),
                          child: DesktopListRow(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CoverArtImage(
                                coverArtId: song.coverArt,
                                size: 128,
                                width: 40,
                                height: 40,
                                placeholderIcon: Icons.music_note_outlined,
                              ),
                            ),
                            title: song.title,
                            subtitle: subtitleParts.isEmpty
                                ? null
                                : subtitleParts.join(' • '),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                SongDownloadStatusIcon(
                                  songId: song.id,
                                  onDownload: () =>
                                      unawaited(_downloadLikedSong(song)),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _formatSongDuration(song.duration),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(width: 2),
                                IconButton(
                                  icon: const Icon(Icons.more_horiz),
                                  onPressed: () {
                                    final renderObject = context
                                        .findRenderObject();
                                    Offset? anchor;
                                    if (renderObject is RenderBox) {
                                      anchor = renderObject.localToGlobal(
                                        Offset(
                                          renderObject.size.width * 0.92,
                                          renderObject.size.height / 2,
                                        ),
                                      );
                                    }
                                    showSongContextMenu(
                                      this.context,
                                      ref,
                                      song,
                                      anchor: anchor,
                                    );
                                  },
                                ),
                              ],
                            ),
                            onTap: () {
                              ref.read(queueProvider.notifier).replace(<String>[
                                song.id,
                              ], autoPlay: true).ignore();
                            },
                            onSecondaryTapDown: (details) =>
                                showSongContextMenu(
                                  this.context,
                                  ref,
                                  song,
                                  anchor: details.globalPosition,
                                ),
                          ),
                        );
                      }
                      return TrackListTile(
                        song: song,
                        showAlbumArt: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SongDownloadStatusIcon(
                              songId: song.id,
                              onDownload: () =>
                                  unawaited(_downloadLikedSong(song)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert),
                              onPressed: () =>
                                  showSongContextMenu(this.context, ref, song),
                            ),
                          ],
                        ),
                        onTap: () {
                          ref.read(queueProvider.notifier).replace(<String>[
                            song.id,
                          ], autoPlay: true).ignore();
                        },
                        onLongPress: () =>
                            showSongContextMenu(this.context, ref, song),
                      );
                    }, childCount: filteredSongs.length),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _openLikedArtistsAll() {
    if (!ref.read(showArtistsPageProvider)) {
      return;
    }
    if (mounted) {
      setState(() {
        _artistsLikedOnly = true;
      });
    }
    ref
        .read(librarySectionProvider.notifier)
        .setSection(LibrarySection.artists);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_artistsItemScrollController.isAttached) {
        unawaited(
          _artistsItemScrollController.scrollTo(
            index: 0,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          ),
        );
        return;
      }
      _animateScrollControllerToTop(_artistsGridScrollController);
    });
  }

  Future<void> _downloadLikedSong(SongsTableData song) async {
    final choice = await showDownloadQualitySheet(context);
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
    AppNoticeMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.downloadSongQueued)),
    );
  }

  Future<void> _queueLikedSongs(
    List<SongsTableData> songs, {
    bool shuffle = false,
  }) async {
    if (songs.isEmpty) {
      return;
    }
    final queue = songs.map((song) => song.id).toList(growable: false);
    if (shuffle) {
      queue.shuffle();
    }
    try {
      await ref.read(queueProvider.notifier).replace(queue, autoPlay: true);
    } on Object {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playbackActionFailed)),
      );
    }
  }

  void _onAlbumsScroll() {
    if (_albumSort == _AlbumSort.byYear) {
      return;
    }
    if (!_albumsScrollController.hasClients) {
      return;
    }

    final metrics = _albumsScrollController.position;
    if (!metrics.hasContentDimensions || metrics.maxScrollExtent <= 0) {
      return;
    }

    final threshold = metrics.maxScrollExtent * 0.7;
    if (metrics.pixels < threshold) {
      return;
    }

    final totalAlbums = ref.read(albumCountProvider).asData?.value;
    final pageSize = ref.read(albumPageSizeProvider);
    if (totalAlbums == null) {
      return;
    }
    if (pageSize * _loadedAlbumPages >= totalAlbums) {
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
        final crossAxisCount = computeArtistGridCrossAxisCount(
          constraints.maxWidth,
        );

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
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 40, 8),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    childAspectRatio: 0.72,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final byLetter =
                        grouped[letter] ?? const <ArtistsTableData>[];
                    final artist = byLetter[index];
                    return RepaintBoundary(
                      child: ArtistGridCard(
                        key: ValueKey(artist.id),
                        artist: artist,
                        onTap: () =>
                            context.go('/library/artists/${artist.id}'),
                        onLongPress: () => _showArtistMenu(context, artist),
                      ),
                    );
                  }, childCount: grouped[letter]?.length ?? 0),
                ),
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
    final topIndex = targetSet.first.index.clamp(
      0,
      _yearListItems.length - 1,
    );
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

  void _scrollToArtistLetter(
    String letter, {
    required bool animate,
  }) {
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
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
          curve: Curves.easeOut,
          alignment: 0,
        ),
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

  void _scrollToYearDecade(
    String label, {
    required bool animate,
  }) {
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

  // Kept for future star action in album context menu.
  // ignore: unused_element
  Future<void> _toggleAlbumStar(AlbumsTableData album) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    final isStarred = album.starred != null;
    // DB update first so all watching streams update immediately (before API ~300ms).
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    await dao.updateAlbumStarred(
      album.id,
      isStarred ? null : DateTime.now(),
    );
    try {
      if (isStarred) {
        await api.unstar(album.id);
      } else {
        await api.star(album.id);
      }
    } on SubsonicConnectionException {
      if (!mounted) return;
      final db = ref.read(navisDatabaseProvider);
      await db.starSyncDao.queueStarAction(
        itemId: album.id,
        itemType: 'album',
        action: isStarred ? 'unstar' : 'star',
      );
    } on Object {
      if (!mounted) return;
      // Rollback the optimistic DB update on failure.
      await dao.updateAlbumStarred(
        album.id,
        isStarred ? DateTime.now() : null,
      );
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.albumDetailStarFailure)),
      );
    }
  }

  Future<void> _toggleArtistStar(ArtistsTableData artist) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    final isStarred = artist.starred != null;
    // DB update first so all watching streams update immediately (before API ~300ms).
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    await dao.updateArtistStarred(
      artist.id,
      isStarred ? null : DateTime.now(),
    );
    try {
      if (isStarred) {
        await api.unstar(artist.id);
      } else {
        await api.star(artist.id);
      }
    } on SubsonicConnectionException {
      if (!mounted) return;
      final db = ref.read(navisDatabaseProvider);
      await db.starSyncDao.queueStarAction(
        itemId: artist.id,
        itemType: 'artist',
        action: isStarred ? 'unstar' : 'star',
      );
    } on Object {
      if (!mounted) return;
      // Rollback the optimistic DB update on failure.
      await dao.updateArtistStarred(
        artist.id,
        isStarred ? DateTime.now() : null,
      );
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.albumDetailStarFailure)),
      );
    }
  }

  Future<void> _showArtistMenu(
    BuildContext context,
    ArtistsTableData artist,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.open_in_new_outlined),
                title: Text(l10n.libraryArtistMenuOpen),
                onTap: () {
                  Navigator.of(context).pop();
                  this.context.go('/library/artists/${artist.id}');
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TypeFilterBadge extends StatelessWidget {
  const _TypeFilterBadge({
    required this.query,
    required this.onClear,
  });

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.filter_list_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Filtering: "$query"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: onClear,
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatusBanner extends StatelessWidget {
  const _SyncStatusBanner({
    required this.syncState,
    required this.onRetry,
    this.onCancel,
  });

  final LibrarySyncState syncState;
  final Future<void> Function() onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (syncState.status == LibrarySyncStatus.failed) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  syncState.errorMessage ?? l10n.librarySyncFailureFallback,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onRetry,
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
      );
    }

    if (!syncState.isRunning && syncState.lastSyncedAt == null) {
      return const SizedBox.shrink();
    }

    if (syncState.isRunning) {
      final total = syncState.total;
      final processed = syncState.processed ?? 0;
      final progress = total == null || total == 0
          ? null
          : processed / total.clamp(1, total);
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(value: progress),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _runningLabel(l10n, total, processed),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (onCancel != null)
                    SizedBox(
                      height: 28,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: onCancel,
                        child: Text(
                          l10n.commonCancel,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  String _runningLabel(
    AppLocalizations l10n,
    int? total,
    int processed,
  ) {
    final pending = syncState.pendingHydrationCount ?? 0;
    if (syncState.metadataReady &&
        syncState.stage == LibrarySyncStage.fetchingSongs) {
      if (total == null || total == 0) {
        return l10n.librarySyncHydratingUnknown;
      }
      final throughput = syncState.hydrationThroughputAlbumsPerSecond;
      if (throughput != null && throughput > 0) {
        return l10n.librarySyncHydratingProgressWithRate(
          processed,
          total,
          pending,
          throughput.toStringAsFixed(1),
        );
      }
      return l10n.librarySyncHydratingProgress(processed, total, pending);
    }

    if (total == null) {
      return l10n.librarySyncRunningStage(_stageLabel(syncState.stage, l10n));
    }
    return l10n.librarySyncRunningWithProgress(processed, total);
  }

  String _stageLabel(LibrarySyncStage stage, AppLocalizations l10n) {
    return switch (stage) {
      LibrarySyncStage.preparing => l10n.librarySyncStagePreparing,
      LibrarySyncStage.fetchingArtists => l10n.librarySyncStageArtists,
      LibrarySyncStage.fetchingAlbums => l10n.librarySyncStageAlbums,
      LibrarySyncStage.persistingMetadata => l10n.librarySyncStagePersisting,
      LibrarySyncStage.fetchingSongs => l10n.librarySyncStageSongs,
      LibrarySyncStage.fetchingGenres => l10n.librarySyncStageGenres,
      LibrarySyncStage.fetchingPlaylists => l10n.librarySyncStagePlaylists,
      LibrarySyncStage.finalizing => l10n.librarySyncStageFinalizing,
      _ => l10n.librarySyncRunning,
    };
  }
}

class _SectionRail extends StatelessWidget {
  const _SectionRail({
    required this.labels,
    required this.activeLabel,
    required this.onLabelSelected,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    this.railKey,
    this.activeLabelKey,
    this.width = 36,
  });

  final Key? railKey;
  final Key? activeLabelKey;
  final double width;
  final List<String> labels;
  final String? activeLabel;
  final void Function(String label, {required bool animate}) onLabelSelected;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      key: railKey,
      width: width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void selectAtDy(double dy) {
            if (constraints.maxHeight <= 0) {
              return;
            }
            final normalized = ((dy / constraints.maxHeight) * labels.length)
                .clamp(0, labels.length - 0.0001);
            final index = normalized.floor().clamp(
              0,
              labels.length - 1,
            );
            onLabelSelected(
              labels[index],
              animate: false,
            );
          }

          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (details) {
              onInteractionStart();
              selectAtDy(details.localPosition.dy);
            },
            onPointerMove: (details) => selectAtDy(details.localPosition.dy),
            onPointerUp: (details) {
              selectAtDy(details.localPosition.dy);
              onInteractionEnd();
            },
            onPointerCancel: (_) => onInteractionEnd(),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: labels
                    .map(
                      (label) => Expanded(
                        child: Center(
                          child: Text(
                            label,
                            key: label == activeLabel ? activeLabelKey : null,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(
                                  color: label == activeLabel
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                  fontWeight: label == activeLabel
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RailOverlay extends StatelessWidget {
  const _RailOverlay({
    required this.overlayKey,
    required this.label,
  });

  final Key overlayKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            key: overlayKey,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Text(
                label,
                style:
                    Theme.of(
                      context,
                    ).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class _ArtistListItem {
  const _ArtistListItem._({required this.letter, this.artist});

  const _ArtistListItem.header(String letter) : this._(letter: letter);

  const _ArtistListItem.artist(String letter, ArtistsTableData artist)
    : this._(letter: letter, artist: artist);

  final String letter;
  final ArtistsTableData? artist;
}

/// A flat list item for the By Year album view.
/// Either a section header (isHeader == true) or a row of 1–2 album cards.
class _YearListItem {
  _YearListItem.header({
    required this.label,
    required this.isUnknownYear,
    this.decadeStart,
  }) : albums = const [];

  _YearListItem.albumRow(AlbumsTableData left, [AlbumsTableData? right])
    : label = '',
      isUnknownYear = false,
      decadeStart = null,
      albums = right != null ? [left, right] : [left];

  final String label; // non-empty for headers
  final bool isUnknownYear; // true when year is unknown
  final int? decadeStart; // decade start year for headers
  final List<AlbumsTableData> albums; // empty = header, 1–2 = album row

  bool get isHeader => albums.isEmpty;
}

class _SortFilterRow<T> extends StatelessWidget {
  const _SortFilterRow({
    required this.sortLabel,
    required this.sortValue,
    required this.sortItems,
    required this.onSortChanged,
    required this.downloadedOnly,
    required this.onDownloadedOnlyChanged,
    this.likedOnly = false,
    this.onLikedOnlyChanged,
  });

  final String sortLabel;
  final T sortValue;
  final List<DropdownMenuItem<T>> sortItems;
  final ValueChanged<T?> onSortChanged;
  final bool downloadedOnly;
  final ValueChanged<bool> onDownloadedOnlyChanged;
  final bool likedOnly;
  final ValueChanged<bool>? onLikedOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget buildSortDropdown() {
      return DropdownButton<T>(
        value: sortValue,
        isExpanded: true,
        isDense: true,
        items: sortItems,
        onChanged: onSortChanged,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useStackedLayout = constraints.maxWidth < 320;

          final filters = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilterChip(
                label: Text(l10n.libraryDownloadedOnlyFilter),
                selected: downloadedOnly,
                onSelected: onDownloadedOnlyChanged,
                avatar: Icon(
                  downloadedOnly
                      ? Icons.download_done
                      : Icons.download_outlined,
                  size: 18,
                ),
              ),
              if (onLikedOnlyChanged != null)
                FilterChip(
                  label: Text(l10n.libraryLikedOnlyFilter),
                  selected: likedOnly,
                  onSelected: onLikedOnlyChanged,
                  avatar: Icon(
                    likedOnly ? Icons.favorite : Icons.favorite_border_outlined,
                    size: 18,
                  ),
                ),
            ],
          );

          if (useStackedLayout) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                filters,
                const SizedBox(height: 8),
                buildSortDropdown(),
              ],
            );
          }

          return Row(
            children: <Widget>[
              Expanded(child: filters),
              const SizedBox(width: 12),
              Flexible(
                fit: FlexFit.loose,
                child: buildSortDropdown(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoadingListPlaceholder extends StatelessWidget {
  const _LoadingListPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ShimmerPlaceholder(height: 18, width: 180),
          SizedBox(height: 8),
          ShimmerPlaceholder(height: 14, width: 120),
        ],
      ),
    );
  }
}

class _LikedArtistStripTile extends ConsumerWidget {
  const _LikedArtistStripTile({
    required this.artist,
    this.onTap,
    this.onLongPress,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(artistCardShapeProvider);
    final borderRadius = coverArtShapeToRadius(shape);
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            CoverArtImage(
              coverArtId: artist.coverArt,
              size: 160,
              width: 64,
              height: 64,
              borderRadius: borderRadius,
              placeholderIcon: Icons.person_outline,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  artist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: textStyle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Playlists tab embedded in the Library screen
// ---------------------------------------------------------------------------

class _LibraryPlaylistsTab extends ConsumerStatefulWidget {
  const _LibraryPlaylistsTab({this.scrollController});

  /// Optional external [ScrollController] for scroll-to-top support.
  final ScrollController? scrollController;

  @override
  ConsumerState<_LibraryPlaylistsTab> createState() =>
      _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState extends ConsumerState<_LibraryPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  late final ProviderSubscription<AsyncValue<void>> _playlistSyncSubscription;
  List<PlaylistsTableData> _cachedPlaylists = const <PlaylistsTableData>[];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _playlistSyncSubscription = ref.listenManual<AsyncValue<void>>(
      playlistSyncProvider,
      (prev, next) {
        if (!mounted) {
          return;
        }
        if (next is AsyncError && (prev == null || prev is! AsyncError)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            final l10n = AppLocalizations.of(context)!;
            AppNoticeMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.playlistsLoadError),
                behavior: SnackBarBehavior.floating,
              ),
            );
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _playlistSyncSubscription.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistListProvider);
    final playlistSyncAsync = ref.watch(playlistSyncProvider);

    playlistsAsync.whenData((playlists) {
      _cachedPlaylists = playlists;
    });

    final effectivePlaylists = playlistsAsync.asData?.value ?? _cachedPlaylists;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(playlistSyncProvider);
            await ref.read(playlistSyncProvider.future);
          },
          child: playlistsAsync.when(
            data: (_) {
              if (effectivePlaylists.isEmpty) {
                return ListView(
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: EmptyState(
                        title: l10n.playlistsEmpty,
                        subtitle: l10n.playlistsEmptySubtitle,
                        icon: Icons.queue_music_outlined,
                      ),
                    ),
                  ],
                );
              }

              return ListView.builder(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: effectivePlaylists.length,
                itemBuilder: (context, index) {
                  final playlist = effectivePlaylists[index];
                  return ListTile(
                    minLeadingWidth: 48,
                    horizontalTitleGap: 12,
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CoverArtImage(
                          coverArtId: playlist.coverArt,
                          size: 48,
                          semanticLabel: playlist.name,
                        ),
                      ),
                    ),
                    title: Text(playlist.name),
                    subtitle: playlist.songCount != null
                        ? Text(l10n.playlistsSongCount(playlist.songCount!))
                        : null,
                    onTap: () => context.push(
                      '/library/playlists/${playlist.id}',
                    ),
                    onLongPress: () => _showPlaylistActions(context, playlist),
                  );
                },
              );
            },
            loading: () {
              if (effectivePlaylists.isNotEmpty) {
                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: effectivePlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = effectivePlaylists[index];
                    return ListTile(
                      minLeadingWidth: 48,
                      horizontalTitleGap: 12,
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CoverArtImage(
                            coverArtId: playlist.coverArt,
                            size: 48,
                            semanticLabel: playlist.name,
                          ),
                        ),
                      ),
                      title: Text(playlist.name),
                      subtitle: playlist.songCount != null
                          ? Text(l10n.playlistsSongCount(playlist.songCount!))
                          : null,
                      onTap: () => context.push(
                        '/library/playlists/${playlist.id}',
                      ),
                      onLongPress: () =>
                          _showPlaylistActions(context, playlist),
                    );
                  },
                );
              }
              return const ShimmerListPage(count: 8);
            },
            error: (error, _) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ErrorState(
                  title: l10n.playlistsLoadError,
                  message: error.toString(),
                  onRetry: () => ref.invalidate(playlistSyncProvider),
                ),
              ],
            ),
          ),
        ),
        if (playlistSyncAsync.isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            heroTag: 'library_playlists_fab',
            onPressed: () => _showCreatePlaylistDialog(context),
            tooltip: l10n.playlistsCreateAction,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsCreateTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) =>
              _createPlaylist(dialogContext, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () =>
                _createPlaylist(dialogContext, controller.text.trim()),
            child: Text(l10n.playlistsCreateAction),
          ),
        ],
      ),
    );
  }

  void _createPlaylist(BuildContext dialogContext, String name) {
    if (name.isEmpty) return;
    Navigator.of(dialogContext).pop();

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .createPlaylist(name)
          .then((_) {
            if (!mounted) return;
            AppNoticeMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateSuccess)),
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            AppNoticeMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateFailed)),
            );
          }),
    );
  }

  void _showPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.playlistsRenameTitle),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showRenameDialog(context, playlist);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.playlistsDeleteConfirmTitle,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete(context, playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, PlaylistsTableData playlist) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: playlist.name);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) =>
              _renamePlaylist(dialogContext, playlist, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => _renamePlaylist(
              dialogContext,
              playlist,
              controller.text.trim(),
            ),
            child: Text(l10n.playlistsRenameTitle),
          ),
        ],
      ),
    );
  }

  void _renamePlaylist(
    BuildContext dialogContext,
    PlaylistsTableData playlist,
    String newName,
  ) {
    if (newName.isEmpty) return;
    Navigator.of(dialogContext).pop();
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    unawaited(
      api
          .updatePlaylist(id: playlist.id, name: newName)
          .then((_) {
            if (!mounted) return;
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {}),
    );
  }

  void _confirmDelete(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsDeleteConfirmTitle),
        content: Text(l10n.playlistsDeleteConfirmMessage(playlist.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _deletePlaylist(playlist);
            },
            child: Text(l10n.playlistsDeleteConfirmTitle),
          ),
        ],
      ),
    );
  }

  void _deletePlaylist(PlaylistsTableData playlist) {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    unawaited(
      api
          .deletePlaylist(playlist.id)
          .then((_) {
            if (!mounted) return;
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {}),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Liked Albums — full-screen list (navigated to from the "See all" button)
// ─────────────────────────────────────────────────────────────────────────────

class LikedAlbumsAllScreen extends ConsumerWidget {
  const LikedAlbumsAllScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final likedAlbumsAsync = ref.watch(likedAlbumsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedContentIds = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;

    Future<void> refresh() {
      return ref
          .read(librarySyncControllerProvider.notifier)
          .syncNow(preferIncremental: true);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryLikedAlbumsAllTitle)),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: likedAlbumsAsync.when(
          loading: () => const _LoadingListPlaceholder(),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              ErrorState(
                title: l10n.libraryAlbumsErrorTitle,
                message: error.toString(),
                onRetry: refresh,
                retryLabel: l10n.commonRetry,
              ),
            ],
          ),
          data: (albums) {
            final filteredAlbums = downloadedOnly
                ? albums
                      .where(
                        (album) =>
                            downloadedContentIds?.albumIds.contains(album.id) ??
                            false,
                      )
                      .toList(growable: false)
                : albums;
            if (filteredAlbums.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: EmptyState(
                      title: downloadedOnly
                          ? l10n.libraryDownloadedOnlyEmpty
                          : l10n.libraryLikedEmptyTitle,
                      subtitle: downloadedOnly
                          ? l10n.libraryDownloadedOnlyEmptySubtitle
                          : l10n.libraryLikedEmptySubtitle,
                      icon: downloadedOnly
                          ? Icons.download_done_outlined
                          : Icons.favorite_border_outlined,
                    ),
                  ),
                ],
              );
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                final gridWidth = (constraints.maxWidth - 24).clamp(
                  240.0,
                  2400.0,
                );
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: computeGridCrossAxisCount(
                            ref.watch(albumGridDensityProvider),
                            gridWidth,
                          ),
                          childAspectRatio: 1,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final album = filteredAlbums[index];
                          return RepaintBoundary(
                            child: AlbumCard(
                              key: ValueKey('liked-all-album-${album.id}'),
                              album: album,
                              size: AlbumCardSize.library,
                              heroTag: buildCoverArtHeroTag(
                                coverArtId: album.coverArt,
                                context: 'liked_all_album',
                              ),
                              badge: AlbumDownloadBadge(albumId: album.id),
                              onTap: () {
                                ref
                                    .read(
                                      librarySyncControllerProvider.notifier,
                                    )
                                    .registerAlbumInteraction(album.id);
                                context.push('/library/albums/${album.id}');
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
                        }, childCount: filteredAlbums.length),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

String _formatSongDuration(int? seconds) {
  if (seconds == null || seconds <= 0) {
    return '--:--';
  }
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}
