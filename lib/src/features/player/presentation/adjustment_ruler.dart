import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';

/// Strength of the haptic tick for a ruler movement.
enum RulerTick { none, minor, major, neutral }

/// Which ruler lines a drag from [from] to [to] crossed or landed on.
///
/// Lines sit on every hundredth (the minor ticks) and every tenth (the
/// labelled major ticks). The line the drag started on does not count, so a
/// finger resting on a line stays quiet. Crossing [resetValue] (1.00× speed
/// or 0 semitones) outranks a major line, which outranks a minor one.
@visibleForTesting
RulerTick rulerTickFeedback(double from, double to, double resetValue) {
  if (from == to) return RulerTick.none;
  const epsilon = 1e-9;
  final start = from * 100;
  final end = to * 100;
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
  final reset = (resetValue * 100).round();
  if (reset >= first && reset <= last) return RulerTick.neutral;
  if ((first / 10).ceil() * 10 <= last) return RulerTick.major;
  return RulerTick.minor;
}

/// A continuous visual scale that settles onto supported hundredths.
class AdjustmentRuler extends StatefulWidget {
  const AdjustmentRuler({
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
    super.key,
  });

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
  double _wheelPixels = 0;
  double? _requestedValue;
  bool _dragging = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _visualValue = widget.value;
    _settle =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 140),
        )..addListener(() {
          setState(() {
            _visualValue =
                _from + (_to - _from) * Curves.easeOut.transform(_settle.value);
          });
        });
  }

  @override
  void didUpdateWidget(AdjustmentRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interactionToken != oldWidget.interactionToken ||
        widget.enabled != oldWidget.enabled ||
        (widget.value != oldWidget.value && widget.value != _requestedValue)) {
      _dragging = false;
      _wheelPixels = 0;
      _settle.stop();
      _visualValue = widget.value;
    } else if (!_dragging && !_settle.isAnimating) {
      _visualValue = widget.value;
    }
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
    final next = widget.range.constrain(value);
    _requestedValue = next;
    if (next != widget.value) widget.onChanged(next);
  }

  void _adjust(int hundredths) {
    _dragging = false;
    _settle.stop();
    final next = widget.range.constrain(
      stepAdjustment(widget.value, hundredths),
    );
    if ((hundredths < 0 && next >= widget.value) ||
        (hundredths > 0 && next <= widget.value)) {
      return;
    }
    setState(() => _visualValue = next);
    _send(next);
    widget.onChangeEnd();
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    final target = widget.range.constrain(_visualValue);
    _send(target);
    widget.onChangeEnd();
    if (MediaQuery.disableAnimationsOf(context) ||
        (_visualValue - target).abs() < 1e-10) {
      setState(() => _visualValue = target);
    } else {
      _from = _visualValue;
      _to = target;
      _settle.forward(from: 0);
    }
  }

  bool _canAdjust(int step) {
    if (!widget.enabled) return false;
    final next = widget.range.constrain(stepAdjustment(widget.value, step));
    return step < 0 ? next < widget.value : next > widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      value: widget.valueLabel,
      enabled: widget.enabled,
      increasedValue: widget.range
          .constrain(stepAdjustment(widget.value, 1))
          .toStringAsFixed(2),
      decreasedValue: widget.range
          .constrain(stepAdjustment(widget.value, -1))
          .toStringAsFixed(2),
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
            _settle.stop();
            _wheelPixels = 0;
            setState(
              () => _visualValue = widget.range.constrain(widget.resetValue),
            );
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
              final pixelsPerStep = widget.pixelsPerUnit / 100;
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
                      rulerTickFeedback(_visualValue, value, widget.resetValue),
                      details.sourceTimeStamp,
                    );
                    setState(() => _visualValue = value);
                    _send(value);
                  }
                : null,
            onHorizontalDragEnd: widget.enabled ? (_) => _endDrag() : null,
            onHorizontalDragCancel: widget.enabled ? _endDrag : null,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colors.surfaceContainerLowest,
                    colors.surfaceContainerHigh,
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? colors.primary : colors.outlineVariant,
                ),
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
                  borderRadius: BorderRadius.circular(12),
                  child: CustomPaint(
                    painter: _RulerPainter(
                      value: _visualValue,
                      range: widget.range,
                      pixelsPerUnit: widget.pixelsPerUnit,
                      color: widget.enabled
                          ? colors.onSurfaceVariant
                          : colors.outline,
                      accent: colors.primary,
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
  _RulerPainter({
    required this.value,
    required this.range,
    required this.pixelsPerUnit,
    required this.color,
    required this.accent,
    required this.textDirection,
    required this.textScaler,
  });
  final double value;
  final AdjustmentRange range;
  final double pixelsPerUnit;
  final Color color;
  final Color accent;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final radius = size.width / (2 * pixelsPerUnit);
    final start = ((value - radius) * 100).floor();
    final end = ((value + radius) * 100).ceil();
    final paint = Paint()..strokeWidth = 1;
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [accent.withValues(alpha: 0.13), accent.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: Offset(center, 26), radius: 45));
    canvas.drawCircle(Offset(center, 26), 45, glow);
    for (var tick = start; tick <= end; tick++) {
      final tickValue = tick / 100;
      if (!range.contains(tickValue)) continue;
      final x = center + (tickValue - value) * pixelsPerUnit;
      final edge = math.min(x, size.width - x) / (size.width * 0.15);
      final opacity = edge.clamp(0.0, 1.0);
      final major = tick % 10 == 0;
      final centered = (tickValue - value).abs() < 0.005;
      final endpoint = tickValue == range.minimum || tickValue == range.maximum;
      paint.color = (centered || endpoint ? accent : color).withValues(
        alpha: opacity * (major ? 1 : 0.7),
      );
      canvas.drawLine(
        Offset(x, 12),
        Offset(x, major || endpoint ? 36 : 25),
        paint,
      );
      if (major) {
        final label = TextPainter(
          text: TextSpan(
            text: tickValue.toStringAsFixed(2),
            style: TextStyle(color: paint.color, fontSize: 11),
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
    canvas.drawLine(Offset(center, 5), Offset(center, 38), paint);
    canvas.drawCircle(Offset(center, 6), 3, paint);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      value != old.value ||
      color != old.color ||
      accent != old.accent ||
      pixelsPerUnit != old.pixelsPerUnit ||
      textDirection != old.textDirection ||
      textScaler != old.textScaler ||
      range.minimum != old.range.minimum ||
      range.maximum != old.range.maximum;
}
