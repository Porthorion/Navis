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

/// [normalizeMetadata] that keeps edition and language qualifiers.
///
/// Bracketed text stays as words, so "Wonder (Japanese Version)" becomes
/// "wonder japanese version" while "Wonder" stays "wonder". Featured-artist
/// credits, bracketed or not, are still dropped because they do not make a
/// different recording. Use it to prefer the same edition among candidates
/// that share a [normalizeMetadata] key, and to deduplicate releases without
/// merging language versions.
String normalizeMetadataKeepingEdition(String value) {
  return _words(
    _fold(value)
        .replaceAll(_bracketedFeaturing, ' ')
        .replaceAll(_featuring, ' '),
  );
}

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
