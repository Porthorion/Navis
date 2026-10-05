import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/theme/artwork_shape.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  // Shared by the results and recent-search lists; only one is shown.
  final _listScrollController = ScrollController();
  // Filter chips navigate to the relevant section; no inline expansion tracking needed.
  late final ProviderSubscription<int> _focusRequestSubscription;
  late final ProviderSubscription<bool> _playerExpandedSubscription;
  int _lastFocusRequest = 0;
  bool _isPlayerExpanded = false;

  @override
  void initState() {
    super.initState();

    final initial = ref.read(searchQueryProvider);
    if (initial.isNotEmpty) {
      _controller.text = initial;
    }

    _lastFocusRequest = ref.read(searchFocusRequestProvider);
    _isPlayerExpanded = ref.read(playerSheetExpandedProvider);
    _focusNode.canRequestFocus = !_isPlayerExpanded;

    _focusRequestSubscription = ref.listenManual<int>(
      searchFocusRequestProvider,
      (previous, next) {
        if (next == _lastFocusRequest) {
          return;
        }
        _lastFocusRequest = next;
        // Re-selecting Search returns its list to the top and focuses the
        // field, ready for a new query.
        if (_listScrollController.hasClients) {
          unawaited(
            _listScrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            ),
          );
        }
        _requestSearchFocus(selectAllIfHasText: true);
      },
    );

    _playerExpandedSubscription = ref.listenManual<bool>(
      playerSheetExpandedProvider,
      (previous, next) {
        _isPlayerExpanded = next;
        _focusNode.canRequestFocus = !next;
        if (next) {
          _dismissSearchFocus();
        }
      },
    );
  }

  @override
  void dispose() {
    _focusRequestSubscription.close();
    _playerExpandedSubscription.close();
    _controller.dispose();
    _focusNode.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    ref.read(searchQueryProvider.notifier).submit(value);
  }

  void _onSearchSubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final dao = ref.read(navisDatabaseProvider).historyDao;
    unawaited(dao.saveSearchQuery(trimmed));
  }

  void _applyRecentSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: query.length),
    );
    ref.read(searchQueryProvider.notifier).submit(query);
    _dismissSearchFocus();
  }

  void _clearSearch() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).clear();
    _requestSearchFocus();
  }

  void _dismissSearchFocus() {
    if (!mounted) {
      return;
    }
    NavService.dismissKeyboard(context);
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  void _requestSearchFocus({bool selectAllIfHasText = false}) {
    if (!mounted || _isPlayerExpanded || !_focusNode.canRequestFocus) {
      return;
    }

    if (selectAllIfHasText && _focusNode.hasFocus) {
      _scheduleSelectAllSearchTextIfPresent();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isPlayerExpanded || !_focusNode.canRequestFocus) {
        return;
      }
      _focusNode.requestFocus();
      if (selectAllIfHasText) {
        _scheduleSelectAllSearchTextIfPresent();
      }
    });
  }

  void _scheduleSelectAllSearchTextIfPresent() {
    if (!mounted) {
      return;
    }
    // EditableText may collapse selection as focus is acquired, so apply
    // select-all after focus settles.
    unawaited(
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        _selectAllSearchTextIfPresent();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _selectAllSearchTextIfPresent();
        });
      }),
    );
  }

  void _selectAllSearchTextIfPresent() {
    if (!mounted || !_focusNode.hasFocus) {
      return;
    }
    final text = _controller.text;
    if (text.isEmpty) {
      return;
    }
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);
    final hasQuery = query.trim().isNotEmpty;
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final desktopMode = adaptiveContext.useDesktopShell;
    final layoutClass = adaptiveContext.desktopLayoutClass;
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final compactHorizontalInset = compactWideLandscapeMode ? 10.0 : 12.0;
    final tabletMode =
        !desktopMode && adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;

    // Sync the text controller when the query changes externally
    // (e.g. NavService.openSearch sets the provider from radio tap).
    if (_controller.text != query) {
      _controller.text = query;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: query.length),
      );
    }

    if (desktopMode) {
      final colors = Theme.of(context).colorScheme;
      final showDesktopWorkspaceTitle =
          DesktopNavigationPresentationScope.iconsOnlyOf(context);
      return Scaffold(
        body: SafeArea(
          child: DesktopFrame(
            layoutClass: layoutClass,
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                Material(
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
                    child: Row(
                      children: <Widget>[
                        if (showDesktopWorkspaceTitle) ...<Widget>[
                          Text(
                            l10n.navSearch,
                            key: const ValueKey<String>(
                              'desktopSearchWorkspaceTitle',
                            ),
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 20),
                        ],
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 620),
                            child: _SearchBar(
                              controller: _controller,
                              focusNode: _focusNode,
                              hint: l10n.searchHint,
                              onChanged: _onQueryChanged,
                              onSubmitted: _onSearchSubmitted,
                              onClear: hasQuery ? _clearSearch : null,
                              desktopMode: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colors.outlineVariant.withValues(alpha: 0.35),
                ),
                if (hasQuery)
                  Material(
                    color: colors.surfaceContainerLow,
                    child: _SearchFilterChips(desktopMode: true),
                  ),
                if (hasQuery) _OfflineSearchBanner(desktopMode: true),
                Expanded(
                  child: hasQuery
                      ? _buildResults(desktopMode: true)
                      : _buildRecentSearches(
                          desktopMode: true,
                          compactWideLandscapeMode: compactWideLandscapeMode,
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (tabletMode) {
      final maxWidth = switch (adaptiveLayoutClass) {
        AdaptiveLayoutClass.tabletMedium => 860.0,
        AdaptiveLayoutClass.tabletExpanded =>
          compactWideLandscapeMode ? double.infinity : 1040.0,
        AdaptiveLayoutClass.phoneCompact => double.infinity,
      };
      final tabletContent = Padding(
        padding: EdgeInsets.fromLTRB(
          compactHorizontalInset,
          12,
          compactHorizontalInset,
          16,
        ),
        child: Column(
          children: <Widget>[
            if (compactWideLandscapeMode)
              _SearchBar(
                controller: _controller,
                focusNode: _focusNode,
                hint: l10n.searchHint,
                onChanged: _onQueryChanged,
                onSubmitted: _onSearchSubmitted,
                onClear: hasQuery ? _clearSearch : null,
              )
            else
              DesktopPanel(
                child: _SearchBar(
                  controller: _controller,
                  focusNode: _focusNode,
                  hint: l10n.searchHint,
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSearchSubmitted,
                  onClear: hasQuery ? _clearSearch : null,
                  desktopMode: true,
                ),
              ),
            const SizedBox(height: 10),
            if (hasQuery)
              _SearchFilterChips(desktopMode: !compactWideLandscapeMode),
            if (hasQuery)
              _OfflineSearchBanner(desktopMode: !compactWideLandscapeMode),
            Expanded(
              child: compactWideLandscapeMode
                  ? (hasQuery ? _buildResults() : _buildRecentSearches())
                  : Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: hasQuery
                          ? _buildResults(desktopMode: true)
                          : _buildRecentSearches(
                              desktopMode: true,
                              compactWideLandscapeMode:
                                  compactWideLandscapeMode,
                            ),
                    ),
            ),
          ],
        ),
      );
      return Scaffold(
        body: SafeArea(
          left: !compactWideLandscapeMode,
          right: !compactWideLandscapeMode,
          child: compactWideLandscapeMode
              ? tabletContent
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: tabletContent,
                  ),
                ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _SearchBar(
          controller: _controller,
          focusNode: _focusNode,
          hint: l10n.searchHint,
          onChanged: _onQueryChanged,
          onSubmitted: _onSearchSubmitted,
          onClear: hasQuery ? _clearSearch : null,
        ),
      ),
      body: Column(
        children: <Widget>[
          if (hasQuery) _SearchFilterChips(),
          if (hasQuery) _OfflineSearchBanner(),
          Expanded(child: hasQuery ? _buildResults() : _buildRecentSearches()),
        ],
      ),
    );
  }

  Widget _buildResults({bool desktopMode = false}) {
    final results = ref.watch(debouncedSearchProvider);
    final query = ref.watch(searchQueryProvider).trim();
    final filter = ref.watch(searchFilterProvider);
    final l10n = AppLocalizations.of(context)!;

    // When a category filter is active, auto-expand that section.
    bool isExpanded(SearchResultType type) => filter == type;

    return results.when(
      data: (state) {
        if (state == null) {
          return const SizedBox.shrink();
        }
        final data = state.result;
        final hasResults =
            data.artists.isNotEmpty ||
            data.albums.isNotEmpty ||
            data.songs.isNotEmpty;
        if (!hasResults && state.isWaitingForApi) {
          return const ShimmerListPage(count: 8);
        }
        if (!hasResults && state.remoteSearchFailed) {
          return ErrorState(
            title: l10n.searchLoadError,
            onRetry: () => ref.invalidate(debouncedSearchProvider),
          );
        }
        if (!hasResults) {
          return EmptyState(
            title: l10n.searchNoResultsForQuery(query),
            subtitle: l10n.searchNoResultsSubtitle,
            icon: Icons.search_off,
          );
        }
        return Column(
          children: <Widget>[
            if (state.isWaitingForApi) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                controller: _listScrollController,
                padding: desktopMode
                    ? const EdgeInsets.fromLTRB(16, 6, 16, 20)
                    : EdgeInsets.zero,
                children: <Widget>[
                  if (data.artists.isNotEmpty)
                    _ArtistResultsSection(
                      artists: data.artists,
                      desktopMode: desktopMode,
                      expanded: isExpanded(SearchResultType.artists),
                      onToggleExpanded: () {
                        if (filter == SearchResultType.artists) {
                          ref.read(searchFilterProvider.notifier).select(null);
                        } else {
                          ref
                              .read(searchFilterProvider.notifier)
                              .select(SearchResultType.artists);
                        }
                      },
                    ),
                  if (data.albums.isNotEmpty)
                    _AlbumResultsSection(
                      albums: data.albums,
                      desktopMode: desktopMode,
                      expanded: isExpanded(SearchResultType.albums),
                      onToggleExpanded: () {
                        if (filter == SearchResultType.albums) {
                          ref.read(searchFilterProvider.notifier).select(null);
                        } else {
                          ref
                              .read(searchFilterProvider.notifier)
                              .select(SearchResultType.albums);
                        }
                      },
                    ),
                  if (data.songs.isNotEmpty)
                    _SongResultsSection(
                      songs: data.songs,
                      desktopMode: desktopMode,
                      expanded: isExpanded(SearchResultType.songs),
                      onToggleExpanded: () {
                        if (filter == SearchResultType.songs) {
                          ref.read(searchFilterProvider.notifier).select(null);
                        } else {
                          ref
                              .read(searchFilterProvider.notifier)
                              .select(SearchResultType.songs);
                        }
                      },
                    ),
                ],
              ),
            ),
            if (state.isWaitingForApi) const LinearProgressIndicator(),
          ],
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.searchLoadError,
        onRetry: () => ref.invalidate(debouncedSearchProvider),
      ),
    );
  }

  Widget _buildRecentSearches({
    bool desktopMode = false,
    bool compactWideLandscapeMode = false,
  }) {
    final recentAsync = ref.watch(recentSearchesProvider);
    final l10n = AppLocalizations.of(context)!;

    return recentAsync.when(
      data: (searches) {
        if (searches.isEmpty) {
          return EmptyState(title: l10n.searchHint, icon: Icons.search);
        }
        return ListView(
          controller: _listScrollController,
          padding: desktopMode
              ? (compactWideLandscapeMode
                    ? const EdgeInsets.fromLTRB(0, 8, 0, 8)
                    : const EdgeInsets.fromLTRB(8, 8, 8, 8))
              : EdgeInsets.zero,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.searchRecentTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final dao = ref.read(navisDatabaseProvider).historyDao;
                      unawaited(dao.clearAllHistory());
                    },
                    child: Text(l10n.searchClearRecent),
                  ),
                ],
              ),
            ),
            ...searches.map(
              (s) => ListTile(
                leading: const Icon(Icons.history),
                title: Text(s.query),
                onTap: () => _applyRecentSearch(s.query),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const new({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    this.desktopMode = false,
    this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final bool desktopMode;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const border = OutlineInputBorder(
      borderRadius: NavisRadius.mdAll,
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: false,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        filled: true,
        // The phone field sits inside the app bar, so it stays compact.
        contentPadding: EdgeInsets.symmetric(
          horizontal: NavisSpace.sm,
          vertical: desktopMode ? 14 : 10,
        ),
        suffixIcon: onClear != null
            ? IconButton(
                tooltip: l10n.searchClearQuery,
                icon: const Icon(Icons.close),
                onPressed: onClear,
              )
            : null,
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

class _SearchFilterChips extends ConsumerWidget {
  const new({this.desktopMode = false});

  final bool desktopMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selected = ref.watch(searchFilterProvider);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: desktopMode ? 20 : 16,
        vertical: 4,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.searchFilterAll),
                selected: selected == null,
                onSelected: (_) =>
                    ref.read(searchFilterProvider.notifier).select(null),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.searchArtistsSection),
                selected: selected == SearchResultType.artists,
                onSelected: (_) => ref
                    .read(searchFilterProvider.notifier)
                    .select(
                      selected == SearchResultType.artists
                          ? null
                          : SearchResultType.artists,
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.searchAlbumsSection),
                selected: selected == SearchResultType.albums,
                onSelected: (_) => ref
                    .read(searchFilterProvider.notifier)
                    .select(
                      selected == SearchResultType.albums
                          ? null
                          : SearchResultType.albums,
                    ),
              ),
            ),
            ChoiceChip(
              label: Text(l10n.searchSongsSection),
              selected: selected == SearchResultType.songs,
              onSelected: (_) => ref
                  .read(searchFilterProvider.notifier)
                  .select(
                    selected == SearchResultType.songs
                        ? null
                        : SearchResultType.songs,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineSearchBanner extends ConsumerWidget {
  const new({this.desktopMode = false});

  final bool desktopMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(searchIsOfflineProvider);
    if (!isOffline) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: desktopMode ? 12 : 16,
        vertical: 8,
      ),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: <Widget>[
          Icon(
            Icons.cloud_off,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            l10n.searchLocalOfflineBanner,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const new({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.itemCount,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return NavisSectionHeader(
      title: title,
      compact: true,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 4),
      onSeeAll: itemCount > 5 ? onToggle : null,
      seeAllLabel: expanded ? l10n.searchShowLess : l10n.searchShowAll,
    );
  }
}

class _ArtistResultsSection extends ConsumerWidget {
  const new({
    required this.artists,
    required this.expanded,
    required this.onToggleExpanded,
    this.desktopMode = false,
  });

  final List<Artist> artists;
  final bool expanded;
  final bool desktopMode;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final artistShape = ref.watch(artistCardShapeProvider);
    final artistRadius = artworkBorderRadius(artistShape, extent: 40);
    final visible = expanded ? artists : artists.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchArtistsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: artists.length,
        ),
        ...visible.map((artist) {
          final isRemote = isExternalCatalogSource(
            id: artist.id,
            apiIsExternal: artist.isExternal,
          );
          final leading = ClipRRect(
            borderRadius: artistRadius,
            child: SizedBox(
              width: 40,
              height: 40,
              child: CoverArtImage(
                coverArtId: artist.coverArt,
                size: 80,
                width: 40,
                height: 40,
                borderRadius: artistRadius,
                placeholderIcon: Icons.person_outline,
                isExternalSource: isRemote,
                remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
              ),
            ),
          );
          if (desktopMode) {
            return DesktopListRow(
              leading: leading,
              title: artist.name,
              subtitleWidget: _SearchResultMetadata(
                text: artist.albumCount != null
                    ? l10n.searchAlbumCount(artist.albumCount!)
                    : '',
                isRemote: isRemote,
              ),
              trailing: Builder(
                builder: (buttonContext) => IconButton(
                  icon: const Icon(Icons.more_horiz),
                  tooltip: MaterialLocalizations.of(buttonContext)
                      .showMenuTooltip,
                  onPressed: () {
                    final renderObject = buttonContext.findRenderObject();
                    if (renderObject is! RenderBox) return;
                    unawaited(
                      showArtistContextMenu(
                        context,
                        ref,
                        artist.id,
                        anchor: renderObject.localToGlobal(
                          renderObject.size.center(Offset.zero),
                        ),
                      ),
                    );
                  },
                ),
              ),
              onTap: () => NavService.openArtistDetail(
                context,
                ref,
                artist.id,
                name: artist.name,
              ),
              onSecondaryTapDown: (details) => unawaited(
                showArtistContextMenu(
                  context,
                  ref,
                  artist.id,
                  anchor: details.globalPosition,
                ),
              ),
            );
          }
          return ListTile(
            leading: leading,
            title: Text(artist.name),
            subtitle: _SearchResultMetadata(
              text: artist.albumCount != null
                  ? l10n.searchAlbumCount(artist.albumCount!)
                  : '',
              isRemote: isRemote,
            ),
            onTap: () => NavService.openArtistDetail(
              context,
              ref,
              artist.id,
              name: artist.name,
            ),
            onLongPress: () =>
                unawaited(showArtistContextMenu(context, ref, artist.id)),
            trailing: Builder(
              builder: (buttonContext) => IconButton(
                icon: const Icon(Icons.more_horiz),
                tooltip: MaterialLocalizations.of(buttonContext)
                    .showMenuTooltip,
                onPressed: () {
                  final renderObject = buttonContext.findRenderObject();
                  if (renderObject is! RenderBox) return;
                  unawaited(
                    showArtistContextMenu(
                      context,
                      ref,
                      artist.id,
                      anchor: renderObject.localToGlobal(
                        renderObject.size.center(Offset.zero),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _AlbumResultsSection extends ConsumerWidget {
  const new({
    required this.albums,
    required this.expanded,
    required this.onToggleExpanded,
    this.desktopMode = false,
  });

  final List<Album> albums;
  final bool expanded;
  final bool desktopMode;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(coverShape, extent: 48);
    final visible = expanded ? albums : albums.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchAlbumsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: albums.length,
        ),
        ...visible.map((album) {
          final isRemote = isExternalCatalogSource(
            id: album.id,
            apiIsExternal: album.isExternal,
          );
          final heroTag = buildCoverArtHeroTag(
            coverArtId: album.coverArt,
            context: 'search_album',
            entityId: album.id,
          );
          final leading = HeroCoverArt(
            coverArtId: album.coverArt,
            heroTag: heroTag,
            size: 80,
            width: 48,
            height: 48,
            borderRadius: coverRadius,
            isExternalSource: isRemote,
            remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
          );
          if (desktopMode) {
            return DesktopListRow(
              leading: leading,
              title: album.name,
              subtitleWidget: _SearchResultMetadata(
                text: album.artist ?? '',
                isRemote: isRemote,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => NavService.openAlbumDetail(
                context,
                ref,
                album.id,
                heroTag: heroTag,
                name: album.name,
                artistName: album.artist,
              ),
            );
          }
          return ListTile(
            leading: leading,
            title: Text(album.name),
            subtitle: _SearchResultMetadata(
              text: album.artist ?? '',
              isRemote: isRemote,
            ),
            onTap: () => NavService.openAlbumDetail(
              context,
              ref,
              album.id,
              heroTag: heroTag,
              name: album.name,
              artistName: album.artist,
            ),
          );
        }),
      ],
    );
  }
}

class _SongResultsSection extends ConsumerWidget {
  const new({
    required this.songs,
    required this.expanded,
    required this.onToggleExpanded,
    this.desktopMode = false,
  });

  final List<Song> songs;
  final bool expanded;
  final bool desktopMode;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(coverShape, extent: 48);
    final visible = expanded ? songs : songs.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchSongsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: songs.length,
        ),
        if (expanded && visible.isNotEmpty)
          AdaptiveTrackHeader(actionExtent: desktopMode ? null : 0),
        ...visible.asMap().entries.map((entry) {
          final song = entry.value;
          final playbackState = ref.watch(
            songPlaybackIndicatorStateProvider(song.id),
          );
          final isSelected = playbackState.isSelected;
          final isRemote = isExternalCatalogSource(
            id: song.id,
            apiIsExternal: song.isExternal,
          );
          final tile = AdaptiveTrackRow(
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.duration,
            selected: isSelected,
            isRemote: isRemote,
            actionExtent: desktopMode ? null : 0,
            leading: ArtworkPlaybackMarker(
              state: playbackState,
              child: CoverArtImage(
                coverArtId: song.coverArt,
                size: 80,
                width: 48,
                height: 48,
                borderRadius: coverRadius,
                isExternalSource: isRemote,
                remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
              ),
            ),
            actions: desktopMode
                ? DesktopSongActions.forSongId(
                    songId: song.id,
                    isExternal: isRemote,
                    keyPrefix: 'search-song',
                    onMore: (anchor) => _showSongContextMenu(
                      context,
                      ref,
                      song,
                      anchor: anchor,
                    ),
                  )
                : null,
            onTap: () => unawaited(
              ref.read(queueProvider.notifier).replaceWithSongs(<Song>[song]),
            ),
            onLongPress: () => _showSongContextMenu(context, ref, song),
            onSecondaryTapDown: (details) => _showSongContextMenu(
              context,
              ref,
              song,
              anchor: details.globalPosition,
            ),
          );
          return SongPlaybackSemantics(state: playbackState, child: tile);
        }),
      ],
    );
  }

  void _showSongContextMenu(
    BuildContext context,
    WidgetRef ref,
    Song song, {
    Offset? anchor,
  }) {
    final l10n = AppLocalizations.of(context)!;
    if (anchor != null) {
      final result = showDesktopContextMenu<String>(
        context: context,
        anchor: anchor,
        items: <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'play-next',
            child: Text(l10n.searchPlayNext),
          ),
          PopupMenuItem<String>(
            value: 'add-queue',
            child: Text(l10n.searchAddToQueue),
          ),
          PopupMenuItem<String>(
            value: 'add-playlist',
            child: Text(l10n.librarySongMenuAddToPlaylist),
          ),
          PopupMenuItem<String>(
            value: 'instant-mix',
            child: Text(l10n.nowPlayingInstantMix),
          ),
        ],
      );
      unawaited(
        result.then((value) {
          if (!context.mounted) return;
          switch (value) {
            case 'play-next':
              ref
                  .read(queueProvider.notifier)
                  .fireAndForget(
                    () =>
                        ref.read(queueProvider.notifier).playNextWithSong(song),
                    label: 'playNext',
                  );
              if (context.mounted) {
                showAppNotice(
                  context,
                  message: l10n.librarySongPlayNextQueued(song.title),
                  level: AppNoticeLevel.success,
                );
              }
              return;
            case 'add-queue':
              ref
                  .read(queueProvider.notifier)
                  .fireAndForget(
                    () => ref.read(queueProvider.notifier).addWithSong(song),
                    label: 'addToQueue',
                  );
              if (context.mounted) {
                showAppNotice(
                  context,
                  message: l10n.librarySongAddedToQueue(song.title),
                  level: AppNoticeLevel.success,
                );
              }
              return;
            case 'add-playlist':
              unawaited(showAddToPlaylistSheet(context, ref, [song.id]));
              return;
            case 'instant-mix':
              unawaited(activatePreferredMixMode(ref, seedSongId: song.id));
              return;
            default:
              return;
          }
        }),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text(l10n.searchPlayNext),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(queueProvider.notifier)
                    .fireAndForget(
                      () => ref
                          .read(queueProvider.notifier)
                          .playNextWithSong(song),
                      label: 'playNext',
                    );
                if (context.mounted) {
                  showAppNotice(
                    context,
                    message: l10n.librarySongPlayNextQueued(song.title),
                    level: AppNoticeLevel.success,
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(l10n.searchAddToQueue),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(queueProvider.notifier)
                    .fireAndForget(
                      () => ref.read(queueProvider.notifier).addWithSong(song),
                      label: 'addToQueue',
                    );
                if (context.mounted) {
                  showAppNotice(
                    context,
                    message: l10n.librarySongAddedToQueue(song.title),
                    level: AppNoticeLevel.success,
                  );
                }
              },
            ),
            if (song.albumId != null)
              ListTile(
                leading: const Icon(Icons.album),
                title: Text(l10n.nowPlayingGoToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.openAlbumDetail(
                    context,
                    ref,
                    song.albumId!,
                    name: song.album,
                    artistName: song.artist,
                  );
                },
              ),
            if (song.artistId != null)
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(l10n.nowPlayingGoToArtist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.openArtistDetail(
                    context,
                    ref,
                    song.artistId!,
                    name: song.artist,
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: Text(l10n.librarySongMenuAddToPlaylist),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(showAddToPlaylistSheet(context, ref, [song.id]));
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore),
              title: Text(l10n.nowPlayingInstantMix),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(activatePreferredMixMode(ref, seedSongId: song.id));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultMetadata extends StatelessWidget {
  const new({required this.text, required this.isRemote});

  final String text;
  final bool isRemote;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return RemoteSourceMetadataLine(
      metadata: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
      isRemote: isRemote,
      spacing: text.isEmpty ? 0 : 8,
    );
  }
}
