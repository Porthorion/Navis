/// Version of the keys [genreKey] produces. The derived `song_genre_index`
/// rows include it in their `source`, so rows keyed by an older normalizer
/// count as stale and are rebuilt by the existing lazy refresh. Bump it
/// whenever [genreKey] output changes.
const int genreKeyVersion = 1;

// Whitespace, ASCII hyphens, underscores, the Unicode hyphens and dashes
// (U+2010-U+2015, U+2212) and zero-width characters (U+200B-U+200D, U+FEFF).
final RegExp _separators = RegExp(
  r'[\s\-_\u2010-\u2015\u2212\u200B-\u200D\uFEFF]+',
);

/// The merge key of a genre name: lowercased, outer whitespace trimmed, and
/// spaces, hyphens (also Unicode dashes), underscores and zero-width
/// characters removed. "Hip Hop", "hip-hop" and
/// "Hip_Hop" share a key; "R&B" and "RnB" do not. Names with nothing else
/// (such as "-") have an empty key and are not genres.
///
/// The one definition shared by the song model, the genre index writer and
/// every genre query, so they cannot drift apart.
String genreKey(String name) => name.toLowerCase().replaceAll(_separators, '');

/// [names] with blank and empty-key entries dropped, outer whitespace
/// trimmed, and duplicates by [genreKey] removed (the first spelling wins).
/// Names are never split.
List<String> resolveGenres(Iterable<String?> names) {
  final byKey = <String, String>{};
  for (final name in names) {
    final trimmed = name?.trim();
    if (trimmed == null) continue;
    final key = genreKey(trimmed);
    if (key.isNotEmpty) byKey.putIfAbsent(key, () => trimmed);
  }
  return byKey.values.toList(growable: false);
}
