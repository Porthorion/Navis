import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';

/// Points path_provider's temporary directory at a fresh folder.
Future<Directory> _tempCacheDir() async {
  final temp = await Directory.systemTemp.createTemp('navis-art-cache-');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => temp.path);
  addTearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });
  return temp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding replaces HttpClient with a mock that answers 400; this
  // test talks to a real loopback server.
  setUpAll(() => HttpOverrides.global = null);

  test('a cover file appears only once it is complete', () async {
    final temp = await _tempCacheDir();
    final firstChunkSent = Completer<void>();
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType('image', 'jpeg')
        ..contentLength = 6
        ..add(<int>[1, 2, 3]);
      await request.response.flush();
      firstChunkSent.complete();
      await release.future;
      request.response.add(<int>[4, 5, 6]);
      await request.response.close();
    });

    final cache = PlaybackArtCache();
    expect(cache.cachedPath('album-1'), isNull);
    final result = cache.getOrFetch(
      'album-1',
      Uri.parse('http://127.0.0.1:${server.port}/art'),
    );
    await firstChunkSent.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Android's artwork provider serves this file to other apps by name, so
    // a half-written cover must never sit there.
    final cover = File('${temp.path}/navis_art_album-1.jpg');
    expect(cover.existsSync(), isFalse);
    expect(cache.cachedPath('album-1'), isNull);

    release.complete();
    expect(await result, cover.path);
    expect(await cover.length(), 6);
    expect(cache.cachedPath('album-1'), cover.path);
    expect(temp.listSync().map((entry) => entry.path), <String>[cover.path]);
  });

  test('an interrupted download leaves no cover behind', () async {
    final temp = await _tempCacheDir();
    // A raw socket, so the connection can drop mid-body.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket
        ..write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: image/jpeg\r\n'
          'Content-Length: 1000\r\n\r\n',
        )
        ..add(<int>[1, 2, 3]);
      unawaited(socket.flush().then((_) => socket.destroy()));
    });

    final cache = PlaybackArtCache();
    final result = await cache.getOrFetch(
      'album-2',
      Uri.parse('http://127.0.0.1:${server.port}/art'),
    );

    expect(result, isNull);
    expect(cache.cachedPath('album-2'), isNull);
    expect(temp.listSync(), isEmpty);
  });

  test('a stalled download is abandoned and can be retried', () async {
    final temp = await _tempCacheDir();
    var requests = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final stalled = <Socket>[];
    addTearDown(() {
      for (final socket in stalled) {
        socket.destroy();
      }
    });
    server.listen((socket) {
      requests++;
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: image/jpeg\r\n'
        'Content-Length: 1000\r\n\r\n',
      );
      // Headers, then nothing more: the body never arrives.
      stalled.add(socket);
    });

    final cache = PlaybackArtCache(
      bodyIdleTimeout: const Duration(milliseconds: 200),
    );
    final uri = Uri.parse('http://127.0.0.1:${server.port}/art');

    expect(await cache.getOrFetch('album-3', uri), isNull);
    expect(temp.listSync(), isEmpty);
    // The cover is no longer pending, so the next request tries again.
    expect(await cache.getOrFetch('album-3', uri), isNull);
    expect(requests, 2);
  });

  test('consecutive art fetches reuse one keep-alive connection', () async {
    final temp = await Directory.systemTemp.createTemp('navis-art-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final clientPorts = <int>{};
    server.listen((request) {
      clientPorts.add(request.connectionInfo!.remotePort);
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(<int>[137, 80, 78, 71, 1, 2, 3])
        ..close();
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    final cache = PlaybackArtCache();
    final base = 'http://127.0.0.1:${server.port}/art';
    final first = await cache.getOrFetch('album-1', Uri.parse('$base/1'));
    final second = await cache.getOrFetch('album-2', Uri.parse('$base/2'));

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(await File(second!).length(), 7);
    expect(clientPorts, hasLength(1));
  });

  test('a downloaded cover is used without any network fetch', () async {
    final temp = await Directory.systemTemp.createTemp('navis-art-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await temp.delete(recursive: true);
    });
    final stored = File('${temp.path}/stored-cover.jpg')
      ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 1, 2]);
    final cache = PlaybackArtCache(
      readPermanentArtwork: (id) async => id == 'al-1' ? stored : null,
    );

    // Port 9 is closed: a network fetch would fail.
    final path = await cache.getOrFetch(
      'al-1',
      Uri.parse('http://127.0.0.1:9/art'),
    );

    expect(path, isNotNull);
    expect(path, endsWith('navis_art_al-1.jpg'));
    expect(File(path!).readAsBytesSync(), stored.readAsBytesSync());
    // Copied through a partial file that is renamed into place.
    expect(File('$path.part').existsSync(), isFalse);
    expect(cache.cachedPath('al-1'), path);
  });

  test('a durable cover that cannot be copied leaves nothing behind', () async {
    final temp = await _tempCacheDir();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    // The store names a file that is gone by the time it is copied.
    final missing = File('${temp.path}/stores/missing-cover.jpg');
    final cache = PlaybackArtCache(readPermanentArtwork: (_) async => missing);

    final path = await cache.getOrFetch(
      'al-2',
      Uri.parse('http://127.0.0.1:${server.port}/art'),
    );

    expect(path, isNull);
    expect(cache.cachedPath('al-2'), isNull);
    expect(temp.listSync(), isEmpty);
  });
}
