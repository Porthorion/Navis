import 'dart:async';
import 'dart:convert';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/settings/presentation/appearance_layout.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/motion_policy.dart';

class InterfaceSettingsScreen extends ConsumerStatefulWidget {
  const new({this.focusLibraryPages = false, super.key});

  /// Scrolls to the Library pages section and briefly highlights the
  /// Genres row (the link from a genre chip while the page is hidden).
  final bool focusLibraryPages;

  @override
  ConsumerState<InterfaceSettingsScreen> createState() =>
      _InterfaceSettingsScreenState();
}

class _InterfaceSettingsScreenState
    extends ConsumerState<InterfaceSettingsScreen> {
  final GlobalKey _libraryPagesKey = GlobalKey();
  Timer? _highlightTimer;
  bool _highlightGenres = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusLibraryPages) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _libraryPagesKey.currentContext;
        if (!mounted || target == null) return;
        Scrollable.ensureVisible(
          target,
          alignment: 0.02,
          duration: MotionPolicy.of(context).surface,
          curve: Curves.easeOutCubic,
        );
        setState(() => _highlightGenres = true);
        _highlightTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted) setState(() => _highlightGenres = false);
        });
      });
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appLocale = ref.watch(appLocaleProvider);
    final languageControlVisible = bool.fromEnvironment(
      'NAVIS_SHOW_LANGUAGE_SETTINGS',
    );
    final languageControlEnabled = AppLocalizations.supportedLocales.length > 1;
    final persistedOrder = ref.watch(homeSectionOrderProvider);
    final sanitizedOrder = HomeSectionIds.resolveOrder(persistedOrder);
    final sanitizedHidden = HomeSectionIds.resolveHidden(
      ref.watch(homeSectionsHiddenProvider),
      persistedOrder: persistedOrder,
    );
    final libraryPageOrder = ref.watch(libraryPageOrderProvider);
    final isDesktop = resolveAdaptiveContextFor(context).useDesktopShell;
    // Quick Actions are now always-visible below the home logo; remove from
    // the section reorder list on all platforms.
    final displayOrder = sanitizedOrder
        .where((id) => id != HomeSectionIds.quickActions)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isDesktop,
        leading: isDesktop
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.settings),
              )
            : null,
        title: Text(l10n.settingsInterfaceTitle),
      ),
      body: AppearanceVisitScope(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
              // A deep link to the Library pages section needs it built to
              // scroll to. The extent is finite: an infinite one breaks the
              // semantics tree.
              scrollCacheExtent: widget.focusLibraryPages
                  ? const ScrollCacheExtent.pixels(20000)
                  : null,
              padding: EdgeInsets.symmetric(vertical: isDesktop ? 24 : 8),
              children: <Widget>[
                if (languageControlVisible) ...[
                  AppearanceHeading(title: l10n.appearanceLanguageLabel),
                  _LanguageSelector(
                    appLocale: appLocale,
                    enabled: languageControlEnabled,
                    onChanged: (localeCode) async {
                      final db = ref.read(navisDatabaseProvider);
                      await db.appSettingsDao.updateAppLocale(localeCode);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                AppearanceHeading(
                  title: l10n.interfaceSongTitlesHeading,
                  level: AppearanceHeadingLevel.section,
                ),
                NavisSwitchListTile(
                  contentPadding: appearanceSwitchPadding(context),
                  title: Text(l10n.appearanceKeepTitleVersionLabel),
                  subtitle: Text(l10n.appearanceKeepTitleVersionSub),
                  value: ref.watch(keepTitleVersionVisibleProvider),
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateKeepTitleVersionVisible(
                      enabled: enabled,
                    );
                  },
                ),
                AppearanceHeading(
                  title: l10n.appearanceHomeSectionsLabel,
                  level: AppearanceHeadingLevel.section,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (!resolveAdaptiveContextFor(context).desktopRuntime)
                      NavisSwitchListTile(
                        title: Text(l10n.appearanceRecommendationsAutoAdvance),
                        subtitle: Text(
                          l10n.appearanceRecommendationsAutoAdvanceSub,
                        ),
                        value: ref.watch(
                          homeRecommendationsAutoAdvanceProvider,
                        ),
                        onChanged: (value) async {
                          await ref
                              .read(navisDatabaseProvider)
                              .appSettingsDao
                              .updateHomeRecommendationsAutoAdvance(
                                enabled: value,
                              );
                        },
                      ),
                    _HomeSectionReorder(
                      order: displayOrder,
                      hidden: sanitizedHidden,
                      onReorder: (newOrder) async {
                        final db = ref.read(navisDatabaseProvider);
                        await db.appSettingsDao.updateHomeSectionOrder(
                          jsonEncode(newOrder),
                        );
                      },
                      onToggleVisibility:
                          (sectionId, {required visible}) async {
                            final db = ref.read(navisDatabaseProvider);
                            final current = List<String>.from(sanitizedHidden);
                            if (visible) {
                              current.remove(sectionId);
                            } else {
                              if (!current.contains(sectionId)) {
                                current.add(sectionId);
                              }
                            }
                            // [] is "hide nothing"; null would bring the
                            // built-in hidden sections back.
                            await db.appSettingsDao.updateHomeSectionsHidden(
                              jsonEncode(current),
                            );
                            // A hidden-by-default section the user has never
                            // seen resolves hidden again unless the order
                            // marks it as seen (see resolveHidden).
                            if (visible &&
                                HomeSectionIds.resolveHidden(
                                  current,
                                  persistedOrder: persistedOrder,
                                ).contains(sectionId)) {
                              await db.appSettingsDao.updateHomeSectionOrder(
                                jsonEncode(sanitizedOrder),
                              );
                            }
                          },
                    ),
                  ],
                ),
                AppearanceHeading(
                  key: _libraryPagesKey,
                  title: l10n.appearancePagesSectionLabel,
                  level: AppearanceHeadingLevel.section,
                  adornment: Consumer(
                    builder: (context, ref, _) =>
                        AppearanceVisitScope.isTagged(
                          context,
                          ref,
                          SetupHighlight.genresPage,
                        )
                        ? const NewFeatureTag()
                        : const SizedBox.shrink(),
                  ),
                ),
                _LibraryPageReorder(
                  highlighted: _highlightGenres ? LibrarySection.genres : null,
                  order: libraryPageOrder,
                  visibleSections: visibleLibrarySections(
                    orderedSections: libraryPageOrder,
                    showAlbums: ref.watch(showAlbumsPageProvider),
                    showLiked: ref.watch(showLikedPageProvider),
                    showArtists: ref.watch(showArtistsPageProvider),
                    showGenres: ref.watch(showGenresPageProvider),
                    showPlaylists: ref.watch(showPlaylistsPageProvider),
                    showRadio: ref.watch(showRadioPageProvider),
                  ).toSet(),
                  onReorder: (newOrder) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateLibraryPageOrder(
                      jsonEncode(
                        newOrder.map((section) => section.name).toList(),
                      ),
                    );
                  },
                  onToggleVisibility: (section, {required visible}) async {
                    final db = ref.read(navisDatabaseProvider);
                    switch (section) {
                      case LibrarySection.albums:
                        await db.appSettingsDao.updateShowAlbumsPage(
                          enabled: visible,
                        );
                      case LibrarySection.liked:
                        await db.appSettingsDao.updateShowLikedPage(
                          enabled: visible,
                        );
                      case LibrarySection.artists:
                        await db.appSettingsDao.updateShowArtistsPage(
                          enabled: visible,
                        );
                      case LibrarySection.genres:
                        await db.appSettingsDao.updateShowGenresPage(
                          enabled: visible,
                        );
                      case LibrarySection.playlists:
                        await db.appSettingsDao.updateShowPlaylistsPage(
                          enabled: visible,
                        );
                      case LibrarySection.radio:
                        await db.appSettingsDao.updateShowRadioPage(
                          enabled: visible,
                        );
                    }
                  },
                ),
                if (isDesktop) ...[
                  AppearanceHeading(
                    title: l10n.desktopNavbarSectionLabel,
                    level: AppearanceHeadingLevel.section,
                  ),
                  _DesktopNavbarSettings(
                    currentStyle: ref.watch(desktopNavbarStyleProvider),
                    autohideEnabled: ref.watch(desktopNavbarAutohideProvider),
                    onStyleChanged: (style) async {
                      final db = ref.read(navisDatabaseProvider);
                      await db.appSettingsDao.updateDesktopNavbarStyle(style);
                    },
                    onAutohideChanged: (enabled) async {
                      final db = ref.read(navisDatabaseProvider);
                      await db.appSettingsDao.updateDesktopNavbarAutohide(
                        enabled,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _localeLabel(Locale locale, AppLocalizations l10n) {
  switch (locale.languageCode) {
    case 'en':
      return l10n.appearanceLanguageEnglish;
    default:
      return locale.languageCode;
  }
}

class _LanguageSelector extends StatelessWidget {
  const new({
    required this.appLocale,
    required this.enabled,
    required this.onChanged,
  });

  final String? appLocale;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: appLocale,
        decoration: InputDecoration(
          helperText: enabled ? null : l10n.appearanceLanguageUnavailable,
        ),
        items: <DropdownMenuItem<String?>>[
          DropdownMenuItem<String?>(
            value: null,
            child: Text(l10n.appearanceLanguageSystemDefault),
          ),
          ...AppLocalizations.supportedLocales.map(
            (locale) => DropdownMenuItem<String?>(
              value: locale.languageCode,
              child: Text(_localeLabel(locale, l10n)),
            ),
          ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home section reorder + visibility toggle
// ---------------------------------------------------------------------------

class _HomeSectionReorder extends StatefulWidget {
  const new({
    required this.order,
    required this.hidden,
    required this.onReorder,
    required this.onToggleVisibility,
  });

  final List<String> order;
  final List<String> hidden;
  final ValueChanged<List<String>> onReorder;
  final void Function(String sectionId, {required bool visible})
  onToggleVisibility;

  @override
  State<_HomeSectionReorder> createState() => _HomeSectionReorderState();
}

class _HomeSectionReorderState extends State<_HomeSectionReorder> {
  late List<String> _localOrder;

  @override
  void initState() {
    super.initState();
    _localOrder = List<String>.from(widget.order);
  }

  @override
  void didUpdateWidget(covariant _HomeSectionReorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.order != widget.order) {
      _localOrder = List<String>.from(widget.order);
    }
  }

  String _sectionLabel(String id, AppLocalizations l10n) {
    switch (id) {
      case HomeSectionIds.recentlyLikedAlbums:
        return l10n.homeSectionRecentlyLikedAlbums;
      case HomeSectionIds.likedTracks:
        return l10n.homeSectionLikedTracks;
      case HomeSectionIds.recentlyAdded:
        return l10n.homeSectionRecentlyAdded;
      case HomeSectionIds.randomAlbumList:
        return l10n.homeSectionRandomAlbumList;
      case HomeSectionIds.recentlyPlayed:
        return l10n.homeSectionRecentlyPlayed;
      case HomeSectionIds.randomAlbums:
        return l10n.homeSectionRandomAlbums;
      case HomeSectionIds.mostPlayed:
        return l10n.homeSectionMostPlayed;
      case HomeSectionIds.recentlyPlayedTracks:
        return l10n.homeSectionRecentlyPlayedTracks;
      case HomeSectionIds.frequentAlbums:
        return l10n.homeSectionFrequentAlbums;
      case HomeSectionIds.newReleases:
        return l10n.homeSectionNewReleases;
      case HomeSectionIds.quickActions:
        return l10n.homeSectionQuickActions;
      default:
        return id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _localOrder.length,
      onReorderStart: (_) =>
          NavisHaptics.dragStart(HapticCategory.listsAndMenus),
      onReorderEnd: (_) => NavisHaptics.dragEnd(HapticCategory.listsAndMenus),
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          final item = _localOrder.removeAt(oldIndex);
          _localOrder.insert(newIndex, item);
        });
        widget.onReorder(_localOrder);
      },
      itemBuilder: (context, index) {
        final id = _localOrder[index];
        final isHidden = widget.hidden.contains(id);
        return Material(
          key: ValueKey(id),
          color: Colors.transparent,
          child: ListTile(
            leading: ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
            title: Text(
              _sectionLabel(id, l10n),
              style: isHidden
                  ? theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(100),
                    )
                  : null,
            ),
            trailing: NavisSwitch(
              value: !isHidden,
              onChanged: (visible) =>
                  widget.onToggleVisibility(id, visible: visible),
            ),
          ),
        );
      },
    );
  }
}

class _LibraryPageReorder extends StatefulWidget {
  const new({
    required this.order,
    required this.visibleSections,
    required this.onReorder,
    required this.onToggleVisibility,
    this.highlighted,
  });

  /// The row shown with a highlight background, if any.
  final LibrarySection? highlighted;
  final List<LibrarySection> order;
  final Set<LibrarySection> visibleSections;
  final ValueChanged<List<LibrarySection>> onReorder;
  final void Function(LibrarySection section, {required bool visible})
  onToggleVisibility;

  @override
  State<_LibraryPageReorder> createState() => _LibraryPageReorderState();
}

class _LibraryPageReorderState extends State<_LibraryPageReorder> {
  late List<LibrarySection> _localOrder;

  @override
  void initState() {
    super.initState();
    _localOrder = List<LibrarySection>.from(widget.order);
  }

  @override
  void didUpdateWidget(covariant _LibraryPageReorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.order != widget.order) {
      _localOrder = List<LibrarySection>.from(widget.order);
    }
  }

  String _sectionLabel(LibrarySection section, AppLocalizations l10n) {
    return switch (section) {
      LibrarySection.albums => l10n.libraryTabAlbums,
      LibrarySection.liked => l10n.libraryTabLiked,
      LibrarySection.artists => l10n.libraryTabArtists,
      LibrarySection.genres => l10n.libraryTabGenres,
      LibrarySection.playlists => l10n.navPlaylists,
      LibrarySection.radio => l10n.navRadio,
    };
  }

  String? _sectionSubtitle(LibrarySection section, AppLocalizations l10n) {
    return switch (section) {
      LibrarySection.albums => null,
      LibrarySection.liked => l10n.appearanceShowLikedPageSubtitle,
      LibrarySection.artists => l10n.appearanceShowArtistsPageSubtitle,
      LibrarySection.genres => l10n.appearanceShowGenresPageSubtitle,
      LibrarySection.playlists => l10n.appearanceShowPlaylistsPageSubtitle,
      LibrarySection.radio => l10n.appearanceShowRadioPageSubtitle,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _localOrder.length,
      onReorderStart: (_) =>
          NavisHaptics.dragStart(HapticCategory.listsAndMenus),
      onReorderEnd: (_) => NavisHaptics.dragEnd(HapticCategory.listsAndMenus),
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          final item = _localOrder.removeAt(oldIndex);
          _localOrder.insert(newIndex, item);
        });
        widget.onReorder(_localOrder);
      },
      itemBuilder: (context, index) {
        final section = _localOrder[index];
        final visible = widget.visibleSections.contains(section);
        final label = _sectionLabel(section, l10n);
        final titleStyle = !visible
            ? theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(100),
              )
            : null;
        final subtitle = _sectionSubtitle(section, l10n);
        return Material(
          key: ValueKey<String>('library-page-${section.name}'),
          borderRadius: NavisShapeData.of(context).mdAll,
          // primaryContainer is near-black in dark themes, so tint the accent.
          color: widget.highlighted == section
              ? theme.colorScheme.primary.withValues(alpha: 0.22)
              : Colors.transparent,
          child: ListTile(
            leading: ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
            title: section == LibrarySection.genres
                ? HighlightedAppearanceOption(
                    highlight: SetupHighlight.genresPage,
                    builder: (context, adornment) =>
                        titleWithAdornment(label, adornment, style: titleStyle),
                  )
                : Text(label, style: titleStyle),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: NavisSwitch(
              value: visible,
              onChanged: (enabled) =>
                  widget.onToggleVisibility(section, visible: enabled),
            ),
          ),
        );
      },
    );
  }
}

class _DesktopNavbarSettings extends StatelessWidget {
  const new({
    required this.currentStyle,
    required this.autohideEnabled,
    required this.onStyleChanged,
    required this.onAutohideChanged,
  });

  final String currentStyle;
  final bool autohideEnabled;
  final ValueChanged<String> onStyleChanged;
  final ValueChanged<bool> onAutohideChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = (currentStyle == 'comfortable' || currentStyle == 'icons')
        ? currentStyle
        : 'compact';

    final colorStyle = NavisColorStyleData.of(context);
    Widget styleOption({
      required String value,
      required String label,
      required IconData icon,
    }) {
      final isSelected = selected == value;
      return Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: () => onStyleChanged(value),
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              backgroundColor: isSelected
                  ? colorStyle.tonalControlFill(colorScheme)
                  : colorScheme.surfaceContainerLow,
              foregroundColor: isSelected
                  ? colorStyle.onTonalControlFill(colorScheme)
                  : colorScheme.onSurfaceVariant,
              shape: NavisShapeData.of(context).mdShape,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.desktopNavbarStyleLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              color: colorScheme.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              styleOption(
                value: 'compact',
                label: l10n.desktopNavbarStyleDefault,
                icon: Icons.view_compact_alt_outlined,
              ),
              const SizedBox(width: 8),
              styleOption(
                value: 'comfortable',
                label: l10n.desktopNavbarStyleLarge,
                icon: Icons.view_sidebar_outlined,
              ),
              const SizedBox(width: 8),
              styleOption(
                value: 'icons',
                label: l10n.desktopNavbarStyleIcons,
                icon: Icons.more_vert_rounded,
              ),
            ],
          ),
        ),
        NavisSwitchListTile(
          title: Text(l10n.desktopNavbarAutohideLabel),
          subtitle: Text(l10n.desktopNavbarAutohideSub),
          value: autohideEnabled,
          onChanged: onAutohideChanged,
        ),
      ],
    );
  }
}
