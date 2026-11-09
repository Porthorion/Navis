import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/html_entities.dart';

void main() {
  test('decodes named and numeric entities once', () {
    expect(decodeHtmlEntities('Come &amp; Get It'), 'Come & Get It');
    expect(decodeHtmlEntities('&#39;&#x26;&apos;&quot;&lt;&gt;'), "'&'\"<>");
    expect(decodeHtmlEntities('&amp;lt;'), '&lt;');
    expect(decodeHtmlEntities('&#x1F600;'), '\u{1F600}');
  });

  test('leaves unknown, bare and invalid entities and plain text literal', () {
    for (final s in <String>[
      '&foo;',
      'AT&T',
      '&',
      '&#xD800;',
      '&#x110000;',
      '&#99999999999;',
      'Plain name',
      '',
    ]) {
      expect(decodeHtmlEntities(s), s);
    }
  });

  test('readDecodedString decodes only strings', () {
    expect(readDecodedString({'n': 'a &amp; b'}, 'n'), 'a & b');
    expect(readDecodedString({'n': 3}, 'n'), 3);
    expect(readDecodedString({}, 'n'), isNull);
  });
}
