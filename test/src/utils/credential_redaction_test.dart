import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/credential_redaction.dart';

void main() {
  group('redactCredentialQueryParameters', () {
    test('redacts HTML-escaped and double-encoded separators', () {
      expect(
        redactCredentialQueryParameters(
          '<a href="https://h.test/rest/stream.view?id=1&amp;u=me&amp;t=abc'
          '&amp;s=salt">',
        ),
        '<a href="https://h.test/rest/stream.view?id=1&amp;u=REDACTED'
        '&amp;t=REDACTED&amp;s=REDACTED">',
      );
      expect(
        redactCredentialQueryParameters(
          'next=%2Frest%2Fstream.view%253Fid%253D1%2526t%253Dabc%2526s%253Dxyz',
        ),
        'next=%2Frest%2Fstream.view%253Fid%253D1%2526t%253DREDACTED'
        '%2526s%253DREDACTED',
      );
    });

    test('redacts the token, salt and user in an mpv stream error', () {
      const line =
          'MPV: [error] stream: Failed to open '
          'https://music.example.test/rest/stream.view?u=listener&v=1.16.1'
          '&c=navis&f=json&s=0a1b2c3d4e5f&t=26719a1196d2a940705a59634eb18eab'
          '&id=song-42.';

      expect(
        redactCredentialQueryParameters(line),
        'MPV: [error] stream: Failed to open '
        'https://music.example.test/rest/stream.view?u=REDACTED&v=1.16.1'
        '&c=navis&f=json&s=REDACTED&t=REDACTED&id=song-42.',
      );
    });

    test('redacts a legacy password and an OpenSubsonic API key', () {
      expect(
        redactCredentialQueryParameters(
          'GET http://10.0.0.2:4533/rest/ping.view?p=enc:73656372657421&f=json',
        ),
        'GET http://10.0.0.2:4533/rest/ping.view?p=REDACTED&f=json',
      );
      expect(
        redactCredentialQueryParameters(
          'https://music.example.test/rest/stream.view?id=7&apiKey=secret-key',
        ),
        'https://music.example.test/rest/stream.view?id=7&apiKey=REDACTED',
      );
    });

    test('redacts every URL in a line and stops at delimiters', () {
      expect(
        redactCredentialQueryParameters(
          'from "https://a.test/x?t=one#frag" to <https://b.test/y?s=two> '
          "and 'https://c.test/z?id=3&t=three'",
        ),
        'from "https://a.test/x?t=REDACTED#frag" to '
        '<https://b.test/y?s=REDACTED> '
        "and 'https://c.test/z?id=3&t=REDACTED'",
      );
    });

    test('redacts a percent-encoded URL nested in another URL', () {
      expect(
        redactCredentialQueryParameters(
          'http://127.0.0.1:9000/proxy?url=https%3A%2F%2Fa.test%2Frest'
          '%2Fstream.view%3Fu%3Dlistener%26t%3Dtoken%26S%3Dsalt%26id%3D9',
        ),
        'http://127.0.0.1:9000/proxy?url=https%3A%2F%2Fa.test%2Frest'
        '%2Fstream.view%3Fu%3DREDACTED%26t%3DREDACTED%26S%3DREDACTED'
        '%26id%3D9',
      );
    });

    test('leaves text without credential parameters unchanged', () {
      const lines = [
        'MPV: [error] ao/pipewire: Could not connect to context',
        'https://music.example.test/rest/getCoverArt.view?id=7&size=300',
        'sort=t&size=s and a=b',
        'https://a.test/x?id=1&title=t&format=s',
        'empty credential https://a.test/x?t=&id=1',
      ];
      for (final line in lines) {
        expect(redactCredentialQueryParameters(line), line);
      }
    });
  });

  test('runWithCredentialRedactedPrint redacts print in nested work', () async {
    final printed = <String>[];
    await runZoned(
      () => runWithCredentialRedactedPrint(() async {
        final logs = StreamController<String>();
        // Mirrors the media_kit adapter, which prints mpv logs from a listener
        // registered in this zone; the listener keeps the zone's print.
        // ignore: avoid_print
        logs.stream.listen(print);
        await Future<void>.delayed(Duration.zero);
        logs.add('stream: Failed to open https://a.test/rest?u=x&t=y&s=z&id=1');
        await logs.close();
      }),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    const redacted =
        'stream: Failed to open '
        'https://a.test/rest?u=REDACTED&t=REDACTED&s=REDACTED&id=1';
    expect(printed, [redacted]);
  });

  test('an uncaught error is reported redacted and marked handled', () {
    final lines = <String>[];
    final handled = runZoned(
      () => reportUncaughtErrorRedacted(
        Exception(
          'HttpException: Connection closed, uri = '
          'https://h.test/rest/stream.view?u=me&t=abc&s=salt&id=7',
        ),
        StackTrace.empty,
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );

    expect(handled, isTrue);
    expect(lines.single, contains('u=REDACTED&t=REDACTED&s=REDACTED&id=7'));
    expect(lines.single, startsWith('Unhandled Exception: '));
    expect(lines.single, isNot(contains('abc')));
  });
}
