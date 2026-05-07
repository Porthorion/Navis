import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/artist_utils.dart';

void main() {
  group('splitArtistNames', () {
    test('splits explicit multi-artist delimiters', () {
      expect(
        splitArtistNames('Alpha; Beta feat. Gamma ft. Delta / Epsilon'),
        <String>['Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon'],
      );
    });

    test('preserves bare slash artist names', () {
      expect(splitArtistNames('AC/DC'), <String>['AC/DC']);
      expect(splitArtistNames('K/DA'), <String>['K/DA']);
    });

    test('trims empty parts', () {
      expect(splitArtistNames(' Alpha ; ; Beta '), <String>['Alpha', 'Beta']);
    });
  });
}
