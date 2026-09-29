import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

void main() {
  test('official AutoEQ exports preserve their own exact layout and Q', () {
    final parser = EqImportParser();
    final parametric = parser.parse(
      File('test/fixtures/autoeq/ParametricEQ.txt').readAsStringSync(),
      id: 'parametric',
      name: 'HD 600',
    );
    final fixed = parser.parse(
      File('test/fixtures/autoeq/FixedBandEQ.txt').readAsStringSync(),
      id: 'fixed',
      name: 'HD 600 fixed',
      fixedBand: true,
    );
    expect(parametric.configuration.mode, EqMode.advanced);
    expect(parametric.configuration.preampDb, -6.3);
    expect(parametric.configuration.filters.first.type, EqFilterType.lowShelf);
    expect(parametric.configuration.filters.first.q, .7);
    expect(fixed.configuration.mode, EqMode.importedFixed);
    expect(fixed.configuration.filters.first.frequencyHz, 31);
    expect(fixed.configuration.filters.first.q, 1.41);
  });

  final parser = EqImportParser();
  EqPreset parse(String text, {bool fixedBand = false}) => parser.parse(
    text,
    id: 'example',
    name: 'Example headphone',
    fixedBand: fixedBand,
  );

  const profile = '''
Preamp: -5.5 dB
Filter 1: ON LSC Fc 105 Hz Gain -1.1 dB Q 0.70
Filter 2: ON PK Fc 2343 Hz Gain 4.8 dB Q 1.08
Filter 3: OFF HSC Fc 10000 Hz Gain -6.6 dB Q 0.70
''';

  test('AutoEQ filters preserve order, Q, flags, and raw source', () {
    final preset = parse(profile);
    expect(preset.configuration.mode, EqMode.advanced);
    expect(preset.configuration.preampDb, -5.5);
    expect(preset.configuration.enabled, isFalse);
    expect(preset.configuration.filters[0].type, EqFilterType.lowShelf);
    expect(preset.configuration.filters[1].frequencyHz, 2343);
    expect(preset.configuration.filters[1].q, 1.08);
    expect(preset.configuration.filters[2].enabled, isFalse);
    expect(preset.source!.originalText, profile);
  });

  test('fixed-band import retains exact rounded frequencies and Q', () {
    final preset = parse(
      'Preamp: -1 dB\nFilter 1: ON PK Fc 31 Hz Gain 2 dB Q 1.41',
      fixedBand: true,
    );
    expect(preset.configuration.mode, EqMode.importedFixed);
    expect(preset.configuration.filters.single.frequencyHz, 31);
    expect(preset.configuration.filters.single.q, 1.41);
  });

  test('ten arbitrary parametric filters do not become ten-band mode', () {
    final preset = parse(
      'Preamp: -10 dB\n${List.generate(10, (i) => 'Filter ${i + 1}: ON PK '
          'Fc ${100 + i * 200} Hz Gain 1 dB Q 2.13').join('\n')}',
    );
    expect(preset.configuration.mode, EqMode.advanced);
  });

  test('accepts BOM, CRLF, comments, disabled flags, and precise decimals', () {
    final preset = parse(
      '\uFEFF# profile\r\nPreamp: -3.123456 dB\r\n'
      'Filter 2: OFF PK Fc 105.123 Hz Gain +2.34567 dB Q .7123 # note\r\n',
    );
    expect(preset.configuration.preampDb, -3.123456);
    expect(preset.configuration.filters.single.frequencyHz, 105.123);
    expect(preset.configuration.filters.single.gainDb, 2.34567);
  });

  test('rejects malformed input without applying a partial import', () {
    for (final invalid in [
      '',
      'Preamp: -3 dB',
      'Preamp: -3 dB\nPreamp: -4 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1',
      '$profile\nInclude: other.txt',
      '$profile\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1',
      'Preamp: -3 dB\nFilter 1: ON PK Fc 100 Hz Gain 25 dB Q 1',
      'Preamp: -3 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 0',
      'Preamp: NaN dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1',
      'GraphicEQ: 20 -3; 1000 0',
    ]) {
      expect(() => parse(invalid), throwsFormatException, reason: invalid);
    }
  });

  test('rejects oversized imports and excessive filters', () {
    expect(
      () => parse(List.filled(EqImportParser.maximumBytes + 1, 'a').join()),
      throwsFormatException,
    );
    final filters = List.generate(
      33,
      (i) => 'Filter ${i + 1}: ON PK Fc 1000 Hz Gain 1 dB Q 1',
    ).join('\n');
    expect(() => parse('Preamp: -3 dB\n$filters'), throwsFormatException);
  });

  test(
    'versioned Navis export preserves values and assigns import identity',
    () {
      final original = parse(profile);
      final imported = parser.parse(
        jsonEncode(original.toJson()),
        id: 'new-identity',
        name: 'ignored',
      );
      expect(imported.id, 'new-identity');
      expect(imported.name, original.name);
      expect(imported.configuration, original.configuration);
      expect(imported.source!.originalText, profile);
    },
  );
}
