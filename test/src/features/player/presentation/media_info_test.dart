import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/media_info.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/providers/provider_retry.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

const _snapshot = PlaybackSnapshot(
  queueSongIds: <String>['s1'],
  currentSongId: 's1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration.zero,
  duration: Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const _song = SongsTableData(
  id: 's1',
  title: 'Aurora',
  artistName: 'Some Artist',
  albumName: 'Some Album',
  suffix: 'flac',
  bitRate: 900,
  sampleRate: 44100,
  size: 30 * 1024 * 1024,
  duration: 180,
  playCount: 7,
  recordingMbid: 'mbid-recording',
  isProvisional: false,
  isExternal: false,
);

const _bareSong = SongsTableData(
  id: 's1',
  title: 'Bare',
  isProvisional: false,
  isExternal: false,
);

/// A catalogue copy (the Deezer row) that streams without being in the
/// library.
const _remoteSong = SongsTableData(
  id: 's1',
  title: 'Aurora',
  artistName: 'Some Artist',
  albumName: 'Some Album',
  suffix: 'mp3',
  bitRate: 128,
  sampleRate: 44100,
  size: 4 * 1024 * 1024,
  duration: 242,
  isProvisional: false,
  isExternal: true,
);

const _flacDetails = <String, dynamic>{
  'path': '/music/a/aurora.flac',
  'bitDepth': 24,
  'channelCount': 2,
  'bpm': 120,
  'comment': 'hello',
};

const _flacStream = MediaItem(
  id: 's1',
  title: 'Aurora',
  extras: <String, dynamic>{
    'resolvedFormat': 'flac',
    'resolvedBitRate': 900,
    'transcodingApplied': false,
  },
);

const _opusStream = MediaItem(
  id: 's1',
  title: 'Aurora',
  extras: <String, dynamic>{
    'transcodingApplied': true,
    'resolvedFormat': 'opus',
    'resolvedBitRate': 128,
  },
);

const _richSong = SongsTableData(
  id: 's1',
  title: 'Set Fire to the Rain',
  artistName: 'Adele',
  albumName: '21',
  suffix: 'flac',
  bitRate: 3000,
  sampleRate: 96000,
  size: 86 * 1024 * 1024,
  duration: 238,
  playCount: 14,
  track: 5,
  discNumber: 1,
  genres: <String>['Pop', 'Soul'],
  replayGainTrackGain: -9.31,
  replayGainAlbumGain: -8.7,
  recordingMbid: 'd1e0a99e-1111-4c2a-9d51-0f6b1a2c3d4e',
  albumMbid: 'd1e0a99e-2222-4c2a-9d51-0f6b1a2c3d4e',
  artistMbid: 'd1e0a99e-3333-4c2a-9d51-0f6b1a2c3d4e',
  isProvisional: false,
  isExternal: false,
);

void main() {
  setUpAll(() async {
    // Real Inter metrics: the default test font is wider than the app's.
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await inter.load();
  });

  Future<void> pump(
    WidgetTester tester, {
    SongsTableData song = _song,
    bool admin = false,
    Map<String, dynamic>? details,
    MediaItem? mediaItem,
    bool downloaded = false,
    bool desktop = true,
    Size size = const Size(800, 600),
    double textScale = 1,
    bool songMissing = false,
    Future<Map<String, dynamic>?> Function()? detailsLoader,
  }) async {
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(_snapshot),
          songByIdProvider.overrideWith(
            (ref, id) => Stream.value(songMissing ? null : song),
          ),
          songServerDetailsProvider.overrideWith(
            (ref, id) =>
                detailsLoader != null ? detailsLoader() : Future.value(details),
          ),
          serverUserIsAdminProvider.overrideWith((ref) async => admin),
          songDownloadStateProvider.overrideWith(
            (ref, id) => SongDownloadState(
              status: downloaded
                  ? SongDownloadStatus.downloaded
                  : SongDownloadStatus.none,
            ),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream.value(mediaItem),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(const Color(0xFF81C995)),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: desktop,
                viewportSize: MediaQuery.sizeOf(context),
                safePadding: EdgeInsets.zero,
              ),
              child: child!,
            ),
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMediaInfo(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void expectNoOverflow(WidgetTester tester) =>
      expect(tester.takeException(), isNull);

  // The dialog body scrolls only when it does not fit.
  double maxScroll(WidgetTester tester) {
    final scrollable = find
        .descendant(
          of: find.byType(SingleChildScrollView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    return tester.state<ScrollableState>(scrollable).position.maxScrollExtent;
  }

  testWidgets('downloaded FLAC: one source per group, closes on Escape', (
    tester,
  ) async {
    await pump(
      tester,
      downloaded: true,
      mediaItem: _flacStream,
      details: _flacDetails,
    );
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('Some Artist · Some Album'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Downloaded copy'), findsOneWidget);
    expect(find.text('Downloaded file'), findsOneWidget);
    expect(find.text('Server file'), findsNothing);
    expect(find.text('Remote file'), findsNothing);
    // Chips (stream) and tiles (file) both carry the quality.
    expect(find.text('FLAC'), findsNWidgets(2));
    expect(find.text('24-bit'), findsNWidgets(2));
    expect(find.text('44.1 kHz'), findsNWidgets(2));
    expect(find.text('900 Kb/s'), findsNWidgets(2));
    expect(find.text('30.0 MB'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
    expect(find.text('Original'), findsNothing);
    expect(find.text('mbid-recording'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expectNoOverflow(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktopMediaInfoDialog')), findsNothing);
  });

  testWidgets('remote direct stream names the track and file Remote', (
    tester,
  ) async {
    await pump(tester, song: _remoteSong, mediaItem: null);
    expect(find.text('Remote track'), findsOneWidget);
    expect(find.text('Remote file'), findsOneWidget);
    expect(find.text('Downloaded file'), findsNothing);
    expect(find.text('Server file'), findsNothing);
    expect(find.text('MP3'), findsNWidgets(2));
    expect(find.text('128 Kb/s'), findsNWidgets(2));
    expect(find.text('Bit depth'), findsNothing);
    expect(find.text('Channels'), findsNothing);
    expect(find.text('Original'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('remote mixed: a library answer never leaks into a remote file', (
    tester,
  ) async {
    await pump(tester, song: _remoteSong, admin: true, details: _flacDetails);
    expect(find.text('Remote file'), findsOneWidget);
    expect(find.text('MP3'), findsNWidgets(2));
    for (final contradiction in <String>[
      '24-bit',
      'Bit depth',
      'Channels',
      'FLAC',
      '/music/a/aurora.flac',
      'File path on server',
      'admin',
      'BPM',
      'hello',
    ]) {
      expect(find.text(contradiction), findsNothing, reason: contradiction);
    }
  });

  testWidgets('transcoded stream shows the stream and the original', (
    tester,
  ) async {
    await pump(
      tester,
      mediaItem: _opusStream,
      details: _flacDetails,
      admin: true,
    );
    expect(find.text('Server stream, transcoded'), findsOneWidget);
    // Stream chips: format and bitrate, no sample rate or depth.
    expect(find.text('OPUS'), findsOneWidget);
    expect(find.text('128 Kb/s'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('FLAC • 24-bit • 44.1 kHz • 900 Kb/s'), findsOneWidget);
    expect(find.text('Server file'), findsOneWidget);
    expect(find.text('The original, not what you hear'), findsOneWidget);
    expect(find.text('/music/a/aurora.flac'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('a plain server stream is not marked transcoded', (tester) async {
    await pump(tester, mediaItem: _flacStream, details: _flacDetails);
    expect(find.text('Server stream'), findsOneWidget);
    expect(find.text('Server stream, transcoded'), findsNothing);
    expect(find.text('Original'), findsNothing);
    expect(find.text('Server file'), findsOneWidget);
  });

  testWidgets('bit depth is shown for lossless files only', (tester) async {
    await pump(
      tester,
      song: _song.copyWith(
        suffix: const Value('mp3'),
        bitRate: const Value(128),
      ),
      details: const <String, dynamic>{'bitDepth': 24, 'channelCount': 2},
    );
    expect(find.text('MP3'), findsNWidgets(2));
    expect(find.text('Bit depth'), findsNothing);
    expect(find.text('24-bit'), findsNothing);
    expect(find.text('Channels'), findsOneWidget);
  });

  testWidgets('a download stored at another quality never mixes with the row', (
    tester,
  ) async {
    // Library row: FLAC 900 Kb/s, 24-bit on the server; the permanent copy
    // was downloaded as MP3 128.
    await pump(
      tester,
      downloaded: true,
      details: _flacDetails,
      admin: true,
      mediaItem: const MediaItem(
        id: 's1',
        title: 'Aurora',
        extras: <String, dynamic>{
          'resolvedFormat': 'mp3',
          'resolvedBitRate': 128,
          'transcodingApplied': false,
        },
      ),
    );
    expect(find.text('Downloaded copy'), findsOneWidget);
    expect(find.text('MP3'), findsOneWidget);
    expect(find.text('128 Kb/s'), findsOneWidget);
    // The 24-bit depth belongs to the FLAC original only.
    expect(find.text('24-bit'), findsOneWidget); // the server file's tile
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('FLAC • 24-bit • 44.1 kHz • 900 Kb/s'), findsOneWidget);
    expect(find.text('Server file'), findsOneWidget);
    expect(find.text('The original, not what you hear'), findsOneWidget);
    expect(find.text('Downloaded file'), findsNothing);
  });

  testWidgets('a stale media item is ignored', (tester) async {
    await pump(
      tester,
      details: _flacDetails,
      mediaItem: const MediaItem(
        id: 'other',
        title: 'Other',
        extras: <String, dynamic>{
          'transcodingApplied': true,
          'resolvedFormat': 'opus',
          'resolvedBitRate': 96,
        },
      ),
    );
    expect(find.text('Server stream'), findsOneWidget);
    expect(find.text('OPUS'), findsNothing);
    expect(find.text('Original'), findsNothing);
  });

  testWidgets('says when server details are loading', (tester) async {
    final never = Completer<Map<String, dynamic>?>();
    await pump(tester, detailsLoader: () => never.future);
    expect(find.text('Loading server details…'), findsOneWidget);
    expect(find.text('Server details unavailable'), findsNothing);
  });

  testWidgets('says when server details are unavailable', (tester) async {
    await pump(
      tester,
      detailsLoader: () async => throw const SubsonicConnectionException('x'),
    );
    expect(find.text('Server details unavailable'), findsOneWidget);
    expect(find.text('Loading server details…'), findsNothing);
  });

  testWidgets('remote tracks never mention server details', (tester) async {
    await pump(
      tester,
      song: _remoteSong,
      detailsLoader: () async => throw const SubsonicConnectionException('x'),
    );
    expect(find.text('Server details unavailable'), findsNothing);
  });

  testWidgets('a missing song row shows a message instead of an empty body', (
    tester,
  ) async {
    await pump(tester, songMissing: true);
    expect(find.text('Track Info'), findsOneWidget);
    expect(find.text('No track information'), findsOneWidget);
  });

  testWidgets('320 px wide at 1.3x text fits without overflow', (tester) async {
    await pump(
      tester,
      song: _richSong,
      desktop: false,
      size: const Size(320, 640),
      textScale: 1.3,
      admin: true,
      downloaded: true,
      details: _flacDetails,
      mediaItem: _opusStream,
    );
    expectNoOverflow(tester);
    await tester.ensureVisible(find.text('Library & IDs'));
    await tester.tap(find.text('Library & IDs'));
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
  });

  testWidgets('hides empty fields and groups', (tester) async {
    await pump(tester, song: _bareSong);
    expect(find.text('Bare'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    for (final hidden in <String>[
      'Library & IDs',
      'Track',
      'Bitrate',
      'MusicBrainz recording ID',
      'Original',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
  });

  testWidgets('the server path is hidden from non-admins', (tester) async {
    await pump(
      tester,
      details: const <String, dynamic>{'path': '/music/a/aurora.flac'},
    );
    expect(find.text('File path on server'), findsNothing);
    expect(find.text('/music/a/aurora.flac'), findsNothing);
    expect(find.text('admin'), findsNothing);
  });

  testWidgets('admins see the server path tagged admin', (tester) async {
    await pump(
      tester,
      admin: true,
      details: const <String, dynamic>{'path': '/music/a/aurora.flac'},
    );
    expect(find.text('File path on server'), findsOneWidget);
    expect(find.text('/music/a/aurora.flac'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
  });

  testWidgets('desktop at 800x600 fits without scrolling, Library open', (
    tester,
  ) async {
    await pump(
      tester,
      song: _richSong,
      admin: true,
      downloaded: true,
      details: _flacDetails,
      mediaItem: _flacStream.copyWith(
        extras: <String, dynamic>{
          'resolvedFormat': 'flac',
          'resolvedBitRate': 3000,
          'resolvedSampleRate': 96000,
        },
      ),
    );
    expect(find.text('Library & IDs'), findsOneWidget);
    expect(find.text('d1e0a99e-1111-4c2a-9d51-0f6b1a2c3d4e'), findsOneWidget);
    expect(find.text('Pop, Soul'), findsOneWidget);
    expect(find.text('/music/a/aurora.flac'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(maxScroll(tester), 0);
    expectNoOverflow(tester);
  });

  testWidgets('phone sheet: Library collapsed, then expanded', (tester) async {
    await pump(
      tester,
      song: _richSong,
      desktop: false,
      size: const Size(390, 844),
      downloaded: true,
      details: _flacDetails,
    );
    expect(find.byKey(const ValueKey('mediaInfoSheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktopMediaInfoDialog')), findsNothing);
    final sheetHeight = tester.getSize(find.byType(BottomSheet)).height;
    expect(sheetHeight, lessThanOrEqualTo(844 * 0.88 + 0.01));
    expect(find.text('Downloaded file'), findsOneWidget);
    expect(find.text('Track'), findsOneWidget);
    expect(find.text('Pop, Soul'), findsOneWidget);
    expect(find.text('Library & IDs'), findsOneWidget);
    expect(find.text('d1e0a99e-1111-4c2a-9d51-0f6b1a2c3d4e'), findsNothing);

    await tester.ensureVisible(find.text('Library & IDs'));
    await tester.tap(find.text('Library & IDs'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('d1e0a99e-1111-4c2a-9d51-0f6b1a2c3d4e'),
    );
    expect(find.text('d1e0a99e-1111-4c2a-9d51-0f6b1a2c3d4e'), findsOneWidget);
    expectNoOverflow(tester);

    await tester.tap(find.byKey(const ValueKey('mediaInfoClose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mediaInfoSheet')), findsNothing);
  });

  testWidgets('rows and tiles carry accessibility labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, admin: true, details: _flacDetails);
    expect(find.bySemanticsLabel('Format: FLAC'), findsOneWidget);
    expect(find.bySemanticsLabel('Play count: 7'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'File path on server (admin): /music/a/aurora.flac',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Track Info'), findsWidgets);
    handle.dispose();
  });

  group('media info prefetch', () {
    testWidgets('prefetches on song start, so the dialog opens instantly', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.pumpApp(tester);
      expect(rig.calls, <String>['alice:s1']);

      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.text('Aurora'), findsOneWidget);
      expect(find.text('FLAC'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('24-bit'), findsNothing);

      rig.complete(0, const <String, dynamic>{'bitDepth': 24});
      await tester.pump();
      await tester.pump();
      expect(find.text('24-bit'), findsWidgets);
      expect(rig.calls, hasLength(1));
    });

    testWidgets('retries once per open after a failure, never in a loop', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.pumpApp(tester);
      rig.fail(0, const SubsonicConnectionException('down'));
      await tester.pump(const Duration(seconds: 5));
      expect(rig.calls, hasLength(1));

      await tester.tap(find.text('open'));
      await tester.pump();
      expect(rig.calls, hasLength(2));
      rig.fail(1, const SubsonicConnectionException('down'));
      await tester.pump(const Duration(seconds: 5));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(rig.calls, hasLength(2));

      await tester.tap(find.text('open'));
      await tester.pump();
      expect(rig.calls, hasLength(3));
      rig.complete(2, const <String, dynamic>{});
      await tester.pump();
    });

    testWidgets('not found is final and opening does not retry', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.pumpApp(tester);
      rig.fail(0, const SubsonicNotFoundException(message: 'gone'));
      await tester.pump();
      expect(
        rig.container(tester).read(songServerDetailsProvider('s1')).value,
        isNull,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(rig.calls, hasLength(1));
    });

    test(
      'song change cancels the old request and never shows its data',
      () async {
        final rig = _Rig(honourCancel: false);
        final c = rig.newContainer();
        await rig.flush();
        expect(rig.calls, <String>['alice:s1']);
        rig.setSong('s2');
        await rig.flush();
        expect(rig.tokens[0].isCancelled, isTrue);
        expect(rig.calls, <String>['alice:s1', 'alice:s2']);

        rig.complete(0, const <String, dynamic>{'comment': 'from s1'});
        rig.complete(1, const <String, dynamic>{'comment': 'from s2'});
        await rig.flush();
        expect(c.read(songServerDetailsProvider('s2')).value, <String, dynamic>{
          'comment': 'from s2',
        });
        expect(rig.calls, hasLength(2));
      },
    );

    test('rapid skips cancel all but the last and retry nothing', () async {
      final rig = _Rig();
      rig.newContainer();
      await rig.flush();
      for (final id in <String>['s2', 's3', 's4']) {
        rig.setSong(id);
        await rig.flush();
      }
      expect(rig.calls, <String>[
        'alice:s1',
        'alice:s2',
        'alice:s3',
        'alice:s4',
      ]);
      expect(rig.tokens.map((t) => t.isCancelled), <bool>[
        true,
        true,
        true,
        false,
      ]);
    });

    test('a failed fetch is not retried by the root retry', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.newContainer();
        async.flushMicrotasks();
        rig.fail(0, const SubsonicConnectionException('down'));
        async.elapse(const Duration(seconds: 5));
        expect(rig.calls, hasLength(1));
      });
    });

    test('radio and idle make no request', () async {
      final rig = _Rig(snapshot: const PlaybackSnapshot.idle());
      rig.newContainer();
      await rig.flush();
      rig.setSnapshot(
        _snapshot.copyWith(
          radioStation: const RadioStationMetadata(
            stationId: 'r',
            stationName: 'R',
            streamUrl: 'https://radio.example/stream',
          ),
        ),
      );
      await rig.flush();
      expect(rig.calls, isEmpty);
    });

    test('offline defers until the network returns', () async {
      final rig = _Rig(network: NetworkType.offline);
      rig.newContainer();
      await rig.flush();
      expect(rig.calls, isEmpty);
      rig.setNetwork(NetworkType.wifi);
      await rig.flush();
      expect(rig.calls, <String>['alice:s1']);
    });

    test('reconciliation defers until it ends', () async {
      final rig = _Rig();
      final c = rig.newContainer(reconciling: true);
      await rig.flush();
      expect(rig.calls, isEmpty);
      c.read(networkReconcilingProvider.notifier).end();
      await rig.flush();
      expect(rig.calls, <String>['alice:s1']);
    });

    test('a network flip keeps the answer', () async {
      final rig = _Rig();
      final c = rig.newContainer();
      await rig.flush();
      rig.complete(0, const <String, dynamic>{'bpm': 90});
      await rig.flush();
      rig.setNetwork(NetworkType.cellular);
      await rig.flush();
      expect(rig.calls, hasLength(1));
      expect(c.read(songServerDetailsProvider('s1')).value, <String, dynamic>{
        'bpm': 90,
      });
    });

    test('server switch cancels and isolates, sign-out clears', () async {
      final rig = _Rig();
      final c = rig.newContainer();
      await rig.flush();
      rig.setConfig(_account('bob'));
      await rig.flush();
      expect(rig.tokens[0].isCancelled, isTrue);
      expect(rig.calls, <String>['alice:s1', 'bob:s1']);
      rig.complete(0, const <String, dynamic>{'path': 'alice-path'});
      rig.complete(1, const <String, dynamic>{'path': 'bob-path'});
      await rig.flush();
      expect(c.read(songServerDetailsProvider('s1')).value, <String, dynamic>{
        'path': 'bob-path',
      });

      rig.setConfig(null);
      await rig.flush();
      expect(c.read(songServerDetailsProvider('s1')).value, isNull);
      expect(rig.calls, hasLength(2));
    });
  });
}

ServerConfigModel _account(String user) => ServerConfigModel(
  url: 'https://example.com',
  username: user,
  password: 'secret',
  apiVersion: '1.16.1',
);

class _Box<T> extends Notifier<T> {
  new(this.initial);
  final T initial;
  @override
  T build() => initial;
  // A method, not a setter: tests call it like a command.
  // ignore: use_setters_to_change_properties
  void set(T value) => state = value;
}

class _FakeApi extends SubsonicApiClient {
  new(this.rig, this.user)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
  final _Rig rig;
  final String user;

  @override
  Future<Map<String, dynamic>> getSongPayload(
    String id, {
    CancelToken? cancelToken,
  }) {
    final completer = Completer<Map<String, dynamic>>();
    rig.calls.add('$user:$id');
    rig.tokens.add(cancelToken!);
    rig.completers.add(completer);
    if (rig.honourCancel) {
      unawaited(
        cancelToken.whenCancel.then((e) {
          if (!completer.isCompleted) completer.completeError(e);
        }),
      );
    }
    return completer.future;
  }
}

/// Test rig: counts getSong calls per account and lets a test drive the
/// song, account, network and reconciliation state.
class _Rig {
  new({
    PlaybackSnapshot snapshot = _snapshot,
    NetworkType network = NetworkType.wifi,
    this.honourCancel = true,
  }) : _snapshotBox =
           NotifierProvider<_Box<PlaybackSnapshot>, PlaybackSnapshot>(
             () => _Box(snapshot),
           ),
       _networkBox = NotifierProvider<_Box<NetworkType>, NetworkType>(
         () => _Box(network),
       );

  final bool honourCancel;
  final calls = <String>[];
  final tokens = <CancelToken>[];
  final completers = <Completer<Map<String, dynamic>>>[];
  final NotifierProvider<_Box<PlaybackSnapshot>, PlaybackSnapshot> _snapshotBox;
  final NotifierProvider<_Box<NetworkType>, NetworkType> _networkBox;
  final _configBox =
      NotifierProvider<_Box<ServerConfigModel?>, ServerConfigModel?>(
        () => _Box(_account('alice')),
      );
  late ProviderContainer _container;

  late final overrides = [
    playerStateProvider.overrideWith((ref) => ref.watch(_snapshotBox)),
    networkTypeProvider.overrideWith((ref) => ref.watch(_networkBox)),
    serverConfigStateProvider.overrideWith(
      (ref) => AsyncData(ref.watch(_configBox)),
    ),
    subsonicApiProvider.overrideWith((ref) {
      final config = ref.watch(_configBox);
      // Like production, the client rebuilds on every network change.
      ref.watch(_networkBox);
      return config == null ? null : _FakeApi(this, config.username);
    }),
    songByIdProvider.overrideWith(
      (ref, id) => Stream.value(_song.copyWith(id: id)),
    ),
    albumProvider.overrideWith((ref, id) => Stream.value(null)),
    serverUserIsAdminProvider.overrideWith((ref) async => true),
    songDownloadStateProvider.overrideWith((ref, id) => SongDownloadState.none),
    currentMediaItemProvider.overrideWith((ref) => Stream.value(null)),
  ];

  /// A container like production's (root retry), keeping the prefetch alive.
  ProviderContainer newContainer({bool reconciling = false}) {
    _container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: overrides,
    );
    addTearDown(_container.dispose);
    if (reconciling) {
      _container.read(networkReconcilingProvider.notifier).begin();
    }
    _container.listen(mediaInfoPrefetchProvider, (_, _) {});
    return _container;
  }

  Future<void> flush() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void setSnapshot(PlaybackSnapshot s) =>
      _container.read(_snapshotBox.notifier).set(s);
  void setSong(String id) => setSnapshot(_snapshot.copyWith(currentSongId: id));
  void setNetwork(NetworkType n) =>
      _container.read(_networkBox.notifier).set(n);
  void setConfig(ServerConfigModel? c) =>
      _container.read(_configBox.notifier).set(c);
  void complete(int call, Map<String, dynamic> payload) {
    if (!completers[call].isCompleted) completers[call].complete(payload);
  }

  void fail(int call, Object error) {
    if (!completers[call].isCompleted) completers[call].completeError(error);
  }

  ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text('open')),
    listen: false,
  );

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: navisProviderRetry,
        overrides: overrides,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              ref.listen(mediaInfoPrefetchProvider, (_, _) {});
              return TextButton(
                onPressed: () => showMediaInfo(context),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
  }
}
