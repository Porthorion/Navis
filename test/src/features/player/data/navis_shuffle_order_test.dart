import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/navis_shuffle_order.dart';

void main() {
  List<String> unshuffle(List<String> playOrder, List<String> original) {
    final ranks = reconcileOriginalRanks(playOrder, original);
    return <String>[for (final i in unshuffledIndices(ranks)) playOrder[i]];
  }

  test('a start song leads and every song stays exactly once', () {
    final items = List<String>.generate(50, (i) => 's$i');
    final shuffled = shuffledFromStart(items, 7, math.Random(1));
    expect(shuffled.first, 's7');
    expect(shuffled.toSet(), items.toSet());
    expect(shuffled, hasLength(50));
    expect(shuffled, isNot(items));
  });

  test('shuffling mid-queue puts history and upcoming songs after current', () {
    final items = List<String>.generate(12, (i) => 's$i');
    final shuffled = shuffledFromStart(items, 5, math.Random(2));
    expect(shuffled.first, 's5');
    expect(shuffled.skip(1).toSet(), {...items.take(5), ...items.skip(6)});
    expect(shuffled, hasLength(12));
    expect(unshuffle(shuffled, items), items);
  });

  test('legacy restore keeps history and current and shuffles upcoming', () {
    final items = List<String>.generate(20, (i) => 's$i');
    final shuffled = shuffledAfter(items, 4, math.Random(2));
    expect(shuffled.take(5), items.take(5));
    expect(shuffled.skip(5).toSet(), items.skip(5).toSet());
  });

  test(
    'an unedited shuffled queue unshuffles exactly, duplicates included',
    () {
      final original = <String>['a', 'b', 'a', 'c', 'b', 'd'];
      for (var seed = 0; seed < 20; seed++) {
        final playOrder = shuffledFromStart(original, 2, math.Random(seed));
        expect(unshuffle(playOrder, original), original);
      }
    },
  );

  test('a song played next lands after the current song', () {
    final original = <String>['a', 'b', 'c', 'd'];
    // Playing c, shuffled as a, c, d, b; x is played next.
    final playOrder = <String>['a', 'c', 'x', 'd', 'b'];
    expect(unshuffle(playOrder, original), <String>['a', 'b', 'c', 'x', 'd']);
  });

  test('appended songs go to the end and removed songs disappear', () {
    final original = <String>['a', 'b', 'c', 'd'];
    final playOrder = <String>['c', 'a', 'd', 'x', 'y'];
    expect(unshuffle(playOrder, original), <String>['a', 'c', 'd', 'x', 'y']);
  });

  test('removing one occurrence of a duplicate keeps the other', () {
    final original = <String>['a', 'b', 'a', 'c'];
    final playOrder = <String>['c', 'a', 'b'];
    expect(unshuffle(playOrder, original), <String>['a', 'b', 'c']);
  });

  test('ranks are a permutation of the play order positions', () {
    final random = math.Random(3);
    for (var round = 0; round < 50; round++) {
      final original = List<String>.generate(
        random.nextInt(30),
        (_) => 's${random.nextInt(10)}',
      );
      final playOrder = <String>[
        ...original.where((_) => random.nextBool()),
        for (var i = 0; i < random.nextInt(5); i++) 'n${random.nextInt(4)}',
      ]..shuffle(random);
      final ranks = reconcileOriginalRanks(playOrder, original);
      expect(ranks.toSet(), Set<int>.of(Iterable<int>.generate(ranks.length)));
    }
  });
}
