import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:navis/src/features/settings/domain/color_namer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/settings/presentation/appearance_layout.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_pickers.dart';
import 'package:navis/src/features/settings/presentation/color_tuning_panel.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/corner_style_provider.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentMode = ref.watch(themeModeProvider);
    final currentSeed = ref.watch(colorSchemeSeedProvider);
    final currentStyle = ref.watch(colorStyleProvider);
    final previewSeed = resolveColorSchemeSeedColor(
      ref.watch(effectiveColorSchemeSeedProvider),
    );
    final previewBrightness = switch (currentMode) {
      'light' => Brightness.light,
      'system' => MediaQuery.platformBrightnessOf(context),
      _ => Brightness.dark,
    };
    final oledForAuto = ref.watch(oledForAutoProvider);
    final previewOled =
        currentMode == 'oled' ||
        (currentMode == 'system' &&
            oledForAuto &&
            previewBrightness == Brightness.dark);
    final dynamicAlbumColorEnabled = ref.watch(
      dynamicAlbumColorEnabledProvider,
    );
    final customPresetsAsync = ref.watch(customColorPresetsProvider);
    final customPresets = customPresetsAsync.asData?.value ?? <int>[];
    final appLocale = ref.watch(appLocaleProvider);
    final languageControlVisible = bool.fromEnvironment(
      'NAVIS_SHOW_LANGUAGE_SETTINGS',
    );
    final languageControlEnabled = AppLocalizations.supportedLocales.length > 1;
    final theme = Theme.of(context);
    final persistedOrder = ref.watch(homeSectionOrderProvider);
    final sanitizedOrder = HomeSectionIds.resolveOrder(persistedOrder);
    final sanitizedHidden = HomeSectionIds.resolveHidden(
      ref.watch(homeSectionsHiddenProvider),
      persistedOrder: persistedOrder,
    );
    final libraryPageOrder = ref.watch(libraryPageOrderProvider);
    final isDesktop = resolveAdaptiveContextFor(context).useDesktopShell;
    final tuningState = ref.watch(colorTuningControllerProvider);
    final options = AppearanceOptionSet(
      oledForAutoVisible: currentMode == 'system',
      oledForAuto: oledForAuto,
      onOledForAutoChanged: (enabled) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateOledForAuto(enabled: enabled);
      },
      nightSchedule: ref.watch(nightScheduleProvider),
      userStyle: currentStyle,
      now: ref.watch(nowProvider)(),
      onNightScheduleChanged: (schedule) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateNightSchedule(
          enabled: schedule.enabled,
          startMinutes: schedule.startMinutes,
          endMinutes: schedule.endMinutes,
        );
      },
      flatSurfaces: ref.watch(flatSurfacesProvider),
      onFlatSurfacesChanged: (enabled) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateFlatSurfaces(enabled: enabled);
      },
      flatAreas: ref.watch(flatAreasProvider),
      onFlatAreasChanged: (areas) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateFlatAreas(areas.bits);
      },
      albumArtShade: ref.watch(albumArtShadeProvider),
      onAlbumArtShadeChanged: (enabled) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateAlbumArtShade(enabled: enabled);
      },
      albumArtColoredShade: ref.watch(albumArtColoredShadeProvider),
      onAlbumArtColoredShadeChanged: (enabled) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateAlbumArtColoredShade(enabled: enabled);
      },
      cornerStyle: ref.watch(cornerStyleProvider),
      onCornerStyleChanged: (style) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateCornerStyle(style.name);
      },
      density: ref.watch(densityProvider),
      onDensityChanged: (density) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateDensity(density);
      },
      nowPlayingBackground: ref.watch(nowPlayingBackgroundProvider),
      onNowPlayingBackgroundChanged: (background) async {
        final db = ref.read(navisDatabaseProvider);
        await db.appSettingsDao.updateNowPlayingBackground(
          background.storageKey,
        );
      },
      colorTuning: tuningState.tuning,
      onOpenColorTuning: (anchor) => unawaited(_openColorTuning(anchor, ref)),
      previewBrightness: previewBrightness,
      previewOled: previewOled,
    );
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
        title: Text(l10n.appearanceTitle),
      ),
      body: AppearanceVisitScope(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
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

                // ── Looks ───────────────────────────────────────────────
                const AppearanceLooksOption(),
                const Divider(height: 32),

                // ── Theme ───────────────────────────────────────────────
                AppearanceHeading(
                  title: l10n.appearanceSectionTheme,
                  level: AppearanceHeadingLevel.section,
                  topPadding: NavisSpace.xs,
                ),
                AppearanceHeading(title: l10n.appearanceThemeModeLabel),
                ThemeModeSelector(
                  currentMode: currentMode,
                  onChanged: (mode) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateThemeMode(mode);
                  },
                ),
                ...options.buildAll(const <AppearanceOptionKind>[
                  AppearanceOptionKind.oledForAuto,
                ]),
                const Divider(height: 32),

                // ── Color ───────────────────────────────────────────────
                AppearanceHeading(
                  title: l10n.appearanceSectionColor,
                  level: AppearanceHeadingLevel.section,
                  topPadding: 0,
                ),
                ColorStyleOption(
                  currentStyle: currentStyle,
                  seed: previewSeed,
                  brightness: previewBrightness,
                  oled: previewOled,
                  onChanged: (style) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateColorStyle(style.storageKey);
                  },
                ),
                ...options.buildAll(const <AppearanceOptionKind>[
                  AppearanceOptionKind.colorTuning,
                  AppearanceOptionKind.nightSchedule,
                ]),
                AppearanceHeading(
                  title: l10n.appearanceColorSchemeLabel,
                  topPadding: NavisSpace.md,
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppearanceLayout.gutterOf(context),
                    vertical: 8,
                  ),
                  child: Text(
                    l10n.appearanceColorSchemeSub,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                ColorSchemeGrid(
                  currentSeed: currentSeed,
                  style: currentStyle,
                  dynamicAlbumColorEnabled: dynamicAlbumColorEnabled,
                  customPresets: customPresets,
                  onSelected: (seed) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateColorSchemeSeed(
                      _normalizeColorSchemeSeed(seed),
                    );
                  },
                  onCustomColorPicked: (colorValue) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateColorSchemeSeed(
                      _normalizeColorSchemeSeed(colorValue),
                    );
                  },
                  onSavePreset: (colorValue) async {
                    if (_normalizeColorSchemeSeed(colorValue) == null) return;
                    final db = ref.read(navisDatabaseProvider);
                    final updated = {
                      ...customPresets,
                      colorValue,
                    }.toList(growable: false);
                    await db.appSettingsDao.updateCustomColorPresets(
                      jsonEncode(updated),
                    );
                    if (context.mounted) {
                      AppNoticeMessenger.of(context).clearSnackBars();
                      showAppNotice(
                        context,
                        message: l10n.appearanceColorPresetSaved,
                        level: AppNoticeLevel.success,
                      );
                    }
                  },
                  onDeletePreset: (colorValue) async {
                    final confirmed = await showConfirmDialog(
                      context,
                      title: l10n.appearanceColorDeletePreset,
                      message: l10n.appearanceColorDeletePresetConfirm,
                      confirmLabel: l10n.appearanceColorDeletePreset,
                    );
                    if (!confirmed || !context.mounted) return;
                    final db = ref.read(navisDatabaseProvider);
                    final updated = List<int>.from(customPresets)
                      ..remove(colorValue);
                    await db.appSettingsDao.updateCustomColorPresets(
                      updated.isEmpty ? null : jsonEncode(updated),
                    );
                    if (currentSeed == colorValue) {
                      await db.appSettingsDao.updateColorSchemeSeed(null);
                    }
                    if (context.mounted) {
                      AppNoticeMessenger.of(context).clearSnackBars();
                      showAppNotice(
                        context,
                        message: l10n.appearanceColorPresetDeleted,
                        level: AppNoticeLevel.success,
                      );
                    }
                  },
                ),
                SwitchListTile(
                  contentPadding: appearanceSwitchPadding(context),
                  title: Text(l10n.appearanceDynamicAlbumColorLabel),
                  subtitle: Text(l10n.appearanceDynamicAlbumColorSub),
                  value: dynamicAlbumColorEnabled,
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateDynamicAlbumColorEnabled(
                      enabled: enabled,
                    );
                  },
                ),
                options.buildAlbumArtShade(),
                const Divider(height: 32),

                // ── Shape & Layout ──────────────────────────────────────
                AppearanceHeading(
                  title: l10n.appearanceSectionShapeLayout,
                  level: AppearanceHeadingLevel.section,
                  topPadding: 0,
                ),
                ...options.buildAll(const <AppearanceOptionKind>[
                  AppearanceOptionKind.flatSurfaces,
                  AppearanceOptionKind.cornerStyle,
                ]),
                AppearanceHeading(
                  title: l10n.appearanceCoverArtShapeLabel,
                  topPadding: NavisSpace.md,
                ),
                _ShapeSelector(
                  label: l10n.appearanceCoverArtShapeSubLabel,
                  value: ref.watch(coverArtShapeProvider),
                  includeCircle: false,
                  onChanged: (shape) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateCoverArtShape(shape);
                  },
                ),
                _ShapeSelector(
                  label: l10n.appearanceNpArtShapeLabel,
                  value: ref.watch(nowPlayingArtShapeProvider),
                  onChanged: (shape) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateNowPlayingArtShape(shape);
                  },
                ),
                _ShapeSelector(
                  label: l10n.appearanceArtistCardShapeLabel,
                  value: ref.watch(artistCardShapeProvider),
                  onChanged: (shape) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateArtistCardShape(shape);
                  },
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppearanceLayout.gutterOf(context),
                    vertical: NavisSpace.xxs,
                  ),
                  child: Text(
                    l10n.appearanceCoverArtShapeNote,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                AppearanceHeading(
                  title: l10n.appearanceArtworkSizeLabel,
                  topPadding: NavisSpace.md,
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppearanceLayout.gutterOf(context),
                    vertical: 4,
                  ),
                  child: Text(
                    l10n.appearanceArtworkSizeSub,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _ArtworkSizeSelector(
                  current: ref.watch(gridArtworkSizeProvider),
                  onChanged: (density) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateGridArtworkSize(density.name);
                  },
                ),
                ...options.buildAll(const <AppearanceOptionKind>[
                  AppearanceOptionKind.density,
                ]),
                AppearanceHeading(
                  title: l10n.appearanceArtistViewModeLabel,
                  topPadding: NavisSpace.md,
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppearanceLayout.gutterOf(context),
                    vertical: 8,
                  ),
                  child: SegmentedButton<String>(
                    segments: <ButtonSegment<String>>[
                      ButtonSegment<String>(
                        value: 'list',
                        label: Text(l10n.appearanceArtistViewModeList),
                        icon: const Icon(Icons.view_list),
                      ),
                      ButtonSegment<String>(
                        value: 'grid',
                        label: Text(l10n.appearanceArtistViewModeGrid),
                        icon: const Icon(Icons.grid_view),
                      ),
                    ],
                    selected: {ref.watch(artistViewModeProvider)},
                    onSelectionChanged: (selection) async {
                      if (selection.isNotEmpty) {
                        final db = ref.read(navisDatabaseProvider);
                        await db.appSettingsDao.updateArtistViewMode(
                          selection.first,
                        );
                      }
                    },
                    showSelectedIcon: false,
                  ),
                ),
                const Divider(height: 32),

                // ── Now Playing ─────────────────────────────────────────
                AppearanceHeading(
                  title: l10n.appearanceSectionNowPlaying,
                  level: AppearanceHeadingLevel.section,
                  topPadding: 0,
                ),
                ...options.buildAll(const <AppearanceOptionKind>[
                  AppearanceOptionKind.nowPlayingBackground,
                ]),
                const Divider(height: 32),

                SettingsCollapsibleGroup(
                  leading: const Icon(Icons.home_outlined),
                  title: l10n.appearanceHomeSectionsLabel,
                  initiallyExpanded: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (!resolveAdaptiveContextFor(context).desktopRuntime)
                        SwitchListTile(
                          title: Text(
                            l10n.appearanceRecommendationsAutoAdvance,
                          ),
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
                              final current = List<String>.from(
                                sanitizedHidden,
                              );
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
                ),
                const Divider(height: 24),

                SettingsCollapsibleGroup(
                  leading: const _BlinkingEyeIcon(),
                  title: l10n.appearancePagesSectionLabel,
                  initiallyExpanded: false,
                  child: _LibraryPageReorder(
                    order: libraryPageOrder,
                    visibleSections: visibleLibrarySections(
                      orderedSections: libraryPageOrder,
                      showAlbums: ref.watch(showAlbumsPageProvider),
                      showLiked: ref.watch(showLikedPageProvider),
                      showArtists: ref.watch(showArtistsPageProvider),
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
                ),
                if (isDesktop) ...[
                  const Divider(height: 24),
                  SettingsCollapsibleGroup(
                    leading: const Icon(Icons.view_sidebar_outlined),
                    title: l10n.desktopNavbarSectionLabel,
                    initiallyExpanded: false,
                    child: _DesktopNavbarSettings(
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
                  ),
                ],
                const SizedBox(height: 8),
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

class SettingsCollapsibleGroup extends StatefulWidget {
  const new({
    required this.leading,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.outerPadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    this.buildCollapsed = true,
    super.key,
  });

  final Widget leading;
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  /// Space around the card.
  final EdgeInsetsGeometry outerPadding;

  /// Whether [child] stays built (but hidden) while collapsed. Setup turns
  /// this off so hidden options are neither focusable nor counted as shown.
  final bool buildCollapsed;

  @override
  State<SettingsCollapsibleGroup> createState() =>
      SettingsCollapsibleGroupState();
}

class SettingsCollapsibleGroupState extends State<SettingsCollapsibleGroup> {
  static const Duration _duration = Duration(milliseconds: 220);
  bool _expanded = false;
  bool _childBuilt = true;
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _childBuilt = widget.buildCollapsed || _expanded;
  }

  @override
  void didUpdateWidget(SettingsCollapsibleGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A group that was told late to start open (its trigger loads
    // asynchronously) still opens, unless the user already chose.
    if (!_userToggled && widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      _childBuilt = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: widget.outerPadding,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: NavisShapeData.of(context).mdAll,
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: NavisShapeData.of(context).mdAll,
              onTap: () {
                final nextExpanded = !_expanded;
                setState(() {
                  _userToggled = true;
                  _expanded = nextExpanded;
                  if (nextExpanded) _childBuilt = true;
                });
                if (!nextExpanded) {
                  return;
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) {
                    return;
                  }
                  Scrollable.ensureVisible(
                    context,
                    alignment: 0.02,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                  );
                });
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Row(
                  children: <Widget>[
                    IconTheme.merge(
                      data: IconThemeData(
                        color: theme.colorScheme.primary,
                        size: 22,
                      ),
                      child: widget.leading,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.title,
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: _duration,
                      curve: Curves.easeOutCubic,
                      child: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
            ),
            ClipRect(
              child: AnimatedAlign(
                alignment: Alignment.topCenter,
                heightFactor: _expanded ? 1 : 0,
                duration: _duration,
                curve: Curves.easeOutCubic,
                onEnd: () {
                  if (!_expanded && !widget.buildCollapsed && _childBuilt) {
                    setState(() => _childBuilt = false);
                  }
                },
                child: AnimatedOpacity(
                  opacity: _expanded ? 1 : 0,
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutCubic,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _childBuilt ? widget.child : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlinkingEyeIcon extends StatefulWidget {
  const new();

  @override
  State<_BlinkingEyeIcon> createState() => _BlinkingEyeIconState();
}

class _BlinkingEyeIconState extends State<_BlinkingEyeIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _blinkScaleY(double t) {
    if (t < 0.78) return 1;
    if (t < 0.86) return _lerp(1, 0.1, (t - 0.78) / 0.08);
    if (t < 0.94) return _lerp(0.1, 1, (t - 0.86) / 0.08);
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scaleY: _blinkScaleY(_controller.value),
          child: child,
        );
      },
      child: const Icon(Icons.remove_red_eye_outlined),
    );
  }
}

/// What Fine-Tune Colors paints from in Settings: the theme the app shows,
/// including the dynamic album colour, read fresh from the providers.
ColorTuningBasis _settingsTuningBasis(WidgetRef ref, Brightness platform) {
  final mode = ref.read(themeModeProvider);
  final oledForAuto = ref.read(oledForAutoProvider);
  final brightness = switch (mode) {
    'light' => Brightness.light,
    'system' => platform,
    _ => Brightness.dark,
  };
  return ColorTuningBasis(
    seed: resolveColorSchemeSeedColor(
      ref.read(effectiveColorSchemeSeedProvider),
    ),
    style: ref.read(effectiveColorStyleProvider),
    brightness: brightness,
    oled:
        mode == 'oled' ||
        (mode == 'system' && oledForAuto && brightness == Brightness.dark),
    darkIsOled: mode == 'oled' || (mode == 'system' && oledForAuto),
  );
}

/// Opens Fine-Tune Colors over the Settings controller: the rulers preview
/// through it, save through it, and follow its tuning when a Look is applied,
/// and the strips follow the effective theme (a new track's album colour).
Future<void> _openColorTuning(BuildContext anchor, WidgetRef ref) async {
  final controller = ref.read(colorTuningControllerProvider.notifier);
  final platform = MediaQuery.platformBrightnessOf(anchor);
  final basis = ValueNotifier<ColorTuningBasis>(
    _settingsTuningBasis(ref, platform),
  );
  final live = ValueNotifier<ColorTuning>(
    ref.read(colorTuningControllerProvider).tuning,
  );
  void refresh() => basis.value = _settingsTuningBasis(ref, platform);
  final subscriptions = [
    ref.listenManual(
      colorTuningControllerProvider,
      (_, state) => live.value = state.tuning,
    ),
    ref.listenManual(effectiveColorSchemeSeedProvider, (_, _) => refresh()),
    ref.listenManual(effectiveColorStyleProvider, (_, _) => refresh()),
    ref.listenManual(themeModeProvider, (_, _) => refresh()),
    ref.listenManual(oledForAutoProvider, (_, _) => refresh()),
  ];
  try {
    await showColorTuningPanel(
      anchor,
      basis: basis,
      looksHint: true,
      tuning: live,
      onPreview: controller.preview,
      onCommit: (tuning) async {
        final failure = await controller.commit(tuning);
        if (failure == null || !anchor.mounted) return;
        showAppNotice(
          anchor,
          message: presetFailureMessage(AppLocalizations.of(anchor)!, failure),
          level: AppNoticeLevel.error,
        );
      },
      onPreviewEnd: controller.clearPreview,
    );
  } finally {
    for (final subscription in subscriptions) {
      subscription.close();
    }
    live.dispose();
    basis.dispose();
  }
}

/// Shared theme-mode control used by Appearance and first-run customization.
class ThemeModeSelector extends StatelessWidget {
  const new({super.key, required this.currentMode, required this.onChanged});

  final String currentMode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = <(String key, String label, IconData icon)>[
      ('light', l10n.appearanceThemeLight, Icons.light_mode_outlined),
      ('dark', l10n.appearanceThemeDark, Icons.dark_mode_outlined),
      ('oled', l10n.appearanceThemeOled, Icons.contrast),
      ('system', l10n.appearanceThemeSystem, Icons.settings_brightness),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 440;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppearanceLayout.gutterOf(context),
            vertical: 8,
          ),
          child: SegmentedButton<String>(
            segments: entries
                .map(
                  (e) => ButtonSegment<String>(
                    value: e.$1,
                    label: Text(
                      e.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? 11 : null),
                    ),
                    icon: Icon(e.$3),
                  ),
                )
                .toList(),
            selected: {currentMode},
            onSelectionChanged: (selection) {
              if (selection.isNotEmpty) onChanged(selection.first);
            },
            // Keep the familiar horizontal selector at every size. Removing its
            // default outer expansion leaves enough room for four labelled
            // segments on phones without turning it into a stacked control.
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
          ),
        );
      },
    );
  }
}

/// Shared accent-color control used by Appearance and first-run customization.
class ColorSchemeGrid extends StatelessWidget {
  const new({
    super.key,
    required this.currentSeed,
    required this.dynamicAlbumColorEnabled,
    required this.customPresets,
    required this.onSelected,
    required this.onCustomColorPicked,
    required this.onSavePreset,
    required this.onDeletePreset,
    this.style = NavisColorStyle.neutral,
  });

  final int? currentSeed;

  /// Colour style the swatches preview: each swatch is filled with its raw
  /// seed (so Night's many hues stay distinguishable) and carries a small dot
  /// with the accent the style will make from it.
  final NavisColorStyle style;
  final bool dynamicAlbumColorEnabled;
  final List<int> customPresets;
  final ValueChanged<int?> onSelected;
  final ValueChanged<int> onCustomColorPicked;
  final ValueChanged<int> onSavePreset;
  final ValueChanged<int> onDeletePreset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final swatches = _mergedColorSwatches(
      customPresets: customPresets,
      customLabel: l10n.appearanceColorCustom,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (dynamicAlbumColorEnabled)
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppearanceLayout.gutterOf(context),
              0,
              AppearanceLayout.gutterOf(context),
              4,
            ),
            child: Text(
              l10n.appearanceColorSchemeDynamicSub,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppearanceLayout.gutterOf(context),
            vertical: 8,
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _ColorChip(
                color: styledSwatchColor(
                  defaultColorSchemeSeedColor,
                  style,
                  adjustment: NavisColorStyleData.of(context).adjustment,
                ),
                seedColor: defaultColorSchemeSeedColor,
                label: l10n.appearanceColorDefault,
                isSelected: _normalizeColorSchemeSeed(currentSeed) == null,
                onTap: () => onSelected(null),
                theme: theme,
                valueKey: 'default',
              ),
              for (final swatch in swatches)
                _ColorChip(
                  color: styledSwatchColor(
                    swatch.color,
                    style,
                    adjustment: NavisColorStyleData.of(context).adjustment,
                  ),
                  seedColor: swatch.color,
                  label: swatch.label,
                  isSelected: currentSeed == swatch.colorValue,
                  onTap: () => onSelected(swatch.colorValue),
                  onLongPress: swatch.isCustom
                      ? () => onDeletePreset(swatch.colorValue)
                      : null,
                  theme: theme,
                  showDeleteHint: swatch.isCustom,
                  isCustom: swatch.isCustom,
                  valueKey: swatch.valueKey,
                ),
              _RainbowChip(
                theme: theme,
                label: l10n.appearanceColorCustom,
                onTap: () async {
                  // Pre-seed with the active color so the user continues from
                  // their current theme rather than always starting at red.
                  final seedColor = resolveColorSchemeSeedColor(currentSeed);
                  final result = await showDialog<_ColorPickerResult>(
                    context: context,
                    builder: (_) => _ColorPickerDialog(initialColor: seedColor),
                  );
                  if (result == null) return;
                  onCustomColorPicked(result.colorValue);
                  if (result.saveAsPreset) {
                    onSavePreset(result.colorValue);
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ColorSwatchEntry {
  const new({
    required this.label,
    required this.colorValue,
    required this.sortKey,
    required this.valueKey,
    this.isCustom = false,
  });

  final String label;
  final int colorValue;
  final double sortKey;
  final String valueKey;
  final bool isCustom;

  Color get color => Color(colorValue);
}

List<_ColorSwatchEntry> _mergedColorSwatches({
  required List<int> customPresets,
  required String customLabel,
}) {
  final defaultColorValue = defaultColorSchemeSeedColor.toARGB32();
  final builtInValues = <int>{defaultColorValue};
  final entries = <_ColorSwatchEntry>[];

  for (var i = 0; i < presetColors.length; i++) {
    final preset = presetColors[i];
    final colorValue = preset.color.toARGB32();
    builtInValues.add(colorValue);
    entries.add(
      _ColorSwatchEntry(
        label: preset.name,
        colorValue: colorValue,
        sortKey: i.toDouble(),
        valueKey: 'preset-$colorValue',
      ),
    );
  }

  final seenCustomValues = <int>{};
  for (final colorValue in customPresets) {
    if (builtInValues.contains(colorValue) ||
        !seenCustomValues.add(colorValue)) {
      continue;
    }
    entries.add(
      _ColorSwatchEntry(
        label: _customColorLabel(Color(colorValue), customLabel),
        colorValue: colorValue,
        sortKey: _customColorSortKey(Color(colorValue)),
        valueKey: 'custom-$colorValue',
        isCustom: true,
      ),
    );
  }

  entries.sort((a, b) {
    final bySort = a.sortKey.compareTo(b.sortKey);
    if (bySort != 0) return bySort;
    if (a.isCustom != b.isCustom) {
      return a.isCustom ? 1 : -1;
    }
    return a.colorValue.compareTo(b.colorValue);
  });

  return entries;
}

int? _normalizeColorSchemeSeed(int? colorValue) {
  return colorValue == defaultColorSchemeSeedColor.toARGB32()
      ? null
      : colorValue;
}

String _customColorLabel(Color color, String customLabel) {
  return '$customLabel: ${nameForColor(color)}';
}

double _customColorSortKey(Color color) {
  final hsv = HSVColor.fromColor(color);
  if (hsv.saturation < 0.08 && hsv.value > 0.92) {
    return -0.5;
  }
  if (hsv.saturation < 0.12) {
    return presetColors.length + (1 - hsv.value);
  }

  final firstLaterPreset = presetColors.indexWhere((preset) {
    final presetHsv = HSVColor.fromColor(preset.color);
    if (presetHsv.saturation < 0.12) {
      return false;
    }
    return presetHsv.hue >= hsv.hue;
  });
  if (firstLaterPreset < 0) {
    return presetColors.length - 4.0;
  }
  return firstLaterPreset - 0.25;
}

class _ColorChip extends StatelessWidget {
  const new({
    required this.color,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.theme,
    this.seedColor,
    this.onLongPress,
    this.showDeleteHint = false,
    this.isCustom = false,
    this.valueKey,
  });

  /// The accent the user gets (the seed under the colour style); fills the chip.
  final Color color;

  /// The raw seed, shown as a small dot so accents that the style makes
  /// near-identical stay distinguishable.
  final Color? seedColor;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ThemeData theme;
  final bool showDeleteHint;
  final bool isCustom;
  final String? valueKey;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final l10n = AppLocalizations.of(context)!;
    final colorBrightness = ThemeData.estimateBrightnessForColor(color);
    final checkColor = colorBrightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final child = Semantics(
      button: true,
      selected: isSelected,
      label: isCustom ? l10n.appearanceColorCustomSemantics(label) : label,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          key: valueKey == null
              ? null
              : ValueKey<String>('colorChip-$valueKey'),
          duration: const Duration(milliseconds: 200),
          width: size,
          height: size,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: isSelected ? 3 : 1,
            ),
            boxShadow:
                isSelected && !NavisColorStyleData.of(context).flatSurfaces
                ? <BoxShadow>[
                    BoxShadow(
                      color: theme.colorScheme.primary.withAlpha(72),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: colorBrightness == Brightness.light
                    ? Colors.black.withAlpha(56)
                    : Colors.white.withAlpha(36),
                width: 1,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                if (isSelected)
                  Container(
                    width: 27,
                    height: 27,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorBrightness == Brightness.light
                          ? Colors.white.withAlpha(210)
                          : Colors.black.withAlpha(130),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      color: checkColor,
                      size: 20,
                    ),
                  ),
                if (seedColor != null)
                  Positioned(
                    key: valueKey == null
                        ? null
                        : ValueKey<String>('seedDot-$valueKey'),
                    left: 3,
                    bottom: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: seedColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 1.5,
                        ),
                      ),
                      child: const SizedBox(width: 14, height: 14),
                    ),
                  ),
                if (isCustom)
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      key: valueKey == null
                          ? null
                          : ValueKey<String>('customColorBadge-$valueKey'),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.onSurface,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!isDesktopRuntime) return child;

    return Tooltip(
      message: showDeleteHint
          ? AppLocalizations.of(context)!.appearanceLongPressHint(label)
          : label,
      child: child,
    );
  }
}

class _RainbowChip extends StatelessWidget {
  const new({required this.theme, required this.label, required this.onTap});

  final ThemeData theme;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final child = Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: <Color>[
                Colors.red,
                Colors.orange,
                Colors.yellow,
                Colors.green,
                Colors.cyan,
                Colors.blue,
                Colors.purple,
                Colors.red,
              ],
            ),
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 24),
        ),
      ),
    );

    if (!isDesktopRuntime) return child;

    return Tooltip(message: label, child: child);
  }
}

// ---------------------------------------------------------------------------
// Color picker dialog
// ---------------------------------------------------------------------------

class _ColorPickerResult {
  const new({required this.colorValue, required this.saveAsPreset});
  final int colorValue;
  final bool saveAsPreset;
}

class _ColorPickerDialog extends StatefulWidget {
  const new({this.initialColor});

  /// If provided, the picker opens pre-seeded with this color.
  final Color? initialColor;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue;
  late double _saturation;
  late double _value;

  late final FocusNode _hexFocusNode;
  late final TextEditingController _hexController;

  Color get _currentColor =>
      HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  String get _hexString {
    final v = _currentColor.toARGB32() & 0xFFFFFF;
    return v.toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialColor;
    if (initial != null) {
      final hsv = HSVColor.fromColor(initial);
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _value = hsv.value;
    } else {
      _hue = 0;
      _saturation = 1;
      _value = 1;
    }
    _hexFocusNode = FocusNode();
    _hexController = TextEditingController(text: _hexString);
    // When the hex field loses focus, re-sync its display to current HSV so
    // any partial / invalid text is corrected automatically.
    _hexFocusNode.addListener(() {
      if (!_hexFocusNode.hasFocus) {
        _hexController.text = _hexString;
      }
    });
  }

  @override
  void dispose() {
    _hexFocusNode.dispose();
    _hexController.dispose();
    super.dispose();
  }

  /// Update hex display whenever sliders move, but only when the hex field
  /// is not focused (to avoid clobbering the user's in-progress input).
  void _syncHexDisplay() {
    if (!_hexFocusNode.hasFocus) {
      _hexController.text = _hexString;
    }
  }

  /// Parse the hex field text and update HSV state.  No-ops on invalid input.
  void _onHexChanged(String raw) {
    final hex = raw.replaceAll('#', '').trim();
    if (hex.length != 6) return;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return;
    final color = Color(0xFF000000 | parsed);
    final hsv = HSVColor.fromColor(color);
    setState(() {
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _value = hsv.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(l10n.appearanceColorPickerTitle),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Color preview
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: _currentColor,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.outline, width: 2),
              ),
            ),
            const SizedBox(height: 16),
            // Hex input — only allows valid hex characters; syncs with sliders
            TextField(
              controller: _hexController,
              focusNode: _hexFocusNode,
              decoration: InputDecoration(
                prefixText: '#',
                labelText: l10n.appearanceColorPickerHexLabel,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
              maxLength: 6,
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => null,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              ],
              onChanged: _onHexChanged,
              onSubmitted: _onHexChanged,
            ),
            const SizedBox(height: 12),
            // Hue slider with rainbow gradient
            _HueSlider(
              hue: _hue,
              onChanged: (value) {
                setState(() => _hue = value);
                _syncHexDisplay();
              },
            ),
            const SizedBox(height: 12),
            // Saturation slider
            Row(
              children: <Widget>[
                const Icon(Icons.water_drop_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: _saturation,
                    onChanged: (value) {
                      setState(() => _saturation = value);
                      _syncHexDisplay();
                    },
                  ),
                ),
              ],
            ),
            // Brightness slider
            Row(
              children: <Widget>[
                const Icon(Icons.brightness_6_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: _value,
                    onChanged: (value) {
                      setState(() => _value = value);
                      _syncHexDisplay();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancelAction),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            _ColorPickerResult(
              colorValue: _currentColor.toARGB32(),
              saveAsPreset: true,
            ),
          ),
          child: Text(l10n.appearanceColorPickerSave),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ColorPickerResult(
              colorValue: _currentColor.toARGB32(),
              saveAsPreset: false,
            ),
          ),
          child: Text(l10n.appearanceColorPickerApply),
        ),
      ],
    );
  }
}

class _HueSlider extends StatelessWidget {
  const new({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          height: 24,
          decoration: BoxDecoration(
            borderRadius: NavisShapeData.of(context).mdAll,
            gradient: LinearGradient(
              colors: List<Color>.generate(
                360 ~/ 10 + 1,
                (i) => HSVColor.fromAHSV(1, min(i * 10.0, 359), 1, 1).toColor(),
              ),
            ),
          ),
        ),
        Slider(value: hue, max: 359, onChanged: onChanged),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Grid density selector
// ---------------------------------------------------------------------------

class _ArtworkSizeSelector extends StatelessWidget {
  const new({required this.current, required this.onChanged});

  final GridArtworkSize current;
  final ValueChanged<GridArtworkSize> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final presets = <(GridArtworkSize value, String label)>[
      (GridArtworkSize.auto, l10n.appearanceGridDensityAuto),
      (GridArtworkSize.small, l10n.appearanceArtworkSizeSmall),
      (GridArtworkSize.medium, l10n.appearanceArtworkSizeMedium),
      (GridArtworkSize.large, l10n.appearanceArtworkSizeLarge),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppearanceLayout.gutterOf(context),
        vertical: 8,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final preset in presets)
            ChoiceChip(
              label: Text(preset.$2),
              selected: current == preset.$1,
              showCheckmark: false,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (_) => onChanged(preset.$1),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shape selector: square / rounded / circle
// ---------------------------------------------------------------------------

class _ShapeSelector extends ConsumerWidget {
  const new({
    required this.label,
    required this.value,
    required this.onChanged,
    this.includeCircle = true,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool includeCircle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final selectedValue = includeCircle
        ? value
        : (value == 'square' ? 'square' : 'rounded');
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppearanceLayout.gutterOf(context),
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'square',
                  label: Text(l10n.shapeSquare),
                  icon: const Icon(Icons.crop_square),
                ),
                ButtonSegment<String>(
                  value: 'rounded',
                  label: Text(l10n.shapeRounded),
                  icon: const Icon(Icons.rounded_corner),
                ),
                if (includeCircle)
                  ButtonSegment<String>(
                    value: 'circle',
                    label: Text(l10n.shapeCircle),
                    icon: const Icon(Icons.circle_outlined),
                  ),
              ],
              selected: {selectedValue},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onChanged(selection.first);
              },
              showSelectedIcon: false,
            ),
          ),
        ],
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
            trailing: Switch(
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
  });

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
      LibrarySection.playlists => l10n.navPlaylists,
      LibrarySection.radio => l10n.navRadio,
    };
  }

  String? _sectionSubtitle(LibrarySection section, AppLocalizations l10n) {
    return switch (section) {
      LibrarySection.albums => null,
      LibrarySection.liked => l10n.appearanceShowLikedPageSubtitle,
      LibrarySection.artists => l10n.appearanceShowArtistsPageSubtitle,
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
        final subtitle = _sectionSubtitle(section, l10n);
        return Material(
          key: ValueKey<String>('library-page-${section.name}'),
          color: Colors.transparent,
          child: ListTile(
            leading: ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
            title: Text(
              _sectionLabel(section, l10n),
              style: !visible
                  ? theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(100),
                    )
                  : null,
            ),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: Switch(
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
    final selected = (currentStyle == 'compact' || currentStyle == 'icons')
        ? currentStyle
        : 'comfortable';

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
                value: 'comfortable',
                label: l10n.desktopNavbarStyleWide,
                icon: Icons.view_sidebar_outlined,
              ),
              const SizedBox(width: 8),
              styleOption(
                value: 'compact',
                label: l10n.desktopNavbarStyleNarrow,
                icon: Icons.view_compact_alt_outlined,
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
        SwitchListTile(
          title: Text(l10n.desktopNavbarAutohideLabel),
          subtitle: Text(l10n.desktopNavbarAutohideSub),
          value: autohideEnabled,
          onChanged: onAutohideChanged,
        ),
      ],
    );
  }
}
