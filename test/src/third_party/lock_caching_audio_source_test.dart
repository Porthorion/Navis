import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/player/data/seek_preview_request.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    as platform;
import 'package:path/path.dart' as p;
import 'package:mocktail/mocktail.dart';

import 'ogg_opus_splicer_test.dart' show cutAfter;

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
  List<Uri> childUris = [];
  Duration? loadedPosition;

  /// While set, [concatenatingRemoveRange] waits for it to complete.
  Completer<void>? removeGate;

  @override
  Stream<platform.PlaybackEventMessage> get playbackEventMessageStream =>
      events.stream;

  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    loadedPosition = request.initialPosition;
    final playlist =
        request.audioSourceMessage as platform.ConcatenatingAudioSourceMessage;
    platform.AudioSourceMessage first = playlist;
    while (first is platform.ConcatenatingAudioSourceMessage) {
      first = first.children.first;
    }
    proxyUri = Uri.parse((first as platform.ProgressiveAudioSourceMessage).uri);
    childUris = [];
    void collect(platform.AudioSourceMessage m) {
      if (m is platform.ConcatenatingAudioSourceMessage) {
        m.children.forEach(collect);
      } else {
        childUris.add(
          Uri.parse((m as platform.ProgressiveAudioSourceMessage).uri),
        );
      }
    }

    collect(playlist);
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
  Future<platform.ConcatenatingInsertAllResponse> concatenatingInsertAll(
    platform.ConcatenatingInsertAllRequest request,
  ) async {
    childUris.addAll([
      for (final child in request.children)
        Uri.parse((child as platform.ProgressiveAudioSourceMessage).uri),
    ]);
    return platform.ConcatenatingInsertAllResponse();
  }

  @override
  Future<platform.ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    platform.ConcatenatingRemoveRangeRequest request,
  ) async {
    await removeGate?.future;
    return platform.ConcatenatingRemoveRangeResponse();
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

// ignore: experimental_member_use, reason: exercises the public stream proxy contract.
class _ResponseSource extends StreamAudioSource {
  new(this.response);

  // ignore: experimental_member_use, reason: fixtures exercise the intended stream response API.
  final StreamAudioResponse response;

  @override
  // ignore: experimental_member_use, reason: fixtures exercise the intended stream response API.
  Future<StreamAudioResponse> request([int? start, int? end]) async => response;
}

enum _OriginFailure { disconnect, stall }

/// Serves [body] slowly, optionally interrupting its first response,
/// and counts the downloads it starts.
Future<(HttpServer, List<int>)> _serve(
  List<int> body, {
  required bool ranges,
  _OriginFailure? firstFailure,
  _OriginFailure? rangeFailure,
  bool knownLength = false,
  List<int>? closedRanges,
  bool rangeHeadersPending = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final downloads = <int>[];
  var rangeRequests = 0;
  server.listen((request) async {
    downloads.add(downloads.length);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('audio', 'mpeg');
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final start = range == null
        ? 0
        : int.parse(range.split('=')[1].split('-')[0]);
    final endText = range?.split('-')[1];
    final end = endText == null || endText.isEmpty
        ? body.length
        : int.parse(endText) + 1;
    if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${body.length}',
      );
    }
    if (range != null && closedRanges != null) {
      response.contentLength = end - start;
      final socket = await response.detachSocket(
        writeHeaders: !rangeHeadersPending,
      );
      final closed = Completer<void>();
      var disconnected = false;
      final peer = socket.listen(
        (_) {},
        onDone: () {
          disconnected = true;
          closedRanges.add(start);
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          disconnected = true;
          closedRanges.add(start);
          if (!closed.isCompleted) closed.complete();
        },
      );
      socket.done.ignore();
      try {
        if (rangeHeadersPending || rangeFailure == _OriginFailure.stall) {
          if (!rangeHeadersPending) {
            socket.add(body.sublist(start, start + 1024));
            await socket.flush();
          }
          await closed.future;
          return;
        }
        for (
          var offset = start;
          offset < end && !disconnected;
          offset += 1024
        ) {
          socket.add(body.sublist(offset, (offset + 1024).clamp(0, end)));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } on Object {
        if (!disconnected) closedRanges.add(start);
      } finally {
        await peer.cancel();
        socket.destroy();
      }
      return;
    }
    final failure = range == null
        ? (downloads.length == 1 ? firstFailure : null)
        : (++rangeRequests == 1 ? rangeFailure : null);
    if (failure == null || knownLength) response.contentLength = end - start;
    response.bufferOutput = false;
    if (ranges) response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      for (var offset = start; offset < end; offset += 1024) {
        response.add(body.sublist(offset, (offset + 1024).clamp(0, end)));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (failure != null) {
          if (failure == _OriginFailure.disconnect) {
            // Expiry destroys the socket without a terminating chunk.
            response.deadline = Duration.zero;
          }
          return;
        }
      }
      await response.close();
    } on Object {
      if (range != null) closedRanges?.add(start);
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

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  for (final splice in [false, true]) {
    for (final action in [
      'remove',
      'clear',
      'replace',
      if (!splice) 'dispose',
    ]) {
      test('$action retains whole-file caching, splice=$splice', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final body = List<int>.generate(32 * 1024, (i) => i % 251);
        server.listen((request) async {
          final response = request.response..bufferOutput = false;
          try {
            response.add(body.sublist(0, 1024));
            await response.flush();
            await release.future;
            response.add(body.sublist(1024));
            await response.close();
          } on Object {
            // A regression may cancel the origin before the gate is released.
          }
        });
        final uri = Uri.parse('http://127.0.0.1:${server.port}/song');
        final file = File(p.join(directory.path, 'retained.mp3'));
        // ignore: experimental_member_use, reason: verifies source-removal caching semantics.
        final source = LockCachingAudioSource(
          uri,
          cacheFile: file,
          continuationUri: splice ? (_) => uri : null,
        );
        addTearDown(source.cancelDownload);
        final other = AudioSource.uri(Uri.parse('https://example.com/other'));
        final player = AudioPlayer(
          handleAudioSessionActivation: false,
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
        );
        addTearDown(player.dispose);
        await player.setAudioSources([source, other]);
        final response = await source.request();
        final bytes = <int>[];
        final errors = <Object>[];
        final done = Completer<void>();
        response.stream.listen(
          bytes.addAll,
          onError: errors.add,
          onDone: done.complete,
        );
        await until(() => source.downloadedBytes == 1024);
        switch (action) {
          case 'remove':
            await player.removeAudioSourceAt(0);
          case 'clear':
            await player.clearAudioSources();
          case 'replace':
            await player.setAudioSources([other]);
          case 'dispose':
            source.pauseDownload();
            await player.dispose();
        }
        expect(
          source.isDownloading,
          isTrue,
          reason: 'removal must retain the original whole-file download',
        );
        release.complete();
        await done.future.timeout(const Duration(seconds: 2));
        await until(() => !source.isDownloading);
        expect(errors, isEmpty);
        expect(bytes, body);
        expect(file.readAsBytesSync(), body);
      });
    }
  }

  test('dispose cancels a continuation waiting for headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final connecting = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    server.listen((request) async {
      if (request.uri.queryParameters.containsKey('timeOffset')) {
        connecting.complete();
        await release.future;
        return;
      }
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('audio', 'ogg');
      final bytes = cutAfter(100800);
      for (var at = 0; at < bytes.length; at += 1024) {
        request.response.add(
          bytes.sublist(at, (at + 1024).clamp(0, bytes.length)),
        );
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      request.response.deadline = Duration.zero;
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/song');
    final file = File(p.join(directory.path, 'dispose.opus'));
    final events = <OggSpliceEvent>[];
    // ignore: experimental_member_use, reason: exercises dispose of the public source.
    final source = LockCachingAudioSource(
      uri,
      cacheFile: file,
      continuationUri: (seconds) =>
          uri.replace(queryParameters: {'timeOffset': '$seconds'}),
      onOggSplice: events.add,
    );
    final player = AudioPlayer(
      handleAudioSessionActivation: false,
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(player.dispose);
    await player.setAudioSource(source).timeout(const Duration(seconds: 2));
    final response = await source.request().timeout(const Duration(seconds: 2));
    final done = response.stream.drain<void>().catchError((Object _) {});
    await connecting.future.timeout(const Duration(seconds: 2));
    await player.dispose().timeout(const Duration(seconds: 2));
    await done.timeout(const Duration(milliseconds: 500));
    await until(() => !source.isDownloading);
    expect(file.existsSync(), isFalse);
    expect(File('${file.path}.part').existsSync(), isFalse);
    expect(events, isEmpty);
  });

  test('replaced adopted previews release their owners', () async {
    final player = AudioPlayer(
      handleAudioSessionActivation: false,
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(player.dispose);
    for (var i = 0; i < 20; i++) {
      final client = _StalledConnection();
      final source = SeekPreviewRequest(
        Uri.parse('http://fixture.invalid/offset'),
        client: client,
      ).asAudioSource();
      await player.setAudioSource(source);
      await player.setAudioSource(
        AudioSource.uri(Uri.parse('https://fixture.invalid/replaced')),
      );
      expect(client.closed, isTrue);
      expect(SeekPreviewRequest.hasOwner(source), isFalse);
      expect(SeekPreviewRequest.retryCount(source), 0);
    }
  });

  test(
    'nested removal preserves a source referenced by another playlist',
    () async {
      final client = _StalledConnection();
      final source = SeekPreviewRequest(
        Uri.parse('http://fixture.invalid/shared'),
        client: client,
      ).asAudioSource();
      final left = ConcatenatingAudioSource(children: [source]);
      final right = ConcatenatingAudioSource(children: [source]);
      final player = AudioPlayer(
        handleAudioSessionActivation: false,
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );
      addTearDown(player.dispose);
      await player.setAudioSources([left, right]);
      await player.setShuffleModeEnabled(true);
      await left.clear();
      expect(client.closed, isFalse);
      expect(SeekPreviewRequest.hasOwner(source), isTrue);
      expect(player.sequence, [source]);
      expect(player.shuffleIndices, [0]);
      await right.clear();
      expect(client.closed, isTrue);
      expect(SeekPreviewRequest.hasOwner(source), isFalse);
    },
  );

  Future<int> statusOf(Uri uri) async {
    final http = HttpClient();
    try {
      final response = await (await http.getUrl(uri)).close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      http.close(force: true);
    }
  }

  // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
  Future<(AudioPlayer, List<LockCachingAudioSource>)> loadedPair() async {
    final body = List<int>.filled(2048, 5);
    final (server, _) = await _serve(body, ranges: false);
    addTearDown(() => server.close(force: true));
    final sources = [
      for (final name in ['a', 'b'])
        // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
        LockCachingAudioSource(
          Uri.parse('http://127.0.0.1:${server.port}/$name'),
          cacheFile: File('${directory.path}/$name.mp3'),
        ),
    ];
    final player = AudioPlayer(
      handleAudioSessionActivation: false,
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(player.dispose);
    await player.setAudioSources(sources);
    return (player, sources);
  }

  test(
    'a removed source is served until the platform edit completes',
    () async {
      final (player, [a, b]) = await loadedPair();
      final removedUri = native.player.childUris[0];
      expect(await statusOf(removedUri), HttpStatus.ok);
      final gate = native.player.removeGate = Completer<void>();
      final removal = player.removeAudioSourceAt(0);
      await until(() => player.sequence.length == 1);
      expect(await statusOf(removedUri), HttpStatus.ok);
      gate.complete();
      await removal;
      native.player.removeGate = null;
    },
  );

  test('a removed source re-added to the playlist is served again', () async {
    final (player, [a, b]) = await loadedPair();
    await player.removeAudioSourceAt(0);
    await player.addAudioSource(a);
    expect(player.sequence, [b, a]);
    expect(await statusOf(native.player.childUris.last), HttpStatus.ok);
  });

  test(
    'removing the item loaded natively keeps the next item served',
    () async {
      final (player, [a, b]) = await loadedPair();
      final nextUri = native.player.childUris[1];
      await player.removeAudioSourceAt(0);
      expect(player.sequence, [b]);
      expect(await statusOf(nextUri), HttpStatus.ok);
    },
  );

  test('replaced idle platforms stop listening to the sequence', () async {
    final (player, [a, b]) = await loadedPair();
    for (var i = 0; i < 3; i++) {
      await player.setAudioSource(a, preload: false);
      await player.load();
    }
    expect(player.debugHasSequenceListeners, isFalse);
  });

  for (final end in ['disconnect', 'dispose', 'clear', 'replace']) {
    test(
      'adopted preview $end closes origin before response headers',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final accepted = Completer<Socket>();
        final serverSubscription = server.listen((request) async {
          accepted.complete(
            await request.response.detachSocket(writeHeaders: false),
          );
        });
        addTearDown(() async {
          await server.close(force: true);
          await serverSubscription.cancel();
        });
        final preview = SeekPreviewRequest(
          Uri.parse('http://127.0.0.1:${server.port}/offset'),
        );
        addTearDown(preview.cancel);
        final socket = await accepted.future;
        final closed = Completer<void>();
        final peer = socket.listen(
          (_) {},
          onDone: closed.complete,
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
        addTearDown(() async {
          socket.destroy();
          await peer.cancel();
        });
        final player = AudioPlayer(
          handleAudioSessionActivation: false,
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
        );
        addTearDown(player.dispose);
        await player.setAudioSource(
          preview.asAudioSource(positionOffset: const Duration(seconds: 90)),
          initialPosition: const Duration(seconds: 90),
        );
        expect(
          player.playbackEvent.updatePosition,
          const Duration(seconds: 90),
        );
        expect(native.player.loadedPosition, Duration.zero);
        if (end == 'disconnect') {
          final client = HttpClient();
          final request = await client.getUrl(native.player.proxyUri);
          request.close().ignore();
          await pumpEventQueue(times: 30);
          client.close(force: true);
        } else if (end == 'dispose') {
          await player.dispose();
        } else if (end == 'clear') {
          await player.clearAudioSources();
        } else {
          await player.setAudioSource(
            AudioSource.uri(Uri.parse('https://fixture.invalid/replaced')),
          );
        }
        await closed.future.timeout(const Duration(seconds: 2));
        expect(preview.usable, isFalse);
      },
    );
  }

  for (final framing in [
    'exact',
    'chunked',
    'short',
    'long',
    'mime',
    'injection',
  ]) {
    test('stream proxy preserves $framing framing and validation', () async {
      final source = _ResponseSource(
        // ignore: experimental_member_use, reason: exercises HTTP framing of source responses.
        StreamAudioResponse(
          sourceLength: null,
          contentLength: switch (framing) {
            'chunked' => null,
            'short' => 4,
            'long' => 2,
            _ => 3,
          },
          offset: null,
          stream: Stream.fromIterable([
            if (framing == 'long')
              [1, 2, 3]
            else ...[
              <int>[],
              [1, 2],
              [3],
            ],
          ]),
          contentType: switch (framing) {
            'mime' =>
              'null', // An origin without a Content-Type uses this value.
            'injection' => 'audio/mpeg\r\nx-injected: true',
            _ => 'audio/mpeg',
          },
        ),
      );
      final player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );
      addTearDown(player.dispose);
      await player.setAudioSource(source);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(native.player.proxyUri);
      Future<List<int>> read() async {
        final response = await request.close();
        expect(
          response.statusCode,
          framing == 'injection'
              ? HttpStatus.internalServerError
              : HttpStatus.ok,
        );
        expect(response.headers.value('x-injected'), isNull);
        return await response.expand((bytes) => bytes).toList();
      }

      if (framing == 'short' || framing == 'long') {
        await expectLater(read(), throwsA(isA<HttpException>()));
      } else {
        expect(await read(), framing == 'injection' ? isEmpty : [1, 2, 3]);
      }
    });
  }

  for (final end in [
    'client',
    'two probes',
    'cancel',
    'dispose',
    'clear',
    'replace',
  ]) {
    test('range lifetime follows $end', () async {
      final closed = <int>[];
      final (server, _) = await _serve(
        List<int>.filled(256 * 1024, 7),
        ranges: true,
        closedRanges: closed,
      );
      addTearDown(() => server.close(force: true));
      // ignore: experimental_member_use, reason: real proxy range lifecycle.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(p.join(directory.path, 'ranges.mp3')),
      );
      final player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );
      addTearDown(player.dispose);
      addTearDown(source.cancelDownload);
      await player.setAudioSource(source);
      Future<HttpClient> probe(int start) async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(native.player.proxyUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
        final response = await request.close();
        final received = Completer<void>();
        response.listen((_) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
        await received.future;
        return client;
      }

      final first = await probe(65536);
      final second = await probe(131072);
      if (end == 'cancel') {
        await source.cancelDownload();
      } else if (end == 'dispose') {
        await player.dispose();
      } else if (end == 'clear') {
        await player.clearAudioSources();
      } else if (end == 'replace') {
        await player.setAudioSource(
          AudioSource.uri(Uri.parse('https://fixture.invalid/replacement')),
        );
      } else {
        first.close(force: true);
      }
      await until(() => closed.contains(65536));
      if (['cancel', 'dispose', 'clear', 'replace'].contains(end)) {
        await until(() => closed.contains(131072));
      } else {
        expect(closed, isNot(contains(131072)));
        second.close(force: true);
        await until(() => closed.contains(131072));
      }
    });
  }

  test('subscribing after range cancellation emits no late errors', () async {
    final (server, _) = await _serve(
      List<int>.filled(256 * 1024, 7),
      ranges: true,
    );
    addTearDown(() => server.close(force: true));
    // ignore: experimental_member_use, reason: late subscription to a cancelled origin range.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: File(p.join(directory.path, 'late.mp3')),
    );
    addTearDown(source.cancelDownload);
    final response = await source.request(65536);
    await source.cancelDownload();
    await response.stream.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  for (final pendingHeaders in [true, false]) {
    test('client disconnect cancels a silent range with '
        '${pendingHeaders ? 'pending headers' : 'a stalled body'}', () async {
      final closed = <int>[];
      final (server, downloads) = await _serve(
        List<int>.filled(256 * 1024, 7),
        ranges: true,
        closedRanges: closed,
        rangeHeadersPending: pendingHeaders,
        rangeFailure: _OriginFailure.stall,
      );
      addTearDown(() => server.close(force: true));
      // ignore: experimental_member_use, reason: observes cancellation without origin writes.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(p.join(directory.path, 'silent.mp3')),
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
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=65536-');
      final response = request.close();
      response.ignore();
      await until(() => downloads.length == 2);
      if (!pendingHeaders) {
        final received = Completer<void>();
        (await response).listen((_) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
        await received.future.timeout(const Duration(seconds: 2));
      }
      client.close(force: true);
      await until(() => closed.contains(65536))
          .timeout(const Duration(milliseconds: 500));
      expect(source.hasActiveRangeFetch, isFalse);
    });
  }

  test('range subscription cancellation closes its origin', () async {
    final closed = <int>[];
    final (server, _) = await _serve(
      List<int>.filled(256 * 1024, 7),
      ranges: true,
      closedRanges: closed,
    );
    addTearDown(() => server.close(force: true));
    // ignore: experimental_member_use, reason: range subscription cancellation.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: File(p.join(directory.path, 'direct.mp3')),
    );
    addTearDown(source.cancelDownload);
    final response = await source.request(65536);
    await response.stream.take(1).drain<void>();
    await until(() => closed.contains(65536));
  });

  test(
    'failed range aborts its proxy response and a fresh probe succeeds',
    () async {
      final body = List<int>.generate(16 * 1024, (i) => i % 251);
      final (server, _) = await _serve(
        body,
        ranges: true,
        rangeFailure: _OriginFailure.disconnect,
        knownLength: true,
      );
      addTearDown(() => server.close(force: true));
      // ignore: experimental_member_use, reason: real origin range retry lifecycle.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(p.join(directory.path, 'retry.mp3')),
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
      final activity = <bool>[];
      final progress = source.downloadProgressStream.listen(
        (_) => activity.add(source.hasActiveRangeFetch),
      );
      addTearDown(progress.cancel);
      Future<HttpClientResponse> probe() async {
        final request = await client.getUrl(native.player.proxyUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=8192-');
        return await request.close();
      }

      final cut = await probe();
      await expectLater(cut.drain<void>(), throwsA(isA<HttpException>()));
      await until(() => !source.hasActiveRangeFetch);
      expect(activity, containsAllInOrder([true, false]));
      final retried = await probe();
      expect(
        await retried.expand((bytes) => bytes).toList(),
        body.sublist(8192),
      );
    },
  );

  test('paused main reads and inactivity deadline resume byte-exact', () async {
    final body = List<int>.generate(64 * 1024, (i) => i % 251);
    final (server, _) = await _serve(body, ranges: true);
    addTearDown(() => server.close(force: true));
    final file = File(p.join(directory.path, 'paused.mp3'));
    // ignore: experimental_member_use, reason: cache download pause contract.
    final source = LockCachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/song'),
      cacheFile: file,
      bodyProgressTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(source.cancelDownload);
    final response = await source.request();
    final drained = response.stream.drain<void>();
    source.pauseDownload();
    source.pauseDownload();
    final before = source.downloadedBytes;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(source.downloadedBytes, before);
    expect(File('${file.path}.part').existsSync(), isTrue);
    // New probes must dispatch even though the main no longer emits chunks.
    final range = await source
        .request(32768, 34816)
        .timeout(const Duration(seconds: 1));
    expect(
      await range.stream.expand((b) => b).toList(),
      body.sublist(32768, 34816),
    );
    source.resumeDownload();
    source.resumeDownload();
    await drained;
    await source.downloadProgressStream
        .firstWhere((p) => p == 1)
        .timeout(const Duration(seconds: 2));
    expect(await file.readAsBytes(), body);
  });

  test(
    'main cut leaves independent range byte-exact and reports range bytes',
    () async {
      final body = List<int>.generate(16 * 1024, (i) => i % 251);
      final (server, _) = await _serve(
        body,
        ranges: true,
        firstFailure: _OriginFailure.disconnect,
        knownLength: true,
      );
      addTearDown(() => server.close(force: true));
      // ignore: experimental_member_use, reason: independent origin range ownership.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(p.join(directory.path, 'cut.mp3')),
      );
      addTearDown(source.cancelDownload);
      final response = await source.request(8192);
      expect(source.hasActiveRangeFetch, isTrue);
      expect(
        await response.stream.expand((b) => b).toList(),
        body.sublist(8192),
      );
      expect(source.rangeFetchBytes, 8192);
      expect(source.hasActiveRangeFetch, isFalse);
    },
  );

  for (final knownLength in [true, false]) {
    test('body bytes emit progress before a whole percent '
        '(knownLength=$knownLength)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final finish = Completer<void>();
      addTearDown(() {
        if (!finish.isCompleted) finish.complete();
      });
      server.listen((request) async {
        final response = request.response..bufferOutput = false;
        if (knownLength) response.contentLength = 20000;
        response.add(List<int>.filled(128, 7));
        await response.flush();
        await finish.future;
        response.add(List<int>.filled(20000 - 128, 7));
        await response.close();
      });
      final cacheFile = File(p.join(directory.path, 'byte-progress.mp3'));
      // ignore: experimental_member_use, reason: tests player-side lock-cache byte events.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: cacheFile,
      );
      addTearDown(source.cancelDownload);
      final received = Completer<int>();
      final published = Completer<void>();
      final subscription = source.downloadProgressStream.listen((progress) {
        if (source.downloadedBytes == 128 && !received.isCompleted) {
          expect(progress, 0);
          received.complete(source.downloadedBytes);
        }
        if (progress == 1 && !published.isCompleted) published.complete();
      });
      addTearDown(subscription.cancel);
      final response = await source.request();
      final drained = response.stream.drain<void>();
      expect(await received.future.timeout(const Duration(seconds: 2)), 128);
      expect(cacheFile.existsSync(), isFalse);
      finish.complete();
      await drained;
      await published.future.timeout(const Duration(seconds: 2));
      expect(source.downloadedBytes, 20000);
    });
  }

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
    for (final failure in _OriginFailure.values) {
      test(
        'proxy aborts an origin ${failure.name} and retries (known length: $knownLength)',
        () async {
          final prefix = List<int>.filled(1024, 7);
          final body = [...prefix, 8, 9, 10];
          final (server, downloads) = await _serve(
            body,
            ranges: false,
            firstFailure: failure,
            knownLength: knownLength,
          );
          addTearDown(() => server.close(force: true));
          final cacheFile = File(p.join(directory.path, 'interrupted.mp3'));
          // ignore: experimental_member_use, reason: exercises origin failures through the real proxy.
          final source = LockCachingAudioSource(
            Uri.parse('http://127.0.0.1:${server.port}/song'),
            cacheFile: cacheFile,
            bodyProgressTimeout: failure == _OriginFailure.stall
                ? const Duration(milliseconds: 300)
                : const Duration(seconds: 10),
          );
          final progress = <double>[];
          final progressSubscription = source.downloadProgressStream.listen(
            progress.add,
          );
          addTearDown(progressSubscription.cancel);
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
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          expect(response.statusCode, HttpStatus.ok);
          expect(response.contentLength, knownLength ? body.length : -1);
          final received = <int>[];
          final ended = Completer<void>();
          Object? responseError;
          final subscription = response.listen(
            received.addAll,
            onError: (Object error) => responseError = error,
            onDone: ended.complete,
          );
          addTearDown(subscription.cancel);

          await ended.future.timeout(const Duration(seconds: 2));

          expect(received, prefix);
          expect(responseError, isA<HttpException>());
          expect(cacheFile.existsSync(), isFalse);
          expect(File('${cacheFile.path}.part').existsSync(), isFalse);
          expect(progress, isNot(contains(1.0)));
          final retry = await client.getUrl(native.player.proxyUri);
          final retried = await retry.close();
          expect(
            await retried
                .expand((bytes) => bytes)
                .toList()
                .timeout(const Duration(seconds: 2)),
            body,
          );
          await source.downloadProgressStream
              .firstWhere((value) => value == 1)
              .timeout(const Duration(seconds: 2));
          expect(downloads, hasLength(2));
          expect(await cacheFile.readAsBytes(), body);
        },
      );
    }
  }

  for (final knownLength in [false, true]) {
    test(
      'header proxy aborts an origin disconnect (known length: $knownLength)',
      () async {
        final prefix = List<int>.filled(1024, 7);
        final body = [...prefix, 8, 9, 10];
        final (server, downloads) = await _serve(
          body,
          ranges: false,
          firstFailure: _OriginFailure.disconnect,
          knownLength: knownLength,
        );
        addTearDown(() => server.close(force: true));
        final player = AudioPlayer(
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
        );
        addTearDown(player.dispose);
        await player.setAudioSource(
          AudioSource.uri(
            Uri.parse('http://127.0.0.1:${server.port}/song'),
            headers: const {'X-Fixture': 'proxy'},
          ),
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(native.player.proxyUri);
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        expect(response.contentLength, knownLength ? body.length : -1);
        final received = <int>[];
        final ended = Completer<void>();
        Object? responseError;
        final subscription = response.listen(
          received.addAll,
          onError: (Object error) => responseError = error,
          onDone: ended.complete,
        );
        addTearDown(subscription.cancel);

        await ended.future.timeout(const Duration(seconds: 2));

        expect(received, prefix);
        expect(responseError, isA<HttpException>());
        expect(downloads, hasLength(1));
        final retry = await client.getUrl(native.player.proxyUri);
        final retried = await retry.close();
        expect(await retried.expand((bytes) => bytes).toList(), body);
        expect(downloads, hasLength(2));
      },
    );
  }

  test('header proxy keeps a live chunked body open until clean EOF', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final finish = Completer<void>();
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
    });
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.add([1, 2, 3]);
      await request.response.flush();
      await finish.future;
      request.response.add([4, 5, 6]);
      await request.response.close();
    });
    final player = AudioPlayer(
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
      userAgent: 'Navis fixture',
    );
    addTearDown(player.dispose);
    await player.setAudioSource(
      AudioSource.uri(
        Uri.parse('http://127.0.0.1:${server.port}/live'),
        options: const ProgressiveAudioSourceOptions(
          androidUseDefaultLoadErrorHandling: true,
        ),
      ),
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(native.player.proxyUri);
    final response = await request.close().timeout(const Duration(seconds: 2));
    expect(response.contentLength, -1);
    final firstBytes = Completer<void>();
    final received = <int>[];
    final ended = Completer<void>();
    final subscription = response.listen((bytes) {
      received.addAll(bytes);
      if (!firstBytes.isCompleted) firstBytes.complete();
    }, onDone: ended.complete);
    addTearDown(subscription.cancel);

    await firstBytes.future.timeout(const Duration(seconds: 2));
    expect(received, [1, 2, 3]);
    expect(ended.isCompleted, isFalse);
    finish.complete();
    await ended.future.timeout(const Duration(seconds: 2));
    expect(received, [1, 2, 3, 4, 5, 6]);
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
        // The stream closes before the cache rename; finish it before teardown.
        await source.downloadProgressStream
            .firstWhere((progress) => progress == 1)
            .timeout(const Duration(seconds: 2));
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

  test(
    'prefetch downloads without a response and a request joins it',
    () async {
      final body = List<int>.filled(256 * 1024, 3);
      final (server, downloads) = await _serve(body, ranges: false);
      addTearDown(() => server.close(force: true));
      final cacheFile = File('${directory.path}/prefetch.mp3');
      // ignore: experimental_member_use, reason: tests the Navis additions to the vendored source.
      final source = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: cacheFile,
      );
      await source.prefetch();
      final joined = await source.request();
      final bytes = await joined.stream.fold<int>(
        0,
        (n, chunk) => n + chunk.length,
      );
      expect(bytes, body.length);
      expect(downloads, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cacheFile.existsSync(), isTrue);
      expect(source.isDownloading, isFalse);
    },
  );
}
