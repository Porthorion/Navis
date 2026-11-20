/// The artist spacing rule shared by Personal Radio and Same Vibes: how many
/// songs one artist may have in a batch and whether the same artist may play
/// twice in a row. The caller passes the artist key (lowercase name, or
/// `looseArtistKey`); the keys of chosen songs go in through [add].
class ArtistSpacing {
  final Map<String, int> _counts = <String, int>{};
  String? _last;

  /// Whether a song by [artist] fits: under [cap] songs of that artist so far
  /// (no cap when null), and, unless [backToBack], not right after the same
  /// artist.
  bool allows(String artist, {int? cap, bool backToBack = false}) =>
      (backToBack || artist != _last) &&
      (cap == null || (_counts[artist] ?? 0) < cap);

  /// Counts a chosen song of [artist] as the latest one.
  void add(String artist) {
    _counts[artist] = (_counts[artist] ?? 0) + 1;
    _last = artist;
  }
}

/// Picks up to [count] of [candidates] (best first), preferring two songs per
/// artist and never the same artist back to back, and relaxing step by step
/// rather than returning fewer: three per artist, then no cap, then back to
/// back. Every pass takes at least one candidate or ends, so it terminates.
/// Pass [spacing] to continue after songs already chosen.
///
/// ponytail: quadratic in the candidate count, which is a few dozen at most.
List<T> spaceByArtist<T>(
  Iterable<T> candidates, {
  required String Function(T) artistOf,
  required int count,
  ArtistSpacing? spacing,
}) {
  final spaced = spacing ?? ArtistSpacing();
  final remaining = candidates.toList();
  final picked = <T>[];
  for (final (cap, backToBack) in const [
    (2, false),
    (3, false),
    (null, false),
    (null, true),
  ]) {
    while (picked.length < count) {
      final index = remaining.indexWhere(
        (song) =>
            spaced.allows(artistOf(song), cap: cap, backToBack: backToBack),
      );
      if (index < 0) break;
      final song = remaining.removeAt(index);
      spaced.add(artistOf(song));
      picked.add(song);
    }
  }
  return picked;
}
