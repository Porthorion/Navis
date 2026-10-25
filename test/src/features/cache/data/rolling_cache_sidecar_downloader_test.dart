import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:path/path.dart' as p;

class _MockHttpClient extends Mock implements HttpClient;

class _MockRequest extends Mock implements HttpClientRequest;

class _MockHeaders extends Mock implements HttpHeaders;

class _FastResponse extends Mock implements HttpClientResponse {
  new(this.body);

  final Stream<List<int>> body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

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

  test('a fast response cannot outrun file writes', () async {
    const chunkSize = 64 * 1024;
    const chunkCount = 64;
    final uri = Uri.parse('http://fixture.invalid/audio');
    final client = _MockHttpClient();
    final request = _MockRequest();
    final headers = _MockHeaders();
    final response = _FastResponse(
      Stream.fromIterable(
        List.generate(chunkCount, (_) => List<int>.filled(chunkSize, 1)),
      ),
    );
    when(() => client.getUrl(uri)).thenAnswer((_) async => request);
    when(request.close).thenAnswer((_) async => response);
    when(() => response.headers).thenReturn(headers);
    when(() => response.statusCode).thenReturn(HttpStatus.ok);
    when(() => response.contentLength).thenReturn(chunkSize * chunkCount);
    final downloader = RollingCacheSidecarDownloader(
      httpClientFactory: () => client,
    );
    addTearDown(downloader.dispose);
    final file = File(p.join(tempDir.path, 'backpressure.opus'));
    var maxPendingBytes = 0;
    await downloader.start(
      songId: 'backpressure',
      uri: uri,
      cacheFilePath: file.path,
      isTranscoded: true,
      onProgress: (_) {
        final path = downloader.activePartFilePath;
        if (path == null) return;
        final part = File(path);
        if (!part.existsSync()) return;
        final pending = downloader.activeReceivedBytes! - part.lengthSync();
        if (pending > maxPendingBytes) maxPendingBytes = pending;
      },
      onComplete: (_) async {},
      onTerminated: () {},
    );
    expect(file.lengthSync(), chunkSize * chunkCount);
    expect(maxPendingBytes, lessThanOrEqualTo(chunkSize));
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
              ..set(HttpHeaders.etagHeader, '"original"')
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
            request.response.headers.contentLength = bytes.length - 65536;
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
            request.response.add(bytes.sublist(65536));
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

    for (final header in [
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
    ]) {
      for (final missing in [false, true]) {
        test(
          'abandons a resume with ${missing ? 'missing' : 'changed'} $header',
          () async {
            final original = header == HttpHeaders.etagHeader
                ? '"original"'
                : 'Wed, 21 Oct 2015 07:28:00 GMT';
            var requests = 0;
            final origin = await serve((request) async {
              requests++;
              if (requests == 1) {
                request.response.headers
                  ..contentLength = bytes.length
                  ..set(header, original);
                await cut(request.response, bytes.sublist(0, 65536));
              } else {
                expect(
                  request.headers.value(HttpHeaders.ifRangeHeader),
                  original,
                );
                request.response.statusCode = HttpStatus.partialContent;
                request.response.headers
                  ..contentLength = bytes.length - 65536
                  ..set(
                    HttpHeaders.contentRangeHeader,
                    'bytes 65536-${bytes.length - 1}/${bytes.length}',
                  );
                if (!missing) {
                  request.response.headers.set(
                    header,
                    header == HttpHeaders.etagHeader
                        ? '"replacement"'
                        : 'Thu, 22 Oct 2015 07:28:00 GMT',
                  );
                }
                request.response.add(
                  List<int>.filled(bytes.length - 65536, 255),
                );
                await request.response.close();
              }
            });
            final downloader = RollingCacheSidecarDownloader();
            addTearDown(downloader.dispose);
            var completed = 0;
            var terminated = 0;
            await downloader.start(
              songId: 'validator',
              uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
              cacheFilePath: p.join(tempDir.path, 'validator.flac'),
              onProgress: (_) {},
              onComplete: (_) async => completed++,
              onTerminated: () => terminated++,
            );
            expect(requests, 2);
            expect(completed, 0);
            expect(terminated, 1);
            expect(tempDir.listSync(), isEmpty);
          },
        );
      }
    }

    test('Accept-Ranges none abandons a cut without retrying', () async {
      var requests = 0;
      final origin = await serve((request) async {
        requests++;
        request.response.headers
          ..contentLength = bytes.length
          ..set(HttpHeaders.acceptRangesHeader, 'none');
        await cut(request.response, bytes.sublist(0, 65536));
      });
      final downloader = RollingCacheSidecarDownloader();
      addTearDown(downloader.dispose);
      var completed = 0;
      var terminated = 0;
      await downloader.start(
        songId: 'no-ranges',
        uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
        cacheFilePath: p.join(tempDir.path, 'no-ranges.flac'),
        onProgress: (_) {},
        onComplete: (_) async => completed++,
        onTerminated: () => terminated++,
      );
      expect(requests, 1);
      expect(completed, 0);
      expect(terminated, 1);
      expect(tempDir.listSync(), isEmpty);
    });

    for (final error in [
      const HandshakeException('resume connect failed'),
      const TlsException('resume connect failed'),
    ]) {
      for (final exhausted in [false, true]) {
        test(
          '${error.runtimeType} on resume ${exhausted ? 'exhausts the same budget' : 'retries the same prefix'}',
          () async {
            var requests = 0;
            final origin = await serve((request) async {
              requests++;
              if (requests == 1) {
                request.response.contentLength = bytes.length;
                await cut(request.response, bytes.sublist(0, 65536));
              } else {
                expect(
                  request.headers.value(HttpHeaders.rangeHeader),
                  'bytes=65536-',
                );
                request.response.statusCode = HttpStatus.partialContent;
                request.response.headers
                  ..contentLength = bytes.length - 65536
                  ..set(
                    HttpHeaders.contentRangeHeader,
                    'bytes 65536-${bytes.length - 1}/${bytes.length}',
                  );
                request.response.add(bytes.sublist(65536));
                await request.response.close();
              }
            });
            final uri = Uri.parse('http://127.0.0.1:${origin.port}/audio');
            final realClient = HttpClient();
            addTearDown(() => realClient.close(force: true));
            final client = _MockHttpClient();
            var connections = 0;
            when(() => client.getUrl(uri)).thenAnswer((_) async {
              connections++;
              if (connections > 1 && (exhausted || connections == 2)) {
                throw error;
              }
              return await realClient.getUrl(uri);
            });
            when(() => client.close(force: true)).thenAnswer((_) {
              realClient.close(force: true);
            });
            final downloader = RollingCacheSidecarDownloader(
              httpClientFactory: () => client,
            );
            addTearDown(downloader.dispose);
            final file = File(p.join(tempDir.path, 'tls.flac'));
            var completed = 0;
            var terminated = 0;
            await downloader.start(
              songId: 'tls',
              uri: uri,
              cacheFilePath: file.path,
              onProgress: (_) {},
              onComplete: (_) async => completed++,
              onTerminated: () => terminated++,
            );
            expect(connections, exhausted ? 4 : 3);
            expect(requests, exhausted ? 1 : 2);
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
    }

    for (final exhausted in [false, true]) {
      test(
        exhausted
            ? 'exhausted retry budget discards the part'
            : 'two cuts resume cumulatively',
        () async {
          final ranges = <String?>[];
          final body = exhausted ? [...bytes, ...bytes] : bytes;
          var offset = 0;
          final origin = await serve((request) async {
            ranges.add(request.headers.value(HttpHeaders.rangeHeader));
            request.response.headers.contentLength = body.length - offset;
            if (offset > 0) {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes $offset-${body.length - 1}/${body.length}',
              );
            }
            if (exhausted || ranges.length < 3) {
              final nextOffset =
                  offset +
                  (exhausted && ranges.length == 1 ? 256 * 1024 - 1 : 32768);
              final prefix = body.sublist(offset, nextOffset);
              offset = nextOffset;
              await cut(request.response, prefix);
            } else {
              request.response.add(body.sublist(offset));
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
            if (exhausted) ...[
              'bytes=262143-',
              'bytes=294911-',
              'bytes=327679-',
            ] else ...[
              'bytes=32768-',
              'bytes=65536-',
            ],
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

    for (final oversized in [false, true]) {
      test(
        '${oversized ? 'oversized' : 'short'} chunked resume is never published',
        () async {
          var requests = 0;
          final origin = await serve((request) async {
            requests++;
            if (requests == 1) {
              request.response.contentLength = bytes.length;
              await cut(request.response, bytes.sublist(0, 65536));
            } else {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes 65536-${bytes.length - 1}/${bytes.length}',
              );
              request.response.add(
                oversized ? bytes : bytes.sublist(65536, 65537),
              );
              await request.response.close();
            }
          });
          final downloader = RollingCacheSidecarDownloader();
          addTearDown(downloader.dispose);
          var completed = false;
          await downloader.start(
            songId: 'incomplete',
            uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            cacheFilePath: p.join(tempDir.path, 'incomplete.flac'),
            onProgress: (_) {},
            onComplete: (_) async => completed = true,
            onTerminated: () {},
          );
          expect(requests, 2);
          expect(completed, isFalse);
          expect(tempDir.listSync(), isEmpty);
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

    for (final isTranscoded in [false, true]) {
      test(
        '${isTranscoded ? 'known length transcode' : 'unknown length'} cut is not retried',
        () async {
          var requests = 0;
          final origin = await serve((request) async {
            requests++;
            if (isTranscoded) request.response.contentLength = bytes.length;
            await cut(request.response, bytes.sublist(0, 65536));
          });
          final downloader = RollingCacheSidecarDownloader();
          addTearDown(downloader.dispose);
          var completed = 0;
          await downloader.start(
            songId: 'unknown',
            isTranscoded: isTranscoded,
            uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            cacheFilePath: p.join(tempDir.path, 'unknown.flac'),
            onProgress: (_) {},
            onComplete: (_) async => completed++,
            onTerminated: () {},
          );
          expect(requests, 1);
          expect(completed, 0);
          expect(tempDir.listSync(), isEmpty);
        },
      );
    }

    test('a weak ETag falls back to Last-Modified for If-Range', () async {
      const modified = 'Wed, 21 Oct 2015 07:28:00 GMT';
      var requests = 0;
      final origin = await serve((request) async {
        requests++;
        if (requests == 1) {
          request.response.headers
            ..contentLength = bytes.length
            ..set(HttpHeaders.etagHeader, 'W/"original"')
            ..set(HttpHeaders.lastModifiedHeader, modified);
          await cut(request.response, bytes.sublist(0, 65536));
        } else {
          expect(request.headers.value(HttpHeaders.ifRangeHeader), modified);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers
            ..contentLength = bytes.length - 65536
            ..set(HttpHeaders.lastModifiedHeader, modified)
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
      final file = File(p.join(tempDir.path, 'modified.flac'));
      await downloader.start(
        songId: 'modified',
        uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
        cacheFilePath: file.path,
        onProgress: (_) {},
        onComplete: (_) async {},
        onTerminated: () {},
      );
      expect(requests, 2);
      expect(file.readAsBytesSync(), bytes);
    });

    test('256 KiB of new data renews the retry budget', () async {
      final body = [...bytes, ...bytes, ...bytes];
      var requests = 0;
      var offset = 0;
      final origin = await serve((request) async {
        requests++;
        request.response.contentLength = body.length - offset;
        if (requests > 1) {
          expect(
            request.headers.value(HttpHeaders.rangeHeader),
            'bytes=$offset-',
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes $offset-${body.length - 1}/${body.length}',
          );
        }
        if (requests < 5) {
          final nextOffset = offset + (requests == 4 ? 256 * 1024 : 32768);
          final prefix = body.sublist(offset, nextOffset);
          offset = nextOffset;
          await cut(request.response, prefix);
        } else {
          request.response.add(body.sublist(offset));
          await request.response.close();
        }
      });
      final downloader = RollingCacheSidecarDownloader();
      addTearDown(downloader.dispose);
      final file = File(p.join(tempDir.path, 'budget.flac'));
      await downloader.start(
        songId: 'budget',
        uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
        cacheFilePath: file.path,
        onProgress: (_) {},
        onComplete: (_) async {},
        onTerminated: () {},
      );
      expect(requests, 5);
      expect(file.readAsBytesSync(), body);
    });

    test('A-B-A during backoff keeps only the new generation', () async {
      var aRequests = 0;
      final origin = await serve((request) async {
        if (request.uri.path == '/a' && ++aRequests == 1) {
          request.response.headers.contentLength = bytes.length;
          await cut(request.response, bytes.sublist(0, 65536));
        } else {
          request.response.add([if (request.uri.path == '/a') 3 else 2]);
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
