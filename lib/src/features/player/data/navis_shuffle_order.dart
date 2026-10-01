import 'dart:math' as math;

/// Navis owns shuffle: the queue is always kept in play order, and while
/// shuffle is on the unshuffled order is remembered separately so it can be
/// restored. The remembered order is only updated lazily, so these helpers
/// reconcile it with the edits made since (songs added and removed while
/// shuffled). Songs are matched by occurrence, so a song queued twice keeps
/// two distinct places.

/// The play order for a queue started at [startIndex] with shuffle on: the
/// start song first, then every other song in random order.
List<T> shuffledFromStart<T>(
  List<T> items,
  int startIndex,
  math.Random random,
) {
  if (items.length <= 1) return List<T>.of(items);
  final rest = <T>[
    for (var i = 0; i < items.length; i++)
      if (i != startIndex) items[i],
  ]..shuffle(random);
  return <T>[items[startIndex], ...rest];
}

/// [items] with everything after [currentIndex] in random order.
List<T> shuffledAfter<T>(List<T> items, int currentIndex, math.Random random) {
  final upcoming = items.sublist(currentIndex + 1)..shuffle(random);
  return <T>[...items.sublist(0, currentIndex + 1), ...upcoming];
}

/// For each position of [playOrder], its position in the unshuffled order,
/// starting from [original] (the unshuffled order as last recorded).
///
/// Songs removed since are dropped. A song added since is placed right after
/// the song before it in [playOrder] (so "play next" lands after the current
/// song), except that songs added at the end of [playOrder] go to the end.
List<int> reconcileOriginalRanks(
  List<String> playOrder,
  List<String> original,
) {
  final playKeys = _occurrenceKeys(playOrder);
  final present = playKeys.toSet();
  // The recorded order without songs that were removed.
  final order = <(String, int)>[
    for (final key in _occurrenceKeys(original))
      if (present.contains(key)) key,
  ];
  final known = order.toSet();
  // Songs added at the very end of the play order were appended.
  var trailingNew = playKeys.length;
  while (trailingNew > 0 && !known.contains(playKeys[trailingNew - 1])) {
    trailingNew--;
  }
  final positions = <(String, int), int>{
    for (var i = 0; i < order.length; i++) order[i]: i,
  };
  for (var i = 0; i < trailingNew; i++) {
    final key = playKeys[i];
    if (known.contains(key)) continue;
    final at = i == 0 ? 0 : positions[playKeys[i - 1]]! + 1;
    order.insert(at, key);
    known.add(key);
    // Everything from the insert on moved one place.
    for (var j = at; j < order.length; j++) {
      positions[order[j]] = j;
    }
  }
  for (var i = trailingNew; i < playKeys.length; i++) {
    positions[playKeys[i]] = order.length;
    order.add(playKeys[i]);
  }
  return <int>[for (final key in playKeys) positions[key]!];
}

/// The unshuffled order of [playOrder] given its [ranks] (from
/// [reconcileOriginalRanks]): the play-order indices sorted by rank.
List<int> unshuffledIndices(List<int> ranks) {
  final indices = List<int>.generate(ranks.length, (i) => i);
  indices.sort((a, b) {
    final byRank = ranks[a].compareTo(ranks[b]);
    return byRank != 0 ? byRank : a.compareTo(b);
  });
  return indices;
}

List<(String, int)> _occurrenceKeys(List<String> ids) {
  final seen = <String, int>{};
  return <(String, int)>[
    for (final id in ids) (id, seen[id] = (seen[id] ?? -1) + 1),
  ];
}
