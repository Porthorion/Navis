import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

void main() {
  group('normalizeMetadata', () {
    test('keeps Japanese text and drops its punctuation', () {
      expect(normalizeMetadata('「残響リファレンス」'), '残響リファレンス');
      expect(normalizeMetadata('ワンオクロック'), 'ワンオクロック');
      expect(normalizeMetadata('Jinsei×Boku='), 'jinsei boku');
    });

    test('keeps Korean and Arabic text', () {
      expect(normalizeMetadata('봄날 (Spring Day)'), '봄날');
      expect(normalizeMetadata('방탄소년단'), '방탄소년단');
      expect(normalizeMetadata('عمرو دياب'), 'عمرو دياب');
      // Arabic letter variants typed interchangeably fold together.
      expect(normalizeMetadata('أحمد'), normalizeMetadata('احمد'));
    });

    test('folds Latin diacritics, composed or decomposed', () {
      expect(normalizeMetadata('Beyoncé'), 'beyonce');
      expect(normalizeMetadata('Beyoncé'), 'beyonce');
      expect(normalizeMetadata('Sigur Rós'), 'sigur ros');
    });

    test('folds full-width forms and the ideographic space', () {
      expect(normalizeMetadata('ＯＮＥ　ＯＫ　ＲＯＣＫ'), 'one ok rock');
      expect(
        normalizeMetadata('ＯＮＥ　ＯＫ　ＲＯＣＫ'),
        normalizeMetadata('ONE OK ROCK'),
      );
      expect(normalizeMetadata('Ｗｏｎｄｅｒ（Ｊａｐａｎｅｓｅ Ｖｅｒｓｉｏｎ）'), 'wonder');
    });

    test('still drops bracketed qualifiers and featured credits', () {
      expect(normalizeMetadata('Wonder (Japanese Version)'), 'wonder');
      expect(normalizeMetadata('Song (Live) feat. Guest'), 'song');
      expect(normalizeMetadata('Song ft. Guest'), 'song');
      expect(normalizeMetadata('AC/DC'), 'ac dc');
      expect(normalizeMetadata('  '), '');
    });

    test('never empties non-empty non-Latin text', () {
      for (final value in <String>[
        '残響リファレンス',
        'ワンオクロック',
        '嵐',
        '방탄소년단',
        'عمرو دياب',
        'Ёлка',
        'Μάνος',
      ]) {
        expect(normalizeMetadata(value), isNotEmpty, reason: value);
      }
    });
  });

  group('normalizeMetadataKeepingEdition', () {
    test('keeps version qualifiers as words', () {
      expect(
        normalizeMetadataKeepingEdition('Wonder (Japanese Version)'),
        'wonder japanese version',
      );
      expect(normalizeMetadataKeepingEdition('Wonder'), 'wonder');
      expect(
        normalizeMetadataKeepingEdition('Wherever You Are [Acoustic]'),
        'wherever you are acoustic',
      );
    });

    test('keeps JP and EN versions distinct while fuzzy keys agree', () {
      const pairs = <(String, String)>[
        ('Wonder (Japanese Version)', 'Wonder (English Version)'),
        ('Wonder', 'Wonder (Japanese Version)'),
        ('Renegades (Acoustic)', 'Renegades'),
        ('Stand Out Fit In (Piano)', 'Stand Out Fit In'),
      ];
      for (final (a, b) in pairs) {
        expect(normalizeMetadata(a), normalizeMetadata(b), reason: '$a / $b');
        expect(
          normalizeMetadataKeepingEdition(a),
          isNot(normalizeMetadataKeepingEdition(b)),
          reason: '$a / $b',
        );
      }
    });

    test('ignores featured credits, which are not editions', () {
      expect(normalizeMetadataKeepingEdition('Wonder (feat. Guest)'), 'wonder');
      expect(normalizeMetadataKeepingEdition('Wonder [ft. Guest]'), 'wonder');
      expect(normalizeMetadataKeepingEdition('Wonder feat. Guest'), 'wonder');
      expect(
        normalizeMetadataKeepingEdition('Wonder (Japanese Version) feat. X'),
        'wonder japanese version',
      );
    });

    test('folds width and diacritics like the fuzzy key', () {
      expect(
        normalizeMetadataKeepingEdition('Ｗｏｎｄｅｒ（Ｊａｐａｎｅｓｅ Ｖｅｒｓｉｏｎ）'),
        'wonder japanese version',
      );
      expect(
        normalizeMetadataKeepingEdition('「残響リファレンス」 (Deluxe Édition)'),
        '残響リファレンス deluxe edition',
      );
    });
  });
}
