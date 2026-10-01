import 'dart:math' as math;

import 'package:flutter/foundation.dart';

double roundAdjustment(double value) => (value * 100).round() / 100;

bool isHundredth(double value) =>
    (value - roundAdjustment(value)).abs() < 0.000000001;

/// Steps from integer hundredths so repeated input does not accumulate drift.
double stepAdjustment(double value, int hundredths) =>
    ((value * 100).round() + hundredths) / 100;

@immutable
class PlaybackAdjustments {
  const new({
    this.speed = 1,
    double pitchSemitones = 0,
    this.lockPitchToSpeed = false,
  }) : _independentPitchSemitones = pitchSemitones;

  final double speed;
  final double _independentPitchSemitones;
  final bool lockPitchToSpeed;
  double get pitchSemitones => lockPitchToSpeed
      ? 12 * math.log(speed) / math.ln2
      : _independentPitchSemitones;
  double get speedPercent => (speed - 1) * 100;
  double get pitchFactor =>
      lockPitchToSpeed ? speed : math.pow(2, pitchSemitones / 12).toDouble();
  bool get isNone => !lockPitchToSpeed && speed == 1 && pitchSemitones == 0;

  bool get isValid =>
      speed.isFinite &&
      speed > 0 &&
      speedPercent.isFinite &&
      speedPercent.abs() < 90071992547409 &&
      pitchSemitones.isFinite &&
      pitchSemitones.abs() < 90071992547409 &&
      pitchFactor.isFinite &&
      pitchFactor > 0;

  PlaybackAdjustments copyWith({
    double? speed,
    double? pitchSemitones,
    bool? lockPitchToSpeed,
  }) => PlaybackAdjustments(
    speed: speed ?? this.speed,
    // Unlocking captures the actual derived pitch without rounding its sound.
    pitchSemitones: pitchSemitones ?? this.pitchSemitones,
    lockPitchToSpeed: lockPitchToSpeed ?? this.lockPitchToSpeed,
  );

  @override
  bool operator ==(Object other) =>
      other is PlaybackAdjustments &&
      speed == other.speed &&
      pitchSemitones == other.pitchSemitones &&
      lockPitchToSpeed == other.lockPitchToSpeed;

  @override
  int get hashCode => Object.hash(speed, pitchSemitones, lockPitchToSpeed);
}

/// Inclusive selectable hundredths; absent endpoints remain unbounded.
@immutable
class AdjustmentRange {
  const new({this.minimum, this.maximum});
  factory inward(double? minimum, double? maximum) => AdjustmentRange(
    minimum: minimum == null ? null : (minimum * 100 - 1e-9).ceil() / 100,
    maximum: maximum == null ? null : (maximum * 100 + 1e-9).floor() / 100,
  );

  final double? minimum;
  final double? maximum;

  double constrain(double value) {
    var result = roundAdjustment(value);
    if (minimum != null) result = math.max(result, minimum!);
    if (maximum != null) result = math.min(result, maximum!);
    return result;
  }

  bool contains(double value) =>
      value.isFinite &&
      (minimum == null || value >= minimum! - 1e-10) &&
      (maximum == null || value <= maximum! + 1e-10);
}

@immutable
class PlaybackPreset {
  const new({required this.id, required this.name, required this.values});

  static const noneId = 'none';

  /// Names that would be confused with the built-in Normal choice. Stored
  /// presets are still decoded leniently so older data is never dropped.
  static bool isReservedName(String name) =>
      const {'none', 'normal'}.contains(name.trim().toLowerCase());
  static const none = PlaybackPreset(
    id: noneId,
    name: 'None',
    values: PlaybackAdjustments(),
  );

  final String id;
  final String name;
  final PlaybackAdjustments values;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'speed': values.speed,
    'pitchSemitones': values.pitchSemitones,
    'lockPitchToSpeed': values.lockPitchToSpeed,
  };

  static PlaybackPreset? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final name = raw['name'];
    final speed = raw['speed'];
    final pitch = raw['pitchSemitones'];
    final lock = raw['lockPitchToSpeed'] ?? false;
    if (id is! String ||
        id.isEmpty ||
        id == noneId ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().toLowerCase() == 'none' ||
        speed is! num ||
        pitch is! num ||
        lock is! bool) {
      return null;
    }
    final values = PlaybackAdjustments(
      speed: speed.toDouble(),
      pitchSemitones: pitch.toDouble(),
      lockPitchToSpeed: lock,
    );
    if (!values.isValid) {
      return null;
    }
    return PlaybackPreset(id: id, name: name.trim(), values: values);
  }
}

/// Limits describe the initialized audio backend, never the visible ruler.
@immutable
class PlaybackAdjustmentCapabilities {
  const new({
    this.pitchSupported = false,
    this.minimumSpeed,
    this.maximumSpeed,
    this.minimumPitchFactor,
    this.maximumPitchFactor,
    this.minimumTempoRatio,
  });

  static const android = PlaybackAdjustmentCapabilities(
    pitchSupported: true,
    minimumSpeed: 0.1,
    maximumSpeed: 8,
    minimumPitchFactor: 0.1,
    maximumPitchFactor: 8,
  );
  static const mediaKit = PlaybackAdjustmentCapabilities(
    pitchSupported: true,
    minimumPitchFactor: 0.01,
    maximumPitchFactor: 100,
    minimumTempoRatio: 0.01,
  );

  final bool pitchSupported;
  final double? minimumSpeed;
  final double? maximumSpeed;
  final double? minimumPitchFactor;
  final double? maximumPitchFactor;
  final double? minimumTempoRatio;

  AdjustmentRange speedRange(PlaybackAdjustments values) {
    var minimum = math.max(0.01, minimumSpeed ?? 0.01);
    var maximum = maximumSpeed;
    if (values.lockPitchToSpeed) {
      minimum = math.max(minimum, minimumPitchFactor ?? minimum);
      if (maximumPitchFactor != null) {
        maximum = maximum == null
            ? maximumPitchFactor
            : math.min(maximum, maximumPitchFactor!);
      }
    } else if (minimumTempoRatio != null) {
      minimum = math.max(minimum, minimumTempoRatio! * values.pitchFactor);
    }
    return AdjustmentRange.inward(minimum, maximum);
  }

  AdjustmentRange pitchRange(PlaybackAdjustments values) {
    var maximum = maximumPitchFactor;
    if (minimumTempoRatio != null) {
      final ratioMaximum = values.speed / minimumTempoRatio!;
      maximum = maximum == null
          ? ratioMaximum
          : math.min(maximum, ratioMaximum);
    }
    return AdjustmentRange.inward(
      minimumPitchFactor == null
          ? null
          : 12 * math.log(minimumPitchFactor!) / math.ln2,
      maximum == null ? null : 12 * math.log(maximum) / math.ln2,
    );
  }

  bool supports(PlaybackAdjustments values) {
    if (!values.isValid ||
        (!pitchSupported &&
            (values.pitchSemitones != 0 || values.lockPitchToSpeed))) {
      return false;
    }
    final pitch = values.pitchFactor;
    final ratio = values.speed / pitch;
    return ratio.isFinite &&
        ratio > 0 &&
        (minimumSpeed == null || values.speed >= minimumSpeed!) &&
        (maximumSpeed == null || values.speed <= maximumSpeed!) &&
        (minimumPitchFactor == null || pitch >= minimumPitchFactor!) &&
        (maximumPitchFactor == null || pitch <= maximumPitchFactor!) &&
        (minimumTempoRatio == null || ratio >= minimumTempoRatio!);
  }
}
