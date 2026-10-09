import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_recovery.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

void main() {
  late HttpServer server;
  late CoverArtHttpFileService service;
  late CoverArtLoadCoordinator coordinator;
  late IntegrationCallRecorder recorder;
  var meteredBytes = 0;
  late List<String> requestedPaths;
  late Completer<void> endResponse;

  setUp(() async {
    meteredBytes = 0;
    requestedPaths = [];
    endResponse = Completer<void>();
    coordinator = CoverArtLoadCoordinator(
      maxActiveDownloads: 1,
      criticalReserve: 0,
    );
    recorder = IntegrationCallRecorder(logCalls: false);
    service = CoverArtHttpFileService(
      loadCoordinator: coordinator,
      recorder: recorder,
      isServerUri: (_) => false,
      reportNetworkUsage: ({required category, required bytes, operation}) {
        expect(category, NetworkUsageCategory.coverArt);
        meteredBytes += bytes;
      },
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      final response = request.response;
      if (request.uri.path == '/partial') {
        response.statusCode = HttpStatus.partialContent;
      }
      if (request.uri.path == '/redirect') {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/valid');
      }
      response.headers.contentType = request.uri.path == '/non-image'
          ? ContentType.json
          : ContentType('image', 'jpeg');
      if (request.uri.path == '/valid') {
        response.add([0xff, 0xd8, 0xff, 1]);
        await response.close();
        return;
      }
      final declared = request.uri.queryParameters['declared'] == 'true';
      final oversized = request.uri.path != '/exact';
      final length = kMaxArtworkResponseBytes + (oversized ? 1 : 0);
      if (declared) response.contentLength = length;
      try {
        if (declared && oversized) {
          // Flush only headers and a tiny prefix. Rejection must not wait for
          // the declared body, which this fixture deliberately never sends.
          response.add([0xff, 0xd8, 0xff, 1]);
          await response.flush();
          await endResponse.future;
          await response.close();
          return;
        }
        final block = Uint8List(64 * 1024)
          ..[0] = 0xff
          ..[1] = 0xd8;
        for (
          var sent = 0;
          sent < kMaxArtworkResponseBytes;
          sent += block.length
        ) {
          response.add(block);
          await response.flush();
        }
        if (oversized) {
          response.add(block);
          await response.flush();
          // The size rejection must complete before this fixture sends EOF.
          await endResponse.future;
          await response.close();
        } else {
          await response.close();
        }
      } on SocketException {
        // Expected when the client aborts an oversized response.
      } on HttpException {
        // Expected when the client aborts an oversized response.
      }
    });
  });

  tearDown(() async {
    if (!endResponse.isCompleted) endResponse.complete();
    service.close(force: true);
    await server.close(force: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  test('rejects oversized Content-Length before consuming any body', () async {
    await expectLater(
      service.get(url('/oversized?declared=true')),
      throwsA(isA<CoverArtInvalidResponseException>()),
    );
    expect(meteredBytes, 0);
    expect(coordinator.activeCount, 0);
    final call = recorder.recentCalls().single;
    expect(call.outcome, IntegrationCallOutcome.error);
    expect(call.statusCode, HttpStatus.ok);
    endResponse.complete();
    final retry = await service.get(url('/valid'));
    await retry.content.drain<void>();
    expect(recorder.recentCalls().last.outcome, IntegrationCallOutcome.ok);
  });

  test(
    'aborts a chunked body on cumulative overflow and releases its slot',
    () async {
      final response = await service.get(url('/oversized'));
      expect(response.contentLength, isNull);
      var yieldedBytes = 0;
      await expectLater(
        response.content
            .forEach((chunk) => yieldedBytes += chunk.length)
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
      expect(yieldedBytes, lessThanOrEqualTo(kMaxArtworkResponseBytes));
      expect(meteredBytes, greaterThan(kMaxArtworkResponseBytes));
      expect(coordinator.activeCount, 0);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.error,
      );
      expect(
        classifyCoverArtFailure(
          const CoverArtInvalidResponseException('oversized'),
        ),
        CoverArtFailureCategory.invalidPayload,
      );
      endResponse.complete();
      final retry = await service.get(url('/valid'));
      await retry.content.drain<void>();
      expect(coordinator.activeCount, 0);
      expect(recorder.recentCalls().last.outcome, IntegrationCallOutcome.ok);
    },
  );

  test(
    'an oversized unused response records an error rather than success',
    () async {
      final response = await service.get(url('/partial'));
      expect(await response.content.toList(), isEmpty);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (recorder.recentCalls().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.error,
      );
      expect(coordinator.activeCount, 0);
      endResponse.complete();
    },
  );

  for (final path in ['/redirect', '/non-image']) {
    test('caps oversized discarded bodies at $path', () async {
      await expectLater(
        service.get(url(path)).timeout(const Duration(seconds: 2)),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
      expect(requestedPaths, [path]);
      expect(coordinator.activeCount, 0);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.error,
      );
      endResponse.complete();
    });
  }

  for (final declared in [false, true]) {
    test(
      'accepts exactly the byte limit (Content-Length: $declared)',
      () async {
        final response = await service.get(url('/exact?declared=$declared'));
        var bytes = 0;
        await response.content.forEach((chunk) => bytes += chunk.length);
        expect(bytes, kMaxArtworkResponseBytes);
        expect(meteredBytes, kMaxArtworkResponseBytes);
        expect(coordinator.activeCount, 0);
        expect(
          recorder.recentCalls().single.outcome,
          IntegrationCallOutcome.ok,
        );
      },
    );
  }
}
