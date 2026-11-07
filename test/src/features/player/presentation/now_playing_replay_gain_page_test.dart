import 'package:audio_service/audio_service.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/media_info.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/now_playing_harness.dart';
import '../../../../helpers/test_database.dart';

const _playback = PlaybackSnapshot(
  queueSongIds: <String>['s1'],
  currentSongId: 's1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3),
  bufferedPosition: Duration(minutes: 1),
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
  size: 30 * 1024 * 1024,
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

class _Decision extends Notifier<ReplayGainDecision?> {
  @override
  ReplayGainDecision? build() => null;
  void set(ReplayGainDecision? value) => state = value;
}

final _decisionProvider = NotifierProvider<_Decision, ReplayGainDecision?>(
  _Decision.new,
);

ReplayGainDecision _tagged(
  double db, {
  String mode = 'smart',
  String resolved = 'album',
}) => ReplayGainDecision(
  mode: mode,
  resolvedMode: resolved,
  db: db,
  source: resolved == 'album' ? ReplayGainSource.album : ReplayGainSource.track,
);

ReplayGainDecision _untagged(double db) => ReplayGainDecision(
  mode: 'track',
  resolvedMode: 'track',
  db: db,
  source: ReplayGainSource.untagged,
);

void main() {
  late ProviderContainer container;

  Future<void> pumpPhone(
    WidgetTester tester, {
    ReplayGainDecision? decision,
    double? fixedUntaggedDb,
  }) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    container = createNowPlayingContainer(
      overrides: <Override>[
        songByIdProvider.overrideWith((ref, id) => Stream.value(_song)),
        songServerDetailsProvider.overrideWith((ref, id) async => null),
        songDownloadStateProvider.overrideWith(
          (ref, id) => SongDownloadState.none,
        ),
        serverUserIsAdminProvider.overrideWith((ref) async => false),
        nowPlayingReplayGainProvider.overrideWith(
          (ref) => ref.watch(_decisionProvider),
        ),
        if (fixedUntaggedDb != null)
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                replayGainUntaggedDb: fixedUntaggedDb,
              ),
            ),
          ),
      ],
    );
    container.read(nowPlayingTestPlaybackProvider.notifier).state = _playback;
    container.read(_decisionProvider.notifier).set(decision);
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) =>
              Scaffold(body: NowPlayingScreen(onCollapse: () {})),
        ),
        GoRoute(
          path: SettingsPage.playback.location,
          builder: (context, state) =>
              const Scaffold(body: Text('Playback settings page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final infoText = find
      .descendant(
        of: find.byKey(const ValueKey('nowPlayingInfoSwitcher')),
        matching: find.byType(Text),
      )
      .first;
  const quality = 'FLAC • 900 Kb/s';

  Future<void> tapInfo(WidgetTester tester) async {
    await tester.tap(infoText);
    await tester.pumpAndSettle();
  }

  testWidgets('the page comes right after Quality with the exact value', (
    tester,
  ) async {
    await pumpPhone(tester, decision: _tagged(-6.2));
    expect(find.text(quality), findsOneWidget);
    await tapInfo(tester);
    expect(find.text('−6.2 dB · album (Smart)'), findsOneWidget);
    await tapInfo(tester);
    expect(find.text('Playing 1 of 1'), findsOneWidget);
  }, skip: !sqliteAvailable);

  for (final (decision, text) in [
    (_tagged(-6.2, mode: 'track', resolved: 'track'), '−6.2 dB · track'),
    (_tagged(-6.2, mode: 'album'), '−6.2 dB · album'),
    (_tagged(-3.4, resolved: 'track'), '−3.4 dB · track (Smart)'),
    (_tagged(0, mode: 'track', resolved: 'track'), '0.0 dB · track'),
    (_tagged(-0.04, mode: 'track', resolved: 'track'), '0.0 dB · track'),
    (_untagged(-8), '−8.0 dB · untagged (Automatic)'),
  ]) {
    testWidgets('shows "$text"', (tester) async {
      await pumpPhone(tester, decision: decision);
      await tapInfo(tester);
      expect(find.text(text), findsOneWidget);
    }, skip: !sqliteAvailable);
  }

  testWidgets('a fixed untagged level is named as such', (tester) async {
    await pumpPhone(tester, decision: _untagged(-12), fixedUntaggedDb: -12);
    await tapInfo(tester);
    expect(find.text('−12.0 dB · untagged (fixed level)'), findsOneWidget);
  }, skip: !sqliteAvailable);

  testWidgets('no decision (off, radio, no song) adds no page', (tester) async {
    await pumpPhone(tester);
    await tapInfo(tester);
    expect(find.text('Playing 1 of 1'), findsOneWidget);
    expect(find.textContaining(' dB '), findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets('the page appears and disappears as the decision changes', (
    tester,
  ) async {
    await pumpPhone(tester);
    final dots = find.byKey(const ValueKey('nowPlayingInfoPageDots'));
    final before = tester.getSize(dots).width;
    container.read(_decisionProvider.notifier).set(_tagged(-5));
    await tester.pumpAndSettle();
    expect(tester.getSize(dots).width, greaterThan(before));
    await tapInfo(tester);
    expect(find.text('−5.0 dB · album (Smart)'), findsOneWidget);
    container.read(_decisionProvider.notifier).set(null);
    await tester.pumpAndSettle();
    expect(find.textContaining(' dB '), findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets('holding the page opens Playback settings', (tester) async {
    await pumpPhone(tester, decision: _tagged(-6.2));
    await tapInfo(tester);
    expect(find.text('Playback settings page'), findsNothing);
    await tester.longPress(infoText);
    await tester.pumpAndSettle();
    expect(find.text('Playback settings page'), findsOneWidget);
  }, skip: !sqliteAvailable);

  testWidgets('holding Quality still opens the track info', (tester) async {
    await pumpPhone(tester, decision: _tagged(-6.2));
    await tester.longPress(find.text(quality));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mediaInfoSheet')), findsOneWidget);
    expect(find.text('Playback settings page'), findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets('the page has the hold hint and a screen-reader action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(tester, decision: _tagged(-6.2));
    await tapInfo(tester);
    final data = tester
        .getSemantics(find.text('−6.2 dB · album (Smart)'))
        .getSemanticsData();
    final labels = data.customSemanticsActionIds
        ?.map((id) => CustomSemanticsAction.getAction(id)?.label)
        .toList();
    expect(labels, contains('ReplayGain settings'));
    expect(data.hint, 'Hold for ReplayGain settings');
    handle.dispose();
  }, skip: !sqliteAvailable);
}
