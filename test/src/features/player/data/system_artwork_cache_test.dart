import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

/// The art AudioService downloads for the OS media session goes through this
/// file service, so a refused URL, a redirect to one, and a download queued
/// before the policy changed must all be stopped before any request is sent.
void main() {
  late HttpServer own;
  late HttpServer external;
  var ownRequests = 0;
  var externalRequests = 0;
  var redirects = false;
  late IntegrationCallRecorder recorder;

  setUp(() async {
    recorder = IntegrationCallRecorder(logCalls: false);
    ownRequests = 0;
    externalRequests = 0;
    redirects = false;
    external = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    external.listen((request) {
      externalRequests++;
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
    });
    own = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    own.listen((request) {
      ownRequests++;
      if (redirects) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:${external.port}/cover.jpg',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      unawaited(request.response.close());
    });
    addTearDown(() async {
      await own.close(force: true);
      await external.close(force: true);
    });
  });

  // The user's server is 127.0.0.1; "localhost" is another host.
  bool allow(IntegrationPolicy policy, Uri uri) =>
      integrationAllowsRadioArtworkUri(policy, uri, serverHost: '127.0.0.1');

  CoverArtHttpFileService build(
    IntegrationPolicy Function() policy, {
    CoverArtLoadCoordinator? coordinator,
  }) {
    final service = createSystemArtworkFileService(
      recorder: recorder,
      isServerUri: (uri) => uri.host == '127.0.0.1',
      allowUri: (uri) => allow(policy(), uri),
      loadCoordinator: coordinator,
    );
    addTearDown(service.close);
    return service;
  }

  test(
    'system artwork signs only the active cover endpoint after queue admission',
    () async {
      final received = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        received.add(request.uri);
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add([0xff, 0xd8, 0xff, 1]);
        unawaited(request.response.close());
      });
      SubsonicApiClient client(String username) => SubsonicApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authConfig: SubsonicAuthConfig(
          username: username,
          password: 'fixture-password',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
      final oldApi = client('old-fixture');
      final newApi = client('new-fixture');
      addTearDown(() => oldApi.close(force: true));
      addTearDown(() => newApi.close(force: true));
      var api = oldApi;
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final blocker = await coordinator.acquire('blocker');
      final service = createSystemArtworkFileService(
        allowUri: (_) => true,
        loadCoordinator: coordinator,
        authenticateUri: (uri) => api.authenticateCoverArtUri(uri),
      );
      addTearDown(service.close);
      final pending = service.get(
        'http://127.0.0.1:${server.port}/rest/getCoverArt.view?id=fixture',
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.queuedCount, 1);
      api = newApi;
      blocker.release();
      await (await pending).content.drain<void>();
      expect(received.single.queryParameters['u'], 'new-fixture');
      expect(received.single.queryParameters['t'], isNotEmpty);
      expect(received.single.queryParameters['s'], isNotEmpty);

      for (final host in ['127.0.0.1', 'localhost']) {
        final response = await service.get(
          'http://$host:${server.port}/external.jpg',
        );
        await response.content.drain<void>();
        expect(received.last.queryParameters, isEmpty);
      }
    },
  );

  test('an allowed URL redirecting to a refused host is stopped', () async {
    redirects = true;
    // External hosts are refused while radio metadata is off.
    final service = build(
      () => const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'}),
    );
    await expectLater(
      service.get('http://127.0.0.1:${own.port}/cover.jpg'),
      throwsA(isA<CoverArtBlockedException>()),
    );
    expect(ownRequests, 1);
    expect(externalRequests, 0);
    expect(
      recorder.recentCalls().single.outcome,
      IntegrationCallOutcome.blocked,
    );
  });

  test('a redirect to a host the policy allows is followed', () async {
    redirects = true;
    final service = build(() => const IntegrationPolicy());
    await expectLater(
      service.get('http://127.0.0.1:${own.port}/cover.jpg'),
      throwsA(isNot(isA<CoverArtBlockedException>())),
    );
    expect(externalRequests, 1);
    expect(recorder.recentCalls().single.outcome, IntegrationCallOutcome.error);
    expect(recorder.recentCalls().single.statusCode, HttpStatus.notFound);
  });

  test('a refused external URL is never requested', () async {
    final service = build(() => const IntegrationPolicy(masterEnabled: false));
    await expectLater(
      service.get('http://localhost:${external.port}/cover.jpg'),
      throwsA(isA<CoverArtBlockedException>()),
    );
    expect(externalRequests, 0);
  });

  test('the own server loads with Online services off', () async {
    final service = build(() => const IntegrationPolicy(masterEnabled: false));
    await expectLater(
      service.get('http://127.0.0.1:${own.port}/cover.jpg'),
      throwsA(isNot(isA<CoverArtBlockedException>())),
    );
    expect(ownRequests, 1);
    expect(recorder.recentCalls(), isEmpty);
  });

  test('a queued download is refused once the policy revokes it', () async {
    var policy = const IntegrationPolicy();
    final coordinator = CoverArtLoadCoordinator(
      maxActiveDownloads: 1,
      criticalReserve: 0,
    );
    final blocker = await coordinator.acquire('blocker');
    final service = build(() => policy, coordinator: coordinator);
    final pending = expectLater(
      service.get('http://localhost:${external.port}/cover.jpg'),
      throwsA(isA<CoverArtBlockedException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.queuedCount, 1);
    policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
    blocker.release();
    await pending;
    expect(externalRequests, 0);
    expect(coordinator.activeCount, 0);
  });
}
