import 'dart:math' as math;

import 'equalizer.dart';

/// Normalized cookbook biquad coefficients, shared by response calculations.
class EqualizerBiquad {
  const EqualizerBiquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory EqualizerBiquad.forFilter(
      EqualizerFilterMessage filter, double sampleRate) {
    if (!filter.enabled || (filter.usesGain && filter.gainDb == 0)) {
      return identity;
    }
    if (!filter.isValid || filter.frequencyHz >= sampleRate / 2) {
      throw const FormatException(
        'EQ frequency exceeds the audio sample rate.',
      );
    }
    final a = math.pow(10, filter.gainDb / 40).toDouble();
    final w = 2 * math.pi * filter.frequencyHz / sampleRate;
    final c = math.cos(w);
    final alpha = math.sin(w) / (2 * filter.q);
    final root = 2 * math.sqrt(a) * alpha;
    final (b0, b1, b2, a0, a1, a2) = switch (filter.type) {
      'peaking' => (
          1 + alpha * a,
          -2 * c,
          1 - alpha * a,
          1 + alpha / a,
          -2 * c,
          1 - alpha / a,
        ),
      'lowShelf' => (
          a * ((a + 1) - (a - 1) * c + root),
          2 * a * ((a - 1) - (a + 1) * c),
          a * ((a + 1) - (a - 1) * c - root),
          (a + 1) + (a - 1) * c + root,
          -2 * ((a - 1) + (a + 1) * c),
          (a + 1) + (a - 1) * c - root,
        ),
      'highShelf' => (
          a * ((a + 1) + (a - 1) * c + root),
          -2 * a * ((a - 1) + (a + 1) * c),
          a * ((a + 1) + (a - 1) * c - root),
          (a + 1) - (a - 1) * c + root,
          2 * ((a - 1) - (a + 1) * c),
          (a + 1) - (a - 1) * c - root,
        ),
      'lowPass' => (
          (1 - c) / 2,
          1 - c,
          (1 - c) / 2,
          1 + alpha,
          -2 * c,
          1 - alpha,
        ),
      'highPass' => (
          (1 + c) / 2,
          -(1 + c),
          (1 + c) / 2,
          1 + alpha,
          -2 * c,
          1 - alpha,
        ),
      'notch' => (1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha),
      _ => throw const FormatException('Unsupported filter type'),
    };
    return EqualizerBiquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  }

  static const identity = EqualizerBiquad(1, 0, 0, 0, 0);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;

  double decibelsAt(double frequency, double sampleRate) {
    final w = 2 * math.pi * frequency / sampleRate;
    final c1 = math.cos(w);
    final c2 = math.cos(2 * w);
    final s1 = math.sin(w);
    final s2 = math.sin(2 * w);
    final nr = b0 + b1 * c1 + b2 * c2;
    final ni = -b1 * s1 - b2 * s2;
    final dr = 1 + a1 * c1 + a2 * c2;
    final di = -a1 * s1 - a2 * s2;
    final power = (nr * nr + ni * ni) / (dr * dr + di * di);
    return 10 * math.log(math.max(power, 1e-30)) / math.ln10;
  }
}

class EqualizerResponse {
  EqualizerResponse(this.configuration, {this.sampleRate = 48000}) {
    if (!configuration.isValid ||
        !configuration.supportsSampleRate(sampleRate)) {
      throw const FormatException('Unsupported EQ configuration.');
    }
    _biquads = configuration.filters
        .map((filter) => EqualizerBiquad.forFilter(filter, sampleRate))
        .toList();
  }

  final EqualizerConfigurationMessage configuration;
  final double sampleRate;
  late final List<EqualizerBiquad> _biquads;

  double curveDbAt(double frequency) => _biquads.fold(
        0,
        (gain, filter) => gain + filter.decibelsAt(frequency, sampleRate),
      );

  /// Dense logarithmic sampling plus local refinement catches narrow peaks.
  late final double maximumBoostDb = _maximumBoost();

  double _maximumBoost() {
    final upper = sampleRate / 2 * 0.9999;
    final lower = math.min(1, upper / 2);
    final step = math.log(upper / lower) / 4096;
    var best = 0.0;
    var bestLog = math.log(lower);
    for (var i = 0; i <= 4096; i++) {
      final logFrequency = math.log(lower) + i * step;
      final gain = curveDbAt(math.exp(logFrequency));
      if (gain > best) {
        best = gain;
        bestLog = logFrequency;
      }
    }
    var left = math.max(math.log(lower), bestLog - step);
    var right = math.min(math.log(upper), bestLog + step);
    for (var i = 0; i < 24; i++) {
      final a = left + (right - left) / 3;
      final b = right - (right - left) / 3;
      if (curveDbAt(math.exp(a)) > curveDbAt(math.exp(b))) {
        right = b;
      } else {
        left = a;
      }
    }
    return math.max(best, curveDbAt(math.exp((left + right) / 2)));
  }

  double get headroomDb {
    if (!configuration.autoHeadroom) return 0;
    final peak = configuration.preampDb + maximumBoostDb;
    return peak > 0 ? -peak - 0.5 : 0;
  }

  double get effectivePreampDb => configuration.preampDb + headroomDb;

  double effectiveDbAt(double frequency) =>
      curveDbAt(frequency) + effectivePreampDb;
}

extension EqualizerFilterValidation on EqualizerFilterMessage {
  bool get usesGain =>
      const ['peaking', 'lowShelf', 'highShelf'].contains(type);
  bool get isValid =>
      const ['peaking', 'lowShelf', 'highShelf', 'lowPass', 'highPass', 'notch']
          .contains(type) &&
      frequencyHz.isFinite &&
      frequencyHz >= 20 &&
      frequencyHz <= 20000 &&
      gainDb.isFinite &&
      gainDb >= -24 &&
      gainDb <= 24 &&
      q.isFinite &&
      q >= .1 &&
      q <= 20;
}

extension EqualizerConfigurationValidation on EqualizerConfigurationMessage {
  bool get isValid =>
      filters.length <= 32 &&
      filters.every((f) => f.isValid) &&
      preampDb.isFinite &&
      preampDb >= -60 &&
      preampDb <= 24;
  bool supportsSampleRate(double rate) =>
      rate.isFinite &&
      rate > 0 &&
      filters.every((f) => !f.enabled || f.frequencyHz < rate / 2);
}
