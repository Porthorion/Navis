import 'dart:async';
import 'dart:io';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// Serves [fast] songs at once and leaves every other song's response open,
/// counting the requests per song.
class _SongHttpClient extends Fake implements HttpClient {
  new(this.fast);
  final Set<String> fast;
  final requests = <String, int>{};
  final hung = <Completer<HttpClientResponse>>[];
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final id = uri.queryParameters['id']!;
    requests[id] = (requests[id] ?? 0) + 1;
    if (fast.contains(id)) {
      return _Request(Future.value(_Response()));
    }
    final open = Completer<HttpClientResponse>();
    hung.add(open);
    return _Request(open.future);
  }

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  new(this.response);
  final Future<HttpClientResponse> response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  Future<HttpClientResponse> close() => response;
}

class _Response extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => 4;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable([
    <int>[1, 2, 3, 4],
  ]).listen(onData, onError: onError, onDone: onDone);
}

class _Headers extends Fake implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('audio', 'ogg');
  @override
  String? value(String name) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  UriAudioSource current(ControllableAudioPlayer player) =>
      player.sequence[player.index!] as UriAudioSource;

  Future<(NavisAudioHandler, ControllableAudioPlayer, _SongHttpClient)>
  setUp647() async {
    final directory = await Directory.systemTemp.createTemp('navis-refill-');
    final client = _SongHttpClient({'song-1'});
    final (handler, player, db) = await createHandler(
      directory,
      3,
      sidecarStreams: true,
      streamingQuality: const StreamingQuality(
        label: 'opus',
        maxBitRate: 128,
        format: 'opus',
      ),
      supportsTranscodeOffset: true,
      sidecarDownloader: RollingCacheSidecarDownloader(
        httpClientFactory: () => client,
      ),
    );
    addTearDown(() async {
      await handler.disposeHandler();
      await db.close();
      await directory.delete(recursive: true);
    });
    player.simulateProgress = true;
    await handler.replaceQueue(
      ['song-0', 'song-1', 'song-2'],
      startIndex: 1,
      expandMatchFlows: false,
    );
    await settleQueue(handler);
    await handler.play();
    // song-1 completes, then the chain starts song-2's warm.
    await until(() => client.requests['song-2'] == 1, reason: 'warm');
    return (handler, player, client);
  }

  Future<void> reloadFromFile(NavisAudioHandler handler) async {
    await handler.seek(const Duration(seconds: 90));
    await until(() => !handler.snapshot.isLoading);
  }

  test('a file reload keeps the next song warm when revisited', () async {
    final (handler, player, client) = await setUp647();
    await reloadFromFile(handler);
    expect(current(player).uri.scheme, 'file');
    await handler.skipToNext();
    await settleQueue(handler);
    await handler.skipToPrevious();
    await settleQueue(handler);

    expect(current(player).uri.scheme, 'file');
    expect(client.requests, {'song-1': 1, 'song-2': 1});
  });

  test('a file lost mid-play is refilled and the warm re-armed', () async {
    final (handler, player, client) = await setUp647();
    await reloadFromFile(handler);
    final path = Uri.parse(current(player).uri.toString()).toFilePath();
    File(path).deleteSync();
    await handler.toggleLike();
    await pumpEventQueue(times: 50);

    expect(client.requests['song-2'], 2);
  });

  // After the next warm failed, its 30 s backoff holds the retry unless a
  // refill of the current song clears it.
  for (final (name, bytes, retried) in [
    ('a complete file leaves the failure backoff alone', [1, 2, 3, 4], 1),
    ('an empty file is absent: the refill clears the backoff', <int>[], 2),
  ]) {
    test(name, () async {
      final (handler, player, client) = await setUp647();
      await reloadFromFile(handler);
      final path = Uri.parse(current(player).uri.toString()).toFilePath();
      for (final open in client.hung) {
        open.completeError(const HttpException('cut'));
      }
      await pumpEventQueue(times: 50);
      File(path).writeAsBytesSync(bytes);
      await handler.toggleLike();
      await pumpEventQueue(times: 50);

      expect(client.requests['song-2'], retried);
    });
  }
}
