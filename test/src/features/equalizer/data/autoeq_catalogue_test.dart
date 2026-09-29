import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';

class _Dio extends Mock implements Dio {}

void main() {
  setUpAll(() => registerFallbackValue(Options()));
  test('official download uses space-separated filenames and preserves provenance', () async {
    final index = AutoEqIndex.decode(
      File('assets/autoeq/index.json').readAsStringSync(),
    );
    final entry = index
        .search('Sennheiser HD 600')
        .firstWhere((e) => e.name == 'Sennheiser HD 600');
    final dio = _Dio();
    for (final fixed in [false, true]) {
      final kind = fixed ? 'FixedBandEQ' : 'ParametricEQ';
      final url =
          'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/${index.revision}/results/${entry.path}/Sennheiser%20HD%20600%20$kind.txt';
      when(() => dio.get<ResponseBody>(url, options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response(
              requestOptions: RequestOptions(path: url),
              data: ResponseBody.fromString(
                File('test/fixtures/autoeq/$kind.txt').readAsStringSync(),
                200,
              ),
            ),
          );
      final preset = await AutoEqCatalogue(client: dio)
          .download(index, entry, fixedBand: fixed);
      expect(
        preset.configuration.mode,
        fixed ? EqMode.importedFixed : EqMode.advanced,
      );
      expect(preset.source?.url, url);
      expect(preset.source?.revision, index.revision);
      expect(preset.source?.measurementSource, entry.measurementSource);
      expect(preset.source?.originalText, contains('Preamp:'));
      verify(() => dio.get<ResponseBody>(url, options: any(named: 'options')))
          .called(1);
    }
  });
  test(
    'bundled official index is pinned, distinct, and searchable offline',
    () {
      final index = AutoEqIndex.decode(
        File('assets/autoeq/index.json').readAsStringSync(),
      );
      expect(index.entries.length, greaterThan(8000));
      expect(index.search('Sennheiser HD 600'), isNotEmpty);
      expect(
        index.search('Sony WH-1000XM4', recommendedOnly: false).length,
        greaterThan(1),
      );
      expect(
        index.entries.map((e) => e.path).toSet().length,
        index.entries.length,
      );
      expect(AutoEqIndex.decode(index.encode()).revision, index.revision);
    },
  );
  test('recommended selection matches path, while alternate measurements remain distinct', () {
    final index = AutoEqIndex.fromMarkdown(
      revision: 'a' * 40,
      recommended:
          '- [Headphone (ANC On)](./lab/in-ear/Headphone%20(ANC%20On))',
      full:
          '- [Headphone (ANC On)](./lab/in-ear/Headphone%20(ANC%20On)) by lab on 711\n'
          '- [Headphone (ANC On)](./other/in-ear/Headphone%20(ANC%20On)) by other',
    );
    expect(index.search('headphone').single.measurementSource, 'lab on 711');
    expect(index.search('headphone', recommendedOnly: false).length, 2);
  });
  test(
    'invalid catalogue paths cannot escape the pinned results directory',
    () {
      for (final path in [
        '../profile',
        '%2E%2E/profile',
        '/profile',
        r'lab\profile',
        'lab?query',
      ]) {
        expect(
          () => AutoEqIndex.decode(
            jsonEncode({
              'version': 1,
              'revision': 'a' * 40,
              'entries': [
                {
                  'name': 'Bad',
                  'path': path,
                  'source': 'lab',
                  'recommended': true,
                },
              ],
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );
}
