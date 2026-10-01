import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_import/graphic_eq_fitter.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_response.dart';

void main() {
  final parser = EqImportParser();
  EqImportResult text(String value, {bool? fixedBand}) =>
      parser.parseText(value, id: 'x', name: 'Imported', fixedBand: fixedBand);
  EqImportResult bytes(List<int> value) =>
      parser.parseBytes(Uint8List.fromList(value), id: 'x', name: 'Imported');
  Set<EqImportWarningCode> warnings(EqImportResult result) =>
      result.warnings.map((warning) => warning.code).toSet();

  const simple =
      'Preamp: -2.5 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.2\n';

  group('encodings', () {
    test('UTF-16 little endian with a BOM (Notepad "Unicode")', () {
      final encoded = <int>[0xFF, 0xFE];
      for (final unit in simple.codeUnits) {
        encoded.addAll(<int>[unit & 0xff, unit >> 8]);
      }
      expect(bytes(encoded).preset.configuration.preampDb, -2.5);
    });

    test('UTF-16 big endian without a BOM', () {
      final encoded = <int>[
        for (final unit in simple.codeUnits) ...<int>[unit >> 8, unit & 0xff],
      ];
      expect(bytes(encoded).preset.configuration.filters.single.gainDb, 3);
    });

    test('UTF-8 with a BOM and a Windows-1252 file', () {
      expect(
        bytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(simple)]).format,
        EqImportFormat.parametric,
      );
      // "# Beyoncé’s" in Windows-1252: é = 0xE9, ’ = 0x92.
      final legacy = <int>[
        ...'# Beyonc'.codeUnits,
        0xE9,
        0x92,
        's\n'.codeUnitAt(0),
        10,
        ...simple.codeUnits,
      ];
      expect(bytes(legacy).preset.configuration.filters, hasLength(1));
    });

    test('files over 1 MB are refused before decoding', () {
      expect(
        () => bytes(List<int>.filled(EqImportParser.maximumBytes + 1, 32)),
        throwsA(
          isA<EqImportException>().having(
            (e) => e.code,
            'code',
            EqImportErrorCode.tooLarge,
          ),
        ),
      );
    });
  });

  group('Equalizer APO language', () {
    test('comma decimals, unnumbered filters and summed preamps', () {
      final result = text(
        'Preamp: -3,5 dB\nPreamp: -1 dB\n'
        'Filter: ON PK Fc 1000 Hz Gain 2,25 dB Q 1,5\n',
      );
      final configuration = result.preset.configuration;
      expect(configuration.preampDb, -4.5);
      expect(configuration.filters.single.gainDb, 2.25);
      expect(configuration.filters.single.q, 1.5);
      expect(warnings(result), contains(EqImportWarningCode.preampSummed));
    });

    test('shelf slopes, bandwidth in octaves, passes and notches', () {
      final filters = text(
        'Preamp: -6 dB\n'
        'Filter 1: ON LS 12dB Fc 100 Hz Gain 6 dB\n'
        'Filter 2: ON HSC 6 dB Fc 8000 Hz Gain -3 dB\n'
        'Filter 3: ON PK Fc 1000 Hz Gain 2 dB BW Oct 1\n'
        'Filter 4: ON HP Fc 30 Hz\n'
        'Filter 5: ON LPQ Fc 18000 Hz Q 0.5\n'
        'Filter 6: ON NO Fc 60 Hz BW Oct 0.2\n',
      ).preset.configuration.filters;
      expect(filters.map((f) => f.type), <EqFilterType>[
        EqFilterType.lowShelf,
        EqFilterType.highShelf,
        EqFilterType.peaking,
        EqFilterType.highPass,
        EqFilterType.lowPass,
        EqFilterType.notch,
      ]);
      // 12 dB/oct is the cookbook's S = 1: Q = 1/sqrt(2).
      expect(filters[0].q, closeTo(math.sqrt1_2, 1e-9));
      // One octave: Q = sqrt(2) / (2 - 1).
      expect(filters[2].q, closeTo(math.sqrt2, 1e-9));
      expect(filters[3].q, closeTo(math.sqrt1_2, 1e-9));
      expect(filters[4].q, 0.5);
      expect(filters[5].q, greaterThan(5));
    });

    test('unsupported filters and instructions are skipped with warnings', () {
      final result = text(
        'Device: Speakers\nPreamp: -3 dB\nInclude: room.txt\n'
        'Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1\n'
        'Filter 2: ON BP Fc 500 Hz Q 1\n'
        'Delay: 3 ms\n',
      );
      expect(result.preset.configuration.filters, hasLength(1));
      expect(
        warnings(result),
        containsAll(<EqImportWarningCode>{
          EqImportWarningCode.instructionIgnored,
          EqImportWarningCode.filterDropped,
        }),
      );
    });

    test('only the first per-channel block is imported', () {
      final result = text(
        'Preamp: -3 dB\nChannel: L\n'
        'Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 1\n'
        'Channel: R\n'
        'Filter 2: ON PK Fc 200 Hz Gain 4 dB Q 1\n',
      );
      expect(result.preset.configuration.filters.single.frequencyHz, 100);
      expect(warnings(result), contains(EqImportWarningCode.channelsLimited));
      expect(
        text(
          'Preamp: -3 dB\nChannel: all\n'
          'Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 1\nChannel: L R\n'
          'Filter 2: ON PK Fc 200 Hz Gain 4 dB Q 1\n',
        ).preset.configuration.filters,
        hasLength(2),
      );
    });

    test('a missing preamp is allowed with a warning', () {
      final result = text('Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1\n');
      expect(result.preset.configuration.preampDb, 0);
      expect(result.preset.configuration.autoHeadroom, isTrue);
      expect(warnings(result), contains(EqImportWarningCode.preampMissing));
    });

    test('REW exports skip their header and empty slots', () {
      final result = text('''
Filter Settings file

Room EQ V5.20.13
Dated: 30-Sep-2026 10:15:30

Notes:

Equaliser: Generic
Average 1
Filter  1: ON  PK       Fc   62.5 Hz  Gain -10.0 dB  Q  4.00
Filter  2: ON  PK       Fc    125 Hz  Gain  -3.5 dB  Q  2.10
Filter  3: OFF None
''');
      expect(result.preset.configuration.filters, hasLength(2));
      expect(result.preset.configuration.filters.first.frequencyHz, 62.5);
    });

    test('an AutoEQ fixed-band file is recognised by its contents', () {
      final fixture = File('test/fixtures/autoeq/FixedBandEQ.txt')
          .readAsStringSync();
      final detected = text(fixture);
      expect(detected.format, EqImportFormat.fixedBand);
      expect(detected.preset.configuration.mode, EqMode.importedFixed);
      final parametric = text(
        File('test/fixtures/autoeq/ParametricEQ.txt').readAsStringSync(),
      );
      expect(parametric.format, EqImportFormat.parametric);
      expect(text(fixture, fixedBand: false).format, EqImportFormat.parametric);
    });

    test('errors name the offending line', () {
      expect(
        () => text('Preamp: -3 dB\n\nFilter 1: ON PK Fc 100 Hz Gain 99 dB Q 1'),
        throwsA(
          isA<EqImportException>()
              .having((e) => e.code, 'code', EqImportErrorCode.invalidValue)
              .having((e) => e.line, 'line', 3),
        ),
      );
    });
  });

  group('JSON', () {
    test('EasyEffects equalizer presets use the left channel', () {
      final result = text(
        jsonEncode(<String, Object?>{
          'output': <String, Object?>{
            'equalizer#0': <String, Object?>{
              'input-gain': -4.0,
              'output-gain': 1.0,
              'num-bands': 3,
              'split-channels': true,
              'left': <String, Object?>{
                'band0': <String, Object?>{
                  'type': 'Lo-shelf',
                  'frequency': 105.0,
                  'gain': 5.0,
                  'q': 0.7,
                  'mute': false,
                },
                'band1': <String, Object?>{
                  'type': 'Bell',
                  'frequency': 2000.0,
                  'gain': -2.0,
                  'q': 1.4,
                  'mute': true,
                },
                'band2': <String, Object?>{
                  'type': 'Off',
                  'frequency': 4000.0,
                  'gain': 0.0,
                  'q': 1.0,
                },
              },
            },
          },
        }),
      );
      final configuration = result.preset.configuration;
      expect(result.format, EqImportFormat.easyEffects);
      expect(configuration.preampDb, -3);
      expect(configuration.filters, hasLength(2));
      expect(configuration.filters.first.type, EqFilterType.lowShelf);
      expect(configuration.filters.last.enabled, isFalse);
      expect(warnings(result), contains(EqImportWarningCode.splitChannels));
    });

    test('a Navis preset never arrives switched on', () {
      final exported = EqPreset(
        id: 'mine',
        name: 'Mine',
        configuration: EqConfiguration(
          enabled: true,
          mode: EqMode.advanced,
          filters: const <EqFilter>[EqFilter(frequencyHz: 100, gainDb: 2)],
        ),
      );
      final imported = text(jsonEncode(exported.toJson()));
      expect(imported.format, EqImportFormat.navisPreset);
      expect(imported.preset.id, 'x');
      expect(imported.preset.name, 'Mine');
      expect(imported.preset.configuration.enabled, isFalse);
    });
  });

  group('GraphicEQ', () {
    String curveFrom(List<EqFilter> filters) {
      final points = <String>[];
      for (var i = 0; i < 127; i++) {
        final hz = 20 * math.pow(1000, i / 126).toDouble();
        final db = filters.fold<double>(
          0,
          (sum, filter) =>
              sum + EqBiquad.forFilter(filter, 48000).decibelsAt(hz, 48000),
        );
        points.add('${hz.toStringAsFixed(1)} ${db.toStringAsFixed(2)}');
      }
      return 'GraphicEQ: ${points.join('; ')}';
    }

    test('a curve made from known filters is fitted closely', () {
      final result = text(
        curveFrom(const <EqFilter>[
          EqFilter(type: EqFilterType.lowShelf, frequencyHz: 105, gainDb: 6),
          EqFilter(frequencyHz: 3000, gainDb: -4, q: 2),
          EqFilter(frequencyHz: 9000, gainDb: 3, q: 1.5),
        ]),
      );
      expect(result.format, EqImportFormat.graphic);
      final configuration = result.preset.configuration;
      expect(configuration.filters.length, lessThanOrEqualTo(31));
      expect(configuration.isValid, isTrue);
      final fitted = result.warnings.singleWhere(
        (w) => w.code == EqImportWarningCode.graphicFitted,
      );
      final rms = double.parse(fitted.detail!.split('|')[1]);
      expect(rms, lessThanOrEqualTo(0.5));
    });

    test('a flat curve produces no filters', () {
      final fit = fitGraphicEq(<(double, double)>[(20, 0), (20000, 0)]);
      expect(fit.filters, isEmpty);
      expect(fit.maxErrorDb, lessThan(0.01));
    });

    test('sparse and out-of-range points are held flat at the ends', () {
      final fit = fitGraphicEq(<(double, double)>[
        (5, 3),
        (1000, 3),
        (40000, 3),
      ]);
      expect(fit.rmsErrorDb, lessThan(1));
      expect(fit.filters.every((filter) => filter.isValid), isTrue);
    });
  });
}
