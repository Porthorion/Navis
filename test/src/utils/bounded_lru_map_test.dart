import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/bounded_lru_map.dart';

void main() {
  test(
    'refreshes reads and replacements and reports only capacity eviction',
    () {
      final evicted = <int>[];
      final cache = BoundedLruMap<String, int>(
        capacity: 2,
        onEvict: evicted.add,
      );
      cache
        ..put('a', 1)
        ..put('b', 2);
      expect(cache.get('missing'), isNull);
      expect(cache.get('a'), 1);
      cache.put('c', 3);
      expect(cache.get('b'), isNull);
      expect(evicted, [2]);
      cache
        ..put('a', 4)
        ..put('d', 5);
      expect(cache.get('c'), isNull);
      expect(cache.get('a'), 4);
      expect(cache.length, 2);
      expect(evicted, [2, 3]);
      cache.clear();
      expect(cache.length, 0);
      expect(evicted, [2, 3]);
    },
  );

  test('reads without recency refresh preserve insertion order', () {
    final cache = BoundedLruMap<String, int>(capacity: 2)
      ..put('a', 1)
      ..put('b', 2);
    expect(cache.get('a', refreshRecency: false), 1);
    cache.put('c', 3);
    expect(cache.get('a'), isNull);
    expect(cache.values, [2, 3]);
  });

  test('zero capacity immediately evicts the inserted value', () {
    final evicted = <int>[];
    final cache = BoundedLruMap<String, int>(capacity: 0, onEvict: evicted.add)
      ..put('a', 1);
    expect(cache.length, 0);
    expect(cache.get('a'), isNull);
    expect(evicted, [1]);
  });
}
