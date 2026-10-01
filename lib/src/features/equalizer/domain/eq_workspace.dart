import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

const eqCustomWorkspace = 'custom';

bool sameEqCurve(EqConfiguration a, EqConfiguration b) =>
    a.copyWith(enabled: false) == b.copyWith(enabled: false);

/// Retains an installation-local working curve for every visited editing mode.
class EqWorkspace {
  new({required this.mode, required Map<EqMode, EqConfiguration> curves})
    : curves = Map.unmodifiable(curves);

  factory fromJson(Map<String, dynamic> json) {
    final mode = EqMode.values.byName(json['mode'] as String);
    final curves = {
      for (final entry in (json['curves'] as Map<String, dynamic>).entries)
        EqMode.values.byName(entry.key): EqConfiguration.fromJson(
          entry.value as Map<String, dynamic>,
        ),
    };
    if (!curves.containsKey(mode) ||
        curves.entries.any((e) => e.key != e.value.mode)) {
      throw const FormatException('Invalid EQ workspace.');
    }
    return EqWorkspace(mode: mode, curves: curves);
  }

  factory fromConfiguration(EqConfiguration configuration) => EqWorkspace(
    mode: configuration.mode,
    curves: {configuration.mode: configuration},
  );

  final EqMode mode;
  final Map<EqMode, EqConfiguration> curves;
  EqConfiguration get configuration => curves[mode]!;

  EqWorkspace edit(EqConfiguration configuration) => EqWorkspace(
    mode: configuration.mode,
    curves: {...curves, configuration.mode: configuration},
  );

  EqWorkspace changeMode(EqMode next) =>
      edit(curves[next] ?? configuration.changeMode(next));

  bool differsFrom(EqConfiguration saved) =>
      curves.values.any((curve) => !sameEqCurve(curve, saved));

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'curves': {
      for (final entry in curves.entries) entry.key.name: entry.value.toJson(),
    },
  };
}

/// Trims trailing fractional zeros only; integers such as 440 stay intact.
String eqNumber(double value, {int decimals = 2}) {
  final text = value.toStringAsFixed(decimals);
  final trimmed = text.contains('.')
      ? text.replaceFirst(RegExp(r'\.?0+$'), '')
      : text;
  return trimmed == '-0' ? '0' : trimmed;
}
