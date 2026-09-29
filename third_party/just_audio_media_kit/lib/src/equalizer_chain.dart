import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Builds commands exclusively from validated numbers, never imported text.
class EqualizerChain {
  EqualizerChain({required this.filters, required this.state});
  final String filters;
  final EqualizerStateMessage state;

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

  static String _biquad(EqualizerBiquad c) =>
      'biquad=b0=${c.b0}:b1=${c.b1}:b2=${c.b2}:a0=1:a1=${c.a1}:a2=${c.a2}:precision=f64:transform=tdii';
}
