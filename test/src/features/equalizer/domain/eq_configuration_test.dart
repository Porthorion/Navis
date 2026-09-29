import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

void main() {
  test('fixed modes have stable frequencies and preserve exact values', () {
    final five = EqConfiguration.flat();
    expect(five.filters.map((f) => f.frequencyHz), [
      63,
      250,
      1000,
      4000,
      16000,
    ]);
    final ten = EqConfiguration.flat(mode: EqMode.tenBand);
    expect(ten.filters.first.frequencyHz, 31.25);
    expect(ten.filters.last.frequencyHz, 16000);
    expect(five.isValid, isTrue);
    expect(ten.isValid, isTrue);
    expect(ten.isFlat, isTrue);
  });

  test('Advanced preserves sound while other fixed modes start flat', () {
    final original = EqConfiguration.flat().copyWith(
      enabled: true,
      preampDb: -4.823,
      filters: EqConfiguration.flat().filters
          .map((f) => f.copyWith(gainDb: 2.123456))
          .toList(),
    );
    final advanced = original.changeMode(EqMode.advanced);
    expect(advanced.filters, original.filters);
    expect(advanced.preampDb, original.preampDb);
    final ten = original.changeMode(EqMode.tenBand);
    expect(ten.isFlat, isTrue);
    expect(ten.enabled, isTrue);
    expect(original.isFlat, isFalse);
  });

  test('configuration JSON is versioned and round trips exactly', () {
    final config = EqConfiguration(
      enabled: true,
      mode: EqMode.advanced,
      preampDb: -6.123456789,
      filters: const [
        EqFilter(
          type: EqFilterType.lowShelf,
          frequencyHz: 105.127,
          gainDb: 3.4567,
          q: 0.71234,
        ),
      ],
    );
    expect(
      EqConfiguration.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      ),
      config,
    );
    expect(
      () => EqConfiguration.fromJson({...config.toJson(), 'version': 99}),
      throwsFormatException,
    );
  });

  test('invalid numbers, filter counts, and fixed layouts are rejected', () {
    expect(
      EqConfiguration.flat().copyWith(preampDb: double.nan).isValid,
      isFalse,
    );
    expect(
      EqConfiguration(
        mode: EqMode.advanced,
        filters: List.filled(33, const EqFilter(frequencyHz: 1000)),
      ).isValid,
      isFalse,
    );
    expect(
      EqConfiguration.flat().copyWith(filters: const []).isValid,
      isFalse,
    );
    expect(const EqFilter(frequencyHz: 1000, q: 0).isValid, isFalse);
    expect(
      const EqFilter(frequencyHz: double.infinity).isValid,
      isFalse,
    );
  });

  test('sample-rate limits apply to the complete enabled profile', () {
    final config = EqConfiguration.flat();
    expect(config.supportsSampleRate(44100), isTrue);
    expect(config.supportsSampleRate(22050), isFalse);
    expect(
      config
          .copyWith(
            filters: config.filters
                .map((f) => f.copyWith(enabled: f.frequencyHz < 11025))
                .toList(),
          )
          .supportsSampleRate(22050),
      isTrue,
    );
  });

  test('preset round trip keeps source text, revision, and precision', () {
    final preset = EqPreset(
      id: 'headphone',
      name: 'Headphone',
      configuration: EqConfiguration.flat(),
      source: const EqSource(
        originalText: 'Preamp: -3.14 dB\r\n',
        revision: 'example-revision',
        target: 'Example target',
      ),
    );
    final result = EqPreset.fromJson(
      jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
    );
    expect(result.configuration, preset.configuration);
    expect(result.source!.originalText, preset.source!.originalText);
    expect(result.source!.revision, 'example-revision');
    expect(result.source!.target, 'Example target');
    expect(result.builtIn, isFalse);
  });
}
