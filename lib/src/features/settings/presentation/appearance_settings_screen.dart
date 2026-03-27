import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentMode = ref.watch(themeModeProvider);
    final currentSeed = ref.watch(colorSchemeSeedProvider);
    final customPresetsAsync = ref.watch(customColorPresetsProvider);
    final customPresets = customPresetsAsync.asData?.value ?? <int>[];
    final appLocale = ref.watch(appLocaleProvider);
    final languageControlVisible = bool.fromEnvironment(
      'NAVIS_SHOW_LANGUAGE_SETTINGS',
    );
    final languageControlEnabled = AppLocalizations.supportedLocales.length > 1;
    final theme = Theme.of(context);
    final allowedHomeSectionIds = HomeSectionIds.defaultOrder.toSet();
    final persistedOrder = ref.watch(homeSectionOrderProvider);
    final persistedHidden = ref.watch(homeSectionsHiddenProvider);
    final baseHidden = persistedHidden ?? HomeSectionIds.defaultHidden;
    final sanitizedOrder = <String>[
      ...?persistedOrder?.where(allowedHomeSectionIds.contains),
      ...HomeSectionIds.defaultOrder.where(
        (id) => !(persistedOrder?.contains(id) ?? false),
      ),
    ];
    final sanitizedHidden = baseHidden
        .where(allowedHomeSectionIds.contains)
        .toList(growable: false);
    final isDesktop =
        resolveAdaptiveContextFor(context).useDesktopShell;
    // Quick Actions move to the desktop brand row; hide from the setting.
    final displayOrder = isDesktop
        ? sanitizedOrder
            .where((id) => id != HomeSectionIds.quickActions)
            .toList(growable: false)
        : sanitizedOrder;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearanceTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          if (languageControlVisible) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                l10n.appearanceLanguageLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
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

          // ── Theme Mode ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              l10n.appearanceThemeModeLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          _ThemeModeSelector(
            currentMode: currentMode,
            onChanged: (mode) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateThemeMode(mode);
            },
          ),
          const Divider(height: 32),

          // ── Color Scheme ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceColorSchemeLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.appearanceColorSchemeSub,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _ColorSchemeGrid(
            currentSeed: currentSeed,
            customPresets: customPresets,
            onSelected: (seed) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateColorSchemeSeed(seed);
            },
            onCustomColorPicked: (colorValue) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateColorSchemeSeed(colorValue);
            },
            onSavePreset: (colorValue) async {
              final db = ref.read(navisDatabaseProvider);
              final updated = List<int>.from(customPresets);
              if (!updated.contains(colorValue)) {
                updated.add(colorValue);
              }
              await db.appSettingsDao.updateCustomColorPresets(
                jsonEncode(updated),
              );
              if (context.mounted) {
                AppNoticeMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(l10n.appearanceColorPresetSaved),
                    ),
                  );
              }
            },
            onDeletePreset: (colorValue) async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(l10n.appearanceColorDeletePreset),
                  content: Text(l10n.appearanceColorDeletePresetConfirm),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(l10n.cancelAction),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(l10n.appearanceColorDeletePreset),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !context.mounted) return;
              final db = ref.read(navisDatabaseProvider);
              final updated = List<int>.from(customPresets)..remove(colorValue);
              await db.appSettingsDao.updateCustomColorPresets(
                updated.isEmpty ? null : jsonEncode(updated),
              );
              if (currentSeed == colorValue) {
                await db.appSettingsDao.updateColorSchemeSeed(null);
              }
              if (context.mounted) {
                AppNoticeMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(l10n.appearanceColorPresetDeleted),
                    ),
                  );
              }
            },
          ),
          const Divider(height: 32),

          // ── Art-Tinted Now Playing ──────────────────────────────
          SwitchListTile(
            title: Text(l10n.appearanceArtTintedLabel),
            subtitle: Text(l10n.appearanceArtTintedSub),
            value: ref.watch(artTintedNowPlayingProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateArtTintedNowPlaying(
                enabled: enabled,
              );
            },
          ),
          SwitchListTile(
            title: const Text('Dynamic Album Color'),
            subtitle: const Text(
              'Use the currently playing album art to theme app accent colors.',
            ),
            value: ref.watch(dynamicAlbumColorEnabledProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateDynamicAlbumColorEnabled(
                enabled: enabled,
              );
            },
          ),
          const Divider(height: 32),

          // ── Grid Density ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceGridDensityLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l10n.appearanceGridDensitySub,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _GridDensitySelector(
            current: ref.watch(albumGridDensityProvider),
            onChanged: (density) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateAlbumGridDensity(density);
            },
          ),
          const Divider(height: 32),

          // ── Artist View Mode ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceArtistViewModeLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

          _SettingsCollapsibleGroup(
            leading: const _CyclingShapeIcon(),
            title: l10n.appearanceCoverArtShapeLabel,
            initiallyExpanded: false,
            child: Column(
              children: <Widget>[
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
              ],
            ),
          ),
          const Divider(height: 24),

          _SettingsCollapsibleGroup(
            leading: const Icon(Icons.home_outlined),
            title: l10n.appearanceHomeSectionsLabel,
            initiallyExpanded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    l10n.appearanceHomeDensityLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    l10n.appearanceHomeDensitySub,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _HomeDensitySelector(
                  current: ref.watch(homeDensityProvider),
                  onChanged: (value) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateHomeDensity(value);
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
                  onToggleVisibility: (sectionId, visible) async {
                    final db = ref.read(navisDatabaseProvider);
                    final current = List<String>.from(sanitizedHidden);
                    if (visible) {
                      current.remove(sectionId);
                    } else {
                      if (!current.contains(sectionId)) current.add(sectionId);
                    }
                    await db.appSettingsDao.updateHomeSectionsHidden(
                      current.isEmpty ? null : jsonEncode(current),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 24),

          _SettingsCollapsibleGroup(
            leading: const _BlinkingEyeIcon(),
            title: l10n.appearancePagesSectionLabel,
            initiallyExpanded: false,
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  title: Text(l10n.appearanceShowLikedPageTitle),
                  subtitle: Text(l10n.appearanceShowLikedPageSubtitle),
                  value: ref.watch(showLikedPageProvider),
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateShowLikedPage(
                      enabled: enabled,
                    );
                  },
                ),
                SwitchListTile(
                  title: Text(l10n.appearanceShowArtistsPageTitle),
                  subtitle: Text(l10n.appearanceShowArtistsPageSubtitle),
                  value: ref.watch(showArtistsPageProvider),
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateShowArtistsPage(
                      enabled: enabled,
                    );
                  },
                ),
                SwitchListTile(
                  title: Text(l10n.appearanceShowPlaylistsPageTitle),
                  subtitle: Text(l10n.appearanceShowPlaylistsPageSubtitle),
                  value: ref.watch(showPlaylistsPageProvider),
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateShowPlaylistsPage(
                      enabled: enabled,
                    );
                  },
                ),
                SwitchListTile(
                  title: Text(l10n.appearanceShowRadioPageTitle),
                  subtitle: Text(l10n.appearanceShowRadioPageSubtitle),
                  value: ref.watch(showRadioPageProvider),
                  onChanged: (enabled) async {
                    final db = ref.read(navisDatabaseProvider);
                    await db.appSettingsDao.updateShowRadioPage(
                      enabled: enabled,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

String _localeLabel(Locale locale) {
  switch (locale.languageCode) {
    case 'en':
      return 'English';
    default:
      return locale.languageCode;
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({
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
          border: const OutlineInputBorder(),
          helperText: enabled
              ? null
              : 'Language switching is disabled in this build.',
        ),
        items: <DropdownMenuItem<String?>>[
          DropdownMenuItem<String?>(
            value: null,
            child: Text(l10n.appearanceLanguageSystemDefault),
          ),
          ...AppLocalizations.supportedLocales.map(
            (locale) => DropdownMenuItem<String?>(
              value: locale.languageCode,
              child: Text(_localeLabel(locale)),
            ),
          ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class _SettingsCollapsibleGroup extends StatefulWidget {
  const _SettingsCollapsibleGroup({
    required this.leading,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  final Widget leading;
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_SettingsCollapsibleGroup> createState() =>
      _SettingsCollapsibleGroupState();
}

class _SettingsCollapsibleGroupState extends State<_SettingsCollapsibleGroup> {
  static const Duration _duration = Duration(milliseconds: 220);
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                final nextExpanded = !_expanded;
                setState(() => _expanded = nextExpanded);
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
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
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
                child: AnimatedOpacity(
                  opacity: _expanded ? 1 : 0,
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutCubic,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: widget.child,
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

class _CyclingShapeIcon extends StatefulWidget {
  const _CyclingShapeIcon();

  @override
  State<_CyclingShapeIcon> createState() => _CyclingShapeIconState();
}

class _CyclingShapeIconState extends State<_CyclingShapeIcon> {
  static const List<double> _cornerRadii = <double>[
    1.5,
    6,
    999,
  ];
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 950), (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % _cornerRadii.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).iconTheme.color;
    return SizedBox(
      width: 22,
      height: 22,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            border: Border.all(
              color: color ?? Theme.of(context).colorScheme.primary,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(_cornerRadii[_index]),
          ),
        ),
      ),
    );
  }
}

class _BlinkingEyeIcon extends StatefulWidget {
  const _BlinkingEyeIcon();

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

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({
    required this.currentMode,
    required this.onChanged,
  });

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<String>(
        segments: entries
            .map(
              (e) => ButtonSegment<String>(
                value: e.$1,
                label: Text(e.$2),
                icon: Icon(e.$3),
              ),
            )
            .toList(),
        selected: {currentMode},
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) onChanged(selection.first);
        },
        showSelectedIcon: false,
      ),
    );
  }
}

class _ColorSchemeGrid extends StatelessWidget {
  const _ColorSchemeGrid({
    required this.currentSeed,
    required this.customPresets,
    required this.onSelected,
    required this.onCustomColorPicked,
    required this.onSavePreset,
    required this.onDeletePreset,
  });

  final int? currentSeed;
  final List<int> customPresets;
  final ValueChanged<int?> onSelected;
  final ValueChanged<int> onCustomColorPicked;
  final ValueChanged<int> onSavePreset;
  final ValueChanged<int> onDeletePreset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          // Default (blue, null seed) option
          _ColorChip(
            color: Colors.blue,
            label: l10n.appearanceColorDefault,
            isSelected: currentSeed == null,
            onTap: () => onSelected(null),
            theme: theme,
          ),
          // Preset colors (skip blue since it's the default)
          for (final preset in presetColors)
            if (preset.color != Colors.blue)
              _ColorChip(
                color: preset.color,
                label: preset.name,
                isSelected: currentSeed == preset.color.toARGB32(),
                onTap: () => onSelected(preset.color.toARGB32()),
                theme: theme,
              ),
          // Custom presets (long-press to delete)
          for (final colorValue in customPresets)
            _ColorChip(
              color: Color(colorValue),
              label: l10n.appearanceColorCustom,
              isSelected: currentSeed == colorValue,
              onTap: () => onSelected(colorValue),
              onLongPress: () => onDeletePreset(colorValue),
              theme: theme,
              showDeleteHint: true,
            ),
          // Rainbow / custom picker chip
          _RainbowChip(
            theme: theme,
            label: l10n.appearanceColorCustom,
            onTap: () async {
              final result = await showDialog<_ColorPickerResult>(
                context: context,
                builder: (_) => const _ColorPickerDialog(),
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
    );
  }
}

class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.color,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.theme,
    this.onLongPress,
    this.showDeleteHint = false,
  });

  final Color color;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ThemeData theme;
  final bool showDeleteHint;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    return Tooltip(
      message: showDeleteHint
          ? AppLocalizations.of(context)!.appearanceLongPressHint(label)
          : label,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: isSelected
                ? Border.all(
                    color: theme.colorScheme.onSurface,
                    width: 3,
                  )
                : null,
            boxShadow: isSelected
                ? <BoxShadow>[
                    BoxShadow(
                      color: color.withAlpha(100),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: isSelected
              ? Icon(
                  Icons.check,
                  color:
                      ThemeData.estimateBrightnessForColor(color) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  size: 24,
                )
              : null,
        ),
      ),
    );
  }
}

class _RainbowChip extends StatelessWidget {
  const _RainbowChip({
    required this.theme,
    required this.label,
    required this.onTap,
  });

  final ThemeData theme;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    return Tooltip(
      message: label,
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
  }
}

// ---------------------------------------------------------------------------
// Color picker dialog
// ---------------------------------------------------------------------------

class _ColorPickerResult {
  const _ColorPickerResult({
    required this.colorValue,
    required this.saveAsPreset,
  });
  final int colorValue;
  final bool saveAsPreset;
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog();

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  double _hue = 0;
  double _saturation = 1;
  double _value = 1;

  Color get _currentColor =>
      HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

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
                border: Border.all(
                  color: theme.colorScheme.outline,
                  width: 2,
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Hue slider with rainbow gradient
            _HueSlider(
              hue: _hue,
              onChanged: (value) => setState(() => _hue = value),
            ),
            const SizedBox(height: 12),
            // Saturation slider
            Row(
              children: <Widget>[
                const Icon(Icons.water_drop_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: _saturation,
                    onChanged: (value) => setState(() => _saturation = value),
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
                    onChanged: (value) => setState(() => _value = value),
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
  const _HueSlider({
    required this.hue,
    required this.onChanged,
  });

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          height: 24,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: List<Color>.generate(
                360 ~/ 10 + 1,
                (i) => HSVColor.fromAHSV(1, min(i * 10.0, 359), 1, 1).toColor(),
              ),
            ),
          ),
        ),
        Slider(
          value: hue,
          max: 359,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Grid density selector
// ---------------------------------------------------------------------------

class _GridDensitySelector extends StatelessWidget {
  const _GridDensitySelector({
    required this.current,
    required this.onChanged,
  });

  final int? current;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final presets = <(int? value, String label)>[
      (null, l10n.appearanceGridDensityAuto),
      (2, l10n.appearanceGridDensityCozy),
      (3, l10n.appearanceGridDensityCompact),
      (4, l10n.appearanceGridDensitySpaciousLabel),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<int?>(
        segments: presets
            .map(
              (e) => ButtonSegment<int?>(value: e.$1, label: Text(e.$2)),
            )
            .toList(),
        selected: {current},
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) onChanged(selection.first);
        },
        showSelectedIcon: false,
      ),
    );
  }
}

class _HomeDensitySelector extends StatelessWidget {
  const _HomeDensitySelector({
    required this.current,
    required this.onChanged,
  });

  final String current;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedValue = current == 'compact' ? 'compact' : 'comfortable';
    final colorScheme = Theme.of(context).colorScheme;

    Widget option({
      required String value,
      required String label,
      required IconData icon,
    }) {
      final selected = selectedValue == value;
      return Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: () => onChanged(value),
            icon: Icon(icon, size: 18),
            label: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              backgroundColor: selected
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerLow,
              foregroundColor: selected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          option(
            value: 'comfortable',
            label: l10n.appearanceHomeDensityComfortable,
            icon: Icons.view_agenda_outlined,
          ),
          const SizedBox(width: 8),
          option(
            value: 'compact',
            label: l10n.appearanceHomeDensityCompact,
            icon: Icons.view_compact_alt_outlined,
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
  const _ShapeSelector({
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
  const _HomeSectionReorder({
    required this.order,
    required this.hidden,
    required this.onReorder,
    required this.onToggleVisibility,
  });

  final List<String> order;
  final List<String> hidden;
  final ValueChanged<List<String>> onReorder;
  final void Function(String sectionId, bool visible) onToggleVisibility;

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
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
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
              onChanged: (visible) => widget.onToggleVisibility(id, visible),
            ),
          ),
        );
      },
    );
  }
}
