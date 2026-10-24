import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/player/data/seek_preview_request.dart';

class _Client extends Fake implements HttpClient {
  final headersReady = Completer<HttpClientResponse>();
  final body = StreamController<List<int>>();
  bool closed = false;
  int gets = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    gets++;
    return _Request(headersReady.future);
  }
  @override
  void close({bool force = false}) {
    closed = force;
  }
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final Future<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response;
}

class _Response extends Fake implements HttpClientResponse {
  _Response(this.body);
  final Stream<List<int>> body;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => -1;
  @override
  HttpHeaders get headers => _Headers();
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData, {
    Function? onError, void Function()? onDone, bool? cancelOnError,
  }) => body.listen(onData, onError: onError, onDone: onDone,
    cancelOnError: cancelOnError);
}

class _Headers extends Fake implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('audio', 'ogg');
}

void main() {
  Future<void> flush() => pumpEventQueue(times: 30);
  SeekPreviewRequest open(_Client client) => SeekPreviewRequest(
    Uri.parse('http://fixture.invalid/stream'), client: client,
  );

  test('cancel closes synchronously while headers are still opening', () async {
    final client = _Client();
    final preview = open(client);
    await flush();
    preview.cancel();
    expect(client.closed, isTrue);
    client.headersReady.complete(_Response(client.body.stream));
    await flush();
    expect(client.body.hasListener, isFalse);
    await client.body.close();
  });

  test('512 KiB cap pauses; adoption returns buffered and remaining bytes', () async {
    final client = _Client();
    final preview = open(client);
    client.headersReady.complete(_Response(client.body.stream));
    final bytes = Uint8List.fromList(List.generate(600000, (i) => i % 251));
    client.body.add(bytes);
    await flush();
    expect(preview.bufferedBytes, 512 * 1024);
    expect(client.body.isPaused, isTrue);
    final source = preview.asAudioSource(positionOffset: const Duration(seconds: 90));
    expect(source.positionOffset, const Duration(seconds: 90));
    final response = await source.request();
    expect(response.rangeRequestsSupported, isFalse);
    final result = response.stream.expand((b) => b).toList();
    await client.body.close();
    expect(await result, bytes);
    expect(client.gets, 1);
    expect(client.closed, isTrue);
  });

  test('adopted body preserves prefix and propagates mid-body error', () async {
    final client = _Client();
    final preview = open(client);
    client.headersReady.complete(_Response(client.body.stream));
    client.body.add([1, 2, 3]);
    await flush();
    final response = await preview.asAudioSource().request();
    final received = <int>[];
    final failed = Completer<Object>();
    final subscription = response.stream.listen(received.addAll,
      onError: (Object error) => failed.complete(error));
    client.body.add([4, 5]);
    client.body.addError(const HttpException('fixture cut'));
    expect(await failed.future, isA<HttpException>());
    expect(received, [1, 2, 3, 4, 5]);
    await subscription.cancel();
    await client.body.close();
    expect(client.closed, isTrue);
  });

  test('50 alternating owners close before the next opens, final adopts', () async {
    final clients = <_Client>[];
    SeekPreviewRequest? owner;
    for (var i = 0; i < 50; i++) {
      owner?.cancel();
      expect(clients.every((c) => c.closed), isTrue);
      final client = _Client();
      clients.add(client);
      owner = open(client);
      // Includes replacement before the old headers have arrived.
      if (i != 0) clients[i - 1].headersReady.complete(
        _Response(clients[i - 1].body.stream));
      await flush();
      expect(clients.where((c) => !c.closed).length, 1);
    }
    final last = clients.last;
    last.headersReady.complete(_Response(last.body.stream));
    last.body.add([49]);
    await flush();
    final response = await owner!.asAudioSource().request();
    final bytes = response.stream.expand((b) => b).toList();
    await last.body.close();
    expect(await bytes, [49]);
    for (final client in clients) {
      expect(client.closed, isTrue);
      expect(client.body.hasListener, isFalse);
      if (!client.body.isClosed) await client.body.close();
    }
  });
}
