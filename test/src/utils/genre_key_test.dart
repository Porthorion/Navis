import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/genre_key.dart';

void main() {
  test('case, spaces, hyphens and underscores share one key', () {
    final keys = {
      genreKey('Hip Hop'),
      genreKey('hip-hop'),
      genreKey('Hip_Hop'),
      genreKey('  HIP  HOP '),
    };
    expect(keys, {'hiphop'});
  });

  test('Unicode dashes and zero-width characters do not split a genre', () {
    for (final dash in [
      '\u2010',
      '\u2011',
      '\u2012',
      '\u2013',
      '\u2014',
      '\u2015',
      '\u2212',
    ]) {
      expect(
        genreKey('Hip${dash}Hop'),
        'hiphop',
        reason: dash.codeUnitAt(0).toRadixString(16),
      );
    }
    for (final zw in ['\u200B', '\u200C', '\u200D', '\uFEFF']) {
      expect(genreKey('Rock$zw'), 'rock');
      expect(genreKey('Ro${zw}ck'), 'rock');
    }
    expect(genreKey('\u2013\u200B'), isEmpty);
  });

  test('other punctuation keeps names apart', () {
    expect(genreKey('R&B'), isNot(genreKey('RnB')));
    expect(genreKey('Drum/Bass'), isNot(genreKey('Drum Bass')));
  });

  test('a name with nothing but separators has an empty key', () {
    expect(genreKey('-'), isEmpty);
    expect(genreKey(' _ - '), isEmpty);
    expect(genreKey(''), isEmpty);
  });

  test('resolveGenres trims, drops empty keys and dedupes by key', () {
    expect(
      resolveGenres(<String?>[
        ' Hip Hop',
        null,
        '-',
        'hip-hop',
        'Rock',
        'ROCK',
      ]),
      <String>['Hip Hop', 'Rock'],
    );
  });
}
