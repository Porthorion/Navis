import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
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
    final languageSelectionEnabled = AppLocalizations.supportedLocales.length > 1;
    final theme = Theme.of(context);
    final allowedHomeSectionIds = HomeSectionIds.defaultOrder.toSet();
    final persistedOrder = ref.watch(homeSectionOrderProvider);
    final persistedHidden = ref.watch(homeSectionsHiddenProvider) ??
        <String>[];
    final sanitizedOrder = <String>[
      ...?persistedOrder?.where(allowedHomeSectionIds.contains),
      ...HomeSectionIds.defaultOrder.where(
        (id) => !(persistedOrder?.contains(id) ?? false),
      ),
    ];
    final sanitizedHidden = persistedHidden
        .where(allowedHomeSectionIds.contains)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearanceTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
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
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceLanguageLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String?>(
              value: appLocale,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                helperText: languageSelectionEnabled
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
              onChanged: languageSelectionEnabled
                  ? (localeCode) async {
                      final db = ref.read(navisDatabaseProvider);
                      await db.appSettingsDao.updateAppLocale(localeCode);
                    }
                  : null,
            ),
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
            onSelected: (int? seed) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateColorSchemeSeed(seed);
            },
            onCustomColorPicked: (int colorValue) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateColorSchemeSeed(colorValue);
            },
            onSavePreset: (int colorValue) async {
              final db = ref.read(navisDatabaseProvider);
              final updated = List<int>.from(customPresets);
              if (!updated.contains(colorValue)) {
                updated.add(colorValue);
              }
              await db.appSettingsDao.updateCustomColorPresets(
                jsonEncode(updated),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(l10n.appearanceColorPresetSaved),
                    ),
                  );
              }
            },
            onDeletePreset: (int colorValue) async {
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
                ScaffoldMessenger.of(context)
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

          // ── Cover Art Shape ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceCoverArtShapeLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
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

          // ── Home Sections (drag to reorder + visibility toggle) ─
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearanceHomeSectionsLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l10n.appearanceHomeSectionsSub,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _HomeSectionReorder(
            order: sanitizedOrder,
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
          const Divider(height: 32),

          // ── Page Visibility ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.appearancePagesSectionLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: Text(l10n.appearanceShowLikedPageTitle),
            subtitle: Text(l10n.appearanceShowLikedPageSubtitle),
            value: ref.watch(showLikedPageProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateShowLikedPage(enabled: enabled);
            },
          ),
          SwitchListTile(
            title: Text(l10n.appearanceShowArtistsPageTitle),
            subtitle: Text(l10n.appearanceShowArtistsPageSubtitle),
            value: ref.watch(showArtistsPageProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateShowArtistsPage(enabled: enabled);
            },
          ),
          SwitchListTile(
            title: Text(l10n.appearanceShowPlaylistsPageTitle),
            subtitle: Text(l10n.appearanceShowPlaylistsPageSubtitle),
            value: ref.watch(showPlaylistsPageProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateShowPlaylistsPage(enabled: enabled);
            },
          ),
          SwitchListTile(
            title: Text(l10n.appearanceShowRadioPageTitle),
            subtitle: Text(l10n.appearanceShowRadioPageSubtitle),
            value: ref.watch(showRadioPageProvider),
            onChanged: (enabled) async {
              final db = ref.read(navisDatabaseProvider);
              await db.appSettingsDao.updateShowRadioPage(enabled: enabled);
            },
          ),
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
              (e) =>
                  ButtonSegment<int?>(value: e.$1, label: Text(e.$2)),
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
          SegmentedButton<String>(
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
              onChanged: (visible) =>
                  widget.onToggleVisibility(id, visible),
            ),
          ),
        );
      },
    );
  }
}
