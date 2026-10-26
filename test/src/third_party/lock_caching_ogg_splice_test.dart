import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'ogg_opus_splicer_test.dart' show cutAfter, from2, full, pagesOf;

enum _End { cut, stall, complete }

/// One scripted origin response: [body] up to [length] bytes, then [end].
class _Reply {
  _Reply(this.length, this.end);
  final int length;
  final _End end;
}

/// Serves `/song` with the scripted replies in order (the last one repeats),
/// recording every request's `timeOffset`.
Future<(HttpServer, List<String?>)> _origin(
  List<List<int>> bodies,
  List<_Reply> replies, {
  bool knownLength = false,
  Completer<void>? gate,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String?>[];
  server.listen((request) async {
    final n = requests.length;
    requests.add(request.uri.queryParameters['timeOffset']);
    final reply = replies[n < replies.length ? n : replies.length - 1];
    final body = bodies[n < bodies.length ? n : bodies.length - 1];
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('audio', 'ogg')
      ..bufferOutput = false;
    if (knownLength) response.contentLength = body.length;
    try {
      for (var at = 0; at < reply.length; at += 1024) {
        final end = at + 1024 < reply.length ? at + 1024 : reply.length;
        response.add(body.sublist(at, end));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (gate != null && n == 0) await gate.future;
      switch (reply.end) {
        case _End.complete:
          await response.close();
        case _End.cut:
          response.deadline = Duration.zero;
        case _End.stall:
          await Future<void>.delayed(const Duration(seconds: 5));
      }
    } on Object {
      // The client went away.
    }
  });
  return (server, requests);
}

void main() {
  late Directory directory;
  late File cacheFile;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-ogg-splice-');
    cacheFile = File('${directory.path}/song.opus');
  });
  tearDown(() => directory.delete(recursive: true));

  Uri base(HttpServer s) => Uri.parse('http://127.0.0.1:${s.port}/song');

  // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
  LockCachingAudioSource source(
    HttpServer server, {
    bool splice = true,
    Duration timeout = const Duration(seconds: 30),
    List<Map<String, Object?>>? events,
  }) => LockCachingAudioSource(
    base(server),
    cacheFile: cacheFile,
    bodyProgressTimeout: timeout,
    continuationUri: splice
        ? (seconds) =>
              base(server).replace(queryParameters: {'timeOffset': '$seconds'})
        : null,
    onOggSplice: events == null
        ? null
        : (e) => events.add({
            'offset': e.offsetSeconds,
            'dropped': e.droppedPackets,
            'attempt': e.attempt,
            'result': e.result,
          }),
  );

  Future<(List<int>, Object?)> drain(LockCachingAudioSource s) async {
    final response = await s.request();
    final bytes = <int>[];
    Object? error;
    await response.stream
        .listen(bytes.addAll, onError: (Object e) => error = e)
        .asFuture<void>()
        .catchError((Object e) => error = e)
        .timeout(const Duration(seconds: 15));
    return (bytes, error);
  }

  final cut = cutAfter(100800);

  test(
    'a mid-body cut is spliced: stitched bytes, no error, part kept',
    () async {
      final (server, requests) = await _origin(
        [full, from2],
        [_Reply(cut.length, _End.cut), _Reply(from2.length, _End.complete)],
      );
      addTearDown(() => server.close(force: true));
      final events = <Map<String, Object?>>[];
      final (bytes, error) = await drain(source(server, events: events));

      expect(error, isNull);
      expect(requests, [null, '1']); // floor(2.09 s) - 1 s pre-roll
      final pages = pagesOf(bytes);
      expect(pages.every((p) => p.crcOk), isTrue);
      expect(pages.map((p) => p.serial).toSet(), hasLength(1));
      expect(pages.last.flags & 4, 4);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cacheFile.readAsBytesSync(), bytes); // the .part became the cache
      expect(File('${cacheFile.path}.part').existsSync(), isFalse);
      expect(events.single['result'], 'ok');
      expect(events.single['offset'], 1);
    },
  );

  test(
    'without the callback the error and part deletion are unchanged',
    () async {
      final (server, requests) = await _origin(
        [full],
        [_Reply(cut.length, _End.cut)],
      );
      addTearDown(() => server.close(force: true));
      final (_, error) = await drain(source(server, splice: false));
      expect(error, isA<HttpException>()); // the origin's own failure
      expect(requests, hasLength(1));
      expect(File('${cacheFile.path}.part').existsSync(), isFalse);
      expect(cacheFile.existsSync(), isFalse);
    },
  );

  test('a cut before the first audio page falls back', () async {
    final (server, requests) = await _origin([full], [_Reply(100, _End.cut)]);
    addTearDown(() => server.close(force: true));
    final (_, error) = await drain(source(server));
    expect(error, isNotNull);
    expect(requests, hasLength(1));
    expect(File('${cacheFile.path}.part').existsSync(), isFalse);
  });

  test('a second cut during the continuation is spliced again', () async {
    final (server, requests) = await _origin(
      [full, from2, from2],
      [
        _Reply(cut.length, _End.cut),
        _Reply(5000, _End.cut),
        _Reply(from2.length, _End.complete),
      ],
    );
    addTearDown(() => server.close(force: true));
    final (bytes, error) = await drain(source(server));
    expect(error, isNull);
    expect(requests, hasLength(3));
    final pages = pagesOf(bytes);
    expect(pages.every((p) => p.crcOk), isTrue);
    expect(
      [for (final p in pages) p.seq],
      [for (var i = 0; i < pages.length; i++) i],
    );
  });

  test('a third cut exhausts the attempts and fails as today', () async {
    final (server, requests) = await _origin(
      [full, from2],
      [_Reply(cut.length, _End.cut), _Reply(5000, _End.cut)],
    );
    addTearDown(() => server.close(force: true));
    final (_, error) = await drain(source(server));
    expect(error, isNotNull);
    expect(requests, hasLength(3)); // the origin plus two continuations
    expect(File('${cacheFile.path}.part').existsSync(), isFalse);
  });

  test('a stalled body continues after the progress timeout', () async {
    final (server, requests) = await _origin(
      [full, from2],
      [_Reply(cut.length, _End.stall), _Reply(from2.length, _End.complete)],
    );
    addTearDown(() => server.close(force: true));
    final (bytes, error) = await drain(
      source(server, timeout: const Duration(milliseconds: 300)),
    );
    expect(error, isNull);
    expect(requests, [null, '1']);
    expect(pagesOf(bytes).every((p) => p.crcOk), isTrue);
  });

  test('cancelling the download makes no continuation', () async {
    final gate = Completer<void>();
    final (server, requests) = await _origin(
      [full, from2],
      [_Reply(cut.length, _End.cut), _Reply(from2.length, _End.complete)],
      gate: gate,
    );
    addTearDown(() => server.close(force: true));
    final s = source(server);
    final response = await s.request();
    final done = Completer<void>();
    response.stream.listen(
      (_) {},
      onError: (Object _) {},
      onDone: done.complete,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await s.cancelDownload();
    gate.complete(); // the origin cuts only after the cancel
    await done.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(requests, hasLength(1));
    expect(File('${cacheFile.path}.part').existsSync(), isFalse);
  });

  test(
    'non-Ogg and known-length responses are byte-identical passthrough',
    () async {
      final mp3 = Uint8List.fromList(List.generate(60000, (i) => i % 251));
      final (a, ra) = await _origin([mp3], [_Reply(mp3.length, _End.complete)]);
      addTearDown(() => a.close(force: true));
      final (bytesA, errA) = await drain(source(a));
      expect(errA, isNull);
      expect(bytesA, mp3);

      final (b, rb) = await _origin(
        [full],
        [_Reply(full.length, _End.complete)],
        knownLength: true,
      );
      addTearDown(() => b.close(force: true));
      final other = File('${directory.path}/other.opus');
      final s = LockCachingAudioSource(
        base(b),
        cacheFile: other,
        continuationUri: (s) => base(b),
      );
      final (bytesB, errB) = await drain(s);
      expect(errB, isNull);
      expect(bytesB, full);
      expect(ra, hasLength(1));
      expect(rb, hasLength(1));
    },
  );
}
