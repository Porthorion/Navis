import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/desktop_media_info_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/providers/provider_retry.dart';
import 'package:navis/src/utils/connectivity.dart';

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

void main() {
  Future<void> pump(
    WidgetTester tester, {
    SongsTableData song = _song,
    bool admin = false,
    Map<String, dynamic>? details,
    MediaItem? mediaItem,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(_snapshot),
          songByIdProvider.overrideWith((ref, id) => Stream.value(song)),
          songServerDetailsProvider.overrideWith((ref, id) async => details),
          serverUserIsAdminProvider.overrideWith((ref) async => admin),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream.value(mediaItem),
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopMediaInfoDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows track, file and library data and closes on Escape', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Media info'), findsOneWidget);
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('30.0 MB'), findsOneWidget);
    expect(find.text('mbid-recording'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktopMediaInfoDialog')), findsNothing);
  });

  testWidgets('hides empty fields and sections', (tester) async {
    await pump(tester, song: _bareSong);
    expect(find.text('Bare'), findsOneWidget);
    expect(find.text('Track'), findsOneWidget);
    for (final hidden in <String>[
      'File',
      'Library data',
      'Transcoding',
      'Server',
      'Bitrate',
      'Year',
      'MusicBrainz recording ID',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
  });

  testWidgets('Server section is admin-only', (tester) async {
    const details = <String, dynamic>{'path': '/music/a/aurora.flac'};
    await pump(tester, details: details);
    expect(find.text('Server'), findsNothing);
    expect(find.text('/music/a/aurora.flac'), findsNothing);
  });

  testWidgets('admins get the Server section with the file path', (
    tester,
  ) async {
    await pump(
      tester,
      admin: true,
      details: const <String, dynamic>{
        'path': '/music/a/aurora.flac',
        'bitDepth': 24,
        'channelCount': 2,
        'bpm': 120,
        'comment': 'hello',
      },
    );
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('/music/a/aurora.flac'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('shows source versus streamed format when transcoding', (
    tester,
  ) async {
    await pump(
      tester,
      mediaItem: const MediaItem(
        id: 's1',
        title: 'Aurora',
        extras: <String, dynamic>{
          'transcodingApplied': true,
          'resolvedFormat': 'opus',
          'resolvedBitRate': 128,
        },
      ),
    );
    expect(find.text('Transcoding'), findsOneWidget);
    expect(find.text('FLAC • 900 Kb/s'), findsOneWidget);
    expect(find.text('OPUS • 128 Kb/s'), findsOneWidget);
  });

  testWidgets('no transcode section for a direct stream', (tester) async {
    await pump(tester);
    expect(find.text('Transcoding'), findsNothing);
  });

  testWidgets('rows carry accessibility labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(find.bySemanticsLabel('Format: FLAC'), findsOneWidget);
    expect(find.bySemanticsLabel('Play count: 7'), findsOneWidget);
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
      expect(find.text('FLAC'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('24'), findsNothing);

      rig.complete(0, const <String, dynamic>{'bitDepth': 24});
      await tester.pump();
      await tester.pump();
      expect(find.text('24'), findsOneWidget);
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
      return config == null ? null : _FakeApi(this, config.username);
    }),
    songByIdProvider.overrideWith(
      (ref, id) => Stream.value(_song.copyWith(id: id)),
    ),
    albumProvider.overrideWith((ref, id) => Stream.value(null)),
    serverUserIsAdminProvider.overrideWith((ref) async => true),
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
                onPressed: () => showDesktopMediaInfoDialog(context),
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
