import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
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

  setUp(() async {
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
      allowUri: (uri) => allow(policy(), uri),
      loadCoordinator: coordinator,
    );
    addTearDown(service.close);
    return service;
  }

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
  });

  test('a redirect to a host the policy allows is followed', () async {
    redirects = true;
    final service = build(() => const IntegrationPolicy());
    await expectLater(
      service.get('http://127.0.0.1:${own.port}/cover.jpg'),
      throwsA(isNot(isA<CoverArtBlockedException>())),
    );
    expect(externalRequests, 1);
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
    expect(IntegrationFeature.radioNowPlaying.key, 'radio.nowPlaying');
  });
}
