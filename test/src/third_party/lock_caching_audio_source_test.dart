import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    as platform;
import 'package:path/path.dart' as p;
import 'package:mocktail/mocktail.dart';

class _StalledConnection extends Fake implements HttpClient {
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      Completer<HttpClientRequest>().future;
  @override
  void close({bool force = false}) {
    closed = force;
  }
}

class _ProxyPlatform extends platform.JustAudioPlatform {
  late _ProxyPlayer player;

  @override
  Future<platform.AudioPlayerPlatform> init(
    platform.InitRequest request,
  ) async => player = _ProxyPlayer(request.id);

  @override
  Future<platform.DisposeAllPlayersResponse> disposeAllPlayers(
    platform.DisposeAllPlayersRequest request,
  ) async => platform.DisposeAllPlayersResponse();

  @override
  Future<platform.DisposePlayerResponse> disposePlayer(
    platform.DisposePlayerRequest request,
  ) async {
    await player.events.close();
    return platform.DisposePlayerResponse();
  }
}

class _ProxyPlayer extends platform.AudioPlayerPlatform {
  new(super.id);

  final events = StreamController<platform.PlaybackEventMessage>.broadcast();
  late Uri proxyUri;

  @override
  Stream<platform.PlaybackEventMessage> get playbackEventMessageStream =>
      events.stream;

  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    final playlist =
        request.audioSourceMessage as platform.ConcatenatingAudioSourceMessage;
    proxyUri = Uri.parse(
      (playlist.children.single as platform.ProgressiveAudioSourceMessage).uri,
    );
    events.add(
      platform.PlaybackEventMessage(
        processingState: platform.ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: null,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
    return platform.LoadResponse(duration: null);
  }

  @override
  Future<platform.SetVolumeResponse> setVolume(
    platform.SetVolumeRequest request,
  ) async => platform.SetVolumeResponse();

  @override
  Future<platform.SetSpeedResponse> setSpeed(
    platform.SetSpeedRequest request,
  ) async => platform.SetSpeedResponse();

  @override
  Future<platform.SetLoopModeResponse> setLoopMode(
    platform.SetLoopModeRequest request,
  ) async => platform.SetLoopModeResponse();

  @override
  Future<platform.SetShuffleModeResponse> setShuffleMode(
    platform.SetShuffleModeRequest request,
  ) async => platform.SetShuffleModeResponse();
}

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
  final native = _ProxyPlatform();
  final previousPlatform = platform.JustAudioPlatform.instance;
  setUpAll(() => platform.JustAudioPlatform.instance = native);
  tearDownAll(() => platform.JustAudioPlatform.instance = previousPlatform);
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-lock-cache-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('proxy frames an unknown-length keep-alive response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final body = List<int>.filled(1024, 7);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'ogg');
      request.response.add(body.sublist(0, 512));
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      request.response.add(body.sublist(512));
      await request.response.close();
    });
    // ignore: experimental_member_use, reason: exercises the real lock-cache proxy response.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: File(p.join(directory.path, 'framing.ogg')),
    );
    final player = AudioPlayer(
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(player.dispose);
    addTearDown(source.cancelDownload);
    await player.setAudioSource(source);
    final uri = native.player.proxyUri;
    final socket = await Socket.connect(uri.host, uri.port);
    addTearDown(socket.destroy);
    socket.write(
      'GET ${uri.path} HTTP/1.1\r\n'
      'Host: ${uri.host}:${uri.port}\r\n'
      'Connection: keep-alive\r\n\r\n',
    );
    await socket.flush();

    final received = StringBuffer();
    final response = await socket
        .cast<List<int>>()
        .transform(latin1.decoder)
        .map((chunk) {
          received.write(chunk);
          return received.toString();
        })
        .firstWhere((wire) {
          final headerEnd = wire.indexOf('\r\n\r\n');
          if (headerEnd < 0) return false;
          final headers = wire.substring(0, headerEnd).toLowerCase();
          if (headers.contains('\r\ntransfer-encoding: chunked')) {
            return wire.endsWith('\r\n0\r\n\r\n');
          }
          final length = RegExp(r'\r\ncontent-length: (\d+)')
              .firstMatch(headers);
          return length != null &&
              int.parse(length[1]!) == body.length &&
              wire.length - headerEnd - 4 == body.length;
        })
        .timeout(const Duration(seconds: 2));

    expect(response, startsWith('HTTP/1.1 200 OK\r\n'));
    expect(response, contains('\r\ncontent-type: audio/ogg\r\n'));
  });

  for (final knownLength in [false, true]) {
    test('proxy closes an open-ended range (known length: $knownLength)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final body = List<int>.generate(1024, (index) => index % 256);
      server.listen((request) async {
        final response = request.response;
        response.headers
          ..contentType = ContentType('audio', 'mpeg')
          ..set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (knownLength) response.contentLength = body.length;
        response.add(body.sublist(0, 512));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        response.add(body.sublist(512));
        await response.close();
      });
      // ignore: experimental_member_use, reason: exercises the real lock-cache proxy response.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(p.join(directory.path, 'proxy.mp3')),
      );
      final player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );
      addTearDown(player.dispose);
      addTearDown(source.cancelDownload);
      await player.setAudioSource(source);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(native.player.proxyUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');

      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );

      expect(
        response.statusCode,
        knownLength
            ? HttpStatus.partialContent
            : HttpStatus.internalServerError,
      );
      expect(response.contentLength, knownLength ? body.length : 0);
      final received = await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      expect(received, knownLength ? body : isEmpty);
      await source.downloadProgressStream
          .firstWhere((progress) => progress == 1)
          .timeout(const Duration(seconds: 2));

      // A later request for the completed cache is still served by this proxy.
      final replay = await client.getUrl(native.player.proxyUri);
      replay.headers.set(HttpHeaders.rangeHeader, 'bytes=32-63');
      final cached = await replay.close();
      expect(cached.statusCode, HttpStatus.partialContent);
      expect(cached.contentLength, 32);
      expect(
        await cached.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        ),
        body.sublist(32, 64),
      );
    });
  }

  for (final knownLength in [true, false]) {
    test(
      '100% means flushed and published (known length: $knownLength)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final body = List<int>.filled(128 * 1024, 7);
        server.listen((request) async {
          if (knownLength) request.response.contentLength = body.length;
          request.response.add(body);
          await request.response.close();
        });
        final cacheFile = File('${directory.path}/published.mp3');
        // ignore: experimental_member_use, reason: tests publication ordering in the vendored source.
        final source = LockCachingAudioSource(
          Uri.parse('http://127.0.0.1:${server.port}/song'),
          cacheFile: cacheFile,
        );
        final published = Completer<bool>();
        final subscription = source.downloadProgressStream.listen((progress) {
          if (progress == 1 && !published.isCompleted) {
            published.complete(
              cacheFile.existsSync() && cacheFile.lengthSync() == body.length,
            );
          }
        });
        addTearDown(subscription.cancel);
        final response = await source.request();
        await response.stream.drain<void>();
        expect(
          await published.future.timeout(const Duration(seconds: 2)),
          isTrue,
        );
      },
    );
  }

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
  test(
    'the connection deadline cancels even an unresolved origin connection',
    () async {
      final client = _StalledConnection();
      await HttpOverrides.runZoned(() async {
        // ignore: experimental_member_use, reason: validates the vendored connection deadline.
        final source = LockCachingAudioSource(
          Uri.parse('https://fixture.invalid/song'),
          cacheFile: File(p.join(directory.path, 'connection.mp3')),
          connectionTimeout: const Duration(milliseconds: 100),
        );
        await expectLater(source.request(), throwsA(isA<TimeoutException>()));
        expect(client.closed, isTrue);
      }, createHttpClient: (_) => client);
    },
  );

  for (final bodyStall in [false, true]) {
    test(
      'a ${bodyStall ? 'body-progress' : 'header'} deadline cancels and permits a fresh fetch',
      () async {
        var attempts = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          attempts++;
          if (attempts == 1) {
            if (bodyStall) {
              request.response.add([1, 2, 3]);
              await request.response.flush();
            }
            return;
          }
          request.response.add([4, 5, 6]);
          await request.response.close();
        });
        final cacheFile = File(p.join(directory.path, 'deadline.mp3'));
        // ignore: experimental_member_use, reason: validates vendored cache deadlines.
        final source = LockCachingAudioSource(
          Uri.parse('http://127.0.0.1:${server.port}/song'),
          cacheFile: cacheFile,
          headerTimeout: const Duration(milliseconds: 100),
          bodyProgressTimeout: const Duration(milliseconds: 100),
        );
        Future<void> fetch() async {
          final response = await source.request();
          await response.stream.drain<void>();
        }

        await expectLater(fetch(), throwsA(isA<TimeoutException>()));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(cacheFile.existsSync(), isFalse);
        expect(File('${cacheFile.path}.part').existsSync(), isFalse);
        final retried = await source.request();
        expect(await retried.stream.expand((bytes) => bytes).toList(), [
          4,
          5,
          6,
        ]);
        expect(attempts, 2);
      },
    );
  }

  test('cancellation before headers unblocks the pending request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    server.listen((_) => entered.complete());
    // ignore: experimental_member_use, reason: validates pre-header cancellation.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: File(p.join(directory.path, 'cancel.mp3')),
    );
    final request = source.request();
    final failed = expectLater(request, throwsA(isA<StateError>()));
    await entered.future;
    await source.cancelDownload();
    await failed.timeout(const Duration(seconds: 1));
  });
}
