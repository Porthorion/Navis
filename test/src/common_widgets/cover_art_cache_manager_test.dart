import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';

void main() {
  group('coverArtImageCacheKey', () {
    test('uses stable cover-art ID and size instead of URL salt', () {
      expect(coverArtImageCacheKey(' cover-1 ', 600), 'cover-1:600');
      expect(coverArtImageCacheKey('cover-1', null), 'cover-1:0');
    });
  });

  group('CoverArtHttpFileService', () {
    test('times out stalled response headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = CoverArtHttpFileService(
        connectionTimeout: const Duration(milliseconds: 50),
        responseTimeout: const Duration(milliseconds: 50),
        bodyReadTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) {
        // Intentionally leave the response open without headers.
      });

      final url = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/rest/getCoverArt.view',
        queryParameters: const <String, String>{
          'id': 'cover-1',
          'size': '600',
          't': 'redacted',
        },
      ).toString();

      await expectLater(
        service.get(url),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('times out stalled response bodies', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = CoverArtHttpFileService(
        connectionTimeout: const Duration(milliseconds: 50),
        responseTimeout: const Duration(milliseconds: 50),
        bodyReadTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(<int>[0xff, 0xd8]);
        await request.response.flush();
        // Intentionally leave the body open so the client must time out.
      });

      final url = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/rest/getCoverArt.view',
        queryParameters: const <String, String>{
          'id': 'cover-2',
          'size': '600',
          't': 'redacted',
        },
      ).toString();

      final response = await service.get(url);

      expect(response.statusCode, HttpStatus.ok);
      await expectLater(
        response.content.drain<void>(),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
