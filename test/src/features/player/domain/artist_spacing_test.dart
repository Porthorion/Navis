import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/artist_spacing.dart';

void main() {
  List<String> space(List<String> artists, {required int count}) =>
      spaceByArtist<String>(artists, artistOf: (a) => a, count: count);

  test('spreads artists: two each, never back to back, when enough exist', () {
    final out = space(['a', 'a', 'a', 'b', 'b', 'c', 'c', 'd'], count: 6);
    expect(out, hasLength(6));
    for (var i = 1; i < out.length; i++) {
      expect(out[i], isNot(out[i - 1]));
    }
    expect(out.where((a) => a == 'a'), hasLength(lessThanOrEqualTo(2)));
  });

  test('relaxes to three per artist, then no cap, to fill the batch', () {
    // Only two artists: cap 2 gives four songs, cap 3 six, then the rest.
    final out = space(['a', 'a', 'a', 'a', 'b', 'b', 'b'], count: 7);
    expect(out, hasLength(7));
    expect(out.take(4).where((a) => a == 'a'), hasLength(2));
    expect(out.take(4).where((a) => a == 'b'), hasLength(2));
  });

  test('a single artist still fills the batch and the loop ends', () {
    expect(space(List.filled(12, 'seed'), count: 10), hasLength(10));
    expect(space(List.filled(3, 'seed'), count: 10), hasLength(3));
    expect(space(const <String>[], count: 10), isEmpty);
  });

  test('other artists interleave a seed-heavy list when any exist', () {
    final out = space([...List.filled(8, 'seed'), 'x', 'y'], count: 10);
    expect(out, hasLength(10));
    expect(out.indexOf('x'), lessThan(4));
    expect(out.indexOf('y'), lessThan(6));
  });
}
