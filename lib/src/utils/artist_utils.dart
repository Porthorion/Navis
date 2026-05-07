/// Utilities for handling artist display strings.
library;

/// Splits a combined artist string into individual artist names.
///
/// Splits on unambiguous multi-artist delimiters: `;`, `feat.`/`feat`/
/// `featuring`, `ft.`, and ` / ` (space-slash-space). Bare `/` values such
/// as `K/DA` and `AC/DC` are preserved.
List<String> splitArtistNames(String raw) {
  final patterns = [
    RegExp(r'\s*;\s*'),
    RegExp(r'\s+feat(?:uring)?\.?\s+', caseSensitive: false),
    RegExp(r'\s+ft\.\s+', caseSensitive: false),
    RegExp(r'\s+/\s+'),
  ];
  var parts = [raw.trim()];
  for (final pat in patterns) {
    parts = parts.expand((p) => p.split(pat)).toList();
  }
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}
