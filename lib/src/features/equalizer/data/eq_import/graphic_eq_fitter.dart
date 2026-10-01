import 'dart:math' as math;

import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_response.dart';

/// A GraphicEQ curve approximated with peaking filters.
class GraphicEqFit {
  const new({
    required this.filters,
    required this.rmsErrorDb,
    required this.maxErrorDb,
  });

  final List<EqFilter> filters;
  final double rmsErrorDb;
  final double maxErrorDb;
}

/// Fits a GraphicEQ curve (frequency/gain points, as AutoEQ and Wavelet
/// write them) with up to 31 third-octave peaking filters.
///
/// A graphic EQ can list hundreds of points, while Navis applies at most
/// 32 biquads. Bands sit on a fixed log grid
/// from 20 Hz to 20 kHz; their gains are solved with a few damped
/// Gauss–Newton steps against the curve sampled at 256 log-spaced points,
/// using the same biquad response Navis plays. Gains are limited to ±24 dB
/// and bands under 0.05 dB are dropped.
GraphicEqFit fitGraphicEq(List<(double, double)> points) {
  final curve = _Curve(points);
  const bandCount = 31;
  const sampleCount = 256;
  const sampleRate = 48000.0;
  // Third-octave spacing: Q = sqrt(2^N) / (2^N - 1) with N = 1/3.
  final q = math.sqrt(math.pow(2, 1 / 3)) / (math.pow(2, 1 / 3) - 1);
  double logSpaced(int index, int count) =>
      20 * math.pow(1000, index / (count - 1)).toDouble();
  final centers = List<double>.generate(
    bandCount,
    (k) => logSpaced(k, bandCount),
  );
  final grid = List<double>.generate(
    sampleCount,
    (i) => logSpaced(i, sampleCount),
  );
  final target = grid.map(curve.at).toList(growable: false);

  List<double> bandResponse(int band, double gain) {
    final biquad = EqBiquad.forFilter(
      EqFilter(frequencyHz: centers[band], gainDb: gain, q: q),
      sampleRate,
    );
    return <double>[
      for (final frequency in grid) biquad.decibelsAt(frequency, sampleRate),
    ];
  }

  final gains = centers.map((hz) => curve.at(hz).clamp(-24.0, 24.0)).toList();
  var responses = <List<double>>[
    for (var k = 0; k < bandCount; k++) bandResponse(k, gains[k]),
  ];
  List<double> residual() => <double>[
    for (var i = 0; i < sampleCount; i++)
      responses.fold<double>(0, (sum, band) => sum + band[i]) - target[i],
  ];

  for (var iteration = 0; iteration < 5; iteration++) {
    final r = residual();
    // Jacobian column k: how the summed response moves with band k's gain.
    final jacobian = <List<double>>[];
    for (var k = 0; k < bandCount; k++) {
      final step = gains[k] > 23 ? -0.5 : 0.5;
      final moved = bandResponse(k, gains[k] + step);
      jacobian.add(<double>[
        for (var i = 0; i < sampleCount; i++)
          (moved[i] - responses[k][i]) / step,
      ]);
    }
    final normal = List.generate(bandCount, (_) => List.filled(bandCount, 0.0));
    final rhs = List.filled(bandCount, 0.0);
    var trace = 0.0;
    for (var a = 0; a < bandCount; a++) {
      for (var b = a; b < bandCount; b++) {
        var sum = 0.0;
        for (var i = 0; i < sampleCount; i++) {
          sum += jacobian[a][i] * jacobian[b][i];
        }
        normal[a][b] = sum;
        normal[b][a] = sum;
      }
      trace += normal[a][a];
      var sum = 0.0;
      for (var i = 0; i < sampleCount; i++) {
        sum -= jacobian[a][i] * r[i];
      }
      rhs[a] = sum;
    }
    // Tikhonov damping keeps neighbouring bands from fighting each other.
    final damping = 1e-3 * trace / bandCount;
    for (var a = 0; a < bandCount; a++) {
      normal[a][a] += damping;
    }
    final delta = _solveSymmetric(normal, rhs);
    var moved = 0.0;
    for (var k = 0; k < bandCount; k++) {
      final next = (gains[k] + delta[k]).clamp(-24.0, 24.0);
      moved = math.max(moved, (next - gains[k]).abs());
      gains[k] = next;
    }
    responses = <List<double>>[
      for (var k = 0; k < bandCount; k++) bandResponse(k, gains[k]),
    ];
    if (moved < 0.01) break;
  }

  final filters = <EqFilter>[
    for (var k = 0; k < bandCount; k++)
      if (gains[k].abs() >= 0.05)
        EqFilter(
          frequencyHz: _round(centers[k], 1),
          gainDb: _round(gains[k], 2),
          q: _round(q, 3),
        ),
  ];
  final kept = <List<double>>[
    for (var k = 0; k < bandCount; k++)
      if (gains[k].abs() >= 0.05) responses[k],
  ];
  var squared = 0.0;
  var worst = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final error =
        kept.fold<double>(0, (sum, band) => sum + band[i]) - target[i];
    squared += error * error;
    worst = math.max(worst, error.abs());
  }
  return GraphicEqFit(
    filters: filters,
    rmsErrorDb: math.sqrt(squared / sampleCount),
    maxErrorDb: worst,
  );
}

double _round(double value, int digits) {
  final scale = math.pow(10, digits);
  return (value * scale).roundToDouble() / scale;
}

/// Solves A·x = b for a symmetric positive-definite A (Cholesky).
List<double> _solveSymmetric(List<List<double>> a, List<double> b) {
  final n = b.length;
  final l = List.generate(n, (_) => List.filled(n, 0.0));
  for (var i = 0; i < n; i++) {
    for (var j = 0; j <= i; j++) {
      var sum = a[i][j];
      for (var k = 0; k < j; k++) {
        sum -= l[i][k] * l[j][k];
      }
      if (i == j) {
        l[i][i] = math.sqrt(math.max(sum, 1e-12));
      } else {
        l[i][j] = sum / l[j][j];
      }
    }
  }
  final y = List.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    var sum = b[i];
    for (var k = 0; k < i; k++) {
      sum -= l[i][k] * y[k];
    }
    y[i] = sum / l[i][i];
  }
  final x = List.filled(n, 0.0);
  for (var i = n - 1; i >= 0; i--) {
    var sum = y[i];
    for (var k = i + 1; k < n; k++) {
      sum -= l[k][i] * x[k];
    }
    x[i] = sum / l[i][i];
  }
  return x;
}

/// The curve between its points, interpolated on a log-frequency axis and
/// held flat beyond its first and last point.
class _Curve {
  new(List<(double, double)> points) : _points = _normalize(points);

  final List<(double, double)> _points;

  static List<(double, double)> _normalize(List<(double, double)> points) {
    final byFrequency = <double, double>{};
    for (final (hz, db) in points) {
      if (hz.isFinite && hz > 0 && db.isFinite) byFrequency[hz] = db;
    }
    return byFrequency.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
  }

  int get length => _points.length;

  double at(double frequency) {
    if (frequency <= _points.first.$1) return _points.first.$2;
    if (frequency >= _points.last.$1) return _points.last.$2;
    var low = 0;
    var high = _points.length - 1;
    while (high - low > 1) {
      final middle = (low + high) >> 1;
      if (_points[middle].$1 <= frequency) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final (f0, g0) = _points[low];
    final (f1, g1) = _points[high];
    final t =
        (math.log(frequency) - math.log(f0)) / (math.log(f1) - math.log(f0));
    return g0 + (g1 - g0) * t;
  }
}

/// Number of distinct usable points in [points].
int graphicEqPointCount(List<(double, double)> points) => _Curve(points).length;
