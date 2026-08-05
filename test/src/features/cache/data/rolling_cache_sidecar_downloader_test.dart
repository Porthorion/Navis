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
}
