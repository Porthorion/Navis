import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/home/presentation/home_onboarding_warmup.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../helpers/stub_library_sync_engine.dart';
import '../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'download control is clone-only; download status is observable',
    () async {
      final primaryService = _downloadServiceStub();
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
        downloadService: primaryService,
      );
      for (final (path, body) in <(String, Map<String, Object?>)>[
        ('/v1/downloads/settings', {'paused': true}),
        ('/v1/downloads/cancel', {'queueId': 1}),
        (
          '/v1/downloads/enqueue',
          {
            'songIds': ['s1'],
          },
        ),
      ]) {
        final forbidden = await primary.post(path, body);
        expect(forbidden.statusCode, HttpStatus.forbidden, reason: path);
      }
      final observed = await primary.get('/v1/downloads/status');
      expect(observed.statusCode, HttpStatus.ok);
      expect(observed.body['qualityPreference'], containsPair('mode', 'ask'));
      verifyNever(() => primaryService.setPaused(paused: any(named: 'paused')));
      await primary.close();

      final service = _downloadServiceStub();
      final clone = await _startFixture(
        SyncDiagnosticsMode.clone,
        downloadService: service,
      );
      addTearDown(clone.close);
      for (final body in <Map<String, Object?>>[
        {'maxConcurrent': 'many'},
        {'paused': 'yes'},
        {'qualityMode': 'lossy'},
        {'qualityMode': 'transcode', 'bitRate': 100},
        {'format': 'wma'},
        {'prompted': 1},
      ]) {
        final invalid = await clone.post('/v1/downloads/settings', body);
        expect(invalid.statusCode, HttpStatus.badRequest, reason: '$body');
      }
      final invalidCancel = await clone.post('/v1/downloads/cancel', {
        'queueId': '1',
      });
      expect(invalidCancel.statusCode, HttpStatus.badRequest);

      final saved = await clone.post('/v1/downloads/settings', {
        'maxConcurrent': 3,
        'paused': true,
        'qualityMode': 'transcode',
        'bitRate': 192,
        'format': 'opus',
        'prompted': true,
      });
      expect(saved.statusCode, HttpStatus.ok);
      verify(() => service.setMaxConcurrentDownloads(3)).called(1);
      verify(() => service.setPaused(paused: true)).called(1);
      expect(saved.body['qualityPreference'], <String, Object?>{
        'mode': 'transcode',
        'bitRate': 192,
        'format': 'opus',
        'prompted': true,
      });
      for (final key in const [
        'paused',
        'maxConcurrent',
        'effectiveConcurrency',
        'activeQueueIds',
        'peakActive',
        'queue',
        'queueItems',
        'permanentDownloads',
        'permanentArtworkCount',
      ]) {
        expect(saved.body, contains(key));
      }

      final enqueued = await clone.post('/v1/downloads/enqueue', {
        'songIds': ['s1'],
        'usePreference': true,
      });
      expect(enqueued.statusCode, HttpStatus.accepted);
      verify(() => service.enqueueSong('s1', quality: '192', format: 'opus'))
          .called(1);

      final database = clone.container.read(navisDatabaseProvider);
      await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('failed'),
          status: DownloadStatus.failed,
          addedAt: DateTime(2026),
          failureReason: const Value(DownloadFailureReason.truncated),
          failureDetail: const Value('4 / 10 bytes'),
        ),
      );
      final failed = await clone.get('/v1/downloads/status');
      final items = failed.body['queueItems'] as List<dynamic>;
      expect(items.single, containsPair('failureReason', 'truncated'));
      expect(items.single, containsPair('failureDetail', '4 / 10 bytes'));

      final cancelled = await clone.post('/v1/downloads/cancel', {
        'queueId': 4,
      });
      expect(cancelled.statusCode, HttpStatus.ok);
      verify(() => service.cancelQueueItem(4)).called(1);
    },
  );

  test(
    'artist diagnostics reject primary mutation and invalid clone commands',
    () async {
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      final forbidden = await primary.post('/v1/artists/playback', {
        'command': 'cancel',
      });
      expect(forbidden.statusCode, HttpStatus.forbidden);
      await primary.close();
      final clone = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(clone.close);
      for (final body in [
        {'command': 'prepare', 'artistId': '', 'action': 'play'},
        {'command': 'prepare', 'artistId': 'artist', 'action': 'invalid'},
        {'command': 'retry', 'extra': true},
      ]) {
        final invalid = await clone.post('/v1/artists/playback', body);
        expect(invalid.statusCode, HttpStatus.badRequest);
      }
      final conflict = await clone.post('/v1/artists/playback', {
        'command': 'available',
      });
      expect(conflict.statusCode, HttpStatus.badRequest);
      final status = await clone.get('/v1/artists/playback/status');
      final value = status.body;
      expect(value.keys, isNot(contains('artistId')));
      expect(value.keys, isNot(contains('unresolvedAlbumIds')));
    },
  );

  test('track presentation actions reject primary mutation and invalid clone input', () async {
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );

    final forbidden = await primary.post('/v1/presentation/track-action', {
      'action': 'more',
    });
    expect(forbidden.statusCode, HttpStatus.forbidden);
    await primary.close();
    final clone = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(clone.close);
    for (final body in [
      {'action': 'arbitraryClick'},
      {'action': 'more', 'x': 1},
    ]) {
      final invalid = await clone.post('/v1/presentation/track-action', body);
      expect(invalid.statusCode, HttpStatus.badRequest);
    }
    final unavailable = await clone.post('/v1/presentation/track-action', {
      'action': 'more',
    });
    expect(unavailable.statusCode, HttpStatus.serviceUnavailable);
  });

  test(
    'playback status exposes radio metadata and null outside radio mode',
    () async {
      final handler = _MockPlaybackHandler();
      when(() => handler.loadFailureStream)
          .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
      when(handler.waitUntilReady).thenAnswer((_) async {});
      Map<String, Object?>? radio = {
        'stationId': 'fixture',
        'stationName': 'Fixture Radio',
        'streamHost': 'stream.example.invalid',
        'metadataSource': 'azuracast',
        'nowPlayingTitle': 'Song',
        'nowPlayingArtist': 'Artist',
        'nowPlayingArtHost': 'art.example.invalid',
        'nowPlayingArtHash': '006b2f45dd4bfe45',
        'publishedArtHost': 'art.example.invalid',
        'publishedArtHash': '006b2f45dd4bfe45',
      };
      when(handler.collectPlaybackDiagnostics)
          .thenAnswer((_) => {'radio': radio});
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        handler: handler,
      );
      addTearDown(fixture.close);
      final unauthorized = await _request(fixture.port, '/v1/playback/status');
      expect(unauthorized.statusCode, HttpStatus.unauthorized);
      final observed = await fixture.get('/v1/playback/status');
      expect(observed.statusCode, HttpStatus.ok);
      expect(observed.body['radio'], radio);
      expect(observed.body.toString(), isNot(contains('https://')));
      expect(observed.body['radio'], isNot(contains('nowPlayingArtUrl')));
      expect(observed.body['radio'], isNot(contains('publishedArtUri')));
      expect(observed.body, contains('providerCacheActivity'));
      radio = null;
      final stopped = await fixture.get('/v1/playback/status');
      expect(stopped.statusCode, HttpStatus.ok);
      expect(stopped.body, containsPair('radio', null));
    },
  );

  test('adjustments API applies both values and manages presets', () async {
    registerFallbackValue(const PlaybackAdjustments());
    final handler = _MockPlaybackHandler();
    var applied = const PlaybackAdjustments();
    when(() => handler.playbackAdjustments).thenAnswer((_) => applied);
    when(() => handler.playbackAdjustmentsStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => handler.loadFailureStream)
        .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
    when(handler.waitUntilReady).thenAnswer((_) async {});
    when(() => handler.playbackAdjustmentCapabilities)
        .thenReturn(PlaybackAdjustmentCapabilities.android);
    when(() => handler.setPlaybackAdjustments(any())).thenAnswer((i) async {
      applied = i.positionalArguments.first as PlaybackAdjustments;
    });
    when(handler.collectPlaybackDiagnostics).thenAnswer(
      (_) => {
        'playbackSpeed': applied.speed,
        'playbackPitchSemitones': applied.pitchSemitones,
      },
    );
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      handler: handler,
    );
    addTearDown(fixture.close);
    final unauthorized = await _request(
      fixture.port,
      '/v1/playback/adjustments',
      method: 'POST',
      body: {'speedPercent': 25},
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    final changed = await fixture.post('/v1/playback/adjustments', {
      'speedPercent': 13.75,
      'pitchSemitones': -2.37,
    });
    expect(changed.statusCode, HttpStatus.ok);
    expect(changed.body['persistedSpeed'], 1.1375);
    expect(changed.body['persistedPitchSemitones'], -2.37);
    final saved = await fixture.post('/v1/playback/adjustments', {
      'action': 'save',
      'name': 'Nightcore',
    });
    expect(saved.statusCode, HttpStatus.ok);
    final id = saved.body['selectedPresetId'];
    final none = await fixture.post('/v1/playback/adjustments', {
      'action': 'select',
      'id': 'none',
    });
    expect(none.body['speedPercent'], 0);
    expect(none.body['pitchSemitones'], 0);
    final restored = await fixture.post('/v1/playback/adjustments', {
      'action': 'select',
      'id': id,
    });
    expect(restored.body['pitchSemitones'], -2.37);
    final immutable = await fixture.post('/v1/playback/adjustments', {
      'action': 'delete',
      'id': 'none',
    });
    expect(immutable.statusCode, HttpStatus.badRequest);
    final ambiguous = await fixture.post('/v1/playback/adjustments', {
      'speed': 1.25,
      'speedPercent': 25,
    });
    expect(ambiguous.statusCode, HttpStatus.badRequest);
    expect(applied.speed, 1.1375);
    final linked = await fixture.post('/v1/playback/adjustments', {
      'speed': 1.25,
      'lockPitchToSpeed': true,
    });
    expect(linked.body['speed'], 1.25);
    expect(linked.body['lockPitchToSpeed'], isTrue);
    expect(linked.body['persistedLockPitchToSpeed'], isTrue);
    expect(applied.pitchFactor, 1.25);
    final rejected = await fixture.post('/v1/playback/adjustments', {
      'pitchSemitones': 0,
    });
    expect(rejected.statusCode, HttpStatus.badRequest);
    await fixture.post('/v1/playback/adjustments', {
      'lockPitchToSpeed': false,
      'speed': 1.5,
    });
    expect(applied.pitchFactor, closeTo(1.25, 1e-14));
  });

  for (final (name, path, body) in <(String, String, Map<String, Object?>)>[
    (
      'adjustments API forbids primary mutation',
      '/v1/playback/adjustments',
      {'speedPercent': 25},
    ),
    (
      'primary diagnostics cannot queue a target fixture',
      '/v1/sync/fixture/queue-target',
      {'targetKind': 'album', 'entityId': 'album-queued'},
    ),
  ]) {
    test(name, () async {
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      final forbidden = await primary.post(path, body);
      expect(forbidden.statusCode, HttpStatus.forbidden);
    });
  }

  test(
    'settings diagnostics dump canonical background, corners and density',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      final dao = fixture.container.read(navisDatabaseProvider).appSettingsDao;
      await dao.updateNowPlayingBackground('artwork');
      await dao.updateCornerStyle('soft');
      await dao.updateDensity(NavisDensity.compact);
      for (final path in [
        '/v1/presentation/appearance',
        '/v1/presentation/integrations',
      ]) {
        final response = await _request(
          fixture.port,
          path,
          token: fixture.token,
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body['nowPlayingBackground'], 'artwork');
        expect(response.body['cornerStyle'], 'soft');
        expect(response.body['density'], 'compact');
      }
    },
  );

  test(
    'appearance diagnostics validate targeted settings and remain clone-only',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/appearance',
        method: 'POST',
        body: {'gridArtworkSize': 'large'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);
      for (final body in [
        <String, Object?>{'gridArtworkSize': 'five'},
        <String, Object?>{'homeRecommendationsAutoAdvance': 'true'},
        <String, Object?>{'unknown': true},
        <String, Object?>{},
        // Cover art has no circle option in Appearance.
        <String, Object?>{'coverArtShape': 'circle'},
        <String, Object?>{'nowPlayingArtShape': 'oval'},
        <String, Object?>{'artistCardShape': 1},
      ]) {
        final invalid = await fixture.post('/v1/presentation/appearance', body);
        expect(invalid.statusCode, HttpStatus.badRequest);
      }
      final changed = await fixture.post('/v1/presentation/appearance', {
        'gridArtworkSize': 'small',
        'homeRecommendationsAutoAdvance': true,
        'coverArtShape': 'rounded',
        'nowPlayingArtShape': 'circle',
        'artistCardShape': 'square',
      });
      expect(changed.statusCode, HttpStatus.ok);
      expect(changed.body, {
        'gridArtworkSize': 'small',
        'homeRecommendationsAutoAdvance': true,
        'showArtistsPage': true,
        'showRadioPage': true,
        'coverArtShape': 'rounded',
        'nowPlayingArtShape': 'circle',
        'artistCardShape': 'square',
        'nowPlayingBackground': 'tinted',
        'cornerStyle': 'rounded',
        'density': 'comfortable',
        'themeMode': 'dark',
        'colorStyle': 'neutral',
        'colorSchemeSeed': null,
        'dynamicAlbumColor': false,
        'oledForAuto': false,
        'nightSchedule': {'enabled': false, 'start': 1320, 'end': 420},
        'flatSurfaces': false,
        'flatAreas': 7,
        'colorVividness': 0,
        'surfaceDepthLight': 0,
        'surfaceDepthDark': 0,
        'surfaceTintLight': 0,
        'surfaceTintDark': 0,
        'controlColor': 'accent',
        'selectedAppearanceLookId': null,
        'appearanceLookCount': 0,
        'albumArtShade': false,
        'albumArtColoredShade': false,
      });
      final observed = await fixture.get('/v1/presentation/appearance');
      expect(observed.body, changed.body);
      final persisted = await fixture.container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .getSettings();
      expect(persisted!.gridArtworkSize, 'small');
      expect(persisted.homeRecommendationsAutoAdvance, isTrue);
      expect(persisted.coverArtShape, 'rounded');
      expect(persisted.nowPlayingArtShape, 'circle');
      expect(persisted.artistCardShape, 'square');
      await fixture.close();
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      for (final method in ['GET', 'POST']) {
        final forbidden = await _request(
          primary.port,
          '/v1/presentation/appearance',
          method: method,
          token: primary.token,
          body: method == 'POST' ? {'gridArtworkSize': 'large'} : null,
        );
        expect(forbidden.statusCode, HttpStatus.forbidden);
      }
    },
  );

  test('Looks diagnostics lists ids and names, applies, counts and rejects unknown ids', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);
    final tuning = fixture.container.read(
      colorTuningControllerProvider.notifier,
    );
    expect(
      await tuning.commit(const ColorTuning(lightDepth: -2, darkDepth: 3)),
      isNull,
    );
    final controller = fixture.container.read(
      appearanceLooksControllerProvider.notifier,
    );
    final look = (await controller.saveAsNew('My look')).value!;
    final listed = await fixture.get('/v1/presentation/looks');
    expect(listed.statusCode, HttpStatus.ok);
    expect(listed.body, {
      'looks': [
        {'id': look.id, 'name': look.name},
      ],
    });
    final appearance = await fixture.get('/v1/presentation/appearance');
    expect(appearance.body, isNot(contains('selectedColorTuningPresetId')));
    expect(appearance.body, isNot(contains('colorTuningPresetCount')));
    expect(appearance.body['selectedAppearanceLookId'], look.id);
    expect(appearance.body['appearanceLookCount'], 1);
    await fixture.post('/v1/presentation/appearance', {'themeMode': 'light'});
    expect(
      (await fixture.get('/v1/presentation/appearance'))
          .body['selectedAppearanceLookId'],
      isNull,
    );
    expect(
      (await fixture.post('/v1/presentation/looks/apply', {
        'id': look.id,
      })).statusCode,
      HttpStatus.ok,
    );
    expect(
      (await fixture.get('/v1/presentation/appearance'))
          .body['selectedAppearanceLookId'],
      look.id,
    );
    expect(
      (await fixture.post('/v1/presentation/looks/apply', {
        'id': 'missing',
      })).statusCode,
      HttpStatus.notFound,
    );
    for (final body in <Map<String, Object?>>[
      {},
      {'id': 1},
      {'id': ''},
      {'id': look.id, 'extra': true},
    ]) {
      expect(
        (await fixture.post('/v1/presentation/looks/apply', body)).statusCode,
        HttpStatus.badRequest,
      );
    }
    expect(
      (await _request(fixture.port, '/v1/presentation/looks')).statusCode,
      HttpStatus.unauthorized,
    );
    expect(
      (await _request(
        fixture.port,
        '/v1/presentation/looks/apply',
        method: 'POST',
        body: {'id': look.id},
      )).statusCode,
      HttpStatus.unauthorized,
    );
    // One test database at a time: close the clone before the primary opens.
    await fixture.close();
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(primary.close);
    expect(
      (await primary.get('/v1/presentation/looks')).statusCode,
      HttpStatus.forbidden,
    );
    expect(
      (await primary.post('/v1/presentation/looks/apply', {
        'id': look.id,
      })).statusCode,
      HttpStatus.forbidden,
    );
  });

  test('appearance theme controls validate before writes and persist targeted values', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);
    const path = '/v1/presentation/appearance';
    final values = <String, Object?>{
      'themeMode': 'system',
      'colorStyle': 'immersive',
      'colorSchemeSeed': 0xFF567890,
      'dynamicAlbumColor': true,
      'oledForAuto': true,
      'nightSchedule': {'enabled': true, 'start': 1200, 'end': 300},
      'flatSurfaces': true,
      'flatAreas': 2,
      'colorVividness': -5,
      'surfaceDepthLight': 5,
      'surfaceDepthDark': -3,
      'surfaceTintLight': 5,
      'surfaceTintDark': 3,
      'controlColor': 'white',
      'albumArtShade': true,
      'albumArtColoredShade': true,
      'cornerStyle': 'square',
      'nowPlayingBackground': 'artwork',
      'density': 'compact',
    };
    final unauthorized = await _request(
      fixture.port,
      path,
      method: 'POST',
      body: values,
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    final changed = await _request(
      fixture.port,
      path,
      method: 'POST',
      token: fixture.token,
      body: values,
    );
    expect(changed.statusCode, HttpStatus.ok);
    for (final entry in values.entries) {
      expect(changed.body[entry.key], entry.value);
    }
    final persisted = await fixture.container
        .read(navisDatabaseProvider)
        .appSettingsDao
        .getSettings();
    expect(persisted!.colorSchemeSeed, 0xFF567890);
    expect(persisted.flatAreas, 2);
    expect(persisted.colorVividness, -5);
    expect(persisted.surfaceDepthLight, 5);
    expect(persisted.surfaceTintLight, 5);
    expect(persisted.surfaceTintDark, 3);
    expect(persisted.controlColor, 'white');
    expect(persisted.albumArtShade, isTrue);
    expect(persisted.albumArtColoredShade, isTrue);
    final observed = await fixture.get(path);
    expect(observed.body, changed.body);
    expect(persisted.colorStyle, 'immersive');
    expect(persisted.nightScheduleStartMinutes, 1200);
    for (final invalid in <Map<String, Object?>>[
      {'themeMode': 'auto'},
      {'colorStyle': 'unknown'},
      {'colorSchemeSeed': 1.5},
      {'colorSchemeSeed': -1},
      {'colorSchemeSeed': 0x100000000},
      {'dynamicAlbumColor': null},
      {'oledForAuto': 'true'},
      {'flatSurfaces': 1},
      {'colorVividness': -6},
      {'colorVividness': 6},
      {'colorVividness': 1.5},
      {'colorVividness': null},
      {'colorVividness': '2'},
      {'surfaceDepthLight': -6},
      {'surfaceDepthLight': 6},
      {'surfaceDepthLight': 1.5},
      {'surfaceDepthLight': null},
      {'surfaceDepthLight': '2'},
      {'surfaceDepthDark': -6},
      {'surfaceDepthDark': 6},
      {'surfaceDepthDark': 1.5},
      {'surfaceDepthDark': null},
      {'surfaceDepthDark': '2'},
      {'surfaceDepth': 2},
      {'surfaceTintLight': -1},
      {'surfaceTintLight': 6},
      {'surfaceTintLight': 1.5},
      {'surfaceTintLight': null},
      {'surfaceTintLight': '3'},
      {'surfaceTintDark': -1},
      {'surfaceTintDark': 6},
      {'surfaceTintDark': 1.5},
      {'surfaceTintDark': null},
      {'surfaceTintDark': '3'},
      {'controlColor': 'unknown'},
      {'controlColor': null},
      {'controlColor': 1},
      {'flatAreas': -1},
      {'flatAreas': 8},
      {'flatAreas': 1.5},
      {'flatAreas': null},
      {'flatAreas': '2'},
      {'albumArtShade': 1},
      {'albumArtShade': null},
      {'albumArtShade': 'true'},
      {'albumArtColoredShade': 1},
      {'albumArtColoredShade': null},
      {'cornerStyle': 'circle'},
      {'nowPlayingBackground': 'blur'},
      {'density': null},
      {'nightSchedule': null},
      {'nightSchedule': {}},
      {
        'nightSchedule': {'enabled': 1},
      },
      {
        'nightSchedule': {'start': -1},
      },
      {
        'nightSchedule': {'end': 1440},
      },
      {
        'nightSchedule': {'start': 1.5},
      },
      {
        'nightSchedule': {'extra': true},
      },
    ]) {
      final result = await _request(
        fixture.port,
        path,
        method: 'POST',
        token: fixture.token,
        body: {'gridArtworkSize': 'small', ...invalid},
      );
      expect(result.statusCode, HttpStatus.badRequest, reason: '$invalid');
    }
    final unchanged = await _request(fixture.port, path, token: fixture.token);
    expect(unchanged.body, changed.body);
    final cleared = await _request(
      fixture.port,
      path,
      method: 'POST',
      token: fixture.token,
      body: {
        'colorSchemeSeed': null,
        'nightSchedule': {'end': 450},
      },
    );
    expect(cleared.statusCode, HttpStatus.ok);
    expect(cleared.body['colorSchemeSeed'], isNull);
    expect(cleared.body['nightSchedule'], {
      'enabled': true,
      'start': 1200,
      'end': 450,
    });
    expect(cleared.body['colorStyle'], 'immersive');
    final partial = await fixture.post(path, {'colorVividness': 3});
    expect(partial.statusCode, HttpStatus.ok);
    expect(partial.body['colorVividness'], 3);
    expect(partial.body['surfaceDepthLight'], 5);
    expect(partial.body['surfaceDepthDark'], -3);
    expect(partial.body['surfaceTintLight'], 5);
    expect(partial.body['surfaceTintDark'], 3);
    expect(partial.body['controlColor'], 'white');
    for (final (shade, colored) in [(false, true), (true, false)]) {
      final toggled = await fixture.post(path, {
        'albumArtShade': shade,
        'albumArtColoredShade': colored,
      });
      expect(toggled.statusCode, HttpStatus.ok);
      expect(toggled.body['albumArtShade'], shade);
      expect(toggled.body['albumArtColoredShade'], colored);
      expect((await fixture.get(path)).body, toggled.body);
    }
    final parentOnly = await fixture.post(path, {'albumArtShade': false});
    expect(parentOnly.body['albumArtShade'], isFalse);
    expect(parentOnly.body['albumArtColoredShade'], isFalse);
    final colorOnly = await fixture.post(path, {'albumArtColoredShade': true});
    expect(colorOnly.body['albumArtShade'], isFalse);
    expect(colorOnly.body['albumArtColoredShade'], isTrue);
    await fixture.close();
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(primary.close);
    final forbidden = await _request(
      primary.port,
      path,
      method: 'POST',
      token: primary.token,
      body: values,
    );
    expect(forbidden.statusCode, HttpStatus.forbidden);
  });

  test(
    'integrations diagnostics report and change the policy, clone-only',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/integrations',
        method: 'POST',
        body: {'master': false},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      for (final body in [
        <String, Object?>{},
        <String, Object?>{'master': 'false'},
        <String, Object?>{'unknown': true},
        <String, Object?>{'key': 'deezer.topSongs'},
        <String, Object?>{'enabled': false},
        <String, Object?>{'key': 'deezer.nope', 'enabled': false},
        <String, Object?>{'key': 'Deezer', 'enabled': false},
        <String, Object?>{'key': 7, 'enabled': false},
        <String, Object?>{'key': 'deezer', 'enabled': 'no'},
        <String, Object?>{'master': false, 'extra': 1},
      ]) {
        final invalid = await fixture.post(
          '/v1/presentation/integrations',
          body,
        );
        expect(invalid.statusCode, HttpStatus.badRequest, reason: '$body');
      }

      final initial = await fixture.get('/v1/presentation/integrations');
      expect(initial.statusCode, HttpStatus.ok);
      expect(initial.body['master'], isTrue);
      expect(initial.body['disabled'], isEmpty);
      final initialFeatures = initial.body['features']! as Map;
      expect(initialFeatures.keys, hasLength(IntegrationFeature.values.length));
      expect(initialFeatures['deezer.topSongs'], {
        'switchOn': true,
        'allowed': true,
        'toggleable': true,
        'lock': null,
      });

      final changed = await fixture.post('/v1/presentation/integrations', {
        'key': 'deezer.topSongs',
        'enabled': false,
      });
      expect(changed.statusCode, HttpStatus.ok);
      expect(changed.body['disabled'], ['deezer.topSongs']);
      expect((changed.body['features']! as Map)['deezer.topSongs'], {
        'switchOn': false,
        'allowed': false,
        'toggleable': true,
        'lock': null,
      });

      final serviceOff = await fixture.post('/v1/presentation/integrations', {
        'key': 'lrclib',
        'enabled': false,
        'master': true,
      });
      expect(serviceOff.statusCode, HttpStatus.ok);
      expect(
        (serviceOff.body['features']! as Map)['lrclib.lyrics'],
        containsPair('lock', 'serviceOff'),
      );
      expect(
        (serviceOff.body['services']! as Map)['lrclib'],
        containsPair('switchOn', false),
      );

      // A column-backed feature writes its column, not the JSON set.
      final sameVibes = await fixture.post('/v1/presentation/integrations', {
        'key': 'lastfm.sameVibes',
        'enabled': false,
      });
      expect(sameVibes.statusCode, HttpStatus.ok);
      expect(sameVibes.body['disabled'], ['deezer.topSongs', 'lrclib']);
      expect(
        (sameVibes.body['features']! as Map)['lastfm.sameVibes'],
        containsPair('switchOn', false),
      );

      final masterOff = await fixture.post('/v1/presentation/integrations', {
        'master': false,
      });
      expect(masterOff.body['master'], isFalse);
      final lockedFeatures = masterOff.body['features']! as Map;
      expect(lockedFeatures['deezer.trending'], {
        'switchOn': true,
        'allowed': false,
        'toggleable': false,
        'lock': 'masterOff',
      });

      final persisted = (await fixture.container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .getSettings())!;
      expect(persisted.externalIntegrationsEnabled, isFalse);
      expect(persisted.legacyInstantMixEnabled, isTrue);
      expect(persisted.disabledIntegrations, '["deezer.topSongs","lrclib"]');

      await fixture.close();
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      for (final method in ['GET', 'POST']) {
        final forbidden = await _request(
          primary.port,
          '/v1/presentation/integrations',
          method: method,
          token: primary.token,
          body: method == 'POST' ? {'master': false} : null,
        );
        expect(forbidden.statusCode, HttpStatus.forbidden);
      }
    },
  );

  for (final mode in [
    SyncDiagnosticsMode.clone,
    SyncDiagnosticsMode.primaryCertification,
  ]) {
    test('integrations diagnostics report counters, calls and spans without '
        'secrets ($mode)', () async {
      const secret = 'SECRET_API_KEY_VALUE';
      final recorder = IntegrationCallRecorder(logCalls: false);
      recorder
        ..recordCall(
          service: IntegrationService.lastFm,
          method: 'GET',
          uri: Uri.parse(
            'https://ws.audioscrobbler.com/2.0/?method=artist.getTopTracks'
            '&api_key=$secret&artist=Someone',
          ),
          duration: const Duration(milliseconds: 120),
          outcome: IntegrationCallOutcome.ok,
          statusCode: 200,
        )
        ..recordCall(
          service: IntegrationService.deezer,
          method: 'GET',
          uri: Uri.parse('https://api.deezer.com/artist/1/top?limit=50'),
          duration: Duration.zero,
          outcome: IntegrationCallOutcome.blocked,
        )
        ..span('topSongs.sourceFetch', {
          'tracks': 50,
        }, const Duration(milliseconds: 90));
      for (var i = 0; i < 120; i++) {
        recorder.recordCall(
          service: IntegrationService.lrclib,
          method: 'GET',
          uri: Uri.parse('https://lrclib.net/api/get'),
          duration: const Duration(milliseconds: 5),
          outcome: IntegrationCallOutcome.ok,
          statusCode: 200,
        );
        recorder.span('filler', const {}, Duration.zero);
      }
      final overrides = [
        integrationCallRecorderProvider.overrideWithValue(recorder),
      ];

      // Read-only and available in every diagnostics mode.
      final fixture = await _startFixture(mode, overrides: overrides);
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/diagnostics/integrations',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final response = await fixture.get('/v1/diagnostics/integrations');
      expect(response.statusCode, HttpStatus.ok, reason: '$mode');
      final counters = response.body['counters']! as Map;
      expect(counters['lastfm'], {
        'requests': 1,
        'blocked': 0,
        'errors': 0,
        'totalMs': 120,
      });
      expect((counters['deezer']! as Map)['blocked'], 1);
      expect((counters['lrclib']! as Map)['requests'], 120);
      expect(response.body['calls'] as List, hasLength(100));
      expect(response.body['spans'] as List, hasLength(50));

      final encoded = jsonEncode(response.body);
      expect(encoded, isNot(contains(secret)));
      expect(encoded, isNot(contains('api_key')));
      expect(encoded, isNot(contains('limit=50')));
    });
  }

  for (final mode in SyncDiagnosticsMode.values) {
    test(
      'update diagnostics are authenticated and mode guarded in $mode',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'Navis',
          packageName: 'com.navis.app.navis',
          version: '1.0.0',
          buildNumber: '1',
          buildSignature: '',
        );
        final dio = _MockUpdateDio();
        var requests = 0;
        final store = _DiagnosticsUpdateCheckStore();
        when(
          () => dio.get<Object?>(any(), options: any(named: 'options')),
        ).thenAnswer((invocation) async {
          requests++;
          final options = invocation.namedArguments[#options] as Options;
          expect(options.extra, containsPair(navisUserInitiatedExtraKey, true));
          return Response<Object?>(
            data: <String, Object?>{},
            requestOptions: RequestOptions(path: '/manifest.json'),
            statusCode: 200,
          );
        });
        final repository = UpdateRepository(dio: dio, updateCheckStore: store);
        final fixture = await _startFixture(
          mode,
          overrides: [
            appSettingsProvider.overrideWith(
              (ref) => Stream.value(
                const AppSettingsModel.defaults().copyWith(
                  updateCheckEnabled: false,
                ),
              ),
            ),
            updateRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(fixture.close);

        for (final (method, path) in [
          ('GET', '/v1/diagnostics/update'),
          ('POST', '/v1/diagnostics/update/check'),
          ('POST', '/v1/diagnostics/update/download'),
        ]) {
          final unauthorized = await _request(
            fixture.port,
            path,
            method: method,
          );
          expect(unauthorized.statusCode, HttpStatus.unauthorized);
        }
        expect(requests, 0);
        final before = await _request(
          fixture.port,
          '/v1/diagnostics/update',
          token: fixture.token,
        );
        expect(before.statusCode, HttpStatus.ok);
        expect(before.body, {
          'manifestUrl': UpdateRepository.manifestUrlFor(),
          'channel': UpdateRepository.channelFor(),
          'url': null,
          'timestamp': null,
          'signatureValid': null,
          'payloadVersion': null,
          'assetKey': null,
          'rejectReason': null,
          'tag': null,
        });
        final checked = await _request(
          fixture.port,
          '/v1/diagnostics/update/check',
          method: 'POST',
          token: fixture.token,
        );
        if (mode == SyncDiagnosticsMode.primaryCertification) {
          expect(checked.statusCode, HttpStatus.forbidden);
          final download = await _request(
            fixture.port,
            '/v1/diagnostics/update/download',
            method: 'POST',
            token: fixture.token,
          );
          expect(download.statusCode, HttpStatus.forbidden);
          expect(requests, 0);
          return;
        }
        expect(checked.statusCode, HttpStatus.ok);
        expect(requests, 1);
        expect(store.forceArguments, [true]);
        expect(checked.body['url'], UpdateRepository.manifestUrlFor());
        expect(checked.body['timestamp'], isNotNull);
        expect(checked.body['signatureValid'], isFalse);
        expect(checked.body['rejectReason'], 'malformed_envelope');
        final after = await _request(
          fixture.port,
          '/v1/diagnostics/update',
          token: fixture.token,
        );
        expect(after.body, checked.body);
        expect(requests, 1);
        expect(
          fixture.container
              .read(updateForceCheckProvider.notifier)
              .consumeForceCheck(),
          isFalse,
        );
        // A rejected manifest offers nothing to download.
        final download = await _request(
          fixture.port,
          '/v1/diagnostics/update/download',
          method: 'POST',
          token: fixture.token,
        );
        expect(download.statusCode, HttpStatus.ok);
        expect(requests, 2);
        expect(download.body['rejectReason'], 'malformed_envelope');
        expect(download.body['downloaded'], isFalse);
        expect(download.body['artifactPath'], isNull);
        expect(download.body['downloadError'], isNull);
      },
    );
  }

  for (final settings in [
    const AppSettingsModel.defaults().copyWith(
      externalIntegrationsEnabled: false,
    ),
    const AppSettingsModel.defaults().copyWith(
      disabledIntegrations: '["updates"]',
    ),
  ]) {
    test(
      'diagnostics Check now respects integration policy $settings',
      () async {
        final store = _DiagnosticsUpdateCheckStore();
        final repository = UpdateRepository(
          dio: _MockUpdateDio(),
          updateCheckStore: store,
        );
        final fixture = await _startFixture(
          SyncDiagnosticsMode.clone,
          overrides: [
            appSettingsProvider.overrideWith((ref) => Stream.value(settings)),
            updateRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(fixture.close);
        final response = await _request(
          fixture.port,
          '/v1/diagnostics/update/check',
          method: 'POST',
          token: fixture.token,
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body['timestamp'], isNull);
        expect(store.forceArguments, isEmpty);
        expect(
          fixture.container
              .read(updateForceCheckProvider.notifier)
              .consumeForceCheck(),
          isFalse,
        );
      },
    );
  }

  test('integrations diagnostics list the retained call fields', () async {
    final recorder = IntegrationCallRecorder(logCalls: false)
      ..recordCall(
        service: IntegrationService.listenBrainz,
        method: 'post',
        uri: Uri.parse('https://api.listenbrainz.org/1/submit-listens?x=1'),
        duration: const Duration(milliseconds: 33),
        outcome: IntegrationCallOutcome.error,
        statusCode: 500,
      )
      ..span('lyrics', {'songs': 2}, const Duration(milliseconds: 7));
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      overrides: [integrationCallRecorderProvider.overrideWithValue(recorder)],
    );
    addTearDown(fixture.close);

    final response = await fixture.get('/v1/diagnostics/integrations');

    final call = (response.body['calls']! as List).single as Map;
    expect(call, containsPair('service', 'listenbrainz'));
    expect(call, containsPair('method', 'POST'));
    expect(call, containsPair('path', '/1/submit-listens'));
    expect(call, containsPair('status', 500));
    expect(call, containsPair('ms', 33));
    expect(call, containsPair('outcome', 'error'));
    expect(call, containsPair('blocked', false));
    expect(call.keys, containsAll(<String>['at']));
    final span = (response.body['spans']! as List).single as Map;
    expect(span, containsPair('name', 'lyrics'));
    expect(span['counts'], {'songs': 2});
    expect(span, containsPair('ms', 7));
  });

  test('playback queue stores a remote song the library lacks', () async {
    final handler = _MockPlaybackHandler();
    final queued = <List<String>>[];
    when(() => handler.loadFailureStream)
        .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
    when(handler.waitUntilReady).thenAnswer((_) async {});
    when(
      () => handler.replaceQueueWithData(
        any(),
        startIndex: any(named: 'startIndex'),
        autoPlay: any(named: 'autoPlay'),
        expandMatchFlows: any(named: 'expandMatchFlows'),
      ),
    ).thenAnswer((invocation) async {
      final songs =
          invocation.positionalArguments.first as List<SongsTableData>;
      queued.add(songs.map((song) => song.id).toList());
    });
    final api = _RemoteSongApiClient(<String, Song>{
      // The server answers for a remote song with its library copy.
      'ext-deezer-song-1': const Song(
        id: 'lib-copy',
        title: 'Dystopia',
        artist: 'ONE OK ROCK',
        artistId: 'lib-artist',
        album: 'Luxury Disease',
        albumId: 'lib-album',
        duration: 200,
      ),
    });
    final clone = await _startFixture(
      SyncDiagnosticsMode.clone,
      handler: handler,
      api: api,
    );
    addTearDown(clone.close);
    final database = clone.database as NavisDatabase;
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(id: 'local-1', title: 'Local Song'),
    ]);

    final response = await clone.post('/v1/playback/queue', <String, Object?>{
      'songIds': <String>['ext-deezer-song-1', 'local-1'],
    });

    expect(response.statusCode, HttpStatus.accepted);
    expect(queued, <List<String>>[
      <String>['ext-deezer-song-1', 'local-1'],
    ]);
    expect(api.requested, <String>['ext-deezer-song-1']);
    final stored = await database.libraryDao.getSongById('ext-deezer-song-1');
    expect(stored?.title, 'Dystopia');
    expect(stored?.isExternal, isTrue);
    expect(stored?.isProvisional, isTrue);
    // The library copy's album and artist are not referenced, so storing the
    // remote row creates no remote-flagged stubs under library ids.
    expect(stored?.albumId, isNull);
    expect(stored?.artistId, isNull);
    expect(stored?.albumName, 'Luxury Disease');
    expect(await database.libraryDao.getAlbumById('lib-album'), isNull);
    expect(await database.libraryDao.getArtistById('lib-artist'), isNull);

    final missing = await clone.post('/v1/playback/queue', <String, Object?>{
      'songIds': <String>['ext-deezer-song-404', 'local-1'],
    });
    expect(missing.statusCode, HttpStatus.notFound);
    expect(missing.body['songId'], 'ext-deezer-song-404');
    expect(queued, hasLength(1));
  });

  test(
    'rapid playback endpoints use the handler and remain clone-only',
    () async {
      final handler = _MockPlaybackHandler();
      var nextCalls = 0;
      var previousCalls = 0;
      when(() => handler.loadFailureStream)
          .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
      when(handler.waitUntilReady).thenAnswer((_) async {});
      when(handler.skipToNext).thenAnswer((_) async {
        nextCalls++;
      });
      when(handler.skipToPrevious).thenAnswer((_) async {
        previousCalls++;
      });
      when(handler.collectPlaybackDiagnostics).thenAnswer(
        (_) => <String, Object?>{
          'navigation': <String, Object?>{'pending': false},
        },
      );

      final clone = await _startFixture(
        SyncDiagnosticsMode.clone,
        handler: handler,
      );
      addTearDown(clone.close);
      for (final path in <String>[
        '/v1/playback/next',
        '/v1/playback/previous',
      ]) {
        final response = await clone.post(path);
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body['navigation'], <String, Object?>{
          'pending': false,
        });
      }
      expect(nextCalls, 1);
      expect(previousCalls, 1);
      await clone.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
        handler: handler,
      );
      addTearDown(primary.close);
      final forbidden = await primary.post('/v1/playback/next');
      expect(forbidden.statusCode, HttpStatus.forbidden);
      expect(nextCalls, 1);
    },
  );

  test(
    'frame evidence separates build, raster and span with bounded reset',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      FrameTiming timing(int build) => FrameTiming(
        vsyncStart: 0,
        buildStart: 100,
        buildFinish: 100 + build,
        rasterStart: 200 + build,
        rasterFinish: 1200 + build,
        rasterFinishWallTime: 1200 + build,
      );
      binding.platformDispatcher.onReportTimings!([
        for (var i = 0; i < 40; i++) timing(999999),
        for (var i = 0; i < 5000; i++) timing(2000),
      ]);
      final report = await fixture.get('/v1/diagnostics/report');
      for (final entry in {
        'frames': 3000,
        'frameBuild': 2000,
        'frameRaster': 1000,
        'frameSpan': 3200,
      }.entries) {
        expect(report.body[entry.key], {
          'samples': 5000,
          'p50Micros': entry.value,
          'p95Micros': entry.value,
          'p99Micros': entry.value,
          'maxMicros': entry.value,
          'over16ms': 0,
          'over33ms': 0,
        });
      }
      expect(
        report.body['frameWindow'],
        allOf(containsPair('frames', 5040), contains('framesPerSecond')),
      );
      expect(
        report.body['imageCache'],
        allOf(contains('currentSizeBytes'), contains('liveImageCount')),
      );
      final slowFrames = report.body['slowFrameSamples']! as List<Object?>;
      expect(slowFrames, hasLength(32));
      expect(slowFrames.first, containsPair('totalMicros', 1000999));
      final reset = await fixture.post('/v1/diagnostics/metrics/reset');
      expect(reset.statusCode, HttpStatus.ok);
      final cleared = await fixture.get('/v1/diagnostics/report');
      for (final key in ['frames', 'frameBuild', 'frameRaster', 'frameSpan']) {
        expect(cleared.body[key], {'samples': 0});
      }
      expect(cleared.body['slowFrameSamples'], isEmpty);
    },
  );

  test('attempt endpoint correlates active and terminal evidence without target keys', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      serverConfig: const ServerConfigModel(
        id: 1,
        url: 'https://private.example',
        username: 'private-user',
        password: 'private-password',
        apiVersion: '1.16.1',
      ),
    );
    addTearDown(fixture.close);
    final database = fixture.database as NavisDatabase;
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://private.example',
        username: 'private-user',
        apiVersion: '1.16.1',
      ),
    );
    const plan = SyncExecutionPlan(
      request: LibrarySyncRequest(
        origin: SyncRunOrigin.interaction,
        intent: SyncRunIntent.targetHydration,
        target: LibrarySyncTarget.album('private-target'),
        grant: SyncNetworkGrant.none,
      ),
      kind: LibrarySyncPlanKind.targetedHydration,
      reason: SyncSafeReason.none,
      budget: SyncExecutionBudget(
        allowedEndpoints: {SyncEndpoint.album},
        maxNewestPages: 0,
        maxAlbumHydrations: 1,
        maxResponseBytes: 1000,
        maxTotalBytes: 1000,
        maxConcurrency: 1,
      ),
    );
    final request = await database.librarySyncDao.enqueueSyncRun(
      serverId: 1,
      plan: plan,
    );
    final attempt = (await database.librarySyncDao.beginSyncRunAttempt(
      requestId: request.id,
      androidWorker: false,
    ))!;
    await database.librarySyncDao.writeAttemptTelemetry(attempt.id, {
      'version': 1,
      'requestId': request.id,
      'attemptId': attempt.id,
      'captureComplete': false,
    });
    final active = await fixture.get('/v1/sync/attempts');
    expect(active.statusCode, HttpStatus.ok);
    final row = (active.body['attempts']! as List).single as Map;
    expect(row['requestId'], request.id);
    expect(row['attemptId'], attempt.id);
    expect(row['status'], 'running');
    expect(row['telemetry']['captureComplete'], isFalse);
    expect(jsonEncode(active.body), isNot(contains('private')));
    await database.librarySyncDao.completeSyncRun(
      requestId: request.id,
      attemptId: attempt.id,
      outcome: const SyncRunOutcome(
        kind: SyncRunOutcomeKind.completed,
        reason: SyncSafeReason.none,
      ),
    );
    final ledger = await fixture.get('/v1/sync/ledger');
    final history = (ledger.body['durableRuns']! as List).single as Map;
    expect(history['requestId'], request.id);
    expect(history['attemptId'], attempt.id);
    expect(history['startedAt'], isA<String>());
    expect(history['intent'], 'targetHydration');
    expect(history['planKind'], 'targetHydration');
    expect(history['targetKind'], 'album');
    expect(history['outcome'], 'completed');
    expect(history['completedAt'], isA<String>());
    expect(ledger.body, isNot(contains('events')));
    expect(jsonEncode(ledger.body), isNot(contains('private')));
  });

  test('local search timing returns only counts and durations', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await fixture.get(
      '/v1/diagnostics/local-search?query=song',
    );
    expect(response.statusCode, HttpStatus.ok);
    for (final kind in <String>['artists', 'albums', 'songs']) {
      final entry = response.body[kind]! as Map<String, Object?>;
      expect(entry.keys, unorderedEquals(<String>['count', 'elapsedMicros']));
    }

    final missing = await fixture.get('/v1/diagnostics/local-search');
    expect(missing.statusCode, HttpStatus.badRequest);
  });

  test('diagnostics API requires its random bearer token', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final unauthorized = await _request(fixture.port, '/v1/health');
    expect(unauthorized.statusCode, HttpStatus.unauthorized);

    final authorized = await fixture.get('/v1/health');
    expect(authorized.statusCode, HttpStatus.ok);
    expect(authorized.body['mode'], 'clone');
    expect(authorized.body['schemaVersion'], fixture.database.schemaVersion);
  });

  test('cache upgrade clears then completes a full library scan', () async {
    const succeeded = LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.completed,
    );
    final engine = StubLibrarySyncEngine((request, {onProgress}) async {
      if (request.intent == SyncRunIntent.repairLibrary) {
        onProgress?.call(
          const LibrarySyncState(
            status: LibrarySyncStatus.running,
            stage: LibrarySyncStage.fetchingArtists,
          ),
        );
      }
      return succeeded;
    });
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      librarySyncEngine: engine,
    );
    addTearDown(fixture.close);
    // The sync controller resets to idle when the (absent) server config
    // first resolves; let that settle so it cannot land mid-scan.
    fixture.container.read(librarySyncControllerProvider);
    await fixture.container.read(serverConfigProvider.future);
    await Future<void>.delayed(Duration.zero);
    await fixture.database.customStatement('DELETE FROM cache_system_state;');

    final response = await fixture.post('/v1/library/cache-upgrade');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['status'], 'succeeded');
    expect(response.body['needsReset'], isFalse);
    expect(
      (response.body['sync'] as Map<String, dynamic>)['status'],
      'succeeded',
    );
    expect(
      engine.requestsWithIntent(SyncRunIntent.repairLibrary),
      hasLength(1),
    );
    expect(await fixture.database.cacheSystemStateDao.getVersion(), 1005);
  });

  test(
    'diagnostics server publishes and clears an Android handshake',
    () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: [navisDatabaseProvider.overrideWith((ref) => database)],
      );
      final published = <Map<String, Object?>>[];
      var clearCount = 0;
      final server = SyncDiagnosticsServer(
        container: container,
        mode: SyncDiagnosticsMode.primaryCertification,
        handshakePath: '/unused/android-handshake.json',
        androidHandshakePublisher: (handshake) async {
          published.add(handshake);
        },
        androidHandshakeClearer: () async {
          clearCount++;
        },
        onShutdown: () async {},
      );
      addTearDown(() async {
        await server.close();
        container.dispose();
        await database.close();
      });

      await server.start();

      expect(published, hasLength(1));
      expect(published.single['port'], isA<int>());
      expect(published.single['pid'], isA<int>());
      expect(published.single['mode'], 'primaryCertification');
      expect(
        published.single['token'],
        matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
      );

      await server.close();
      expect(clearCount, 1);
    },
  );

  test('primary certification rejects mutation and cancellation', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(fixture.close);

    final cancel = await fixture.post('/v1/sync/cancel');
    expect(cancel.statusCode, HttpStatus.forbidden);

    final maintenance = await fixture.post('/v1/cache/maintenance');
    expect(maintenance.statusCode, HttpStatus.forbidden);

    final corruptCache = await fixture.post(
      '/v1/diagnostics/cache/corrupt',
      <String, Object?>{'songId': 'song-1'},
    );
    expect(corruptCache.statusCode, HttpStatus.forbidden);

    final mutation = await fixture.post(
      '/v1/diagnostics/local-mutation',
      <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );
    expect(mutation.statusCode, HttpStatus.forbidden);

    final restore = await fixture.post(
      '/v1/diagnostics/restore-server-star',
      <String, Object?>{'songId': 'song-1', 'liked': false},
    );
    expect(restore.statusCode, HttpStatus.forbidden);

    final signOut = await fixture.post('/v1/session/sign-out');
    expect(signOut.statusCode, HttpStatus.forbidden);

    final reset = await fixture.post('/v1/session/reset-initial-state');
    expect(reset.statusCode, HttpStatus.forbidden);
  });

  test(
    'repair diagnostics uses the repair session and forwards mobile consent',
    () async {
      final controller = _RepairRouteController();
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        overrides: [
          librarySyncControllerProvider.overrideWith(() => controller),
        ],
      );
      addTearDown(fixture.close);
      final start = await fixture.post('/v1/sync/repair', const {
        'allowMeteredBroadOverride': true,
      });
      expect(start.statusCode, HttpStatus.accepted);
      expect(controller.repairGrants, [true]);
      expect(controller.forceFullCalls, 0);
    },
  );

  test(
    'Android playback deferral is exposed as a bounded diagnostic outcome',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        overrides: [
          pingServerProvider.overrideWithValue(() async => 'fixture'),
        ],
        serverConfig: const ServerConfigModel(
          id: 1,
          url: 'https://example.test',
          username: 'fixture',
          password: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      addTearDown(fixture.close);
      final database = fixture.database as NavisDatabase;
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: 1,
        workerResult: 'deferredPlayback',
        workerStopReason: 'deferredPlayback',
      );

      final response = await fixture.get('/v1/sync/status');
      expect(response.statusCode, HttpStatus.ok);
      final background = response.body['androidBackground']! as Map;
      expect(background['result'], 'deferredPlayback');
      expect(background['stopReason'], 'deferredPlayback');
      expect(background, isNot(contains('profileKey')));
    },
  );

  test('target sync diagnostics exercises controller-scoped status', () async {
    final completion = Completer<LibrarySyncState>();
    final engine = StubLibrarySyncEngine((request, {onProgress}) {
      onProgress?.call(
        const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingSongs,
        ),
      );
      return completion.future;
    });
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      librarySyncEngine: engine,
    );
    addTearDown(fixture.close);

    final start = await fixture.post('/v1/sync/target', const <String, Object?>{
      'targetKind': 'album',
      'entityId': 'album-1',
    });
    expect(start.statusCode, HttpStatus.accepted);
    await Future<void>.delayed(Duration.zero);
    expect(engine.requests, hasLength(1));

    final status = await fixture.get('/v1/sync/status');
    expect(status.statusCode, HttpStatus.ok);
    expect(status.body['status'], 'idle');
    expect(status.body['stage'], 'idle');
    expect(status.body, containsPair('nextAutomaticCheckAt', isNull));
    expect(status.body, containsPair('nextRetryAt', isNull));
    expect(status.body, containsPair('deletionCandidateCount', 0));
    expect(status.body, containsPair('durableOperations', isEmpty));
    expect(status.body['catalog'], <String, int>{
      'artists': 0,
      'albums': 0,
      'songs': 0,
    });

    completion.complete(
      const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final ledger = await fixture.get('/v1/sync/ledger');
    expect(ledger.statusCode, HttpStatus.ok);
    expect(ledger.body, isNot(contains('events')));
    expect(ledger.body['durableRuns'], isEmpty);
    expect(ledger.body['durableOperations'], isEmpty);
  });

  test(
    'clone diagnostics can queue but not dispatch an album target fixture',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.container
          .read(serverConfigRepositoryProvider)
          .save(
            const ServerConfigModel(
              url: 'https://music.example.test',
              username: 'listener',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          );

      final response = await fixture.post(
        '/v1/sync/fixture/queue-target',
        const <String, Object?>{
          'targetKind': 'album',
          'entityId': 'album-queued',
        },
      );

      expect(response.statusCode, HttpStatus.accepted);
      expect(response.body['status'], 'queued');
      expect(response.body['targetKind'], 'album');
      expect(response.body['pendingWork'], 1);
      final work = await fixture.database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: 'album:album-queued',
      );
      expect(work?.status, 'queued');
    },
  );

  test(
    'library album observation is authenticated and omits metadata',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
      ]);
      await fixture.database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album title must not be exposed',
          artistId: const Value('artist-1'),
          songsHydrated: const Value(true),
          songCount: const Value(1),
        ),
      ]);

      final missing = await _request(
        fixture.port,
        '/v1/library/album?id=album-1',
      );
      expect(missing.statusCode, HttpStatus.unauthorized);

      final invalid = await fixture.get('/v1/library/album');
      expect(invalid.statusCode, HttpStatus.badRequest);

      final present = await fixture.get('/v1/library/album?id=album-1');
      expect(present.statusCode, HttpStatus.ok);
      expect(present.body, <String, Object?>{
        'id': 'album-1',
        'exists': true,
        'songsHydrated': true,
        'songCount': 1,
      });
      expect(jsonEncode(present.body), isNot(contains('Album title')));

      final absent = await fixture.get('/v1/library/album?id=absent');
      expect(absent.body, <String, Object?>{'id': 'absent', 'exists': false});
    },
  );

  test(
    'recent-albums observation returns only ordered identity evidence',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-earlier',
          name: 'Private title',
          serverCreatedAt: Value(DateTime.utc(2026, 8, 10)),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-later',
          name: 'Another private title',
          serverCreatedAt: Value(DateTime.utc(2026, 8, 11)),
        ),
      ]);

      final response = await fixture.get('/v1/library/recent-albums?limit=2');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['sort'], 'recentlyAdded');
      expect(
        (response.body['albums'] as List<Object?>).first,
        contains('recentlyAddedRank'),
      );
      expect(
        (response.body['albums'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((album) => album['id']),
        <String>['album-later', 'album-earlier'],
      );
      expect(jsonEncode(response.body), isNot(contains('Private title')));
    },
  );

  test(
    'session status observes setup without creating a rebuild controller',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        overrides: [
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
        ],
      );
      addTearDown(fixture.close);
      final provider = requiredLibraryRebuildControllerProvider(
        RequiredLibraryRebuildReason.initialLogin,
      );
      expect(fixture.container.exists(provider), isFalse);
      final response = await fixture.get('/v1/session/status');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['initialSync'], 'idle');
      expect(fixture.container.exists(provider), isFalse);
      for (final action in ['retry', 'mobile', 'cancel']) {
        final inactive = await fixture.post('/v1/session/initial-sync/$action');
        expect(inactive.statusCode, HttpStatus.conflict);
        expect(fixture.container.exists(provider), isFalse);
      }
    },
  );

  test(
    'initial sync actions and status use the mounted rebuild controller',
    () async {
      final provider = requiredLibraryRebuildControllerProvider(
        RequiredLibraryRebuildReason.initialLogin,
      );
      final controller = _DiagnosticsRebuildController();
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        overrides: [
          provider.overrideWith(() => controller),
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
        ],
      );
      addTearDown(fixture.close);
      final visit = fixture.container.listen(provider, (_, _) {});
      addTearDown(visit.close);
      for (final (action, status) in [
        ('retry', 'syncing'),
        ('mobile', 'complete'),
        ('cancel', 'cancelling'),
      ]) {
        final response = await fixture.post('/v1/session/initial-sync/$action');
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body['initialSync'], status);
      }
      expect(controller.actions, ['retry', 'mobile', 'cancelAndSignOut']);
    },
  );

  test('initial sync actions remain clone-only', () async {
    final provider = requiredLibraryRebuildControllerProvider(
      RequiredLibraryRebuildReason.initialLogin,
    );
    final controller = _DiagnosticsRebuildController();
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      overrides: [provider.overrideWith(() => controller)],
    );
    addTearDown(fixture.close);
    final visit = fixture.container.listen(provider, (_, _) {});
    addTearDown(visit.close);
    for (final action in ['retry', 'mobile', 'cancel']) {
      final response = await fixture.post('/v1/session/initial-sync/$action');
      expect(response.statusCode, HttpStatus.forbidden);
    }
    expect(controller.actions, isEmpty);
  });

  test('session status exposes only lifecycle activity fields', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await fixture.get('/v1/session/status');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body.keys, <String>[
      'phase',
      'transition',
      'initialSync',
      'sync',
      'queues',
      'activity',
    ]);
    expect(response.body['queues'], isA<Map<String, dynamic>>());
    expect(response.body['activity'], isA<Map<String, dynamic>>());
    final encoded = jsonEncode(response.body).toLowerCase();
    expect(encoded, isNot(contains('username')));
    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('token')));
    expect(encoded, isNot(contains('url')));
  });

  test('cache status is authenticated and exposes no file paths', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await fixture.get('/v1/cache/status');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body.keys, <String>[
      'entries',
      'rollingEntries',
      'permanentEntries',
      'missingFiles',
      'renewalRequired',
    ]);
    expect(response.body['renewalRequired'], isFalse);
  });

  test('clone local mutation remains pending for sync precedence', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final mutation = await fixture.post(
      '/v1/diagnostics/local-mutation',
      <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );

    expect(mutation.statusCode, HttpStatus.ok);
    final pending = await fixture.database.starSyncDao.getPendingActions();
    expect(pending, hasLength(1));
    expect(pending.single.itemId, 'song-1');
    expect(pending.single.action, 'star');
  });

  test('clone mode accepts diagnostics override mutations', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await fixture.post(
      '/v1/diagnostics/overrides',
      <String, Object?>{
        'networkType': 'cellular',
        'nativeMetered': true,
        'requestReporting': true,
        'cachedListenBrainzPresentation': true,
        'forceSearchRemoteFailure': true,
        'artistTopTracksPresentationFixture': true,
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['networkType'], 'cellular');
    expect(response.body['requestReporting'], isTrue);
    expect(response.body['cachedListenBrainzPresentation'], isTrue);
    expect(response.body['forceSearchRemoteFailure'], isTrue);
    expect(response.body['artistTopTracksPresentationFixture'], isTrue);

    final cleared = await fixture.post(
      '/v1/diagnostics/overrides',
      const <String, Object?>{},
    );
    expect(cleared.statusCode, HttpStatus.ok);
    expect(cleared.body['networkType'], isNull);
    expect(cleared.body['nativeMetered'], isNull);
    expect(cleared.body['forceSearchRemoteFailure'], isFalse);
    expect(cleared.body['artistTopTracksPresentationFixture'], isFalse);
  });

  test('clone diagnostics can simulate foreground sync admission', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      serverConfig: const ServerConfigModel(
        id: 1,
        url: 'https://example.test',
        username: 'fixture',
        password: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    addTearDown(fixture.close);
    await fixture.database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    final response = await fixture.post(
      '/v1/diagnostics/sync-foreground',
      <String, Object?>{'active': true},
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['active'], isTrue);
    final invalid = await fixture.post(
      '/v1/diagnostics/sync-foreground',
      <String, Object?>{'active': 'true'},
    );
    expect(invalid.statusCode, HttpStatus.badRequest);
    final due = await fixture.post('/v1/diagnostics/automatic-sync-due');
    expect(due.statusCode, HttpStatus.ok);
    expect(due.body['due'], isTrue);
    final scheduled = await fixture.database.librarySyncDao.getOrCreateState(1);
    expect(scheduled.nextAutomaticCheckAt, isNotNull);
    expect(scheduled.nextAutomaticCheckAt!.isAfter(DateTime.now()), isFalse);
  });

  test(
    'primary certification rejects diagnostics override mutations',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(fixture.close);

      final response = await fixture.post(
        '/v1/diagnostics/overrides',
        <String, Object?>{'networkType': 'cellular'},
      );

      expect(response.statusCode, HttpStatus.forbidden);
      final foreground = await fixture.post(
        '/v1/diagnostics/sync-foreground',
        <String, Object?>{'active': true},
      );
      expect(foreground.statusCode, HttpStatus.forbidden);
      final due = await fixture.post('/v1/diagnostics/automatic-sync-due');
      expect(due.statusCode, HttpStatus.forbidden);
    },
  );

  test('handshake is removed when the diagnostics server closes', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    expect(fixture.handshake.existsSync(), isTrue);

    await fixture.close();

    expect(fixture.handshake.existsSync(), isFalse);
  });

  test(
    'playback bootstrap status is authenticated and exposes safe state',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/playback/bootstrap/status',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final status = await fixture.get('/v1/playback/bootstrap/status');
      expect(status.statusCode, HttpStatus.ok);
      expect(status.body['status'], 'initializing');
      expect(status.body['attempt'], 0);
      expect(status.body['timedOut'], isFalse);
      expect(status.body['retryScheduled'], isFalse);
      expect(status.body['handlerReady'], isFalse);
    },
  );

  test(
    'playback recovery diagnostics action has a bounded clone-only contract',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);

      final invalid = await fixture.post(
        '/v1/presentation/playback-recovery',
        <String, Object?>{'action': 'invalid'},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
      await fixture.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      final forbidden = await primary.post(
        '/v1/presentation/playback-recovery',
        <String, Object?>{'action': 'retry'},
      );
      expect(forbidden.statusCode, HttpStatus.forbidden);
    },
  );

  test(
    'setup highlights reset is authenticated, clone-only and targeted',
    () async {
      const path = '/v1/presentation/setup-highlights/reset';
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      final dao = fixture.database.appSettingsDao;
      await dao.getSettings();
      await dao.completeOnboarding(1);
      await dao.updateColorStyle('pastel');
      await dao.updateSetupHighlightsSeenRelease('1.5.0');
      await dao.updateSetupCardDismissedRelease('1.5.0');

      final unauthorized = await _request(fixture.port, path, method: 'POST');
      expect(unauthorized.statusCode, HttpStatus.unauthorized);
      expect((await dao.getSettings())!.setupHighlightsSeenRelease, '1.5.0');
      final before = await _request(
        fixture.port,
        '/v1/presentation/integrations',
        token: fixture.token,
      );
      expect(before.statusCode, HttpStatus.ok);
      expect(before.body['setupHighlightsSeenRelease'], '1.5.0');
      expect(before.body['setupCardDismissedRelease'], '1.5.0');

      for (var run = 0; run < 2; run++) {
        final reset = await _request(
          fixture.port,
          path,
          method: 'POST',
          token: fixture.token,
        );
        expect(reset.statusCode, HttpStatus.ok);
        expect(reset.body, {
          'setupHighlightsSeen': <Object?>[],
          'setupHighlightsSeenRelease': null,
          'setupCardDismissedRelease': null,
        });
      }
      final row = await dao.getSettings();
      expect(row.setupHighlightsSeenRelease, isNull);
      expect(row.setupCardDismissedRelease, isNull);
      expect(row.onboardingVersion, 1);
      expect(row.colorStyle, 'pastel');
      await fixture.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      await primary.database.appSettingsDao.getSettings();
      await primary.database.appSettingsDao.updateSetupHighlightsSeenRelease(
        '1.5.0',
      );
      final forbidden = await _request(
        primary.port,
        path,
        method: 'POST',
        token: primary.token,
      );
      expect(forbidden.statusCode, HttpStatus.forbidden);
      expect(
        (await primary.database.appSettingsDao.getSettings())!
            .setupHighlightsSeenRelease,
        '1.5.0',
      );
    },
    skip: !sqliteAvailable,
  );

  test('presentation endpoints use the authenticated clone control plane', () async {
    final presentation = _MockPresentationController();
    final navigationDriver = _MockDiagnosticsNavigationDriver();
    when(() => navigationDriver.resolves(any())).thenAnswer(
      (invocation) => !(invocation.positionalArguments.single as String)
          .startsWith('/missing'),
    );
    var location = '/';
    when(() => navigationDriver.location).thenAnswer((_) => location);
    when(() => navigationDriver.go(any())).thenAnswer((invocation) {
      final requested = invocation.positionalArguments.single as String;
      location = requested == '/redirect' ? '/target' : requested;
    });
    when(() => presentation.status).thenReturn(
      const DiagnosticsPresentationStatus(
        logicalWidth: 1280,
        logicalHeight: 720,
        devicePixelRatio: 1.5,
        screenshotReady: true,
      ),
    );
    when(() => presentation.appReady).thenReturn(true);
    when(presentation.waitForFrame).thenAnswer((_) async {});
    when(presentation.dismissPopupRoutes).thenAnswer((_) async {});
    when(presentation.systemBack).thenAnswer((_) async {});
    when(() => presentation.tapNavigationDestination(any()))
        .thenAnswer((_) async {});
    when(() => presentation.capture(label: any(named: 'label'))).thenAnswer(
      (_) async => const DiagnosticsScreenshot(
        artifact: 'screenshots/capture.png',
        logicalWidth: 1280,
        logicalHeight: 720,
        pixelWidth: 1280,
        pixelHeight: 720,
        pixelRatio: 1,
        byteCount: 42,
        sha256Digest:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
    );
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      presentationController: presentation,
      navigationDriver: navigationDriver,
    );
    addTearDown(fixture.close);

    for (final unauthorized in <(String, String)>[
      ('POST', '/v1/presentation/tooltip'),
      ('GET', '/v1/presentation/window'),
      ('POST', '/v1/presentation/window'),
      ('GET', '/v1/presentation/status'),
      ('POST', '/v1/presentation/navigate'),
      ('POST', '/v1/presentation/dismiss-popup'),
      ('POST', '/v1/presentation/onboarding/complete'),
      ('POST', '/v1/presentation/setup-highlights/reset'),
      ('GET', '/v1/presentation/home-warmup'),
      ('POST', '/v1/presentation/library-filter'),
      ('POST', '/v1/presentation/notice'),
      ('POST', '/v1/presentation/search'),
      ('POST', '/v1/presentation/search/play'),
    ]) {
      final response = await _request(
        fixture.port,
        unauthorized.$2,
        method: unauthorized.$1,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    }

    final dismissed = await fixture.post('/v1/presentation/dismiss-popup');
    expect(dismissed.statusCode, HttpStatus.ok);
    verify(presentation.dismissPopupRoutes).called(1);

    final status = await fixture.get('/v1/presentation/status');
    expect(status.statusCode, HttpStatus.ok);
    expect(status.body['route'], '/');
    expect(status.body['appReady'], isTrue);
    expect(status.body['screenshotReady'], isTrue);

    fixture.container.read(homeOnboardingWarmupTrackerProvider).recordTargets(
      const <HomeArtworkWarmupTarget>[
        HomeArtworkWarmupTarget(coverArtId: 'private-cover-a', size: 600),
        HomeArtworkWarmupTarget(coverArtId: 'private-cover-b', size: 160),
      ],
    );
    fixture.container
        .read(homeOnboardingWarmupTrackerProvider)
        .recordReady(
          const HomeArtworkWarmupTarget(
            coverArtId: 'private-cover-a',
            size: 600,
          ),
        );
    final warmupStatus = await fixture.get('/v1/presentation/home-warmup');
    expect(warmupStatus.statusCode, HttpStatus.ok);
    expect(warmupStatus.body, <String, Object?>{
      'targetCount': 2,
      'readyCount': 1,
    });
    expect(jsonEncode(warmupStatus.body), isNot(contains('private-cover')));

    final completeOnboarding = await fixture.post(
      '/v1/presentation/onboarding/complete',
    );
    expect(completeOnboarding.statusCode, HttpStatus.ok);
    expect(completeOnboarding.body['actualLocation'], '/');

    final invalidNavigation = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': 'https://example.com'},
    );
    expect(invalidNavigation.statusCode, HttpStatus.badRequest);

    final nonStringNavigation = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': 42},
    );
    expect(nonStringNavigation.statusCode, HttpStatus.badRequest);

    final navigation = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': '/target'},
    );
    expect(navigation.statusCode, HttpStatus.ok);
    expect(navigation.body['requestedLocation'], '/target');
    expect(navigation.body['actualLocation'], '/target');
    verify(presentation.waitForFrame).called(2);

    final redirected = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': '/redirect'},
    );
    expect(redirected.statusCode, HttpStatus.ok);
    expect(redirected.body['actualLocation'], '/target');
    expect(redirected.body['redirected'], isTrue);

    final likedNavigation = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': '/library#liked'},
    );
    expect(likedNavigation.statusCode, HttpStatus.ok);
    // The older fragment form is accepted and normalised to the section URL.
    expect(likedNavigation.body['actualLocation'], '/library?section=liked');
    expect(
      fixture.container.read(librarySectionProvider),
      LibrarySection.liked,
    );

    final unknownRoute = await fixture.post(
      '/v1/presentation/navigate',
      const <String, Object?>{'location': '/missing/page'},
    );
    expect(unknownRoute.statusCode, HttpStatus.badRequest);
    expect(
      likedNavigation.body['actualLocation'],
      '/library?section=liked',
      reason: 'a rejected location must not navigate',
    );

    final back = await fixture.post(
      '/v1/presentation/system-back',
      const <String, Object?>{},
    );
    expect(back.statusCode, HttpStatus.ok);
    expect(back.body['location'], isA<String>());
    verify(presentation.systemBack).called(1);

    final tab = await fixture.post(
      '/v1/presentation/tab',
      const <String, Object?>{'branch': 'settings'},
    );
    expect(tab.statusCode, HttpStatus.ok);
    verify(() => presentation.tapNavigationDestination(3)).called(1);

    final badTab = await fixture.post(
      '/v1/presentation/tab',
      const <String, Object?>{'branch': 'radio'},
    );
    expect(badTab.statusCode, HttpStatus.badRequest);

    final invalidLibraryFilter = await fixture.post(
      '/v1/presentation/library-filter',
      <String, Object?>{'query': 'x' * 65},
    );
    expect(invalidLibraryFilter.statusCode, HttpStatus.badRequest);

    final libraryFilter = await fixture.post(
      '/v1/presentation/library-filter',
      const <String, Object?>{'query': 'no-match'},
    );
    expect(libraryFilter.statusCode, HttpStatus.ok);
    expect(libraryFilter.body['query'], 'no-match');
    expect(libraryFilter.body['section'], 'liked');
    expect(
      fixture.container.read(libraryTypeFilterDiagnosticsProvider),
      'no-match',
    );

    for (final query in <Object?>[42, true, <String>[]]) {
      final invalid = await fixture.post(
        '/v1/presentation/library-filter',
        <String, Object?>{'query': query},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
      expect(
        fixture.container.read(libraryTypeFilterDiagnosticsProvider),
        'no-match',
      );
    }
    final missingQuery = await fixture.post(
      '/v1/presentation/library-filter',
      const <String, Object?>{},
    );
    expect(missingQuery.statusCode, HttpStatus.badRequest);
    expect(
      fixture.container.read(libraryTypeFilterDiagnosticsProvider),
      'no-match',
    );

    final maxLength = await fixture.post(
      '/v1/presentation/library-filter',
      <String, Object?>{'query': 'x' * 64},
    );
    expect(maxLength.statusCode, HttpStatus.ok);
    expect(maxLength.body['query'], hasLength(64));

    for (final query in <Object?>['', null, '   ']) {
      final cleared = await fixture.post(
        '/v1/presentation/library-filter',
        <String, Object?>{'query': query},
      );
      expect(cleared.statusCode, HttpStatus.ok);
      expect(cleared.body['query'], '');
      expect(fixture.container.read(libraryTypeFilterDiagnosticsProvider), '');
    }

    final invalidNotice = await fixture.post(
      '/v1/presentation/notice',
      const <String, Object?>{
        'message': 'Could not save album.',
        'level': 'unknown',
      },
    );
    expect(invalidNotice.statusCode, HttpStatus.badRequest);

    final notice = await fixture.post(
      '/v1/presentation/notice',
      const <String, Object?>{
        'message': 'Could not save album.',
        'level': 'error',
      },
    );
    expect(notice.statusCode, HttpStatus.ok);
    expect(notice.body['level'], 'error');
    expect(notice.body['messageLength'], 21);
    expect(
      fixture.container.read(appNoticeDiagnosticsProvider)?.level,
      AppNoticeLevel.error,
    );

    final overlay = await fixture.post(
      '/v1/presentation/player-overlay',
      const <String, Object?>{'surface': 'queue', 'visible': true},
    );
    expect(overlay.statusCode, HttpStatus.ok);
    expect(overlay.body['visible'], isTrue);

    final nowPlaying = await fixture.post(
      '/v1/presentation/player-overlay',
      const <String, Object?>{'surface': 'nowPlaying', 'visible': true},
    );
    expect(nowPlaying.statusCode, HttpStatus.ok);
    expect(nowPlaying.body['visible'], isTrue);
    expect(nowPlaying.body['desktopNowPlayingVisible'], isTrue);
    expect(
      fixture.container.read(desktopNowPlayingDiagnosticsProvider),
      isTrue,
    );

    when(() => presentation.capture(label: 'Bad Label'))
        .thenThrow(const FormatException('invalid label'));
    final invalidScreenshot = await fixture.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': 'Bad Label'},
    );
    expect(invalidScreenshot.statusCode, HttpStatus.badRequest);

    final nonStringScreenshot = await fixture.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': <String>[]},
    );
    expect(nonStringScreenshot.statusCode, HttpStatus.badRequest);

    final screenshot = await fixture.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': 'target'},
    );
    expect(screenshot.statusCode, HttpStatus.created);
    expect(screenshot.body['artifact'], 'screenshots/capture.png');
    expect(screenshot.body['sha256'], hasLength(64));
    verify(() => presentation.capture(label: 'target')).called(1);

    final badRatio = await fixture.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': 'target', 'pixelRatio': 3},
    );
    expect(badRatio.statusCode, HttpStatus.badRequest);
    when(() => presentation.capture(label: 'sharp', deviceResolution: true))
        .thenAnswer((_) async => (await presentation.capture(label: 'target')));
    final sharp = await fixture.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': 'sharp', 'pixelRatio': 'device'},
    );
    expect(sharp.statusCode, HttpStatus.created);
    verify(() => presentation.capture(label: 'sharp', deviceResolution: true))
        .called(1);

    final noKey = await fixture.post(
      '/v1/presentation/press',
      const <String, Object?>{'key': ''},
    );
    expect(noKey.statusCode, HttpStatus.badRequest);
    when(() => presentation.pressKeyedButton('homeRadioButton'))
        .thenAnswer((_) async => true);
    final press = await fixture.post(
      '/v1/presentation/press',
      const <String, Object?>{'key': 'homeRadioButton'},
    );
    expect(press.statusCode, HttpStatus.ok);
    expect(press.body['pressed'], isTrue);
    verify(() => presentation.pressKeyedButton('homeRadioButton')).called(1);
  });

  test(
    'presentation endpoints reject primary mode and missing surfaces',
    () async {
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      for (final endpoint in <(String, String)>[
        ('POST', '/v1/presentation/tooltip'),
        ('GET', '/v1/presentation/window'),
        ('POST', '/v1/presentation/window'),
        ('GET', '/v1/presentation/status'),
        ('POST', '/v1/presentation/navigate'),
        ('POST', '/v1/presentation/dismiss-popup'),
        ('POST', '/v1/presentation/onboarding/complete'),
        ('POST', '/v1/presentation/setup-highlights/reset'),
        ('GET', '/v1/presentation/home-warmup'),
        ('POST', '/v1/presentation/library-filter'),
        ('POST', '/v1/presentation/notice'),
        ('POST', '/v1/presentation/search'),
        ('POST', '/v1/presentation/search/play'),
        ('POST', '/v1/presentation/press'),
        ('POST', '/v1/presentation/screenshot'),
      ]) {
        final forbidden = await _request(
          primary.port,
          endpoint.$2,
          method: endpoint.$1,
          token: primary.token,
        );
        expect(forbidden.statusCode, HttpStatus.forbidden);
      }
      final unavailablePrimaryCapture = await primary.post(
        '/v1/presentation/screenshot',
        const <String, Object?>{'label': 'settings'},
      );
      expect(unavailablePrimaryCapture.statusCode, HttpStatus.forbidden);
      await primary.close();

      final clone = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(clone.close);
      for (final endpoint in <(String, String)>[
        ('POST', '/v1/presentation/tooltip'),
        ('GET', '/v1/presentation/status'),
        ('POST', '/v1/presentation/navigate'),
        ('POST', '/v1/presentation/dismiss-popup'),
        ('POST', '/v1/presentation/library-filter'),
        ('POST', '/v1/presentation/notice'),
        ('POST', '/v1/presentation/search'),
        ('POST', '/v1/presentation/search/play'),
        ('POST', '/v1/presentation/press'),
        ('POST', '/v1/presentation/screenshot'),
      ]) {
        final unavailable = await _request(
          clone.port,
          endpoint.$2,
          method: endpoint.$1,
          token: clone.token,
        );
        expect(unavailable.statusCode, HttpStatus.serviceUnavailable);
      }
    },
  );

  test('library actions are bounded, authenticated and clone-only', () async {
    final presentation = _MockPresentationController();
    final navigationDriver = _MockDiagnosticsNavigationDriver();
    when(() => navigationDriver.resolves(any())).thenAnswer(
      (invocation) => !(invocation.positionalArguments.single as String)
          .startsWith('/missing'),
    );
    when(() => navigationDriver.location).thenReturn('/library');
    for (final action in DiagnosticsPresentationController.libraryActions) {
      when(() => presentation.activateLibraryControl(action: action))
          .thenAnswer((_) async {});
    }
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      presentationController: presentation,
      navigationDriver: navigationDriver,
    );
    addTearDown(fixture.close);
    final unauthorized = await _request(
      fixture.port,
      '/v1/presentation/library-action',
      method: 'POST',
      body: const {'action': 'openFirstAlbum'},
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    for (final body in <Map<String, Object?>>[
      {},
      {'action': 42},
      {'action': 'arbitraryClick'},
      {'action': 'openFirstAlbum', 'key': 'arbitrary'},
    ]) {
      final response = await fixture.post(
        '/v1/presentation/library-action',
        body,
      );
      expect(response.statusCode, HttpStatus.badRequest);
    }
    for (final action in DiagnosticsPresentationController.libraryActions) {
      final response = await fixture.post('/v1/presentation/library-action', {
        'action': action,
      });
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['action'], action);
      verify(() => presentation.activateLibraryControl(action: action))
          .called(1);
    }
    await fixture.close();
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      presentationController: presentation,
    );
    addTearDown(primary.close);
    final forbidden = await primary.post(
      '/v1/presentation/library-action',
      const {'action': 'openFirstAlbum'},
    );
    expect(forbidden.statusCode, HttpStatus.forbidden);
  });

  test('page scroll is bounded, authenticated and clone-only', () async {
    final presentation = _MockPresentationController();
    when(
      () => presentation.scrollPrimary(
        by: any(named: 'by'),
        to: any(named: 'to'),
      ),
    ).thenAnswer(
      (_) async => const DiagnosticsScrollResult(
        pixels: 640,
        maxScrollExtent: 2400,
        viewportDimension: 844,
      ),
    );
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      presentationController: presentation,
    );
    addTearDown(fixture.close);
    final unauthorized = await _request(
      fixture.port,
      '/v1/presentation/scroll',
      method: 'POST',
      body: const {'by': 640},
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    for (final body in <Map<String, Object?>>[
      {},
      {'by': 1, 'to': 1},
      {'by': 'down'},
      {'by': 100001},
      {'to': -1},
      {'to': 100001},
    ]) {
      final response = await fixture.post('/v1/presentation/scroll', body);
      expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
    }
    verifyNever(
      () => presentation.scrollPrimary(
        by: any(named: 'by'),
        to: any(named: 'to'),
      ),
    );
    final scrolled = await fixture.post('/v1/presentation/scroll', const {
      'by': -120.5,
    });
    expect(scrolled.statusCode, HttpStatus.ok);
    expect(scrolled.body, <String, Object?>{
      'pixels': 640,
      'maxScrollExtent': 2400,
      'viewportDimension': 844,
    });
    verify(() => presentation.scrollPrimary(by: -120.5)).called(1);
    final jumped = await fixture.post('/v1/presentation/scroll', const {
      'to': 0,
    });
    expect(jumped.statusCode, HttpStatus.ok);
    verify(() => presentation.scrollPrimary(to: 0)).called(1);

    when(
      () => presentation.scrollPrimary(
        by: any(named: 'by'),
        to: any(named: 'to'),
      ),
    ).thenThrow(const DiagnosticsPresentationUnavailable());
    final unavailable = await fixture.post('/v1/presentation/scroll', const {
      'by': 10,
    });
    expect(unavailable.statusCode, HttpStatus.serviceUnavailable);
    await fixture.close();

    final noSurface = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(noSurface.close);
    final missing = await noSurface.post('/v1/presentation/scroll', const {
      'by': 10,
    });
    expect(missing.statusCode, HttpStatus.serviceUnavailable);
    await noSurface.close();

    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      presentationController: presentation,
    );
    addTearDown(primary.close);
    final forbidden = await primary.post('/v1/presentation/scroll', const {
      'by': 10,
    });
    expect(forbidden.statusCode, HttpStatus.forbidden);
  });

  test(
    'onboarding step and focus controls are validated and clone-only',
    () async {
      final presentation = _MockPresentationController();
      when(() => presentation.setOnboardingStep(any())).thenAnswer(
        (invocation) async => invocation.positionalArguments[0] as int,
      );
      when(() => presentation.focusOnboardingField(any())).thenAnswer(
        (invocation) async => invocation.positionalArguments[0] != 'none',
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        presentationController: presentation,
      );
      addTearDown(fixture.close);
      Future<_Response> post(String path, Map<String, Object?> body) =>
          fixture.post(path, body);
      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/onboarding/step',
        method: 'POST',
        body: const {'step': 3},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      for (final body in <Map<String, Object?>>[
        {},
        {'step': '3'},
        {'step': 1.5},
        {'step': 1, 'extra': true},
      ]) {
        final response = await post('/v1/presentation/onboarding/step', body);
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }
      verifyNever(() => presentation.setOnboardingStep(any()));
      final moved = await post('/v1/presentation/onboarding/step', {'step': 3});
      expect(moved.statusCode, HttpStatus.ok);
      expect(moved.body, {'step': 3});
      verify(() => presentation.setOnboardingStep(3)).called(1);

      when(() => presentation.setOnboardingStep(any()))
          .thenThrow(const DiagnosticsPresentationOutOfRange(4));
      final outOfRange = await post('/v1/presentation/onboarding/step', {
        'step': 9,
      });
      expect(outOfRange.statusCode, HttpStatus.notFound);
      when(() => presentation.setOnboardingStep(any()))
          .thenThrow(const DiagnosticsPresentationUnavailable());
      final notMounted = await post('/v1/presentation/onboarding/step', {
        'step': 0,
      });
      expect(notMounted.statusCode, HttpStatus.conflict);

      for (final body in <Map<String, Object?>>[
        {},
        {'field': 'password'},
        {'field': 3},
        {'field': 'none', 'extra': 1},
      ]) {
        final response = await post('/v1/presentation/onboarding/focus', body);
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }
      verifyNever(() => presentation.focusOnboardingField(any()));
      for (final field in ['listenBrainzToken', 'lastFmKey', 'none']) {
        final response = await post('/v1/presentation/onboarding/focus', {
          'field': field,
        });
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body, {'field': field, 'focused': field != 'none'});
        verify(() => presentation.focusOnboardingField(field)).called(1);
      }
      when(() => presentation.focusOnboardingField(any()))
          .thenThrow(const DiagnosticsPresentationUnavailable());
      final hidden = await post('/v1/presentation/onboarding/focus', {
        'field': 'lastFmKey',
      });
      expect(hidden.statusCode, HttpStatus.conflict);
      await fixture.close();

      final noSurface = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(noSurface.close);
      final missing = await noSurface.post(
        '/v1/presentation/onboarding/step',
        const {'step': 0},
      );
      expect(missing.statusCode, HttpStatus.serviceUnavailable);
      await noSurface.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
        presentationController: presentation,
      );
      addTearDown(primary.close);
      for (final (path, body) in <(String, Map<String, Object?>)>[
        ('/v1/presentation/onboarding/step', {'step': 0}),
        ('/v1/presentation/onboarding/focus', {'field': 'none'}),
      ]) {
        final forbidden = await primary.post(path, body);
        expect(forbidden.statusCode, HttpStatus.forbidden, reason: path);
      }
    },
  );

  test('playback recovery fixtures reject primary mutations', () async {
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(primary.close);
    for (final path in [
      '/v1/playback/recovery-fixture',
      '/v1/playback/radio',
    ]) {
      final result = await primary.post(path, {
        'action': 'denyFocus',
        'stationId': 'fixture',
      });
      expect(result.statusCode, HttpStatus.forbidden);
    }
  });

  test('playback recovery fixture rejects malformed clone actions', () async {
    final clone = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(clone.close);
    final invalid = await clone.post('/v1/playback/recovery-fixture', {
      'action': 'unknown',
    });
    expect(invalid.statusCode, HttpStatus.badRequest);
  });

  test(
    'release card control taps a card and reports its page, clone-only',
    () async {
      final presentation = _MockPresentationController();
      when(
        () => presentation.tapReleaseCard(
          surface: any(named: 'surface'),
          index: any(named: 'index'),
          location: any(named: 'location'),
        ),
      ).thenAnswer(
        (_) async => const DiagnosticsReleaseCardResult(
          outcome: 'albumPage',
          location: '/library/albums/ext-deezer-album-1',
        ),
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        presentationController: presentation,
      );
      addTearDown(fixture.close);
      Future<_Response> post(Map<String, Object?> body) =>
          fixture.post('/v1/presentation/release-card', body);
      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/release-card',
        method: 'POST',
        body: const {'surface': 'newReleases'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      for (final body in <Map<String, Object?>>[
        {},
        // The release sheet and its dismissal are gone.
        {'dismiss': true},
        {'dismiss': true, 'surface': 'newReleases'},
        {'surface': 'artists', 'index': 0},
        {'surface': 'newReleases', 'index': -1},
        {'surface': 'newReleases', 'index': '0'},
        {'surface': 'newReleases', 'index': 0, 'extra': 1},
        {'index': 0},
      ]) {
        final response = await post(body);
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }

      final tapped = await post({'surface': 'missingAlbums', 'index': 2});
      expect(tapped.statusCode, HttpStatus.ok);
      expect(tapped.body, {
        'outcome': 'albumPage',
        'location': '/library/albums/ext-deezer-album-1',
      });
      verify(
        () => presentation.tapReleaseCard(
          surface: 'missingAlbums',
          index: 2,
          location: any(named: 'location'),
        ),
      ).called(1);
      // The index defaults to the first card.
      expect(
        (await post({'surface': 'newReleases'})).statusCode,
        HttpStatus.ok,
      );
      verify(
        () => presentation.tapReleaseCard(
          surface: 'newReleases',
          index: 0,
          location: any(named: 'location'),
        ),
      ).called(1);

      when(
        () => presentation.tapReleaseCard(
          surface: any(named: 'surface'),
          index: any(named: 'index'),
          location: any(named: 'location'),
        ),
      ).thenThrow(const DiagnosticsPresentationOutOfRange(3));
      expect(
        (await post({'surface': 'newReleases', 'index': 5})).statusCode,
        HttpStatus.notFound,
      );
      when(
        () => presentation.tapReleaseCard(
          surface: any(named: 'surface'),
          index: any(named: 'index'),
          location: any(named: 'location'),
        ),
      ).thenThrow(const DiagnosticsPresentationUnavailable());
      expect(
        (await post({'surface': 'newReleases'})).statusCode,
        HttpStatus.conflict,
      );
      // The old path no longer exists.
      final retired = await fixture.post(
        '/v1/presentation/release-sheet',
        const {'surface': 'newReleases'},
      );
      expect(retired.statusCode, HttpStatus.notFound);
      await fixture.close();

      final noSurface = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(noSurface.close);
      final missing = await noSurface.post(
        '/v1/presentation/release-card',
        const {'surface': 'newReleases'},
      );
      expect(missing.statusCode, HttpStatus.serviceUnavailable);
      await noSurface.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
        presentationController: presentation,
      );
      addTearDown(primary.close);
      final forbidden = await primary.post(
        '/v1/presentation/release-card',
        const {'surface': 'newReleases'},
      );
      expect(forbidden.statusCode, HttpStatus.forbidden);
    },
  );

  test('adjustments can open only the Now Playing settings sheet', () async {
    final presentation = _MockPresentationController();
    when(presentation.openNowPlayingSettingsSheet).thenAnswer((_) async {});
    when(presentation.playbackQuickControls).thenReturn(const []);
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      presentationController: presentation,
    );
    addTearDown(fixture.close);

    final result = await fixture.post(
      '/v1/presentation/adjustments',
      const <String, Object?>{'settingsSheet': true},
    );

    expect(result.statusCode, HttpStatus.ok);
    expect(result.body['surface'], 'settingsSheet');
    verify(presentation.openNowPlayingSettingsSheet).called(1);
    verifyNever(
      () => presentation.revealPlaybackAdjustments(open: any(named: 'open')),
    );
  });

  test(
    'playback settings toggle is bounded and reports persisted fields',
    () async {
      final presentation = _MockPresentationController();
      when(() => presentation.togglePlaybackSetting(setting: 'scrobble'))
          .thenAnswer((_) async {});
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        presentationController: presentation,
      );
      addTearDown(fixture.close);
      final dao = fixture.container.read(navisDatabaseProvider).appSettingsDao;
      await dao.saveSettings(
        cachedPlaybackFirst: false,
        scrobbleEnabled: false,
        gaplessEnabled: true,
        skipSilenceEnabled: false,
        showAlbumsPage: true,
        showRadioPage: true,
        showPlaylistsPage: true,
        showArtistsPage: true,
        showLikedPage: true,
        wifiOnlyDownloads: true,
        autoDownloadStarredOnWifi: false,
        customDownloadFolderEnabled: false,
        themeMode: 'dark',
        colorStyle: 'neutral',
        oledForAuto: false,
        nightScheduleEnabled: false,
        nightScheduleStartMinutes: 1320,
        nightScheduleEndMinutes: 420,
        flatSurfaces: false,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        dynamicAlbumColorEnabled: false,
        updateCheckEnabled: true,
        updateChannel: 'stable',
        syncIntervalMinutes: 60,
        backgroundSyncUnmeteredOnly: false,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        coverArtShape: 'square',
        nowPlayingArtShape: 'rounded',
        artistCardShape: 'circle',
        artistViewMode: 'grid',
        desktopPlaybackVolume: 0.37,
        desktopLastAudibleVolume: 0.37,
        homeDensity: 'comfortable',
        listenBrainzTokenValid: true,
        listenBrainzUserName: 'fixture-listener',
      );
      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/playback-settings',
        method: 'POST',
        body: const {'toggle': 'scrobble'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);
      for (final body in <Map<String, Object?>>[
        {},
        {'toggle': 42},
        {'toggle': 'gapless'},
        {'toggle': 'scrobble', 'value': true},
      ]) {
        final response = await fixture.post(
          '/v1/presentation/playback-settings',
          body,
        );
        expect(response.statusCode, HttpStatus.badRequest);
      }
      final toggled = await fixture.post(
        '/v1/presentation/playback-settings',
        const {'toggle': 'scrobble'},
      );
      expect(toggled.statusCode, HttpStatus.ok);
      verify(() => presentation.togglePlaybackSetting(setting: 'scrobble'))
          .called(1);
      final observed = await fixture.get('/v1/presentation/playback-settings');
      expect(observed.body, {
        'scrobbleEnabled': false,
        'backgroundSyncUnmeteredOnly': false,
        'listenBrainzTokenValid': true,
        'listenBrainzAccountStored': true,
        'persistedVolume': 0.37,
      });
      await fixture.close();
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
        presentationController: presentation,
      );
      addTearDown(primary.close);
      for (final method in ['GET', 'POST']) {
        final forbidden = await _request(
          primary.port,
          '/v1/presentation/playback-settings',
          method: method,
          token: primary.token,
          body: method == 'POST' ? const {'toggle': 'scrobble'} : null,
        );
        expect(forbidden.statusCode, HttpStatus.forbidden);
      }
    },
  );

  test(
    'ListenBrainz discover observation counts restarts and is clone-only',
    () async {
      const path = '/v1/presentation/listenbrainz-discover';
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        overrides: <Override>[
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            CloneDiagnosticsExternalScrobbleCredentialStore(),
          ),
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
        ],
      );
      addTearDown(fixture.close);
      // The running app always has settings listeners; mirror that so a save
      // reaches the discovery stream's dependency.
      final settings = fixture.container.listen(appSettingsProvider, (_, _) {});
      addTearDown(settings.close);
      await fixture.container.read(appSettingsProvider.future);
      final dao = fixture.container.read(navisDatabaseProvider).appSettingsDao;

      Future<void> settingsApplied(
        bool Function(AppSettingsModel settings) applied,
      ) async {
        while (!applied(
          fixture.container.read(appSettingsProvider).requireValue,
        )) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      final unauthorized = await _request(fixture.port, path);
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final first = await fixture.get(path);
      expect(first.statusCode, HttpStatus.ok);
      expect(first.body.keys, <String>[
        'streamBuilds',
        'state',
        'playlistCount',
      ]);
      expect(first.body['state'], isIn(<String>['loading', 'data', 'error']));
      final builds = first.body['streamBuilds'] as int;

      final repeated = await fixture.get(path);
      expect(repeated.body['streamBuilds'], builds);

      await dao.updateGridArtworkSize('large');
      await settingsApplied(
        (settings) => settings.gridArtworkSize == GridArtworkSize.large,
      );
      final unrelated = await fixture.get(path);
      expect(unrelated.body['streamBuilds'], builds);

      await dao.updateListenBrainzScrobblingState(
        tokenValid: true,
        userName: 'fixture-listener',
      );
      await settingsApplied(
        (settings) => settings.listenBrainzUserName == 'fixture-listener',
      );
      final restarted = await fixture.get(path);
      expect(restarted.body['streamBuilds'], builds + 1);

      await fixture.close();
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      final forbidden = await primary.get(path);
      expect(forbidden.statusCode, HttpStatus.forbidden);
    },
  );

  test(
    'folder adoption records Manual Matching and reports its status',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      // The download service keeps its own files under app support.
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProvider,
            (call) async => fixture.temp.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );
      final folder = Directory(p.join(fixture.temp.path, 'adopt-fixture'))
        ..createSync();
      File(p.join(folder.path, 'Unknown Artist', 'Unknown.flac'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final before = await fixture.get('/v1/downloads/folder/status');
      expect(before.body, <String, Object?>{
        'enabled': false,
        'configured': false,
        'busy': false,
        'manualMatchingPending': 0,
      });

      final outside = await fixture.post(
        '/v1/downloads/folder/adopt',
        <String, Object?>{'path': Directory.systemTemp.path},
      );
      expect(outside.statusCode, HttpStatus.badRequest);

      final adopted = await fixture.post(
        '/v1/downloads/folder/adopt',
        <String, Object?>{'path': folder.path},
      );
      expect(adopted.statusCode, HttpStatus.ok);
      expect(adopted.body['items'], 1);
      expect(adopted.body['manualMatchingPending'], 1);

      final after = await fixture.get('/v1/downloads/folder/status');
      expect(after.body, <String, Object?>{
        'enabled': true,
        'configured': true,
        'busy': false,
        'manualMatchingPending': 1,
      });
      expect(after.body.toString(), isNot(contains(folder.path)));
    },
  );

  test('tooltip control validates its bounded targets', () async {
    final presentation = _MockPresentationController();
    when(() => presentation.hoverTooltip(target: 'lyrics'))
        .thenAnswer((_) async => true);
    when(() => presentation.hoverTooltip(target: null))
        .thenAnswer((_) async => false);
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      presentationController: presentation,
    );
    addTearDown(fixture.close);
    for (final target in <Object>['unknown', 42, <String>[]]) {
      final invalid = await fixture.post(
        '/v1/presentation/tooltip',
        <String, Object?>{'target': target},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
    }
    for (final target in <String?>['lyrics', null]) {
      final result = await fixture.post(
        '/v1/presentation/tooltip',
        <String, Object?>{'target': target},
      );
      expect(result.statusCode, HttpStatus.ok);
      expect(result.body['visible'], target != null);
    }
    verify(() => presentation.hoverTooltip(target: 'lyrics')).called(1);
    verify(() => presentation.hoverTooltip(target: null)).called(1);
  });

  test('primary mode permits only app-owned screenshot capture', () async {
    final presentation = _MockPresentationController();
    when(() => presentation.capture(label: 'settings')).thenAnswer(
      (_) async => const DiagnosticsScreenshot(
        artifact: 'screenshots/settings.png',
        logicalWidth: 400,
        logicalHeight: 800,
        pixelWidth: 400,
        pixelHeight: 800,
        pixelRatio: 1,
        byteCount: 42,
        sha256Digest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      presentationController: presentation,
    );
    addTearDown(primary.close);

    final screenshot = await primary.post(
      '/v1/presentation/screenshot',
      const <String, Object?>{'label': 'settings'},
    );

    expect(screenshot.statusCode, HttpStatus.created);
    expect(screenshot.body['artifact'], 'screenshots/settings.png');
    verify(() => presentation.capture(label: 'settings')).called(1);
  });

  test(
    'window presentation endpoint reports and selects desktop modes',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);

      final initial = await fixture.get('/v1/presentation/window');
      expect(initial.statusCode, HttpStatus.ok);
      expect(initial.body['mode'], 'desktop');

      final mini = await fixture.post(
        '/v1/presentation/window',
        const <String, Object?>{'mode': 'miniPlayer'},
      );
      expect(mini.statusCode, HttpStatus.ok);
      expect(mini.body['mode'], 'miniPlayer');

      final pinned = await fixture.post(
        '/v1/presentation/window',
        const <String, Object?>{'miniAlwaysOnTop': true},
      );
      expect(pinned.statusCode, HttpStatus.ok);
      expect(pinned.body['miniAlwaysOnTopSupported'], isTrue);
      expect(pinned.body['miniAlwaysOnTop'], isTrue);

      final invalid = await fixture.post(
        '/v1/presentation/window',
        const <String, Object?>{'width': 559, 'height': 360},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
    },
  );

  test(
    'song indicator endpoint is authenticated, validated, and sanitized',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1'],
          currentSongId: 'song-1',
          currentIndex: 0,
          playing: false,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
        ),
      );
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-1',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final invalid = await fixture.get('/v1/presentation/song-indicator');
      expect(invalid.statusCode, HttpStatus.badRequest);

      expect(
        fixture.container.read(songPlaybackIndicatorStateProvider('song-1')),
        SongPlaybackIndicatorState.current,
      );
      final current = await fixture.get(
        '/v1/presentation/song-indicator?songId=song-1',
      );
      expect(current.statusCode, HttpStatus.ok);
      expect(current.body, <String, Object?>{
        'state': 'current',
        'selected': true,
        'markerRole': 'equalizer',
        'semanticRole': 'nowPlaying',
        'backgroundColorRole': 'primaryTint08',
        'foregroundColorRole': 'primary',
      });

      final inactive = await fixture.get(
        '/v1/presentation/song-indicator?songId=song-2',
      );
      expect(inactive.body['state'], 'inactive');
      expect(inactive.body['selected'], isFalse);
      expect(inactive.body.containsKey('songId'), isFalse);
    },
  );

  test(
    'song indicator endpoint exposes the loading presentation state',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1', 'song-2'],
          currentSongId: 'song-1',
          currentIndex: 1,
          playing: true,
          processingState: AudioProcessingState.loading,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
          isLoading: true,
          loadingSongId: 'song-2',
        ),
      );
      addTearDown(fixture.close);

      final response = await fixture.get(
        '/v1/presentation/song-indicator?songId=song-2',
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['state'], 'loading');
      expect(response.body['markerRole'], 'progress');
      expect(response.body['semanticRole'], 'nowPlaying');
    },
  );

  test(
    'volume API uses production controller and persists mute state',
    () async {
      final handler = _MockPlaybackHandler();
      var handlerVolume = 1.0;
      when(() => handler.loadFailureStream)
          .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
      when(handler.waitUntilReady).thenAnswer((_) async {});
      when(() => handler.setVolume(any())).thenAnswer((invocation) async {
        handlerVolume = invocation.positionalArguments.single as double;
      });
      when(handler.collectPlaybackDiagnostics).thenAnswer(
        (_) => <String, Object?>{
          'userVolume': handlerVolume,
          'effectivePlayerVolume': handlerVolume,
        },
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        handler: handler,
      );
      addTearDown(fixture.close);
      fixture.container
          .read(playbackVolumeProvider.notifier)
          .hydrate(volume: 1, lastAudibleVolume: 1);

      final invalid = await fixture.post(
        '/v1/playback/volume',
        <String, Object?>{'value': 2},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      final set = await fixture.post('/v1/playback/volume', <String, Object?>{
        'value': 0.37,
      });
      expect(set.statusCode, HttpStatus.ok);
      expect(set.body['volume'], 0.37);
      expect(set.body['persistedVolume'], 0.37);
      expect(set.body['handlerUserVolume'], 0.37);

      final muted = await fixture.post('/v1/playback/volume/toggle-mute');
      expect(muted.statusCode, HttpStatus.ok);
      expect(muted.body['volume'], 0);
      expect(muted.body['lastAudibleVolume'], 0.37);
      expect(muted.body['persistedLastAudibleVolume'], 0.37);
      expect(muted.body['effectivePlayerVolume'], 0);

      final observed = await fixture.get('/v1/playback/volume');
      expect(observed.statusCode, HttpStatus.ok);
      expect(observed.body['persistedVolume'], 0);
    },
  );

  test('primary certification observes volume but rejects mutation', () async {
    final handler = _MockPlaybackHandler();
    when(() => handler.loadFailureStream)
        .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
    when(handler.waitUntilReady).thenAnswer((_) async {});
    when(handler.collectPlaybackDiagnostics).thenReturn(<String, Object?>{
      'userVolume': 1.0,
      'effectivePlayerVolume': 1.0,
    });
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      handler: handler,
    );
    addTearDown(fixture.close);
    fixture.container
        .read(playbackVolumeProvider.notifier)
        .hydrate(volume: 1, lastAudibleVolume: 1);

    final observed = await fixture.get('/v1/playback/volume');
    expect(observed.statusCode, HttpStatus.ok);
    expect(observed.body['desktopPersistenceEnabled'], isTrue);

    final response = await fixture.post(
      '/v1/playback/volume',
      <String, Object?>{'value': 0.37},
    );
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test(
    'source audit is authenticated, sanitized, and classifies mixed rows',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
      );
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'server-artist', name: 'Local Artist'),
      ]);

      final unauthorized = await _request(
        fixture.port,
        '/v1/search/source-audit',
        method: 'POST',
        body: const <String, Object?>{'query': 'mixed'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final response = await fixture.post(
        '/v1/search/source-audit',
        const <String, Object?>{'query': 'mixed'},
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['songCount'], 20);
      expect(response.body['songOffset'], 0);
      expect(response.body['resultCounts'], <String, Object?>{
        'artists': 1,
        'albums': 1,
        'songs': 1,
      });
      final records = response.body['records'] as List<dynamic>;
      expect(records, hasLength(3));
      expect(records, contains(containsPair('source', 'remote')));
      final local = records.cast<Map<String, dynamic>>().singleWhere(
        (record) => record['id'] == 'server-artist',
      );
      expect(local['locallyIndexed'], isTrue);
      expect(local['source'], 'onServer');
      for (final record in records.cast<Map<String, dynamic>>()) {
        expect(
          record.keys,
          unorderedEquals(<String>[
            'kind',
            'id',
            'displayLabel',
            'source',
            'apiIsExternal',
            'locallyIndexed',
            'isProvisional',
          ]),
        );
      }
    },
  );

  test('presentation search drives production providers and returns ranked sources', () async {
    var location = '/';
    final navigationDriver = _MockDiagnosticsNavigationDriver();
    when(() => navigationDriver.resolves(any())).thenAnswer(
      (invocation) => !(invocation.positionalArguments.single as String)
          .startsWith('/missing'),
    );
    when(() => navigationDriver.location).thenAnswer((_) => location);
    when(() => navigationDriver.go(any())).thenAnswer((invocation) {
      location = invocation.positionalArguments.single as String;
    });
    final presentation = _MockPresentationController();
    when(presentation.waitForFrame).thenAnswer((_) async {});
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      api: _SourceAuditApiClient(),
      navigationDriver: navigationDriver,
      presentationController: presentation,
    );
    addTearDown(fixture.close);
    await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(id: 'server-prefix', name: 'Aurora Local'),
    ]);

    final response = await fixture.post(
      '/v1/presentation/search',
      const <String, Object?>{'query': 'Aurora'},
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['route'], '/search');
    final artists = (response.body['artists'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(artists.map((record) => record['id']), <String>[
      'remote-exact',
      'server-prefix',
      'remote-prefix',
    ]);
    expect(artists.first['relevance'], 'exact');
    expect(artists.first['source'], 'remote');
    expect(artists[1]['source'], 'onServer');
    expect(
      artists.expand((record) => record.keys),
      everyElement(isIn(<String>['id', 'source', 'relevance'])),
    );
  });

  test(
    'presentation search result playback uses the production queue path',
    () async {
      var location = '/';
      final navigationDriver = _MockDiagnosticsNavigationDriver();
      when(() => navigationDriver.resolves(any())).thenAnswer(
        (invocation) => !(invocation.positionalArguments.single as String)
            .startsWith('/missing'),
      );
      when(() => navigationDriver.location).thenAnswer((_) => location);
      when(() => navigationDriver.go(any())).thenAnswer((invocation) {
        location = invocation.positionalArguments.single as String;
      });
      final presentation = _MockPresentationController();
      when(presentation.waitForFrame).thenAnswer((_) async {});
      final handler = _MockPlaybackHandler();
      when(() => handler.loadFailureStream)
          .thenAnswer((_) => const Stream<PlaybackLoadFailure>.empty());
      when(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: any(named: 'startIndex'),
          autoPlay: any(named: 'autoPlay'),
          expandMatchFlows: any(named: 'expandMatchFlows'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
        handler: handler,
        navigationDriver: navigationDriver,
        presentationController: presentation,
      );
      addTearDown(fixture.close);

      final search = await fixture.post(
        '/v1/presentation/search',
        const <String, Object?>{'query': 'Remote Song', 'filter': 'songs'},
      );
      expect(search.statusCode, HttpStatus.ok);

      final play = await fixture.post(
        '/v1/presentation/search/play',
        const <String, Object?>{'songId': 'provider-song-1'},
      );
      expect(play.statusCode, HttpStatus.accepted);
      expect(play.body['source'], 'remote');
      final persisted = await fixture.database.libraryDao.getSongById(
        'provider-song-1',
      );
      expect(persisted?.isExternal, isTrue);
      verify(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: 0,
          autoPlay: true,
          expandMatchFlows: true,
        ),
      ).called(1);
    },
  );

  test('current diagnostics playback source is resumed, not replaced', () {
    const active = PlaybackSnapshot(
      queueSongIds: <String>['song-1'],
      currentSongId: 'song-1',
      currentIndex: 0,
      playing: false,
      processingState: AudioProcessingState.ready,
      position: Duration(seconds: 12),
      duration: Duration(minutes: 4),
      bufferedPosition: Duration(seconds: 30),
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );

    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-1'),
      isTrue,
    );
    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-2'),
      isFalse,
    );
    expect(
      canResumeDiagnosticsPlayback(
        snapshot: const PlaybackSnapshot.idle(),
        songId: 'song-1',
      ),
      isFalse,
    );
  });
}

Future<_DiagnosticsFixture> _startFixture(
  SyncDiagnosticsMode mode, {
  SubsonicApiClient? api,
  LibrarySyncEngine? librarySyncEngine,
  NavisPlaybackHandler? handler,
  PlaybackSnapshot? playbackSnapshot,
  DiagnosticsPresentationController? presentationController,
  DiagnosticsNavigationDriver? navigationDriver,
  ServerConfigModel? serverConfig,
  DownloadService? downloadService,
  List<Override> overrides = const <Override>[],
}) async {
  final temp = await Directory.systemTemp.createTemp('navis_diagnostics_test_');
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: [
      navisDatabaseProvider.overrideWith((ref) => database),
      packageInfoProvider.overrideWith(
        (ref) async => PackageInfo(
          appName: 'Navis',
          packageName: 'navis',
          version: '1.5.0',
          buildNumber: '10500',
        ),
      ),
      if (serverConfig != null)
        serverConfigStateProvider.overrideWithValue(AsyncData(serverConfig)),
      libraryCacheResetServiceProvider.overrideWith(
        (ref) => LibraryCacheResetService(database: database),
      ),
      audioHandlerProvider.overrideWith((ref) => handler),
      if (playbackSnapshot != null)
        playerStateProvider.overrideWithValue(playbackSnapshot),
      if (api != null) subsonicApiProvider.overrideWithValue(api),
      if (api != null) searchIsOfflineProvider.overrideWithValue(false),
      if (librarySyncEngine != null)
        librarySyncEngineProvider.overrideWithValue(librarySyncEngine),
      if (downloadService != null)
        downloadServiceProvider.overrideWithValue(downloadService),
      ...overrides,
    ],
  );
  final handshake = File(p.join(temp.path, 'handshake.json'));
  final server = SyncDiagnosticsServer(
    container: container,
    mode: mode,
    handshakePath: handshake.path,
    presentationController: presentationController,
    navigationDriver: navigationDriver,
    onShutdown: () async {},
  );
  await server.start();
  final value =
      jsonDecode(await handshake.readAsString()) as Map<String, dynamic>;
  return _DiagnosticsFixture(
    server: server,
    container: container,
    database: database,
    temp: temp,
    handshake: handshake,
    port: value['port'] as int,
    token: value['token'] as String,
  );
}

class _MockPlaybackHandler extends Mock implements NavisPlaybackHandler {
  // Playback status reads the UI snapshot, which subscribes up front.
  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();

  @override
  Stream<PlaybackSnapshot> get snapshotStream => const Stream.empty();
}

class _MockDownloadService extends Mock implements DownloadService;

_MockDownloadService _downloadServiceStub() {
  final service = _MockDownloadService();
  when(() => service.isPaused).thenReturn(false);
  when(() => service.folderChanges).thenAnswer((_) => Stream.value(null));
  when(() => service.maxConcurrentDownloads).thenReturn(2);
  when(() => service.effectiveConcurrency).thenReturn(2);
  when(() => service.activeQueueIds).thenReturn(const <int>{});
  when(() => service.peakActiveDownloads).thenReturn(0);
  when(() => service.artworkStore).thenReturn(
    PermanentArtworkStore(
      readApplicationSupportDirectory: Directory.systemTemp.createTemp,
    ),
  );
  when(() => service.setMaxConcurrentDownloads(any())).thenAnswer((_) async {});
  when(() => service.setPaused(paused: any(named: 'paused')))
      .thenAnswer((_) async {});
  when(() => service.cancelQueueItem(any())).thenAnswer((_) async {});
  when(
    () => service.enqueueSong(
      any(),
      quality: any(named: 'quality'),
      format: any(named: 'format'),
    ),
  ).thenAnswer((_) async {});
  return service;
}

class _MockPresentationController extends Mock
    implements DiagnosticsPresentationController;

class _MockDiagnosticsNavigationDriver extends Mock
    implements DiagnosticsNavigationDriver;

class _DiagnosticsRebuildController extends RequiredLibraryRebuildController {
  new() : super(RequiredLibraryRebuildReason.initialLogin);

  final List<String> actions = [];

  @override
  RequiredLibraryRebuildState build() => const RequiredLibraryRebuildState();

  @override
  Future<void> retry() async {
    actions.add('retry');
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
  }

  @override
  Future<void> startUsingMobileData() async {
    actions.add('mobile');
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.complete,
    );
  }

  @override
  Future<void> cancelAndSignOut() async {
    actions.add('cancelAndSignOut');
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.cancelling,
    );
  }
}

class _SourceAuditApiClient extends SubsonicApiClient {
  new()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'test',
          apiVersion: '1.16.1',
        ),
      );

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int artistOffset = 0,
    int albumCount = 20,
    int albumOffset = 0,
    int songCount = 20,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    if (query == 'Aurora') {
      return const SearchResult3(
        artists: <Artist>[
          Artist(id: 'remote-prefix', name: 'Aurora Remote', isExternal: true),
          Artist(id: 'remote-exact', name: 'Aurora', isExternal: true),
          Artist(id: 'server-prefix', name: 'Aurora Local', isExternal: false),
        ],
      );
    }
    return const SearchResult3(
      artists: <Artist>[
        Artist(id: 'server-artist', name: 'Local Artist', isExternal: false),
      ],
      albums: <Album>[Album(id: 'ext-deezer-album-1', name: 'Remote Album')],
      songs: <Song>[
        Song(id: 'provider-song-1', title: 'Remote Song', isExternal: true),
      ],
    );
  }
}

/// Answers getSong from [songs]; any other id is not found.
class _RemoteSongApiClient extends SubsonicApiClient {
  new(this.songs)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'test',
          apiVersion: '1.16.1',
        ),
      );

  final Map<String, Song> songs;
  final List<String> requested = <String>[];

  @override
  Future<Song> getSong(String id, {CancelToken? cancelToken}) async {
    requested.add(id);
    final song = songs[id];
    if (song == null) {
      throw const SubsonicNotFoundException(message: 'Song not found');
    }
    return song;
  }
}

Future<_Response> _request(
  int port,
  String path, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(
      statusCode: response.statusCode,
      body: jsonDecode(text) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

class _DiagnosticsFixture {
  new({
    required this.server,
    required this.container,
    required this.database,
    required this.temp,
    required this.handshake,
    required this.port,
    required this.token,
  });

  final SyncDiagnosticsServer server;
  final ProviderContainer container;
  final dynamic database;
  final Directory temp;
  final File handshake;
  final int port;
  final String token;
  bool _closed = false;

  Future<_Response> get(String path) => _request(port, path, token: token);

  Future<_Response> post(String path, [Map<String, Object?>? body]) =>
      _request(port, path, method: 'POST', token: token, body: body);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
    container.dispose();
    await database.close();
    await temp.delete(recursive: true);
  }
}

class _Response {
  const new({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}

class _RepairRouteController extends LibrarySyncController {
  final List<bool> repairGrants = [];
  int forceFullCalls = 0;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> repairLibrary({
    bool allowMeteredBroadOverride = false,
  }) async {
    repairGrants.add(allowMeteredBroadOverride);
    return const LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.completed,
    );
  }

  @override
  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) async {
    forceFullCalls++;
    return const LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.completed,
    );
  }
}

class _MockUpdateDio extends Mock implements Dio;

class _DiagnosticsUpdateCheckStore extends UpdateCheckStore {
  final List<bool> forceArguments = [];

  @override
  Future<bool> shouldCheck({bool force = false}) async {
    forceArguments.add(force);
    return force;
  }

  @override
  Future<void> recordCheck([DateTime? checkedAt]) async {}
}
