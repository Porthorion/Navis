// ignore_for_file: experimental_member_use, reason: exercises the Navis splice additions to the vendored source.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';

import 'ogg_opus_splicer_test.dart' show cutAfter, from2, full, pagesOf;

enum _End { cut, stall, complete }

/// One scripted origin response: [body] up to [length] bytes, then [end].
class _Reply {
  new(
    this.length,
    this.end, {
    this.status = 200,
    this.headersGate,
    this.headersDelay = Duration.zero,
    this.bodyPause = Duration.zero,
  });
  final Duration headersDelay;
  final Duration bodyPause;
  final int status;
  final Completer<void>? headersGate;
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
    await reply.headersGate?.future;
    if (reply.headersDelay > Duration.zero) {
      await Future<void>.delayed(reply.headersDelay);
    }
    final response = request.response
      ..statusCode = reply.status
      ..headers.contentType = ContentType('audio', 'ogg')
      ..bufferOutput = false;
    if (knownLength) response.contentLength = body.length;
    try {
      for (var at = 0; at < reply.length; at += 1024) {
        final end = at + 1024 < reply.length ? at + 1024 : reply.length;
        response.add(body.sublist(at, end));
        await response.flush();
        if (at == 0 && reply.bodyPause > Duration.zero) {
          await Future<void>.delayed(reply.bodyPause);
        }
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
      expect(events.single['dropped'], 55);
      expect(pages.last.granule, pagesOf(from2).last.granule + 48000);
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

  for (final splice in [false, true]) {
    test(
      'cancel after headers never publishes cache, splice=$splice',
      () async {
        final (server, _) = await _origin(
          [full],
          [_Reply(cut.length, _End.complete)],
        );
        addTearDown(() => server.close(force: true));
        late LockCachingAudioSource s;
        var cancelled = false;
        final progress = <double>[];
        Future<void>? cancellation;
        await HttpOverrides.runZoned(
          () async {
            s = source(server, splice: splice);
            final subscription = s.downloadProgressStream.listen(progress.add);
            addTearDown(subscription.cancel);
            final prefetch = s.prefetch().catchError((Object _) {});
            await Future<void>.delayed(const Duration(milliseconds: 400));
            await cancellation;
            await prefetch;
          },
          createHttpClient: (context) => _HeadersClient(
            Zone.root.run(() => HttpClient(context: context)),
            () {
              if (cancelled) return;
              cancelled = true;
              Timer.run(() => cancellation = s.cancelDownload());
            },
          ),
        );
        expect(cancelled, isTrue);
        expect(
          cacheFile.existsSync(),
          isFalse,
          reason: 'a cancelled download must not publish a cache file',
        );
        expect(File('${cacheFile.path}.part').existsSync(), isFalse);
        expect(progress.where((p) => p >= 1), isEmpty);
        expect(s.isDownloading, isFalse);
      },
    );
  }

  for (final length in [10, 100, 140, 4000]) {
    test('fallback preserves withheld bytes at cut $length', () async {
      final (server, requests) = await _origin(
        [full],
        [_Reply(length, _End.cut)],
      );
      addTearDown(() => server.close(force: true));
      final (bytes, error) = await drain(source(server));
      expect(error, isA<HttpException>());
      expect(bytes, full.take(length).toList());
      expect(requests, hasLength(length == 4000 ? 3 : 1));
    });
  }

  test('a clean EOF flushes its ragged final bytes unchanged', () async {
    final (server, _) = await _origin(
      [full],
      [_Reply(cut.length, _End.complete)],
    );
    addTearDown(() => server.close(force: true));
    final (bytes, error) = await drain(source(server));
    expect(error, isNull);
    expect(bytes, cut);
  });

  test('known-length cut is passthrough and never continues', () async {
    final (server, requests) = await _origin(
      [full],
      [_Reply(cut.length, _End.cut)],
      knownLength: true,
    );
    addTearDown(() => server.close(force: true));
    final (bytes, error) = await drain(source(server));
    expect(error, isA<HttpException>());
    expect(bytes, cut);
    expect(requests, hasLength(1));
    expect(cacheFile.existsSync(), isFalse);
  });

  for (final spec in [
    ('startup', const Duration(milliseconds: 2500), Duration.zero),
    ('body progress', Duration.zero, const Duration(milliseconds: 1500)),
  ]) {
    test('realistic continuation ${spec.$1} delay still splices', () async {
      final (server, requests) = await _origin(
        [full, from2],
        [
          _Reply(cut.length, _End.cut),
          _Reply(
            from2.length,
            _End.complete,
            headersDelay: spec.$2,
            bodyPause: spec.$3,
          ),
        ],
      );
      addTearDown(() => server.close(force: true));
      final events = <Map<String, Object?>>[];
      final (bytes, error) = await drain(
        source(server, timeout: const Duration(seconds: 3), events: events),
      );
      expect(error, isNull);
      expect(requests, [null, '1']);
      expect(pagesOf(bytes).every((page) => page.crcOk), isTrue);
      expect(events.single['result'], 'ok');
      expect(pagesOf(bytes).last.flags & 4, 4);
    });
  }

  for (final failure in [
    'status',
    'connect',
    'headers',
    'mismatch',
    'truncated',
  ]) {
    test(
      'continuation $failure preserves origin error and tail within its deadline',
      () async {
        final headersGate = Completer<void>();
        addTearDown(() {
          if (!headersGate.isCompleted) headersGate.complete();
        });
        final bad = Uint8List.fromList(from2)..[37] = 2;
        final (server, requests) = await _origin(
          [full, failure == 'mismatch' ? bad : from2],
          [
            _Reply(cut.length, _End.cut),
            _Reply(
              failure == 'truncated' ? 100 : from2.length,
              _End.complete,
              status: failure == 'status' ? 404 : 200,
              headersGate: failure == 'headers' ? headersGate : null,
            ),
          ],
        );
        addTearDown(() => server.close(force: true));
        final unavailable = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = unavailable.port;
        await unavailable.close();
        final events = <OggSpliceEvent>[];
        final s = LockCachingAudioSource(
          base(server),
          cacheFile: cacheFile,
          continuationUri: (offset) => failure == 'connect'
              ? Uri.parse('http://127.0.0.1:$port/song')
              : base(server)
                    .replace(queryParameters: {'timeOffset': '$offset'}),
          onOggSplice: events.add,
        );
        final clock = Stopwatch()..start();
        final originErrors = <Object>[];
        final (bytes, error) = await HttpOverrides.runZoned(
          () => drain(s),
          createHttpClient: (context) => _HeadersClient(
            Zone.root.run(() => HttpClient(context: context)),
            () {},
            originErrors,
          ),
        );
        expect(error, same(originErrors.first));
        expect(error, isA<HttpException>());
        expect(error.toString(), contains('Connection closed'));
        expect(bytes, cut);
        if (failure == 'headers') {
          expect(
            clock.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 6)),
          );
          expect(clock.elapsed, lessThan(const Duration(seconds: 8)));
        } else {
          expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        }
        expect(
          events.last.result,
          ['mismatch', 'truncated'].contains(failure) ? 'refused' : 'failed',
        );
        expect(requests.length, failure == 'connect' ? 1 : 2);
        expect(cacheFile.existsSync(), isFalse);
      },
    );
  }

  test(
    'cancel races a hung continuation connect without a failed trace',
    () async {
      final (server, _) = await _origin([full], [_Reply(cut.length, _End.cut)]);
      addTearDown(() => server.close(force: true));
      final connecting = Completer<void>();
      final client = _HungContinuationClient(connecting);
      final events = <OggSpliceEvent>[];
      late LockCachingAudioSource s;
      await HttpOverrides.runZoned(
        () async {
          s = LockCachingAudioSource(
            base(server),
            cacheFile: cacheFile,
            continuationUri: (_) =>
                Uri.parse('http://continuation.invalid/song'),
            onOggSplice: events.add,
          );
          final response = await s.request();
          final done = response.stream.drain<void>().catchError((Object _) {});
          await connecting.future;
          await s.cancelDownload().timeout(const Duration(milliseconds: 300));
          await done;
        },
        createHttpClient: (context) {
          client.inner = Zone.root.run(() => HttpClient(context: context));
          return client;
        },
      );
      expect(client.closed, isTrue);
      expect(events, isEmpty);
      expect(cacheFile.existsSync(), isFalse);
    },
  );

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
    await s.cancelDownload().timeout(const Duration(milliseconds: 300));
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

class _HeadersClient extends Fake implements HttpClient {
  _HeadersClient(this.inner, this.onHeaders, [this.errors]);
  final List<Object>? errors;
  final HttpClient inner;
  final void Function() onHeaders;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async =>
      _HeadersRequest(await inner.getUrl(uri), onHeaders, errors);
  @override
  void close({bool force = false}) => inner.close(force: force);
}

class _HeadersRequest extends Fake implements HttpClientRequest {
  _HeadersRequest(this.inner, this.onHeaders, this.errors);
  final List<Object>? errors;
  final HttpClientRequest inner;
  final void Function() onHeaders;
  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future<HttpClientResponse> close() async {
    final response = await inner.close();
    onHeaders();
    return errors == null ? response : _ObservedResponse(response, errors!);
  }
}

class _HungContinuationClient extends Fake implements HttpClient {
  _HungContinuationClient(this.connecting);
  final Completer<void> connecting;
  late HttpClient inner;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    if (uri.host != 'continuation.invalid') return inner.getUrl(uri);
    connecting.complete();
    return Completer<HttpClientRequest>().future;
  }

  @override
  void close({bool force = false}) {
    closed = force;
    inner.close(force: force);
  }
}

// Retain the exact body error object seen before continuation recovery.
class _ObservedResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _ObservedResponse(this.inner, List<Object> errors)
    : super(
        inner.transform(
          StreamTransformer.fromHandlers(
            handleError:
                (Object error, StackTrace stack, EventSink<List<int>> sink) {
                  errors.add(error);
                  sink.addError(error, stack);
                },
          ),
        ),
      );
  final HttpClientResponse inner;
  @override
  int get statusCode => inner.statusCode;
  @override
  int get contentLength => inner.contentLength;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
