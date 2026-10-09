import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// The colour a seed swatch shows under [style]: the accent the style will
/// actually use, taken from its dark scheme where accents sit at their
/// clearest tone. Neutral shows the seed itself.
Color styledSwatchColor(Color seed, NavisColorStyle style) {
  if (style == NavisColorStyle.neutral) {
    return seed;
  }
  return buildStyledColorScheme(
    seed: seed,
    brightness: Brightness.dark,
    style: style,
  ).primary;
}

/// Localized name of [style].
String colorStyleLabel(AppLocalizations l10n, NavisColorStyle style) {
  return switch (style) {
    NavisColorStyle.neutral => l10n.appearanceColorStyleNeutral,
    NavisColorStyle.pastel => l10n.appearanceColorStylePastel,
    NavisColorStyle.immersive => l10n.appearanceColorStyleImmersive,
    NavisColorStyle.night => l10n.appearanceColorStyleNight,
  };
}

String _colorStyleDescription(AppLocalizations l10n, NavisColorStyle style) {
  return switch (style) {
    NavisColorStyle.neutral => l10n.appearanceColorStyleNeutralSub,
    NavisColorStyle.pastel => l10n.appearanceColorStylePastelSub,
    NavisColorStyle.immersive => l10n.appearanceColorStyleImmersiveSub,
    NavisColorStyle.night => l10n.appearanceColorStyleNightSub,
  };
}

/// Colour style picker shared by Appearance and first-run customization.
///
/// Each tile is a small preview painted from the style's real scheme for the
/// current brightness and accent, so the choice shows its result before it
/// is made.
class ColorStyleSelector extends StatelessWidget {
  const new({
    super.key,
    required this.currentStyle,
    required this.seed,
    required this.brightness,
    required this.oled,
    required this.onChanged,
  });

  final NavisColorStyle currentStyle;

  /// Effective accent seed the previews are built from.
  final Color seed;
  final Brightness brightness;
  final bool oled;
  final ValueChanged<NavisColorStyle> onChanged;

  static const double _gap = 12;
  static const double _minTileWidth = 72;
  static const double _maxTileWidth = 132;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    const styles = NavisColorStyle.values;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              final rowWidth =
                  (constraints.maxWidth - _gap * (styles.length - 1)) /
                  styles.length;
              // One row of four when each tile keeps a readable preview,
              // otherwise two rows of two.
              final perRow = rowWidth >= _minTileWidth ? styles.length : 2;
              final tileWidth =
                  ((constraints.maxWidth - _gap * (perRow - 1)) / perRow).clamp(
                    0.0,
                    _maxTileWidth,
                  );
              return Wrap(
                spacing: _gap,
                runSpacing: _gap,
                children: <Widget>[
                  for (final style in styles)
                    SizedBox(
                      width: tileWidth,
                      child: _ColorStyleTile(
                        style: style,
                        label: colorStyleLabel(l10n, style),
                        description: _colorStyleDescription(l10n, style),
                        selected: style == currentStyle,
                        scheme: buildStyledColorScheme(
                          seed: seed,
                          brightness: brightness,
                          oled: oled,
                          style: style,
                        ),
                        onTap: () => onChanged(style),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: NavisSpace.sm),
          Text(
            _colorStyleDescription(l10n, currentStyle),
            key: const ValueKey<String>('colorStyleDescription'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorStyleTile extends StatelessWidget {
  const new({
    required this.style,
    required this.label,
    required this.description,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  final NavisColorStyle style;
  final String label;
  final String description;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outer = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      hint: description,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey<String>('colorStyleTile-${style.storageKey}'),
        onTap: onTap,
        borderRadius: NavisShapeData.of(context).mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(
                  Radius.circular(NavisShapeData.of(context).md + 3),
                ),
                border: Border.all(
                  color: selected ? outer.primary : outer.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              child: AspectRatio(
                aspectRatio: 0.8,
                child: _StylePreview(scheme: scheme, selected: selected),
              ),
            ),
            const SizedBox(height: NavisSpace.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? outer.primary : outer.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A miniature Navis screen: a heading, an accent pill, and the mini player
/// with its play button, all drawn from [scheme].
class _StylePreview extends StatelessWidget {
  const new({required this.scheme, required this.selected});

  final ColorScheme scheme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: NavisShapeData.of(context).mdAll,
      child: ColoredBox(
        color: scheme.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final unit = w / 10;
            return Stack(
              children: <Widget>[
                Positioned(
                  left: unit,
                  top: unit * 1.2,
                  child: _Bar(
                    color: scheme.onSurface,
                    width: w * 0.55,
                    height: unit * 0.75,
                  ),
                ),
                Positioned(
                  left: unit,
                  top: unit * 2.5,
                  child: _Bar(
                    color: scheme.onSurfaceVariant,
                    width: w * 0.38,
                    height: unit * 0.5,
                  ),
                ),
                Positioned(
                  left: unit,
                  top: unit * 3.9,
                  child: _Bar(
                    color: scheme.primary,
                    width: w * 0.42,
                    height: unit * 1.3,
                  ),
                ),
                Positioned(
                  left: unit * 0.6,
                  right: unit * 0.6,
                  bottom: unit * 0.6,
                  child: Container(
                    height: unit * 2.6,
                    padding: EdgeInsets.symmetric(horizontal: unit * 0.6),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: NavisShapeData.of(context)
                          .scaledAll(unit * 0.8),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _Bar(
                                color: scheme.onSurface,
                                width: w * 0.36,
                                height: unit * 0.45,
                              ),
                              SizedBox(height: unit * 0.35),
                              _Bar(
                                color: scheme.onSurfaceVariant,
                                width: w * 0.24,
                                height: unit * 0.35,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: unit * 1.7,
                          height: unit * 1.7,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: unit * 1.2,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: unit * 0.6,
                    right: unit * 0.6,
                    child: Container(
                      width: unit * 1.8,
                      height: unit * 1.8,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        size: unit * 1.3,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const new({required this.color, required this.width, required this.height});

  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: NavisShapeData.of(context).scaledAll(height / 2),
      ),
    );
  }
}
