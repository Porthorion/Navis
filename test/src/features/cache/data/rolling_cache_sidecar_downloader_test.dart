import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempDir;
  late HttpServer server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('navis_sidecar_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentLength = 4;
        request.response.add(<int>[1, 2, 3, 4]);
        await request.response.close();
      }),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('range resume', () {
    final bytes = List<int>.generate(4 * 65536, (index) => index % 251);

    Future<HttpServer> serve(
      Future<void> Function(HttpRequest request) handler,
    ) async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) => unawaited(handler(request)));
      return origin;
    }

    Future<void> cut(HttpResponse response, List<int> prefix) async {
      response.add(prefix);
      await response.flush();
      response.deadline = Duration.zero;
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 400 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    test(
      'cut resumes a contiguous prefix with Range and strong If-Range',
      () async {
        final requests = <HttpHeaders>[];
        final secondResponse = Completer<HttpResponse>();
        final origin = await serve((request) async {
          requests.add(request.headers);
          if (requests.length == 1) {
            request.response.headers
              ..contentLength = bytes.length
              ..set(HttpHeaders.etagHeader, '"original"');
            await cut(request.response, bytes.sublist(0, 65536));
          } else {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers
              ..contentLength = bytes.length - 65536
              ..set(
                'content-range',
                'bytes 65536-${bytes.length - 1}/${bytes.length}',
              );
            secondResponse.complete(request.response);
          }
        });
        final downloader = RollingCacheSidecarDownloader();
        addTearDown(downloader.dispose);
        final file = File(p.join(tempDir.path, 'resumed.flac'));
        final progress = <double>[];
        var completed = 0;
        var terminated = 0;
        final downloading = downloader.start(
          songId: 'resume',
          uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
          cacheFilePath: file.path,
          onProgress: progress.add,
          onComplete: (_) async => completed++,
          onTerminated: () => terminated++,
        );
        await until(() => (downloader.activeReceivedBytes ?? 0) == 65536);
        final partPath = downloader.activePartFilePath!;
        await downloader.start(
          songId: 'resume',
          uri: Uri.parse('http://127.0.0.1:${origin.port}/other'),
          cacheFilePath: file.path,
          onProgress: (_) {},
          onComplete: (_) async => fail('duplicate completion'),
          onTerminated: () => fail('duplicate termination'),
        );
        final response = await secondResponse.future.timeout(
          const Duration(seconds: 3),
        );
        expect(terminated, 0);
        expect(downloader.activePartFilePath, partPath);
        expect(File(partPath).readAsBytesSync(), bytes.sublist(0, 65536));
        expect(requests[1].value(HttpHeaders.rangeHeader), 'bytes=65536-');
        expect(requests[1].value(HttpHeaders.ifRangeHeader), '"original"');
        response.add(bytes.sublist(65536));
        await response.close();
        await downloading;
        expect(file.readAsBytesSync(), bytes);
        expect(completed, 1);
        expect(terminated, 1);
        expect(progress, orderedEquals([...progress]..sort()));
        expect(progress.first, .25);
        expect(progress.last, 1);
      },
    );

    for (final invalid in [
      '200',
      '416',
      'start',
      'total',
      'end',
      'etag',
      'encoding',
    ]) {
      test('abandons a resume with invalid $invalid', () async {
        var requests = 0;
        final origin = await serve((request) async {
          requests++;
          request.response.headers.contentLength = bytes.length;
          if (requests == 1) {
            request.response.headers.set(HttpHeaders.etagHeader, '"original"');
            await cut(request.response, bytes.sublist(0, 65536));
          } else {
            request.response.statusCode = invalid == '200'
                ? HttpStatus.ok
                : invalid == '416'
                ? HttpStatus.requestedRangeNotSatisfiable
                : HttpStatus.partialContent;
            request.response.headers
              ..set(
                'content-range',
                'bytes ${invalid == 'start' ? 0 : 65536}-${bytes.length - (invalid == 'end' ? 2 : 1)}/${bytes.length + (invalid == 'total' ? 1 : 0)}',
              )
              ..set(
                HttpHeaders.etagHeader,
                invalid == 'etag' ? '"changed"' : '"original"',
              );
            if (invalid == 'encoding') {
              request.response.headers.set(
                HttpHeaders.contentEncodingHeader,
                'gzip',
              );
            }
            request.response.add(bytes);
            await request.response.close();
          }
        });
        final downloader = RollingCacheSidecarDownloader();
        addTearDown(downloader.dispose);
        var completed = 0;
        var terminated = 0;
        await downloader.start(
          songId: 'invalid',
          uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
          cacheFilePath: p.join(tempDir.path, 'invalid.flac'),
          onProgress: (_) {},
          onComplete: (_) async => completed++,
          onTerminated: () => terminated++,
        );
        expect(requests, 2);
        expect(completed, 0);
        expect(terminated, 1);
        expect(tempDir.listSync(), isEmpty);
      });
    }

    for (final exhausted in [false, true]) {
      test(
        exhausted
            ? 'exhausted retry budget discards the part'
            : 'two cuts resume cumulatively',
        () async {
          final ranges = <String?>[];
          final origin = await serve((request) async {
            ranges.add(request.headers.value(HttpHeaders.rangeHeader));
            final offset = (ranges.length - 1) * 32768;
            request.response.headers.contentLength = bytes.length - offset;
            if (offset > 0) {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes $offset-${bytes.length - 1}/${bytes.length}',
              );
            }
            if (exhausted || ranges.length < 3) {
              await cut(
                request.response,
                bytes.sublist(offset, offset + 32768),
              );
            } else {
              request.response.add(bytes.sublist(offset));
              await request.response.close();
            }
          });
          final downloader = RollingCacheSidecarDownloader();
          addTearDown(downloader.dispose);
          final file = File(p.join(tempDir.path, 'cuts.flac'));
          var completed = 0;
          var terminated = 0;
          await downloader.start(
            songId: 'cuts',
            uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            cacheFilePath: file.path,
            onProgress: (_) {},
            onComplete: (_) async => completed++,
            onTerminated: () => terminated++,
          );
          expect(ranges, [
            null,
            'bytes=32768-',
            'bytes=65536-',
            if (exhausted) 'bytes=98304-',
          ]);
          expect(completed, exhausted ? 0 : 1);
          expect(terminated, 1);
          if (exhausted) {
            expect(tempDir.listSync(), isEmpty);
          } else {
            expect(file.readAsBytesSync(), bytes);
          }
        },
      );
    }

    for (final cancel in [false, true]) {
      test(
        '${cancel ? 'cancel' : 'pause'} during backoff prevents a GET',
        () async {
          var requests = 0;
          final origin = await serve((request) async {
            requests++;
            if (requests == 1) {
              request.response.headers.contentLength = bytes.length;
              await cut(request.response, bytes.sublist(0, 65536));
            } else {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers
                ..contentLength = bytes.length - 65536
                ..set(
                  'content-range',
                  'bytes 65536-${bytes.length - 1}/${bytes.length}',
                );
              request.response.add(bytes.sublist(65536));
              await request.response.close();
            }
          });
          final downloader = RollingCacheSidecarDownloader();
          addTearDown(downloader.dispose);
          var completed = 0;
          var terminated = 0;
          final downloading = downloader.start(
            songId: 'gate',
            uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            cacheFilePath: p.join(tempDir.path, 'gate.flac'),
            onProgress: (_) {},
            onComplete: (_) async => completed++,
            onTerminated: () => terminated++,
          );
          await until(() => (downloader.activeReceivedBytes ?? 0) == 65536);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final rate = downloader.activeBytesPerSecond;
          if (cancel) {
            await downloader.cancel();
            await downloading.timeout(const Duration(milliseconds: 500));
          } else {
            downloader.pause();
          }
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          expect(requests, 1);
          if (!cancel) {
            expect(downloader.activeBytesPerSecond, rate);
            expect(terminated, 0);
            downloader.resume();
          }
          await downloading;
          expect(completed, cancel ? 0 : 1);
          expect(terminated, 1);
        },
      );
    }

    test('unknown length cut is not retried', () async {
      var requests = 0;
      final origin = await serve((request) async {
        requests++;
        await cut(request.response, bytes.sublist(0, 65536));
      });
      final downloader = RollingCacheSidecarDownloader();
      addTearDown(downloader.dispose);
      var completed = 0;
      await downloader.start(
        songId: 'unknown',
        uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
        cacheFilePath: p.join(tempDir.path, 'unknown.flac'),
        onProgress: (_) {},
        onComplete: (_) async => completed++,
        onTerminated: () {},
      );
      expect(requests, 1);
      expect(completed, 0);
      expect(tempDir.listSync(), isEmpty);
    });

    test('A-B-A during backoff keeps only the new generation', () async {
      var aRequests = 0;
      final origin = await serve((request) async {
        if (request.uri.path == '/a' && ++aRequests == 1) {
          request.response.headers.contentLength = bytes.length;
          await cut(request.response, bytes.sublist(0, 65536));
        } else {
          request.response.add([request.uri.path == '/a' ? 3 : 2]);
          await request.response.close();
        }
      });
      final downloader = RollingCacheSidecarDownloader();
      addTearDown(downloader.dispose);
      final completed = <int>[];
      final terminated = <int>[];
      Future<void> start(String song, int generation) => downloader.start(
        songId: song,
        uri: Uri.parse('http://127.0.0.1:${origin.port}/$song'),
        cacheFilePath: p.join(tempDir.path, '$song.flac'),
        onProgress: (_) {},
        onComplete: (_) async => completed.add(generation),
        onTerminated: () => terminated.add(generation),
      );
      final firstA = start('a', 1);
      await until(() => (downloader.activeReceivedBytes ?? 0) == 65536);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await start('b', 2);
      await start('a', 3);
      await firstA;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(aRequests, 2);
      expect(completed, [2, 3]);
      expect(terminated, [1, 2, 3]);
      expect(File(p.join(tempDir.path, 'a.flac')).readAsBytesSync(), [3]);
      expect(
        tempDir.listSync().where((file) => file.path.contains('.part.')),
        isEmpty,
      );
    });
  });

  for (final pauseBeforeData in [false, true]) {
    test(
      'transfer rate excludes response latency, pause before data=$pauseBeforeData',
      () async {
        final streaming = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => streaming.close(force: true));
        final responseReady = Completer<HttpResponse>();
        streaming.listen((request) {
          request.response.headers.contentLength = 2 * 65536;
          responseReady.complete(request.response);
        });
        final downloader = RollingCacheSidecarDownloader();
        addTearDown(downloader.dispose);
        final firstChunk = Completer<void>();
        final downloading = downloader.start(
          songId: 'delayed',
          uri: Uri.parse('http://127.0.0.1:${streaming.port}/audio'),
          cacheFilePath: p.join(tempDir.path, 'delayed.flac'),
          onProgress: (_) {
            if ((downloader.activeReceivedBytes ?? 0) >= 65536 &&
                !firstChunk.isCompleted) {
              firstChunk.complete();
            }
          },
          onTerminated: () {},
          onComplete: (_) async {},
        );
        final response = await responseReady.future;
        if (pauseBeforeData) {
          downloader.pause();
          downloader.resume();
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        response.add(List<int>.filled(65536, 1));
        await response.flush();
        await firstChunk.future;
        downloader.pause();
        final rate = downloader.activeBytesPerSecond;
        downloader.resume();
        response.add(List<int>.filled(65536, 2));
        await response.close();
        await downloading;
        expect(rate, greaterThan(65536 / .25));
      },
    );
  }

  for (final cancel in [false, true]) {
    test(
      'paused sidecar ${cancel ? 'cancels without hanging' : 'resumes the same GET and excludes paused time'}',
      () async {
        final streaming = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => streaming.close(force: true));
        final responseReady = Completer<HttpResponse>();
        var gets = 0;
        streaming.listen((request) {
          gets++;
          request.response.headers.contentLength = 3 * 65536;
          responseReady.complete(request.response);
        });
        final downloader = RollingCacheSidecarDownloader();
        addTearDown(downloader.dispose);
        final file = File(p.join(tempDir.path, 'paused.flac'));
        var completed = false;
        final downloading = downloader.start(
          songId: 'paused',
          uri: Uri.parse('http://127.0.0.1:${streaming.port}/audio'),
          cacheFilePath: file.path,
          onProgress: (_) {},
          onTerminated: () {},
          onComplete: (_) async => completed = true,
        );
        final response = await responseReady.future;
        expect(downloader.activeBytesPerSecond, isNull);
        response.add(List<int>.filled(65536, 1));
        await response.flush();
        for (
          var i = 0;
          i < 200 && (downloader.activeReceivedBytes ?? 0) < 65536;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(downloader.activeReceivedBytes, 65536);
        downloader.pause();
        final rate = downloader.activeBytesPerSecond!;
        expect(downloader.isPaused, isTrue);
        response.add(List<int>.filled(65536, 2));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(downloader.activeReceivedBytes, 65536);
        expect(downloader.activeBytesPerSecond, closeTo(rate, rate * .01));
        if (cancel) {
          await downloader.cancel();
          await downloading.timeout(const Duration(seconds: 2));
          expect(completed, isFalse);
          expect(downloader.isPaused, isFalse);
          return;
        }
        await downloader.start(
          songId: 'paused',
          uri: Uri.parse('http://127.0.0.1:${streaming.port}/audio'),
          cacheFilePath: file.path,
          onProgress: (_) {},
          onTerminated: () {},
          onComplete: (_) async {},
        );
        downloader.resume();
        response.add(List<int>.filled(65536, 3));
        await response.close();
        await downloading;
        expect(gets, 1);
        expect(completed, isTrue);
        expect(file.lengthSync(), 3 * 65536);
        expect(file.readAsBytesSync()[65536], 2);
      },
    );
  }

  test(
    'downloads into the rolling cache file and reports completion',
    () async {
      final downloader = RollingCacheSidecarDownloader();
      addTearDown(downloader.dispose);
      final cacheFile = File(p.join(tempDir.path, 'song.bin'));
      final progressValues = <double>[];
      final done = Completer<File>();

      await downloader.start(
        songId: 'song-1',
        uri: Uri.parse('http://127.0.0.1:${server.port}/audio'),
        cacheFilePath: cacheFile.path,
        onProgress: progressValues.add,
        onTerminated: () {},
        onComplete: (file) async => done.complete(file),
      );

      final completed = await done.future.timeout(const Duration(seconds: 5));
      expect(completed.path, cacheFile.path);
      expect(cacheFile.existsSync(), isTrue);
      expect(cacheFile.readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(progressValues, isNotEmpty);
      expect(progressValues.last, 1);
      expect(File('${cacheFile.path}.part').existsSync(), isFalse);
    },
  );

  test('refuses a server error document instead of audio', () async {
    final errorServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => errorServer.close(force: true));
    unawaited(
      errorServer.forEach((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"subsonic-response":{"status":"failed",'
          '"error":{"code":70,"message":"data not found"}}}',
        );
        await request.response.close();
      }),
    );

    final downloader = RollingCacheSidecarDownloader();
    addTearDown(downloader.dispose);
    final cacheFile = File(p.join(tempDir.path, 'missing.flac'));
    var completed = false;

    await downloader.start(
      songId: 'song-missing',
      uri: Uri.parse('http://127.0.0.1:${errorServer.port}/audio'),
      cacheFilePath: cacheFile.path,
      onProgress: (_) {},
      onTerminated: () {},
      onComplete: (_) async => completed = true,
    );

    expect(completed, isFalse);
    expect(cacheFile.existsSync(), isFalse);
    expect(tempDir.listSync(), isEmpty);
  });

  test('cancel stops an in-flight download without completing', () async {
    final slowServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => slowServer.close(force: true));
    unawaited(
      slowServer.forEach((request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.statusCode = 200;
        request.response.add(<int>[9]);
        await request.response.close();
      }),
    );

    final downloader = RollingCacheSidecarDownloader();
    addTearDown(downloader.dispose);
    final cacheFile = File(p.join(tempDir.path, 'slow.bin'));
    var completed = false;

    final startFuture = downloader.start(
      songId: 'song-slow',
      uri: Uri.parse('http://127.0.0.1:${slowServer.port}/audio'),
      cacheFilePath: cacheFile.path,
      onProgress: (_) {},
      onTerminated: () {},
      onComplete: (_) async {
        completed = true;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await downloader.cancel();
    await startFuture;
    expect(completed, isFalse);
    expect(cacheFile.existsSync(), isFalse);
  });

  test('old A cleanup cannot remove a new A download after A-B-A', () async {
    final delayedServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => delayedServer.close(force: true));
    final firstAReceived = Completer<void>();
    final releaseFirstA = Completer<void>();
    var aRequests = 0;
    unawaited(
      delayedServer.forEach((request) async {
        try {
          if (request.uri.path == '/a') {
            aRequests++;
            if (aRequests == 1) {
              firstAReceived.complete();
              await releaseFirstA.future;
            }
            request.response.add(<int>[if (aRequests == 1) 1 else 3]);
          } else {
            request.response.add(<int>[2]);
          }
          await request.response.close();
        } on HttpException {
          // The first request is intentionally aborted by the downloader.
        }
      }),
    );

    final downloader = RollingCacheSidecarDownloader();
    addTearDown(downloader.dispose);
    final aFile = File(p.join(tempDir.path, 'a.bin'));
    final bFile = File(p.join(tempDir.path, 'b.bin'));
    final aUri = Uri.parse('http://127.0.0.1:${delayedServer.port}/a');
    final bUri = Uri.parse('http://127.0.0.1:${delayedServer.port}/b');
    final completions = <int>[];
    final terminations = <int>[];
    Future<void> start(String songId, Uri uri, File file, int completion) {
      return downloader.start(
        songId: songId,
        uri: uri,
        cacheFilePath: file.path,
        onProgress: (_) {},
        onTerminated: () => terminations.add(completion),
        onComplete: (_) async => completions.add(completion),
      );
    }

    final firstA = start('a', aUri, aFile, 1);
    await firstAReceived.future.timeout(const Duration(seconds: 5));
    await start('b', bUri, bFile, 2);
    await start('a', aUri, aFile, 3);
    releaseFirstA.complete();
    await firstA.timeout(const Duration(seconds: 5));

    expect(aFile.readAsBytesSync(), <int>[3]);
    expect(completions, <int>[2, 3]);
    expect(terminations, <int>[1, 2, 3]);
    expect(
      tempDir.listSync().whereType<File>().where(
        (file) => file.path.contains('.part.'),
      ),
      isEmpty,
    );
  });
}
