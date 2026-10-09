import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_logging_interceptor.dart';

void main() {
  test('strips URL user info without modifying the request URI', () {
    final uri = Uri.parse(
      'https://user:pass%40word@example.com/rest/ping.view?id=cover',
    );
    final redacted = SubsonicLoggingInterceptor.redactUri(uri);
    expect(redacted.userInfo, isEmpty);
    expect(redacted.host, 'example.com');
    expect(redacted.queryParameters['id'], 'cover');
    expect(uri.userInfo, 'user:pass%40word');
  });

  test('redacts sensitive auth params from uri', () {
    final uri = Uri.parse(
      'https://example.com/rest/ping.view?u=user&t=token&s=salt&p=enc:abc&apiKey=key&f=json&query=test',
    );

    final redacted = SubsonicLoggingInterceptor.redactUri(uri);

    expect(redacted.queryParameters['u'], 'REDACTED');
    expect(redacted.queryParameters['t'], 'REDACTED');
    expect(redacted.queryParameters['s'], 'REDACTED');
    expect(redacted.queryParameters['p'], 'REDACTED');
    expect(redacted.queryParameters['apiKey'], 'REDACTED');
    expect(redacted.queryParameters['query'], 'test');
  });
}
