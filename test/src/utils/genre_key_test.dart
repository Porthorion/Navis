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
