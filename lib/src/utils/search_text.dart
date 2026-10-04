/// Text normalization shared by the local search index and search queries.
///
/// Lowercases, folds common Latin diacritics and Arabic letter variants,
/// removes combining marks, and collapses every run of non-letter,
/// non-number characters to one space. Letters and numbers from every script
/// are kept, so Arabic, CJK, and accented titles remain searchable.
String normalizeSearchText(String value) {
  if (value.isEmpty) return '';
  return foldSearchLetters(value.toLowerCase())
      .replaceAll(_separators, ' ')
      .trim();
}

/// Folds common Latin diacritics (é → e, ß → ss) and Arabic letter variants
/// in lowercased [value], and removes combining marks and the Arabic tatweel.
/// Every other character is kept.
String foldSearchLetters(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final folded = _foldedRunes[rune];
    if (folded != null) {
      buffer.write(folded);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString().replaceAll(_removedMarks, '');
}

/// Separator between the normalized title, artist, and album stored in the
/// song search index. Normalized text never contains it.
const String songSearchFieldSeparator = '|';

/// The stored search text for a song: its normalized title, artist, and album
/// joined by [songSearchFieldSeparator].
String buildSongSearchText({
  required String title,
  String? artistName,
  String? albumName,
}) {
  return <String>[
    normalizeSearchText(title),
    normalizeSearchText(artistName ?? ''),
    normalizeSearchText(albumName ?? ''),
  ].join(songSearchFieldSeparator);
}

/// A GLOB pattern matching any text that contains [token]'s characters in
/// order. Every ranked match (exact, prefix, substring, token, or fuzzy
/// subsequence) satisfies it, so it is a safe SQL prefilter.
String songSearchSubsequenceGlob(String token) {
  final buffer = StringBuffer('*');
  for (final rune in token.runes) {
    final char = String.fromCharCode(rune);
    // Normalized tokens contain only letters and numbers; escape GLOB
    // metacharacters defensively anyway.
    buffer.write(switch (char) {
      '*' || '?' || '[' => '[$char]',
      _ => char,
    });
    buffer.write('*');
  }
  return buffer.toString();
}

final RegExp _removedMarks = RegExp(r'[\p{M}ـ]', unicode: true);
final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

final Map<int, String> _foldedRunes = () {
  const groups = <String, String>{
    'àáâãäåāăąǎ': 'a',
    'æ': 'ae',
    'çćĉċč': 'c',
    'ďđð': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g',
    'ĥħ': 'h',
    'ìíîïĩīĭįıǐ': 'i',
    'ĳ': 'ij',
    'ĵ': 'j',
    'ķ': 'k',
    'ĺļľŀł': 'l',
    'ñńņňŉ': 'n',
    'òóôõöøōŏőǒ': 'o',
    'œ': 'oe',
    'ŕŗř': 'r',
    'śŝşšș': 's',
    'ß': 'ss',
    'ţťŧț': 't',
    'ùúûüũūŭůűųǔ': 'u',
    'ŵ': 'w',
    'ýÿŷ': 'y',
    'źżž': 'z',
    'þ': 'th',
    // Arabic letter variants commonly typed interchangeably.
    'أإآٱ': 'ا',
    'ى': 'ي',
    'ة': 'ه',
    'ؤ': 'و',
    'ئ': 'ي',
  };
  return <int, String>{
    for (final entry in groups.entries)
      for (final rune in entry.key.runes) rune: entry.value,
  };
}();
