import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/settings/presentation/appearance_layout.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Fine-Tune Colors: the Color (Muted to Vivid) and Brightness (Lighter to
/// Deeper) rulers that adjust any color style. Shared by Appearance settings
/// and setup.
///
/// Each ruler is the Speed and Pitch ruler ([AdjustmentRuler]) in whole-step
/// mode, so its scale is a picture of the result: eleven stepped swatches,
/// one per step, painted from the style's real scheme at that step. The
/// swatches are computed from [seed], [style], [brightness], [oled] and the
/// other axis, never from the ambient theme, so they hold still while the app
/// recolours around them.
///
/// The widget keeps the values it shows. While a ruler moves it reports each
/// whole step through [onPreview]; when input ends (drag release, stepper,
/// keyboard, Reset) it reports the final value through [onChanged].
/// [onPreviewEnd] fires if the widget goes away mid-drag, so a preview never
/// outlives it.
class ColorTuningOption extends StatefulWidget {
  const new({
    required this.value,
    required this.seed,
    required this.style,
    required this.brightness,
    required this.oled,
    required this.onPreview,
    required this.onChanged,
    this.onPreviewEnd,
    this.adornment,
    super.key,
  });

  /// The saved (or drafted) adjustment.
  final ColorAdjustment value;

  /// What the swatches are built from: the previewed theme's inputs.
  final Color seed;
  final NavisColorStyle style;
  final Brightness brightness;
  final bool oled;

  final ValueChanged<ColorAdjustment> onPreview;
  final ValueChanged<ColorAdjustment> onChanged;
  final VoidCallback? onPreviewEnd;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  State<ColorTuningOption> createState() => _ColorTuningOptionState();
}

class _ColorTuningOptionState extends State<ColorTuningOption> {
  static const double _maxRulerWidth = 480;

  late ColorAdjustment _shown = widget.value;
  bool _previewing = false;
  int _resetToken = 0;

  late RulerBand _colorBand;
  Object? _colorBandKey;
  late RulerBand _brightnessBand;
  Object? _brightnessBandKey;

  @override
  void didUpdateWidget(ColorTuningOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow a value changed elsewhere, but never yank a ruler mid-gesture
    // for the echo of an earlier save.
    if (widget.value != oldWidget.value && !_previewing) {
      _shown = widget.value;
    }
  }

  @override
  void dispose() {
    if (_previewing) {
      // A provider cannot change while the tree is being torn down.
      final end = widget.onPreviewEnd;
      if (end != null) scheduleMicrotask(end);
    }
    super.dispose();
  }

  void _preview(ColorAdjustment next) {
    if (next == _shown) return;
    setState(() {
      _shown = next;
      _previewing = true;
    });
    widget.onPreview(next);
  }

  void _commit() {
    _previewing = false;
    widget.onChanged(_shown);
  }

  void _reset() {
    setState(() {
      _shown = ColorAdjustment.none;
      _resetToken++;
    });
    widget.onPreview(_shown);
    _commit();
  }

  /// Swatches for the steps −5…+5 of one axis, with the tick colour that
  /// reads on each. [at] gives the adjustment for a step.
  RulerBand _buildBand({
    required ColorAdjustment Function(int step) at,
    required Color Function(ColorScheme) swatch,
    required Color Function(ColorScheme) ink,
  }) {
    final schemes = [
      for (var step = -5; step <= 5; step++)
        buildStyledColorScheme(
          seed: widget.seed,
          brightness: widget.brightness,
          oled: widget.oled,
          style: widget.style,
          adjustment: at(step),
        ),
    ];
    return RulerBand(
      colors: [for (final scheme in schemes) swatch(scheme)],
      inks: [for (final scheme in schemes) ink(scheme)],
    );
  }

  /// Rebuilt only when an input changes, not on every theme frame.
  RulerBand _bandFor({required bool color}) {
    final key = (
      widget.seed.toARGB32(),
      widget.style,
      widget.brightness,
      widget.oled,
      color ? _shown.depth : _shown.vividness,
    );
    if (color) {
      if (_colorBandKey != key) {
        _colorBandKey = key;
        _colorBand = _buildBand(
          at: (step) => ColorAdjustment(vividness: step, depth: _shown.depth),
          swatch: (scheme) => scheme.primary,
          ink: (scheme) => scheme.onPrimary,
        );
      }
      return _colorBand;
    }
    if (_brightnessBandKey != key) {
      _brightnessBandKey = key;
      _brightnessBand = _buildBand(
        at: (step) => ColorAdjustment(vividness: _shown.vividness, depth: step),
        // OLED keeps its surface black at every depth; its panels move.
        swatch: (scheme) =>
            widget.oled ? scheme.surfaceContainerHigh : scheme.surface,
        ink: (scheme) => scheme.onSurfaceVariant,
      );
    }
    return _brightnessBand;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final gutter = AppearanceLayout.gutterOf(context);
    final colorBand = _bandFor(color: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppearanceHeading(
          title: l10n.appearanceColorTuningLabel,
          adornment: widget.adornment,
          topPadding: NavisSpace.md,
        ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: gutter,
            vertical: NavisSpace.xxs,
          ),
          child: Text(
            l10n.appearanceColorTuningSub,
            style: theme.textTheme.bodySmall,
          ),
        ),
        // The swatch strip is eleven steps wide; on a wide page the rulers
        // stop growing so the steppers stay beside it.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _maxRulerWidth + 2 * gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _TuningRow(
                  keyName: 'color',
                  label: l10n.appearanceColorTuningColor,
                  lowCaption: l10n.appearanceColorTuningMuted,
                  highCaption: l10n.appearanceColorTuningVivid,
                  lowTooltip: l10n.appearanceColorTuningMoreMuted,
                  highTooltip: l10n.appearanceColorTuningMoreVivid,
                  step: _shown.vividness,
                  band: colorBand,
                  // The needle is the live primary: the swatch under it.
                  accent: colorBand.colors[_shown.vividness + 5],
                  resetToken: _resetToken,
                  onStep: (step) => _preview(
                    ColorAdjustment(vividness: step, depth: _shown.depth),
                  ),
                  onEnd: _commit,
                ),
                _TuningRow(
                  keyName: 'brightness',
                  label: l10n.appearanceColorTuningBrightness,
                  lowCaption: l10n.appearanceColorTuningLighter,
                  highCaption: l10n.appearanceColorTuningDeeper,
                  lowTooltip: l10n.appearanceColorTuningLighterBackgrounds,
                  highTooltip: l10n.appearanceColorTuningDeeperBackgrounds,
                  step: _shown.depth,
                  band: _bandFor(color: false),
                  resetToken: _resetToken,
                  onStep: (step) => _preview(
                    ColorAdjustment(vividness: _shown.vividness, depth: step),
                  ),
                  onEnd: _commit,
                ),
                if (_shown != ColorAdjustment.none)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: gutter > NavisSpace.xs
                            ? gutter - NavisSpace.xs
                            : 0,
                      ),
                      child: TextButton.icon(
                        key: const ValueKey<String>('colorTuning-reset'),
                        onPressed: _reset,
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: Text(l10n.appearanceColorTuningReset),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One ruler in the Speed and Pitch layout: a title and value readout, then
/// the − stepper, the ruler and the + stepper, then the captions of its two
/// ends. The ruler's value is the whole step, −5…+5.
class _TuningRow extends StatelessWidget {
  const new({
    required this.keyName,
    required this.label,
    required this.lowCaption,
    required this.highCaption,
    required this.lowTooltip,
    required this.highTooltip,
    required this.step,
    required this.band,
    required this.resetToken,
    required this.onStep,
    required this.onEnd,
    this.accent,
  });

  final String keyName;
  final String label;
  final String lowCaption;
  final String highCaption;
  final String lowTooltip;
  final String highTooltip;
  final int step;
  final RulerBand band;
  final Color? accent;
  final int resetToken;
  final ValueChanged<int> onStep;
  final VoidCallback onEnd;

  static const int _limit = 5;

  /// "+2" and "−3", the true minus sign as the tick labels use.
  static String signed(double value) {
    final step = value.round();
    if (step == 0) return '0';
    return '${step > 0 ? '+' : '−'}${step.abs()}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final gutter = AppearanceLayout.gutterOf(context);
    final readout = step == 0
        ? l10n.appearanceColorTuningDefault
        : signed(step.toDouble());

    Widget stepper({required bool up}) {
      final next = step + (up ? 1 : -1);
      return RulerStepButton(
        key: ValueKey<String>('colorTuning-$keyName-${up ? 'plus' : 'minus'}'),
        icon: up ? Icons.add : Icons.remove,
        tooltip: up ? highTooltip : lowTooltip,
        enabled: next.abs() <= _limit,
        onStep: () {
          final target = step + (up ? 1 : -1);
          if (target.abs() > _limit) return false;
          onStep(target);
          return true;
        },
        onEnd: onEnd,
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        NavisSpace.sm,
        gutter,
        NavisSpace.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
              Flexible(
                child: Text(
                  readout,
                  textAlign: TextAlign.end,
                  key: ValueKey<String>('colorTuning-$keyName-value'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    // Fixed-width digits keep the readout still while dragging.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          // The painter puts lower values on the left in every locale, so the
          // row stays LTR like Speed and Pitch.
          Row(
            textDirection: TextDirection.ltr,
            children: <Widget>[
              stepper(up: false),
              Expanded(
                child: AdjustmentRuler(
                  key: ValueKey<String>('colorTuning-$keyName-ruler'),
                  value: step.toDouble(),
                  label: label,
                  valueLabel: readout,
                  onChanged: (value) => onStep(value.round()),
                  onChangeEnd: onEnd,
                  range: const AdjustmentRange(minimum: -5, maximum: 5),
                  snapStep: 1,
                  // 32 px a step keeps about six steps in view, so the
                  // swatches ahead of the needle preview where it is going.
                  pixelsPerUnit: 32,
                  interactionToken: resetToken,
                  labelBuilder: signed,
                  band: band,
                  accent: accent,
                ),
              ),
              stepper(up: true),
            ],
          ),
          Row(
            textDirection: TextDirection.ltr,
            children: <Widget>[
              // Lines the captions up with the ruler between the steppers.
              const SizedBox(width: kMinInteractiveDimension),
              Expanded(
                // Each caption keeps its end and wraps rather than overflows
                // at large text sizes.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        lowCaption,
                        textAlign: TextAlign.left,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        highCaption,
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: kMinInteractiveDimension),
            ],
          ),
        ],
      ),
    );
  }
}
