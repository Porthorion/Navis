import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Strength of the haptic tick for a ruler movement.
enum RulerTick { none, minor, major, neutral }

/// Which ruler lines a drag from [from] to [to] crossed or landed on.
///
/// Lines sit on every hundredth (the minor ticks) and every tenth (the
/// labelled major ticks). The line the drag started on does not count, so a
/// finger resting on a line stays quiet. Crossing [resetValue] (1.00× speed
/// or 0 semitones) outranks a major line, which outranks a minor one.
///
/// A whole-step ruler ([AdjustmentRuler.snapStep]) passes its own [perUnit]
/// line density and a null [majorEvery], so every step is a minor tick.
@visibleForTesting
RulerTick rulerTickFeedback(
  double from,
  double to,
  double resetValue, {
  int perUnit = 100,
  int? majorEvery = 10,
}) {
  if (from == to) return RulerTick.none;
  const epsilon = 1e-9;
  final start = from * perUnit;
  final end = to * perUnit;
  final int first;
  final int last;
  if (end > start) {
    first = (start + epsilon).floor() + 1;
    last = (end + epsilon).floor();
  } else {
    first = (end - epsilon).ceil();
    last = (start - epsilon).ceil() - 1;
  }
  if (last < first) return RulerTick.none;
  final reset = (resetValue * perUnit).round();
  if (reset >= first && reset <= last) return RulerTick.neutral;
  if (majorEvery != null && (first / majorEvery).ceil() * majorEvery <= last) {
    return RulerTick.major;
  }
  return RulerTick.minor;
}

/// A stepped colour strip painted behind a whole-step ruler's scale.
///
/// [colors] holds one swatch per step from the range minimum to its maximum
/// and [inks] the tick colour readable on each swatch.
@immutable
class RulerBand {
  const new({required this.colors, required this.inks})
    : assert(colors.length == inks.length, 'one ink per swatch');

  final List<Color> colors;
  final List<Color> inks;

  @override
  bool operator ==(Object other) =>
      other is RulerBand &&
      listEquals(colors, other.colors) &&
      listEquals(inks, other.inks);

  @override
  int get hashCode => Object.hash(Object.hashAll(colors), Object.hashAll(inks));
}

/// A continuous visual scale that settles onto supported hundredths, or onto
/// whole steps when [snapStep] is set (the colour rulers: value is the step
/// number, so −5…+5 is the range −5…5 with [snapStep] 1).
///
/// The optional [labelBuilder], [snapStep], [band] and [accent] default to
/// the Speed and Pitch behaviour.
class AdjustmentRuler extends StatefulWidget {
  const new({
    required this.value,
    required this.label,
    required this.valueLabel,
    required this.onChanged,
    required this.onChangeEnd,
    this.range = const AdjustmentRange(),
    this.resetValue = 0,
    this.pixelsPerUnit = 800,
    this.interactionToken = 0,
    this.enabled = true,
    this.readOnly = false,
    this.snapStep,
    this.labelBuilder = _hundredthsLabel,
    this.band,
    this.accent,
    super.key,
  });

  static String _hundredthsLabel(double value) => value.toStringAsFixed(2);

  final double value;
  final String label;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;
  final AdjustmentRange range;
  final double resetValue;
  final double pixelsPerUnit;
  final int interactionToken;
  final bool enabled;

  /// Shown at full contrast while another control drives the value (Pitch
  /// Lock): input stays off like [enabled] false, but nothing is greyed out.
  final bool readOnly;

  /// Spacing of the supported values when they are whole steps rather than
  /// hundredths. Dragging settles on a step, every step is one minor haptic
  /// tick (stronger on [resetValue]) and keyboard and wheel input move a step
  /// at a time.
  final double? snapStep;

  /// Text for a tick label and for the semantics of the next value.
  final String Function(double value) labelBuilder;

  /// Stepped colour strip behind the scale. Needs [snapStep]; its first
  /// swatch sits on `range.minimum`.
  final RulerBand? band;

  /// The needle and neutral-line colour; defaults to the theme primary.
  final Color? accent;

  @override
  State<AdjustmentRuler> createState() => _AdjustmentRulerState();
}

class _AdjustmentRulerState extends State<AdjustmentRuler>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final AnimationController _settle;
  late double _visualValue;
  double _from = 0;
  double _to = 0;
  Curve _curve = Curves.easeOut;

  /// True while gliding to a value chosen elsewhere (chip, preset, reset),
  /// which ticks like a swipe; drag-release settling stays silent.
  bool _glideTicks = false;
  double _lastGlideValue = 0;
  double _wheelPixels = 0;
  double? _requestedValue;
  bool _dragging = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _visualValue = widget.value;
    _settle = AnimationController(vsync: this, duration: _settleDuration)
      ..addListener(() {
        final next = _from + (_to - _from) * _curve.transform(_settle.value);
        if (_glideTicks && widget.enabled) {
          _tick(_feedback(_lastGlideValue, next), _settle.lastElapsedDuration);
        }
        _lastGlideValue = next;
        setState(() => _visualValue = next);
      })
      ..addStatusListener((status) {
        // Only a finished glide stops ticking. `forward(from: 0)` on a
        // completed controller first reports `dismissed` as it rewinds,
        // which previously silenced every glide after the first.
        if (status == AnimationStatus.completed) {
          _glideTicks = false;
        }
      });
  }

  static const _settleDuration = Duration(milliseconds: 140);

  /// Lines per unit of value: hundredths, or one per snap step.
  int get _perUnit =>
      widget.snapStep == null ? 100 : (1 / widget.snapStep!).round();

  /// Every tenth line is labelled and stronger; whole steps have none.
  int? get _majorEvery => widget.snapStep == null ? 10 : null;

  /// [value] moved by [steps] lines, without accumulating float drift.
  double _stepBy(double value, int steps) => widget.snapStep == null
      ? stepAdjustment(value, steps)
      : value + steps * widget.snapStep!;

  /// [value] on the nearest supported line and inside the range.
  double _constrain(double value) {
    final step = widget.snapStep;
    return widget.range.constrain(
      step == null ? value : (value / step).round() * step,
    );
  }

  RulerTick _feedback(double from, double to) => rulerTickFeedback(
    from,
    to,
    widget.resetValue,
    perUnit: _perUnit,
    majorEvery: _majorEvery,
  );

  @override
  void didUpdateWidget(AdjustmentRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    final externalChange =
        widget.value != oldWidget.value && widget.value != _requestedValue;
    if (widget.enabled != oldWidget.enabled) {
      _snapTo(widget.value);
    } else if (externalChange ||
        widget.interactionToken != oldWidget.interactionToken) {
      _glideTo(widget.value);
    } else if (!_dragging && !_settle.isAnimating) {
      _visualValue = widget.value;
    }
  }

  void _snapTo(double value) {
    _dragging = false;
    _wheelPixels = 0;
    _glideTicks = false;
    _settle.stop();
    _visualValue = value;
  }

  /// Sweeps the scale to [target] as if it were swiped there: farther jumps
  /// take a little longer, and the lines it passes tick like a drag.
  void _glideTo(double target) {
    // Measured in 800 px units so a step scale glides as long as the same
    // distance on the speed scale would.
    final distance = (target - _visualValue).abs() * widget.pixelsPerUnit / 800;
    if (distance < 1e-10 || MediaQuery.disableAnimationsOf(context)) {
      _snapTo(target);
      return;
    }
    _dragging = false;
    _wheelPixels = 0;
    _from = _visualValue;
    _to = target;
    _lastGlideValue = _visualValue;
    // Glide timestamps restart at zero, unlike drag timestamps.
    _lastMinorTick = null;
    _glideTicks = true;
    _curve = Curves.easeInOutCubic;
    _settle.duration = Duration(
      milliseconds: (160 + math.min(distance, 2) * 160).round(),
    );
    _settle.forward(from: 0);
  }

  /// Minor ticks closer together than this are skipped so fast swipes do
  /// not saturate the vibration motor; major and neutral ticks always fire.
  static const _minorTickSpacing = Duration(milliseconds: 12);
  Duration? _lastMinorTick;

  void _tick(RulerTick tick, Duration? at) {
    switch (tick) {
      case RulerTick.none:
        return;
      case RulerTick.minor:
        final last = _lastMinorTick;
        if (at != null && last != null && at - last < _minorTickSpacing) {
          return;
        }
        _lastMinorTick = at;
        unawaited(HapticFeedback.selectionClick());
      case RulerTick.major:
        unawaited(HapticFeedback.lightImpact());
      case RulerTick.neutral:
        unawaited(HapticFeedback.mediumImpact());
    }
  }

  void _send(double value) {
    final next = _constrain(value);
    _requestedValue = next;
    if (next != widget.value) widget.onChanged(next);
  }

  void _adjust(int steps) {
    _dragging = false;
    _glideTicks = false;
    _settle.stop();
    final next = _constrain(_stepBy(widget.value, steps));
    if ((steps < 0 && next >= widget.value) ||
        (steps > 0 && next <= widget.value)) {
      return;
    }
    setState(() => _visualValue = next);
    _send(next);
    widget.onChangeEnd();
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    final target = _constrain(_visualValue);
    _send(target);
    widget.onChangeEnd();
    if (MediaQuery.disableAnimationsOf(context) ||
        (_visualValue - target).abs() < 1e-10) {
      setState(() => _visualValue = target);
    } else {
      _from = _visualValue;
      _to = target;
      _glideTicks = false;
      _curve = Curves.easeOut;
      _settle.duration = _settleDuration;
      _settle.forward(from: 0);
    }
  }

  bool _canAdjust(int step) {
    if (!widget.enabled) return false;
    final next = _constrain(_stepBy(widget.value, step));
    return step < 0 ? next < widget.value : next > widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      value: widget.valueLabel,
      enabled: widget.enabled,
      increasedValue: widget.labelBuilder(_constrain(_stepBy(widget.value, 1))),
      decreasedValue: widget.labelBuilder(
        _constrain(_stepBy(widget.value, -1)),
      ),
      onIncrease: _canAdjust(1) ? () => _adjust(1) : null,
      onDecrease: _canAdjust(-1) ? () => _adjust(-1) : null,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: widget.enabled,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (_, event) {
          if (!widget.enabled || event is KeyUpEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          final step = HardwareKeyboard.instance.isShiftPressed ? 10 : 1;
          if (key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.arrowUp) {
            _adjust(step);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowDown) {
            _adjust(-step);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.home) {
            _dragging = false;
            _glideTicks = false;
            _settle.stop();
            _wheelPixels = 0;
            setState(() => _visualValue = _constrain(widget.resetValue));
            _send(widget.resetValue);
            widget.onChangeEnd();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerSignal: (event) {
            if (!widget.enabled ||
                !_focus.hasFocus ||
                event is! PointerScrollEvent) {
              return;
            }
            GestureBinding.instance.pointerSignalResolver.register(event, (
              signal,
            ) {
              final scroll = signal as PointerScrollEvent;
              _wheelPixels += scroll.scrollDelta.dx != 0
                  ? scroll.scrollDelta.dx
                  : scroll.scrollDelta.dy;
              final pixelsPerStep = widget.pixelsPerUnit / _perUnit;
              final steps = (_wheelPixels / pixelsPerStep).truncate();
              if (steps != 0) {
                _wheelPixels -= steps * pixelsPerStep;
                _adjust(steps);
              }
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? _focus.requestFocus : null,
            onHorizontalDragStart: widget.enabled
                ? (_) {
                    _focus.requestFocus();
                    _glideTicks = false;
                    _settle.stop();
                    _dragging = true;
                    _visualValue = widget.value;
                  }
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (details) {
                    if (!_dragging) return;
                    var value =
                        _visualValue - details.delta.dx / widget.pixelsPerUnit;
                    if (widget.range.minimum != null) {
                      value = math.max(value, widget.range.minimum!);
                    }
                    if (widget.range.maximum != null) {
                      value = math.min(value, widget.range.maximum!);
                    }
                    _tick(
                      _feedback(_visualValue, value),
                      details.sourceTimeStamp,
                    );
                    setState(() => _visualValue = value);
                    _send(value);
                  }
                : null,
            onHorizontalDragEnd: widget.enabled ? (_) => _endDrag() : null,
            onHorizontalDragCancel: widget.enabled ? _endDrag : null,
            // Flat on the panel: the outline appears only as a focus ring.
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: NavisShapeData.of(context).mdAll,
                border: _focused ? Border.all(color: colors.primary) : null,
              ),
              child: SizedBox(
                width: double.infinity,
                height:
                    76 +
                    12 *
                        (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(
                          0,
                          3,
                        ),
                child: ClipRRect(
                  borderRadius: NavisShapeData.of(context).mdAll,
                  child: CustomPaint(
                    painter: _RulerPainter(
                      value: _visualValue,
                      range: widget.range,
                      resetValue: widget.resetValue,
                      pixelsPerUnit: widget.pixelsPerUnit,
                      color: widget.enabled || widget.readOnly
                          ? colors.onSurfaceVariant
                          : colors.outline,
                      accent: widget.enabled || widget.readOnly
                          ? widget.accent ?? colors.primary
                          : colors.outline,
                      perUnit: _perUnit,
                      majorEvery: _majorEvery,
                      labelBuilder: widget.labelBuilder,
                      band: widget.band,
                      bandRadius: NavisShapeData.of(context).sm,
                      labelStyle:
                          Theme.of(context).textTheme.labelSmall ??
                          const TextStyle(),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settle.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _RulerPainter extends CustomPainter {
  new({
    required this.value,
    required this.range,
    required this.resetValue,
    required this.pixelsPerUnit,
    required this.color,
    required this.accent,
    required this.labelStyle,
    required this.textDirection,
    required this.textScaler,
    required this.perUnit,
    required this.majorEvery,
    required this.labelBuilder,
    required this.band,
    required this.bandRadius,
  });
  final double value;
  final AdjustmentRange range;
  final double resetValue;
  final double pixelsPerUnit;
  final Color color;

  /// Reserved for the marker and the neutral line, so accent always means
  /// "you are here" or "normal".
  final Color accent;
  final TextStyle labelStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// Lines per unit of value, and how many lines apart the labelled major
  /// ones sit (null when every line is minor).
  final int perUnit;
  final int? majorEvery;
  final String Function(double value) labelBuilder;
  final RulerBand? band;
  final double bandRadius;

  // Vertical layout of a banded scale: the strip, with the detent rising to
  // its top and the other lines standing on its bottom edge.
  static const _bandTop = 14.0;
  static const _bandBottom = 38.0;
  static const _bandTickTop = 29.0;

  /// The band swatch index for [tickValue], clamped to the strip.
  int _bandIndex(RulerBand band, double tickValue) {
    final minimum = range.minimum ?? 0;
    return ((tickValue - minimum) * perUnit).round().clamp(
      0,
      band.colors.length - 1,
    );
  }

  void _paintBand(Canvas canvas, Size size, RulerBand band) {
    final center = size.width / 2;
    final minimum = range.minimum ?? 0;
    final half = pixelsPerUnit / (2 * perUnit);
    double x(double v) => center + (v - value) * pixelsPerUnit;
    final strip = RRect.fromLTRBR(
      x(minimum) - half,
      _bandTop,
      x(minimum + (band.colors.length - 1) / perUnit) + half,
      _bandBottom,
      Radius.circular(bandRadius),
    );
    // The strip fades at the edges exactly like the ticks do, so the scale
    // reads as sliding past rather than being cut off.
    final bounds = Offset.zero & size;
    canvas
      ..saveLayer(bounds, Paint())
      ..save()
      ..clipRRect(strip);
    final paint = Paint();
    for (var i = 0; i < band.colors.length; i++) {
      final centre = x(minimum + i / perUnit);
      if (centre + half < 0 || centre - half > size.width) continue;
      paint.color = band.colors[i];
      // A hair of overlap hides the seam between neighbouring swatches.
      canvas.drawRect(
        Rect.fromLTRB(
          centre - half,
          _bandTop,
          centre + half + 0.5,
          _bandBottom,
        ),
        paint,
      );
    }
    canvas
      ..restore()
      // A hairline frames the strip, so near-surface swatches (light paper,
      // dark panels) still read as a scale against the page.
      ..drawRRect(
        strip.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.4),
      )
      ..drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = LinearGradient(
            colors: const [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: const [0, 0.15, 0.85, 1],
          ).createShader(bounds),
      )
      ..restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final radius = size.width / (2 * pixelsPerUnit);
    final start = ((value - radius) * perUnit).floor();
    final end = ((value + radius) * perUnit).ceil();
    final neutral = (resetValue * perUnit).round();
    final band = this.band;
    if (band != null) _paintBand(canvas, size, band);
    final paint = Paint()..strokeWidth = 1;
    for (var tick = start; tick <= end; tick++) {
      final tickValue = tick / perUnit;
      if (!range.contains(tickValue)) continue;
      final x = center + (tickValue - value) * pixelsPerUnit;
      final edge = math.min(x, size.width - x) / (size.width * 0.15);
      final opacity = edge.clamp(0.0, 1.0);
      final isNeutral = tick == neutral;
      final major =
          (majorEvery != null && tick % majorEvery! == 0) ||
          isNeutral ||
          perUnit == 1;
      final endpoint = tickValue == range.minimum || tickValue == range.maximum;
      if (band != null) {
        // Lines read against their own swatch; labels sit below the strip.
        final ink = band.inks[_bandIndex(band, tickValue)];
        canvas.drawLine(
          Offset(x, isNeutral ? _bandTop : _bandTickTop),
          Offset(x, _bandBottom),
          paint..color = ink.withValues(alpha: opacity * (isNeutral ? 1 : 0.7)),
        );
      } else {
        paint.color = (isNeutral ? accent : color).withValues(
          alpha: opacity * (major ? 1 : 0.7),
        );
        // The neutral line rises above the scale, like a detent mark.
        canvas.drawLine(
          Offset(x, isNeutral ? 4 : 12),
          Offset(x, major || endpoint ? 36 : 25),
          paint,
        );
      }
      if (major) {
        final label = TextPainter(
          text: TextSpan(
            text: labelBuilder(tickValue),
            style: labelStyle.copyWith(
              color: band != null
                  ? (isNeutral ? accent : color).withValues(alpha: opacity)
                  : paint.color,
            ),
          ),
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout();
        label.paint(canvas, Offset(x - label.width / 2, 44));
      }
    }
    paint
      ..color = accent
      ..strokeWidth = 2;
    if (band == null) {
      canvas.drawLine(Offset(center, 0), Offset(center, 40), paint);
      return;
    }
    // The needle is the live colour above and below the strip; across it, the
    // swatch's own ink, since the colour itself would vanish into its swatch.
    canvas
      ..drawLine(Offset(center, 0), Offset(center, _bandTop), paint)
      ..drawLine(Offset(center, _bandBottom), Offset(center, 44), paint);
    canvas.drawLine(
      Offset(center, _bandTop),
      Offset(center, _bandBottom),
      paint..color = band.inks[_bandIndex(band, value)],
    );
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      value != old.value ||
      resetValue != old.resetValue ||
      color != old.color ||
      accent != old.accent ||
      labelStyle != old.labelStyle ||
      pixelsPerUnit != old.pixelsPerUnit ||
      textDirection != old.textDirection ||
      textScaler != old.textScaler ||
      range.minimum != old.range.minimum ||
      range.maximum != old.range.maximum ||
      perUnit != old.perUnit ||
      majorEvery != old.majorEvery ||
      band != old.band ||
      bandRadius != old.bandRadius;
}

/// An icon stepper that repeats while held and reports when input ends.
class RulerStepButton extends StatefulWidget {
  const new({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onStep,
    required this.onEnd,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;

  /// Applies one step; returns false once a limit stops further steps.
  final bool Function() onStep;
  final VoidCallback onEnd;

  @override
  State<RulerStepButton> createState() => _RulerStepButtonState();
}

class _RulerStepButtonState extends State<RulerStepButton> {
  static const _repeatInterval = Duration(milliseconds: 120);
  Timer? _repeat;

  void _startRepeat() {
    if (!widget.onStep()) return;
    _repeat?.cancel();
    _repeat = Timer.periodic(_repeatInterval, (_) {
      if (!mounted || !widget.onStep()) _stopRepeat();
    });
  }

  void _stopRepeat() {
    final wasRepeating = _repeat != null;
    _repeat?.cancel();
    _repeat = null;
    if (wasRepeating) widget.onEnd();
  }

  @override
  void didUpdateWidget(RulerStepButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stopRepeat();
  }

  @override
  Widget build(BuildContext context) {
    // A manual tooltip keeps hover hints without competing with hold-to-repeat
    // for the long-press gesture.
    return Tooltip(
      message: widget.tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPressStart: widget.enabled ? (_) => _startRepeat() : null,
        onLongPressEnd: widget.enabled ? (_) => _stopRepeat() : null,
        onLongPressCancel: widget.enabled ? _stopRepeat : null,
        child: IconButton(
          onPressed: widget.enabled
              ? () {
                  if (widget.onStep()) widget.onEnd();
                }
              : null,
          icon: Icon(widget.icon),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _repeat = null;
    super.dispose();
  }
}
