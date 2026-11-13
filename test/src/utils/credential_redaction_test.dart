import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/credential_redaction.dart';

void main() {
  test(
    'credentialFreeUri keeps non-Subsonic parameters such as a proxy token',
    () {
      final uri = Uri.parse(
        'https://h/x?token=a&password=b&access_token=c&id=1&u=me',
      );
      final cleaned = credentialFreeUri(uri);
      expect(cleaned.queryParameters, {
        'token': 'a',
        'password': 'b',
        'access_token': 'c',
        'id': '1',
      });
      expect(uriCarriesCredentials(Uri.parse('https://h/x?token=a')), isFalse);
    },
  );

  test('credential-free cache URIs remove all credential keys and keep repeated metadata', () {
    final uri = credentialFreeUri(
      Uri.parse(
        'https://user:pass@example.com/rest?id=1&id=2&U=user&T=token&S=salt&P=enc:password&APIKEY=key&size=600',
      ),
    );
    expect(uriCarriesCredentials(uri), isFalse);
    expect(uri.queryParametersAll['id'], ['1', '2']);
    expect(uri.queryParameters['size'], '600');
  });

  test('URL user info is a credential even without query authentication', () {
    expect(
      uriCarriesCredentials(
        Uri.parse('https://user:pass@example.com/cover?id=7'),
      ),
      isTrue,
    );
    expect(
      uriCarriesCredentials(Uri.parse('https://example.com/cover?id=7')),
      isFalse,
    );
    expect(
      uriCarriesCredentials(Uri.parse('https://example.com/cover?T=token')),
      isTrue,
    );
  });

  group('redactCredentialQueryParameters', () {
    test('redacts Last.fm api_key in URLs and encoded queries', () {
      for (final separator in ['?', '&amp;', '%3F', '%253F']) {
        final input =
            'https://service.example/${separator}API_KEY=fixture-key&method=track.getsimilar';
        expect(
          redactCredentialQueryParameters(input),
          'https://service.example/${separator}API_KEY=REDACTED&method=track.getsimilar',
        );
      }
      expect(
        uriCarriesCredentials(
          Uri.parse('https://service.example/?api_key=fixture-key'),
        ),
        isTrue,
      );
    });

    test('strips user info from multiple URLs and keeps path parameters', () {
      expect(
        redactCredentialQueryParameters(
          'GET https://user:pass%40word@example.com/rest?id=7&t=token then //name:secret@other.test/path',
        ),
        'GET https://example.com/rest?id=7&t=REDACTED then //other.test/path',
      );
      expect(
        redactCredentialQueryParameters(
          'https://example.com/path/user@name?id=7',
        ),
        'https://example.com/path/user@name?id=7',
      );
    });

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

  test('a multi-line stack is printed one line per call, redacted', () {
    final lines = <String>[];
    runZoned(
      () => reportUncaughtErrorRedacted(
        Exception('boom https://h.test/rest/stream.view?u=me&t=abc'),
        StackTrace.fromString(
          '#0 Handler (https://h.test/rest/stream.view?u=me&t=abc&id=7)\n'
          '#1 main',
        ),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );

    const redactedUrl = 'https://h.test/rest/stream.view?u=REDACTED&t=REDACTED';
    expect(lines, [
      'Unhandled Exception: Exception: boom $redactedUrl',
      '#0 Handler ($redactedUrl&id=7)',
      '#1 main',
    ]);
  });

  test('server host redaction hides URI authorities, the host and the socket address', () {
    expect(
      redactServerHost(
        'HttpException: closed, uri = https://music.example.com:4533/rest/stream?id=1',
      ),
      'HttpException: closed, uri = <server>/rest/stream?id=1',
    );
    expect(
      redactServerHost(
        "SocketException: Failed host lookup: 'Music.Example.com:4533' "
        '(OS error: nope, errno = -2), address = music.example.com, port = 4533',
        host: 'music.example.com',
      ),
      "SocketException: Failed host lookup: '<server>' (OS error: nope, errno = -2)",
    );
    expect(
      redactServerHost('Connection reset by peer'),
      'Connection reset by peer',
    );
    // Rows stored before redaction and redirect targets carry no known host.
    expect(
      redactServerHost(
        "SocketException: Failed host lookup: 'cdn.example.net'",
      ),
      "SocketException: Failed host lookup: '<server>'",
    );
    expect(
      redactServerHost('refused at [::1]:4533 now', host: '::1'),
      'refused at <server> now',
    );
    expect(
      redactServerHost('Connection closed by ion', host: 'ion'),
      'Connection closed by <server>',
    );
  });

  test('server host redaction stays fast on long letter runs', () {
    final watch = Stopwatch()..start();
    redactServerHost('${'a' * 60000}://');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  group('redactedDiagnosticsJson', () {
    const url =
        'https://alice:pw@nas.example.com:4533/rest/stream.view?u=alice&t=tok123&s=salt99&p=enc:abc&apiKey=key77&id=song-42';

    test('strips credentials and the server host from every nested string', () {
      final text = redactedDiagnosticsJson(<String, Object?>{
        'n': 3,
        'nested': <String, Object?>{
          'list': <Object?>[
            url,
            'failed ${Uri.encodeComponent(url)}',
            'SocketException: Connection refused, address = nas.example.com, port = 4533',
            <String, Object?>{'deep': url},
          ],
        },
        'quoted': 'Failed to open "https://nas.example.com:4533/rest/stream.view?t=tok123&id=1"',
      }, host: 'nas.example.com');
      for (final secret in <String>[
        'alice',
        'pw@',
        'tok123',
        'salt99',
        'enc:abc',
        'key77',
        'nas.example.com',
        '4533',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('song-42'));
      final decoded = jsonDecode(text) as Map<String, Object?>;
      expect(decoded['n'], 3);
      expect(decoded['quoted'], isA<String>());
    });

    test('redacts map keys like values', () {
      final text = redactedDiagnosticsJson(<String, Object?>{
        'https://alice:pw@nas.example.com/x?t=tok123&id=1': 'ok',
        'nested': <String, Object?>{'?token=tok456&id=2': 1},
      });
      for (final secret in <String>['alice', 'pw@', 'tok123', 'tok456']) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(jsonDecode(text), isA<Map<String, Object?>>());
    });

    test('redacts generic credential parameters, tokens and headers', () {
      final text = redactedDiagnosticsJson(<String, Object?>{
        'a': 'https://h/x?id=1&PASSWORD=pw111&Token=tk222&access_token=at333',
        'b': 'https://h/x?refresh_token=rt444&id=2',
        'c': 'Bearer bt555 failed',
        'd': 'Authorization: Basic YWxpY2U6cHc= retry',
        'e': {'Authorization': 'Bearer bt666'},
        'f': 'x%3Faccess_token%3Dat777%26id%3D3 and Bearer%20bt888',
        'g': [
          'n',
          {'h': 'authorization=Digest dg999;'},
        ],
      });
      for (final secret in <String>[
        'pw111',
        'tk222',
        'at333',
        'rt444',
        'bt555',
        'YWxpY2U6cHc=',
        'bt666',
        'at777',
        'bt888',
        'dg999',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('id=1'));
      expect(text, contains('failed'));
      expect(text, contains('retry'));
    });

    test('encodes a DateTime leaf as ISO 8601', () {
      final text = redactedDiagnosticsJson(<String, Object?>{
        'at': DateTime.utc(2026, 11, 13, 1, 2, 3),
        'odd': Uri.parse('https://h/x?t=tok123'),
      });
      final decoded = jsonDecode(text) as Map<String, Object?>;
      expect(decoded['at'], '2026-11-13T01:02:03.000Z');
      expect(text, isNot(contains('tok123')));
    });
  });
}
