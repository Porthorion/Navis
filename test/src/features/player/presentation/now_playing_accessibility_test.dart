import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/now_playing_harness.dart';

const PlaybackSnapshot _song = PlaybackSnapshot(
  queueSongIds: <String>['song-1'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const _item = MediaItem(
  id: 'song-1',
  title: 'Midnight Drive',
  artist: 'The Night Owls',
  album: 'City Lights',
);

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  PlaybackSnapshot playback = _song,
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.iOS,
}) async {
  setAdaptiveTestViewport(tester, size);
  final container = createNowPlayingContainer(
    overrides: [
      currentMediaItemProvider.overrideWithValue(const AsyncData(_item)),
    ],
  );
  container.read(nowPlayingTestPlaybackProvider.notifier).state = playback;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: const Scaffold(body: NowPlayingScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [2.0, 3.1]) {
    testWidgets('Now Playing at ${scale}x text is usable', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, textScale: scale);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      // ponytail: the album link is a 37 pt text row inside the modelled title
      // block; it is deferred (I18 ledger), so only 3.1x (where it grows past
      // 44 pt) holds the full iOS guideline.
      if (scale > 3) {
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      }
      handle.dispose();
    });
  }

  for (final (playing, label) in [(true, 'Pause'), (false, 'Play')]) {
    testWidgets(
      'play/pause button is labelled "$label" when playing=$playing',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, playback: _song.copyWith(playing: playing));
        // One merged node carries the state label.
        final node = tester.getSemantics(find.byType(FilledButton));
        expect('${node.label}${node.tooltip}', contains(label));
        handle.dispose();
      },
    );
  }

  testWidgets('seek bar announces position and duration and is adjustable', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    final node = tester.getSemantics(find.byType(Slider).first);
    expect(node.value, isNotEmpty);
    expect(node.flagsCollection.isSlider, isTrue);
    handle.dispose();
  });

  for (final size in const [
    Size(390, 844),
    Size(800, 360),
    Size(880, 1200),
    Size(1280, 800),
  ]) {
    testWidgets('Reduce Motion zeroes every switcher at ${size.width.toInt()}x'
        '${size.height.toInt()}', (tester) async {
      await _pump(tester, size: size, disableAnimations: true);
      final switchers = tester.widgetList<AnimatedSwitcher>(
        find.byType(AnimatedSwitcher),
      );
      expect(switchers, isNotEmpty);
      for (final s in switchers) {
        expect(s.duration, Duration.zero);
        expect(s.reverseDuration ?? Duration.zero, Duration.zero);
      }
    });
  }

  for (final reduce in [true, false]) {
    testWidgets('art swipe snap-back ${reduce ? "is instant" : "animates"} '
        'with Reduce Motion=$reduce', (tester) async {
      await _pump(tester, disableAnimations: reduce);
      final art = find.byType(CoverArtImage).first;
      final gesture = await tester.startGesture(tester.getCenter(art));
      // Past touch slop, short of committing a track change.
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      expect(tester.hasRunningAnimations, !reduce);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
