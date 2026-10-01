import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_response.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';

/// Response samples calculated once per configuration change, never in paint.
class EqGraphSamples {
  new(EqConfiguration configuration, double rate, int? selected) {
    if (!configuration.supportsSampleRate(rate)) return;
    final response = EqResponse(configuration, sampleRate: rate);
    final frequencies = <double>{
      for (var i = 0; i <= 240; i++) (20 * math.pow(1000, i / 240)).toDouble(),
      for (final band in configuration.filters)
        for (final factor in [.98, .995, 1.0, 1.005, 1.02])
          (band.frequencyHz * factor).clamp(20, 20000),
    }.toList()..sort();
    final band = selected == null || selected >= configuration.filters.length
        ? null
        : EqBiquad.forFilter(configuration.filters[selected], rate);
    for (final hz in frequencies) {
      final db = response.curveDbAt(hz);
      combined.add(Offset(hz, db));
      maximum = math.max(maximum, db.clamp(-60, 768).abs().toDouble());
      if (band != null) individual.add(Offset(hz, band.decibelsAt(hz, rate)));
    }
  }
  final combined = <Offset>[];
  final individual = <Offset>[];

  /// Largest absolute gain of the combined curve, in dB.
  double maximum = 0;

  /// Smallest ±range in 6 dB steps that shows the whole combined curve.
  double get fittedLimit => fittedLimitAtLeast(24);

  /// Smallest 6 dB step that contains the response, but never below
  /// [minimum]; compact previews use a tighter floor so gentle curves stay
  /// visible.
  double fittedLimitAtLeast(double minimum) =>
      math.max(minimum, (maximum / 6).ceil() * 6.0);
}

/// Short axis/chip label: `63`, `1k`, `1.2k`, `16k`.
String eqShortFrequency(double hz) => hz >= 1000
    ? '${eqNumber(hz / 1000, decimals: hz >= 10000 ? 0 : 1)}k'
    : eqNumber(hz, decimals: 0);

/// Signed gain readout that keeps the up-to-two-decimal display contract.
String eqSignedGain(double db) {
  final text = eqNumber(db);
  return db > 0 && text != '0' ? '+$text' : text;
}

/// Paints the calculated response. Selection is conveyed by fill, size and
/// contrast rather than hue, so it stays legible in monochrome themes.
class EqGraphPainter extends CustomPainter {
  new({
    required this.samples,
    required this.configuration,
    required this.geometry,
    required this.colors,
    required this.selected,
    required this.textScaler,
    this.labelStyle = const TextStyle(),
    this.outputOffset,
    this.dragging = false,
    this.readOnly = false,
    this.filterLabel = '',
    this.outputLabel = '',
  });

  final EqGraphSamples samples;
  final EqConfiguration configuration;
  final EqGraphGeometry geometry;
  final ColorScheme colors;
  final int? selected;
  final TextScaler textScaler;

  /// Theme typography for canvas labels, which do not inherit DefaultTextStyle.
  final TextStyle labelStyle;
  final double? outputOffset;
  final bool dragging;
  final bool readOnly;
  final String filterLabel;
  final String outputLabel;

  static const _majorFrequencies = [
    20.0,
    50.0,
    100.0,
    200.0,
    500.0,
    1000.0,
    2000.0,
    5000.0,
    10000.0,
    20000.0,
  ];

  /// Handle radius used for painting; touch targets stay [EqGraphGeometry.hitRadius].
  static double handleRadius(int count) => count > 16 ? 6.5 : 9;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;
    if (plot.width < 32 || plot.height < 24) return;
    final active = selected != null && selected! < configuration.filters.length
        ? configuration.filters[selected!]
        : null;
    final marker = active == null || readOnly
        ? null
        : _markerRect(size, plot, active);
    _grid(canvas, size, plot, marker);
    canvas.save();
    canvas.clipRect(plot.inflate(1));
    if (active != null && !readOnly) {
      final x = geometry.x(active.frequencyHz);
      _dashedLine(
        canvas,
        [Offset(x, plot.top), Offset(x, plot.bottom)],
        Paint()
          ..color = colors.primary.withValues(alpha: .35)
          ..strokeWidth = 1,
      );
    }
    if (samples.individual.isNotEmpty) _selectedResponse(canvas, plot);
    _trace(
      canvas,
      samples.combined,
      Paint()
        ..color = colors.primary.withValues(
          alpha: configuration.enabled || readOnly ? 1 : .6,
        )
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
    if (outputOffset != null) {
      _dashedLine(
        canvas,
        [
          for (final point in samples.combined)
            Offset(
              geometry.x(point.dx),
              geometry.y(point.dy + outputOffset!).clamp(plot.top, plot.bottom),
            ),
        ],
        Paint()
          ..color = colors.onSurfaceVariant
          ..strokeWidth = 1.75
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.restore();
    _clipping(canvas, plot);
    if (outputOffset != null) _legend(canvas, plot);
    if (!readOnly) {
      _handles(canvas);
      if (active != null) {
        _frequencyMarker(canvas, size, plot, active);
        if (dragging) _readout(canvas, plot, active);
      }
    }
  }

  void _grid(Canvas canvas, Size size, Rect plot, Rect? marker) {
    final minor = Paint()
      ..color = colors.outlineVariant.withValues(alpha: .45)
      ..strokeWidth = .6;
    final major = Paint()
      ..color = colors.outlineVariant
      ..strokeWidth = .8;
    final step = geometry.limit <= 24 ? 6.0 : geometry.limit / 4;
    for (
      var gain = -geometry.limit;
      gain <= geometry.limit + .01;
      gain += step
    ) {
      final y = geometry.y(gain);
      final labelled =
          gain == 0 ||
          (gain.abs() - geometry.limit).abs() < .01 ||
          (gain.abs() - geometry.limit / 2).abs() < .01;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        gain == 0
            ? (Paint()
                ..color = colors.outline
                ..strokeWidth = 1)
            : labelled
            ? major
            : minor,
      );
      if (labelled && plot.height >= 60) {
        final label = _label(
          eqSignedGain(gain.roundToDouble()),
          colors.onSurfaceVariant,
        );
        label.paint(
          canvas,
          Offset(plot.left - label.width - 4, y - label.height / 2),
        );
      }
    }
    var labelEdge = double.negativeInfinity;
    for (final hz in _majorFrequencies) {
      final x = geometry.x(hz);
      final decade = hz == 20 || hz == 100 || hz == 1000 || hz == 10000;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        decade ? major : minor,
      );
      final label = _label(eqShortFrequency(hz), colors.onSurfaceVariant);
      final left = (x - label.width / 2).clamp(
        plot.left - 4,
        size.width - label.width,
      );
      if (left < labelEdge + 6) continue;
      final bounds = Rect.fromLTWH(
        left,
        plot.bottom + 5,
        label.width,
        label.height,
      );
      if (marker != null && marker.inflate(3).overlaps(bounds)) continue;
      label.paint(canvas, bounds.topLeft);
      labelEdge = left + label.width;
    }
  }

  void _selectedResponse(Canvas canvas, Rect plot) {
    final zero = geometry.y(0).clamp(plot.top, plot.bottom);
    final points = [
      for (final point in samples.individual)
        Offset(
          geometry.x(point.dx),
          geometry.y(point.dy).clamp(plot.top - 2, plot.bottom + 2),
        ),
    ];
    if (points.isEmpty) return;
    final area = Path()..moveTo(points.first.dx, zero);
    for (final point in points) {
      area.lineTo(point.dx, point.dy);
    }
    area
      ..lineTo(points.last.dx, zero)
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = colors.primary.withValues(alpha: .16),
    );
    _trace(
      canvas,
      samples.individual,
      Paint()
        ..color = colors.primary.withValues(alpha: .55)
        ..strokeWidth = 1.25
        ..style = PaintingStyle.stroke,
    );
  }

  void _trace(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.isEmpty) return;
    final plot = geometry.plot;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = geometry.x(points[i].dx);
      final y = geometry.y(points[i].dy).clamp(plot.top - 2, plot.bottom + 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  /// Fixed pixel dashes, independent of response sample density.
  void _dashedLine(Canvas canvas, List<Offset> points, Paint paint) {
    const on = 6.0;
    const off = 4.0;
    var remaining = on;
    var drawing = true;
    for (var i = 1; i < points.length; i++) {
      var start = points[i - 1];
      final end = points[i];
      var length = (end - start).distance;
      while (length > 0) {
        final part = math.min(length, remaining);
        final next = Offset.lerp(start, end, part / length)!;
        if (drawing) canvas.drawLine(start, next, paint);
        length -= part;
        remaining -= part;
        start = next;
        if (remaining <= 0) {
          drawing = !drawing;
          remaining = drawing ? on : off;
        }
      }
    }
  }

  /// Marks frequency ranges whose response lies outside the visible range.
  void _clipping(Canvas canvas, Rect plot) {
    final paint = Paint()
      ..color = colors.error
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final top in [true, false]) {
      double? start;
      var previous = plot.left;
      for (final point in samples.combined) {
        final x = geometry.x(point.dx);
        final outside = top
            ? point.dy > geometry.limit
            : point.dy < -geometry.limit;
        if (outside) {
          start ??= x;
        } else if (start != null) {
          final y = top ? plot.top : plot.bottom;
          canvas.drawLine(Offset(start, y), Offset(previous, y), paint);
          start = null;
        }
        previous = x;
      }
      if (start != null) {
        final y = top ? plot.top : plot.bottom;
        canvas.drawLine(Offset(start, y), Offset(previous, y), paint);
      }
    }
  }

  void _legend(Canvas canvas, Rect plot) {
    var y = plot.top + 6;
    for (final (text, dashed) in [(filterLabel, false), (outputLabel, true)]) {
      if (text.isEmpty) continue;
      final label = _label(text, colors.onSurface);
      final origin = Offset(plot.left + 8, y + label.height / 2);
      final paint = Paint()
        ..color = dashed ? colors.onSurfaceVariant : colors.primary
        ..strokeWidth = dashed ? 1.75 : 2.5;
      final background = Rect.fromLTWH(
        plot.left + 4,
        y - 2,
        label.width + 36,
        label.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(background, const Radius.circular(4)),
        Paint()..color = colors.surfaceContainerHigh.withValues(alpha: .85),
      );
      if (dashed) {
        _dashedLine(canvas, [origin, origin + const Offset(20, 0)], paint);
      } else {
        canvas.drawLine(origin, origin + const Offset(20, 0), paint);
      }
      label.paint(canvas, Offset(plot.left + 32, y));
      y += label.height + 6;
    }
  }

  void _handles(Canvas canvas) {
    final filters = configuration.filters;
    final radius = handleRadius(filters.length);
    final points = [for (final filter in filters) geometry.handle(filter)];
    bool crowded(int i) {
      for (var j = 0; j < points.length; j++) {
        if (j != i && (points[j] - points[i]).distance < radius * 2 + 3) {
          return true;
        }
      }
      return false;
    }

    for (var i = 0; i < filters.length; i++) {
      if (i == selected) continue;
      final filter = filters[i];
      final point = points[i];
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = filter.enabled
              ? colors.surfaceContainerHighest
              : colors.surface,
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = filter.enabled ? colors.onSurfaceVariant : colors.outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = filter.enabled ? 1.5 : 1.25,
      );
      if (radius >= 8 && !crowded(i)) {
        _centered(
          canvas,
          '${i + 1}',
          point,
          filter.enabled ? colors.onSurface : colors.outline,
          size: 9.5,
        );
      }
    }
    if (selected == null || selected! >= filters.length) return;
    final filter = filters[selected!];
    final point = points[selected!];
    final large = radius + 3;
    canvas.drawCircle(
      point,
      large + (dragging ? 14 : 8),
      Paint()..color = colors.primary.withValues(alpha: dragging ? .24 : .18),
    );
    canvas.drawCircle(
      point,
      large,
      Paint()..color = filter.enabled ? colors.primary : colors.surface,
    );
    canvas.drawCircle(
      point,
      large,
      Paint()
        ..color = filter.enabled ? colors.onPrimary : colors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = filter.enabled ? 1.5 : 2.5,
    );
    _centered(
      canvas,
      '${selected! + 1}',
      point,
      filter.enabled ? colors.onPrimary : colors.primary,
      size: 10.5,
      bold: true,
    );
  }

  TextPainter _markerLabel(EqFilter filter) => _label(
    '${eqNumber(filter.frequencyHz)} Hz',
    colors.onPrimary,
    bold: true,
  );

  Rect _markerRect(Size size, Rect plot, EqFilter filter) {
    final text = _markerLabel(filter);
    final width = text.width + 10;
    final left = (geometry.x(filter.frequencyHz) - width / 2)
        .clamp(0.0, math.max(0.0, size.width - width))
        .toDouble();
    return Rect.fromLTWH(left, plot.bottom + 3, width, text.height + 4);
  }

  void _frequencyMarker(Canvas canvas, Size size, Rect plot, EqFilter filter) {
    final rect = _markerRect(size, plot, filter);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = colors.primary,
    );
    _markerLabel(filter).paint(canvas, Offset(rect.left + 5, rect.top + 2));
  }

  /// Keeps the dragged values visible above a finger instead of beneath it.
  void _readout(Canvas canvas, Rect plot, EqFilter filter) {
    final text = _label(
      filter.usesGain
          ? '${eqNumber(filter.frequencyHz)} Hz · ${eqSignedGain(filter.gainDb)} dB'
          : '${eqNumber(filter.frequencyHz)} Hz',
      colors.onInverseSurface,
      bold: true,
      size: 11.5,
    );
    final point = geometry.handle(filter);
    final width = text.width + 16;
    final height = text.height + 10;
    var top = point.dy - 44 - height / 2;
    if (top < plot.top) top = point.dy + 30;
    final left = (point.dx - width / 2)
        .clamp(plot.left, math.max(plot.left, plot.right - width))
        .toDouble();
    final rect = Rect.fromLTWH(left, top, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = colors.inverseSurface,
    );
    text.paint(canvas, Offset(left + 8, top + 5));
  }

  void _centered(
    Canvas canvas,
    String text,
    Offset center,
    Color color, {
    double size = 10,
    bool bold = false,
  }) {
    final label = _label(text, color, size: size, bold: bold, scale: false);
    label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
  }

  TextPainter _label(
    String text,
    Color color, {
    double size = 10,
    bool bold = false,
    bool scale = true,
  }) => _EqLabelCache.label(
    text,
    labelStyle.copyWith(
      color: color,
      fontSize: size,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.1,
      letterSpacing: 0,
    ),
    scale ? textScaler : TextScaler.noScaling,
  );

  @override
  bool shouldRepaint(EqGraphPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.configuration != configuration ||
      oldDelegate.geometry.plot != geometry.plot ||
      oldDelegate.geometry.limit != geometry.limit ||
      oldDelegate.colors != colors ||
      oldDelegate.selected != selected ||
      oldDelegate.outputOffset != outputOffset ||
      oldDelegate.dragging != dragging ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.filterLabel != filterLabel ||
      oldDelegate.outputLabel != outputLabel;
}

/// Reuses laid-out axis and handle labels across drag frames.
abstract final class _EqLabelCache {
  static final _labels = <(String, TextStyle, TextScaler), TextPainter>{};

  static TextPainter label(String text, TextStyle style, TextScaler scaler) {
    final key = (text, style, scaler);
    final cached = _labels.remove(key);
    if (cached != null) return _labels[key] = cached;
    if (_labels.length >= 256) {
      final oldest = _labels.keys.first;
      _labels.remove(oldest)!.dispose();
    }
    return _labels[key] = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
  }
}
