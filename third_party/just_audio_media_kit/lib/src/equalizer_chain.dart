import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Builds commands exclusively from validated numbers, never imported text.
class EqualizerChain {
  EqualizerChain({required this.filters, required this.state});

  factory EqualizerChain.compile(EqualizerConfigurationMessage configuration,
      {required double speed, required double pitch, double? sampleRate}) {
    if (!configuration.isValid ||
        !speed.isFinite ||
        speed <= 0 ||
        !pitch.isFinite ||
        pitch <= 0) {
      throw const FormatException('Invalid audio processing configuration');
    }
    final tempo = '@navis_tempo:scaletempo:scale=${speed / pitch}';
    if (!configuration.enabled) {
      return EqualizerChain(
          filters: tempo,
          state: EqualizerStateMessage(enabled: false, sampleRate: sampleRate));
    }
    if (sampleRate == null) {
      return EqualizerChain(
          filters: tempo,
          state: const EqualizerStateMessage(enabled: false, pending: true));
    }
    // mpv's speed property applies the pitch shift after filters. Designing at
    // rate*pitch keeps each filter centered at its authored audible frequency.
    final effectiveRate = sampleRate * pitch;
    if (!configuration.supportsSampleRate(effectiveRate)) {
      return EqualizerChain(
          filters: tempo,
          state: EqualizerStateMessage(
              enabled: false,
              sampleRate: sampleRate,
              reason:
                  'This profile cannot be represented at the current sample rate and pitch.'));
    }
    final response =
        EqualizerResponse(configuration, sampleRate: effectiveRate);
    final parts = <String>[
      'volume=${response.effectivePreampDb}dB:precision=double',
      for (final f in configuration.filters.where((f) => f.enabled))
        _biquad(EqualizerBiquad.forFilter(f, effectiveRate)),
    ];
    return EqualizerChain(
        filters: '$tempo,@navis_eq:lavfi=[${parts.join(',')}]',
        state: EqualizerStateMessage(
            enabled: true,
            sampleRate: sampleRate,
            responseSampleRate: effectiveRate,
            headroomDb: response.headroomDb));
  }
  final String filters;
  final EqualizerStateMessage state;

  /// The peak limiter behind the whole chain, -1 dBFS. Byte-constant, so mpv
  /// keeps the filter instance when `af` is rewritten at a gapless join.
  /// `level=0` (no auto-level) and `latency=1` (sample-aligned) are mandatory,
  /// and a bad graph here is accepted by mpv and only fails at audio init,
  /// which drops the file: never edit it without a runtime check.
  static const limiterStage =
      '@navis_lim:lavfi=[alimiter=limit=0.891:level=0:attack=5:release=100:latency=1]';

  /// The wrapper form of the filter name: unlike the `lavfi=[...]` graph above,
  /// mpv looks the name up while parsing `af`, so a build without `alimiter`
  /// (the bundled Windows and macOS libmpv today) rejects it synchronously.
  static const limiterProbeChain = '@navis_probe:lavfi-alimiter';

  /// Whether this libmpv has `alimiter`, probed once on an idle player by
  /// writing [limiterProbeChain] through [setProperty] (true when accepted),
  /// then clearing `af` again.
  static bool probeLimiter(
      bool Function(String name, String value) setProperty) {
    final found = setProperty('af', limiterProbeChain);
    setProperty('af', '');
    return found;
  }

  /// The whole `af` chain: the ReplayGain stage of [db] ahead of [filters],
  /// and the limiter after them while [db] boosts and [limiterSupported] says
  /// the probe found it. mpv runs filters in float, so a boost cannot clip
  /// before the output converts; the limiter only catches what it would clip
  /// to. The RG label is always present: `af-command` needs it to exist.
  String withReplayGain(double db, {bool limiterSupported = false}) {
    final stage =
        '@navis_rg:lavfi=[volume=${db.toStringAsFixed(3)}dB:precision=float]';
    return [
      stage,
      if (filters.isNotEmpty) filters,
      if (limiterSupported && db > 0) limiterStage,
    ].join(',');
  }

  static String _biquad(EqualizerBiquad c) =>
      'biquad=b0=${c.b0}:b1=${c.b1}:b2=${c.b2}:a0=1:a1=${c.a1}:a2=${c.a2}:precision=f64:transform=tdii';
}
