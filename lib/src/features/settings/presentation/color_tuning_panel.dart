import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/quick_panel.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// What the Fine-Tune Colors swatches are painted from: the previewed theme's
/// inputs, never the ambient theme, so the strips hold still while the app
/// recolours around them.
@immutable
class ColorTuningBasis {
  const new({
    required this.seed,
    required this.style,
    required this.brightness,
    required this.oled,
    required this.darkIsOled,
  });

  final Color seed;
  final NavisColorStyle style;

  /// The mode the app shows now; the Brightness switch starts on it.
  final Brightness brightness;

  /// Whether that mode is OLED.
  final bool oled;

  /// Whether the dark mode would be OLED (OLED theme, or Auto with Use OLED
  /// When Dark), so the Dark strip shows what Dark really looks like.
  final bool darkIsOled;

  bool get dark => brightness == Brightness.dark;
}

/// "+2" and "−3", the true minus sign the ruler's tick labels use.
String signedStep(int step) =>
    step == 0 ? '0' : '${step > 0 ? '+' : '−'}${step.abs()}';

/// One line for Fine-Tune Colors: "Default" or the steps that are not zero
/// ("Intensity +2 · Brightness −1"). Brightness
/// is the mode shown now ([dark]); with only the other mode adjusted, that
/// mode is named.
String colorTuningSummary(
  AppLocalizations l10n,
  ColorTuning tuning, {
  required bool dark,
}) {
  if (tuning == ColorTuning.none) return l10n.appearanceColorTuningDefault;
  final depth = dark ? tuning.darkDepth : tuning.lightDepth;
  final other = dark ? tuning.lightDepth : tuning.darkDepth;
  final parts = <String>[
    if (tuning.vividness != 0)
      l10n.appearanceColorTuningSummaryIntensity(signedStep(tuning.vividness)),
    if (depth != 0)
      l10n.appearanceColorTuningSummaryBrightness(signedStep(depth)),
    if (tuning.vividness == 0 && depth == 0 && other != 0)
      l10n.appearanceColorTuningSummaryModeBrightness(
        dark ? l10n.appearanceThemeLight : l10n.appearanceThemeDark,
        signedStep(other),
      ),
  ];
  return parts.join(' · ');
}

/// Opens Fine-Tune Colors from [anchorContext]: a sheet on touch layouts, an
/// anchored popover on desktop (the Speed and Pitch shell).
///
/// [tuning] is the live value, kept by the host (Settings follows the saved
/// and previewed tuning; setup its draft). The panel reports each whole step
/// while a ruler moves through [onPreview]; drag release, stepper, keyboard
/// and Reset report through [onCommit]. [onPreviewEnd] fires if the panel goes
/// away mid-drag.
Future<void> showColorTuningPanel(
  BuildContext anchorContext, {
  required ColorTuningBasis basis,
  required ValueListenable<ColorTuning> tuning,
  required ValueChanged<ColorTuning> onPreview,
  required ValueChanged<ColorTuning> onCommit,
  VoidCallback? onPreviewEnd,
}) {
  final l10n = AppLocalizations.of(anchorContext)!;
  return showQuickPanel(
    anchorContext,
    panelKey: const ValueKey<String>('colorTuningPanel'),
    title: l10n.appearanceColorTuningLabel,
    width: 440,
    maxHeight: 680,
    subtitleBuilder: (_) => ValueListenableBuilder<ColorTuning>(
      valueListenable: tuning,
      builder: (context, value, _) => Text(
        colorTuningSummary(
          AppLocalizations.of(context)!,
          value,
          dark: basis.dark,
        ),
        key: const ValueKey<String>('colorTuning-summary'),
      ),
    ),
    bodyBuilder: (_) => _PanelBody(
      basis: basis,
      tuning: tuning,
      onPreview: onPreview,
      onCommit: onCommit,
      onPreviewEnd: onPreviewEnd,
    ),
    footerBuilder: (_) => ValueListenableBuilder<ColorTuning>(
      valueListenable: tuning,
      builder: (context, value, _) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey<String>('colorTuning-reset'),
          onPressed: value == ColorTuning.none
              ? null
              : () => onCommit(ColorTuning.none),
          icon: const Icon(Icons.restart_alt),
          label: Text(AppLocalizations.of(context)!.appearanceColorTuningReset),
        ),
      ),
    ),
  );
}

class _PanelBody extends StatefulWidget {
  const new({
    required this.basis,
    required this.tuning,
    required this.onPreview,
    required this.onCommit,
    this.onPreviewEnd,
  });

  final ColorTuningBasis basis;
  final ValueListenable<ColorTuning> tuning;
  final ValueChanged<ColorTuning> onPreview;
  final ValueChanged<ColorTuning> onCommit;
  final VoidCallback? onPreviewEnd;

  @override
  State<_PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<_PanelBody> {
  late ColorTuning _shown = widget.tuning.value;

  /// Which mode's Brightness the second ruler edits; starts on the mode shown.
  late bool _darkMode = widget.basis.dark;
  bool _previewing = false;

  late RulerBand _colorBand;
  Object? _colorBandKey;
  late RulerBand _brightnessBand;
  Object? _brightnessBandKey;

  @override
  void initState() {
    super.initState();
    widget.tuning.addListener(_follow);
  }

  @override
  void didUpdateWidget(_PanelBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tuning != oldWidget.tuning) {
      oldWidget.tuning.removeListener(_follow);
      widget.tuning.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.tuning.removeListener(_follow);
    if (_previewing) {
      // A provider cannot change while the tree is being torn down.
      final end = widget.onPreviewEnd;
      if (end != null) scheduleMicrotask(end);
    }
    super.dispose();
  }

  /// Follows a change made elsewhere (applying a Look, a failed save putting
  /// the old value back), but never yanks a ruler mid-gesture for the echo of
  /// an earlier preview.
  void _follow() {
    if (_previewing || widget.tuning.value == _shown) return;
    setState(() => _shown = widget.tuning.value);
  }

  void _preview(ColorTuning next) {
    if (next == _shown) return;
    setState(() {
      _shown = next;
      _previewing = true;
    });
    widget.onPreview(next);
  }

  void _commit() {
    _previewing = false;
    widget.onCommit(_shown);
  }

  int get _depth => _darkMode ? _shown.darkDepth : _shown.lightDepth;

  ColorTuning _with({int? vividness, int? depth}) => ColorTuning(
    vividness: vividness ?? _shown.vividness,
    lightDepth: !_darkMode && depth != null ? depth : _shown.lightDepth,
    darkDepth: _darkMode && depth != null ? depth : _shown.darkDepth,
  );

  /// Swatches for the steps −5…+5 of one axis, with the tick colour that
  /// reads on each. [at] gives the adjustment for a step.
  RulerBand _buildBand({
    required bool dark,
    required bool oled,
    required ColorAdjustment Function(int step) at,
    required Color Function(ColorScheme) swatch,
    required Color Function(ColorScheme) ink,
  }) {
    final schemes = [
      for (var step = -5; step <= 5; step++)
        buildStyledColorScheme(
          seed: widget.basis.seed,
          brightness: dark ? Brightness.dark : Brightness.light,
          oled: oled,
          style: widget.basis.style,
          adjustment: at(step),
        ),
    ];
    return RulerBand(
      colors: [for (final scheme in schemes) swatch(scheme)],
      inks: [for (final scheme in schemes) ink(scheme)],
    );
  }

  /// Intensity, in the mode shown now. Rebuilt only when an input changes, not
  /// on every theme frame.
  RulerBand get _intensityBand {
    final basis = widget.basis;
    final depth = _shown.forMode(dark: basis.dark).depth;
    final key = (
      basis.seed.toARGB32(),
      basis.style,
      basis.dark,
      basis.oled,
      depth,
    );
    if (_colorBandKey != key) {
      _colorBandKey = key;
      _colorBand = _buildBand(
        dark: basis.dark,
        oled: basis.oled,
        at: (step) => ColorAdjustment(vividness: step, depth: depth),
        swatch: (scheme) => scheme.primary,
        ink: (scheme) => scheme.onPrimary,
      );
    }
    return _colorBand;
  }

  /// Brightness, in the mode the switch is on, so Light shows paper and Dark
  /// or OLED their own surfaces.
  RulerBand get _depthBand {
    final basis = widget.basis;
    final oled = _darkMode && basis.darkIsOled;
    final key = (
      basis.seed.toARGB32(),
      basis.style,
      _darkMode,
      oled,
      _shown.vividness,
    );
    if (_brightnessBandKey != key) {
      _brightnessBandKey = key;
      _brightnessBand = _buildBand(
        dark: _darkMode,
        oled: oled,
        at: (step) => ColorAdjustment(vividness: _shown.vividness, depth: step),
        // OLED keeps its surface black at every depth; its panels move.
        swatch: (scheme) => oled ? scheme.surfaceContainerHigh : scheme.surface,
        ink: (scheme) => scheme.onSurfaceVariant,
      );
    }
    return _brightnessBand;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final basis = widget.basis;
    final intensityBand = _intensityBand;
    final elsewhere = _darkMode != basis.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ColorTuningRulerRow(
          keyName: 'color',
          label: l10n.appearanceColorTuningColor,
          lowCaption: l10n.appearanceColorTuningMuted,
          highCaption: l10n.appearanceColorTuningVivid,
          lowTooltip: l10n.appearanceColorTuningMoreMuted,
          highTooltip: l10n.appearanceColorTuningMoreVivid,
          step: _shown.vividness,
          band: intensityBand,
          // The needle is the live primary: the swatch under it.
          accent: intensityBand.colors[_shown.vividness + 5],
          onStep: (step) => _preview(_with(vividness: step)),
          onEnd: _commit,
        ),
        const SizedBox(height: NavisSpace.md),
        ColorTuningRulerRow(
          keyName: 'brightness',
          label: l10n.appearanceColorTuningBrightness,
          lowCaption: l10n.appearanceColorTuningLighter,
          highCaption: l10n.appearanceColorTuningDeeper,
          lowTooltip: l10n.appearanceColorTuningLighterBackgrounds,
          highTooltip: l10n.appearanceColorTuningDeeperBackgrounds,
          step: _depth,
          band: _depthBand,
          belowTitle: Padding(
            padding: const EdgeInsets.only(top: NavisSpace.xs),
            child: Wrap(
              spacing: NavisSpace.sm,
              runSpacing: NavisSpace.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SegmentedButton<bool>(
                  key: const ValueKey<String>('colorTuning-mode'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(
                      value: false,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: Text(l10n.appearanceThemeLight),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: Text(l10n.appearanceThemeDark),
                    ),
                  ],
                  selected: <bool>{_darkMode},
                  onSelectionChanged: (selection) =>
                      setState(() => _darkMode = selection.first),
                ),
                // Only when the strip shows a mode other than the one on
                // screen, where the app will not show the change.
                if (elsewhere)
                  Text(
                    _darkMode
                        ? l10n.appearanceColorTuningAppliesDark
                        : l10n.appearanceColorTuningAppliesLight,
                    key: const ValueKey<String>('colorTuning-applies'),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          onStep: (step) => _preview(_with(depth: step)),
          onEnd: _commit,
        ),
      ],
    );
  }
}

/// One ruler in the Speed and Pitch layout: a title and value readout, then
/// the − stepper, the ruler and the + stepper, then the captions of its two
/// ends. The ruler's value is the whole step, −5…+5.
///
/// The ruler is the Speed and Pitch [AdjustmentRuler] in whole-step mode, so
/// its scale is a picture of the result: one gradient strip through eleven
/// colours, one per step, taken from the style's real scheme at that step.
class ColorTuningRulerRow extends StatelessWidget {
  const new({
    required this.keyName,
    required this.label,
    required this.lowCaption,
    required this.highCaption,
    required this.lowTooltip,
    required this.highTooltip,
    required this.step,
    required this.band,
    required this.onStep,
    required this.onEnd,
    this.accent,
    this.belowTitle,
    super.key,
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

  /// Reports each whole step while the ruler moves or a stepper is pressed.
  final ValueChanged<int> onStep;

  /// Reports that input ended (drag release, stepper, keyboard).
  final VoidCallback onEnd;

  /// Shown between the title and the ruler, for example a mode switch.
  final Widget? belowTitle;

  static const int _limit = 5;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final readout = step == 0
        ? l10n.appearanceColorTuningDefault
        : signedStep(step);

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

    return Column(
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
        ?belowTitle,
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
                // 64 px a step keeps about six steps in view, so the colours
                // ahead of the needle preview where it is going, and leaves
                // room for a click every 8 px between steps.
                pixelsPerUnit: 64,
                labelBuilder: (value) => signedStep(value.round()),
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
              // Each caption keeps its end and wraps rather than overflows at
              // large text sizes.
              child: Row(
                textDirection: TextDirection.ltr,
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
    );
  }
}
