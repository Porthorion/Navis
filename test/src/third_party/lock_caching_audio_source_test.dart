import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

/// Serves [body] slowly so a download stays in progress, with or without
/// byte-range support, and counts the downloads it starts.
Future<(HttpServer, List<int>)> _serve(
  List<int> body, {
  required bool ranges,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final downloads = <int>[];
  server.listen((request) async {
    downloads.add(downloads.length);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('audio', 'mpeg')
      ..contentLength = body.length;
    if (ranges) response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      for (var offset = 0; offset < body.length; offset += 1024) {
        response.add(
          body.sublist(offset, (offset + 1024).clamp(0, body.length)),
        );
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await response.close();
    } on Object {
      // The client went away.
    }
  });
  return (server, downloads);
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-lock-cache-');
  });
  tearDown(() => directory.delete(recursive: true));

  for (final ranges in [true, false]) {
    test('reports whether the origin supports ranges ($ranges)', () async {
      final (server, _) = await _serve(
        List<int>.filled(64 * 1024, 7),
        ranges: ranges,
      );
      addTearDown(() => server.close(force: true));
      // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File('${directory.path}/song.mp3'),
      );
      expect(source.originSupportsRangeRequests, isNull);
      final response = await source.request();
      expect(source.originSupportsRangeRequests, ranges);
      final drained = response.stream.drain<void>().catchError((_) {});
      await source.cancelDownload();
      await drained;
    });
  }

  test('a cancelled download discards its partial file and restarts', () async {
    final body = List<int>.filled(256 * 1024, 3);
    final (server, downloads) = await _serve(body, ranges: false);
    addTearDown(() => server.close(force: true));
    final cacheFile = File('${directory.path}/song.mp3');
    // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: cacheFile,
    );
    final first = await source.request();
    final failed = Completer<void>();
    first.stream.listen(
      (_) {},
      onError: (Object _) {
        if (!failed.isCompleted) failed.complete();
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await source.cancelDownload();

    await failed.future.timeout(const Duration(seconds: 2));
    expect(File('${cacheFile.path}.part').existsSync(), isFalse);
    expect(cacheFile.existsSync(), isFalse);

    final second = await source.request();
    final bytes = await second.stream.fold<int>(
      0,
      (n, chunk) => n + chunk.length,
    );
    expect(bytes, body.length);
    expect(downloads, hasLength(2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cacheFile.lengthSync(), body.length);
  });
}
