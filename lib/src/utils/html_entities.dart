// ponytail: stored names are not rewritten; a full repair corrects them (a
// normal sync can carry encoded song titles forward when the album matches).
// JSON re-read from local stores decodes again, which only alters names that
// still hold entity text after one decode. For a forced repair, bump
// `currentLibrarySyncModelVersion` and the genres-pending gate.
final RegExp _entity = RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);');

/// Decodes the HTML entities Navidrome leaves literally in tag-derived names
/// (`Come &amp; Get It`). Each entity decodes once (`&amp;lt;` -> `&lt;`);
/// unknown names and out-of-range or surrogate code points stay literal.
String decodeHtmlEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final body = m[1]!;
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = body.startsWith('#x')
        ? int.tryParse(body.substring(2), radix: 16)
        : int.tryParse(body.substring(1));
    if (code == null ||
        code < 0x20 ||
        code > 0x10FFFF ||
        (code >= 0xD800 && code <= 0xDFFF)) {
      return m[0]!;
    }
    return String.fromCharCode(code);
  });
}

/// `@JsonKey(readValue:)` hook: decodes [key] only when it holds a string.
Object? readDecodedString(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  return value is String ? decodeHtmlEntities(value) : value;
}
