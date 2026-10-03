import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding replaces HttpClient with a mock that answers 400; this
  // test talks to a real loopback server.
  setUpAll(() => HttpOverrides.global = null);

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
  });
}
