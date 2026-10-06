import 'package:navis/src/utils/search_text.dart';

/// Version of the keys [normalizeMetadata] produces.
///
/// The derived `song_search_text` and `album_artist_index` rows store keys in
/// this form and include the version in their `source`, so rows written by an
/// older version count as stale and are re-keyed by the existing lazy
/// refreshes. Bump it whenever [normalizeMetadata] output changes.
const int metadataKeyVersion = 2;

final RegExp _parentheses = RegExp(r'\([^)]*\)');
final RegExp _bracketedFeaturing = RegExp(r'[(\[]\s*(?:feat|ft)\b[^)\]]*[)\]]');
final RegExp _featuring = RegExp(r'\b(feat\.?|ft\.?)\b.*$');
final RegExp _bracketed = RegExp(r'[(\[]([^)\]]*)[)\]]');
final RegExp _dashSuffix = RegExp(r'\s[-–—]\s([^-–—]*)$');
final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);
final RegExp _whitespace = RegExp(r'\s+');

/// The fuzzy key used to match the same song, album, or artist across
/// sources (Last.fm, ListenBrainz, LRCLIB, Subsonic search, the library).
///
/// Width-folds full-width ASCII and the ideographic space, lowercases, folds
/// Latin diacritics and Arabic letter variants, drops parenthesized
/// qualifiers and featured-artist credits, and keeps only letters and digits
/// of every script, separated by single spaces. "Wonder (Japanese Version)"
/// and "Wonder" therefore share a key; use
/// [normalizeMetadataKeepingEdition] to tell them apart.
String normalizeMetadata(String value) {
  return _words(
    _fold(value).replaceAll(_parentheses, ' ').replaceAll(_featuring, ' '),
  );
}

/// Qualifiers that mark mastering or packaging rather than a different
/// version of the recording, matched against a whole bracketed qualifier or
/// " - " suffix in [normalizeMetadata]'s word form:
///
/// - remasters, optionally digital and with a year or "version"/"edition":
///   "Remastered 2011", "2011 Remaster", "Digital Remaster";
/// - a bare year: "(1975)";
/// - deluxe, expanded, special, collector's and anniversary editions;
/// - explicit and clean;
/// - mono and stereo (optionally "version"/"mix");
/// - album, single and original versions, and bonus tracks.
///
/// Language versions, acoustic, piano, instrumental, live, remix, radio edit
/// and every other qualifier stay significant.
final RegExp _nonEditionQualifier = RegExp(
  '^(?:'
  r'(?:\d{4} )?(?:digital(?:ly)? )?remaster(?:ed)?'
  r'(?: \d{4})?(?: (?:version|edition))?(?: \d{4})?'
  r'|\d{4}'
  '|(?:super )?deluxe(?: (?:edition|version))?'
  r'|(?:expanded|special|collector s|(?:\d+(?:st|nd|rd|th) )?anniversary) '
  'edition'
  '|(?:explicit|clean)(?: version)?'
  '|(?:mono|stereo)(?: (?:version|mix))?'
  '|(?:album|single|original) version'
  '|bonus track(?: version)?'
  r')$',
);

/// [normalizeMetadata] that keeps edition and language qualifiers.
///
/// Bracketed text stays as words, so "Wonder (Japanese Version)" becomes
/// "wonder japanese version" while "Wonder" stays "wonder". Featured-artist
/// credits, bracketed or not, are still dropped because they do not make a
/// different recording, and so are mastering and packaging qualifiers such
/// as "(Remastered 2011)", "(Deluxe Edition)" or " - Album Version" (see
/// `_nonEditionQualifier`). Use it to prefer the same edition among
/// candidates that share a [normalizeMetadata] key, and to deduplicate
/// releases without merging language versions.
String normalizeMetadataKeepingEdition(String value) {
  final folded = _fold(value)
      .replaceAll(_bracketedFeaturing, ' ')
      .replaceAll(_featuring, ' ')
      .replaceAllMapped(
        _bracketed,
        (match) => _isNonEdition(match[1]!) ? ' ' : ' ${match[1]} ',
      )
      .replaceFirstMapped(
        _dashSuffix,
        (match) => _isNonEdition(match[1]!) ? '' : match[0]!,
      );
  return _words(folded);
}

bool _isNonEdition(String qualifier) =>
    _nonEditionQualifier.hasMatch(_words(qualifier));

String _fold(String value) =>
    foldSearchLetters(_foldWidth(value).toLowerCase());

String _words(String value) =>
    value.replaceAll(_nonWord, ' ').replaceAll(_whitespace, ' ').trim();

/// Maps full-width ASCII (U+FF01–U+FF5E) to ASCII and the ideographic space
/// (U+3000) to a space, the part of NFKC that music metadata relies on.
String _foldWidth(String value) {
  if (!value.codeUnits.any((unit) => unit == 0x3000 || unit >= 0xFF01)) {
    return value;
  }
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x3000) {
      buffer.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Leading articles one name may have and the other lack.
const Set<String> _leadingArticles = {
  'the',
  'a',
  'an',
  'los',
  'las',
  'le',
  'la',
  'les',
  'die',
  'der',
};

final RegExp _ampersand = RegExp(r'[&\uFF06]');

/// A name for loose comparison: its leading article, if any, and the rest
/// without spaces. "&" reads as "and". The article stays part of the rest
/// when nothing but an article would remain, so "The The" is never "The".
({String? article, String rest}) _looseName(String name) {
  final words = normalizeMetadata(name.replaceAll(_ampersand, ' and '))
      .split(' ')
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length > 1 &&
      _leadingArticles.contains(words.first) &&
      !(words.length == 2 && _leadingArticles.contains(words[1]))) {
    return (article: words.first, rest: words.skip(1).join());
  }
  return (article: null, rest: words.join());
}

/// Whether [libraryName] and [deezerName] may name the same artist although
/// their [normalizeMetadata] forms differ, for matching only (never shown).
///
/// They may differ in one leading article present on one side only ("The",
/// "A", "An", "Los", "Las", "Le", "La", "Les", "Die", "Der"), in "&" against
/// "and", and in spacing and punctuation: "The Black Eyed Peas" and "Black
/// Eyed Peas", "Simon & Garfunkel" and "Simon and Garfunkel", "AC/DC" and
/// "ACDC". Two different articles ("A Band", "The Band") never match. A
/// loose match is only a candidate; callers must resolve ambiguity before linking.
bool artistNamesMatchLoosely(String libraryName, String deezerName) {
  final library = _looseName(libraryName);
  final deezer = _looseName(deezerName);
  if (library.rest.isEmpty || library.rest != deezer.rest) return false;
  return library.article == null ||
      deezer.article == null ||
      library.article == deezer.article;
}

/// Candidate key for loose artist matching, ignoring a leading article,
/// spacing and punctuation, and treating ampersands as "and".
///
/// Equal keys still require [artistNamesMatchLoosely] and a unique candidate.
String looseArtistKey(String name) => _looseName(name).rest;
