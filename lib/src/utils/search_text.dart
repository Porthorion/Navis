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
  for (final rune in foldKanaWidthAndVoicing(value).runes) {
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

/// Folds half-width kana and composes their voiced/semi-voiced marks before
/// [foldSearchLetters] removes combining marks. Other scripts stay unchanged.
String foldKanaWidthAndVoicing(String value) {
  final runes = <int>[];
  for (var rune in value.runes) {
    if (rune >= 0xFF61 && rune <= 0xFF9F) {
      rune = _fullWidthKana.codeUnitAt(rune - 0xFF61);
    }
    if ((rune == 0x3099 || rune == 0x309A) && runes.isNotEmpty) {
      final composed = _voicedKana[String.fromCharCodes([runes.last, rune])];
      if (composed != null) {
        runes[runes.length - 1] = composed;
        continue;
      }
    }
    runes.add(rune);
  }
  return String.fromCharCodes(runes);
}

// Unicode compatibility mapping for U+FF61–U+FF9F, in code-point order.
const _fullWidthKana =
    '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゙゚';

// Canonical kana compositions with U+3099/U+309A.
final Map<String, int> _voicedKana = {
  'ゔ': 0x3094,
  'が': 0x304C,
  'ぎ': 0x304E,
  'ぐ': 0x3050,
  'げ': 0x3052,
  'ご': 0x3054,
  'ざ': 0x3056,
  'じ': 0x3058,
  'ず': 0x305A,
  'ぜ': 0x305C,
  'ぞ': 0x305E,
  'だ': 0x3060,
  'ぢ': 0x3062,
  'づ': 0x3065,
  'で': 0x3067,
  'ど': 0x3069,
  'ば': 0x3070,
  'ぱ': 0x3071,
  'び': 0x3073,
  'ぴ': 0x3074,
  'ぶ': 0x3076,
  'ぷ': 0x3077,
  'べ': 0x3079,
  'ぺ': 0x307A,
  'ぼ': 0x307C,
  'ぽ': 0x307D,
  'ゞ': 0x309E,
  'ヴ': 0x30F4,
  'ガ': 0x30AC,
  'ギ': 0x30AE,
  'グ': 0x30B0,
  'ゲ': 0x30B2,
  'ゴ': 0x30B4,
  'ザ': 0x30B6,
  'ジ': 0x30B8,
  'ズ': 0x30BA,
  'ゼ': 0x30BC,
  'ゾ': 0x30BE,
  'ダ': 0x30C0,
  'ヂ': 0x30C2,
  'ヅ': 0x30C5,
  'デ': 0x30C7,
  'ド': 0x30C9,
  'バ': 0x30D0,
  'パ': 0x30D1,
  'ビ': 0x30D3,
  'ピ': 0x30D4,
  'ブ': 0x30D6,
  'プ': 0x30D7,
  'ベ': 0x30D9,
  'ペ': 0x30DA,
  'ボ': 0x30DC,
  'ポ': 0x30DD,
  'ヷ': 0x30F7,
  'ヸ': 0x30F8,
  'ヹ': 0x30F9,
  'ヺ': 0x30FA,
  'ヾ': 0x30FE,
};
