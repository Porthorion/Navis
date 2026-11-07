import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/playback_surface_presentation.dart';
import 'package:navis/src/features/player/presentation/queue_shuffle_controls.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/haptics_spy.dart';
import '../../../../helpers/test_theme.dart';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

const _snapshot = PlaybackSnapshot(
  queueSongIds: <String>['song-1'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: false,
  position: Duration.zero,
  bufferedPosition: Duration.zero,
  duration: Duration.zero,
  processingState: AudioProcessingState.ready,
  repeatMode: AudioServiceRepeatMode.none,
  shuffleMode: AudioServiceShuffleMode.none,
);

Future<void> _pump(WidgetTester tester, Widget body) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      playerStateProvider.overrideWithValue(_snapshot),
      audioHandlerProvider.overrideWithValue(null),
    ],
    child: MaterialApp(
      theme: testTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: body),
    ),
  ),
);

void main() {
  testWidgets('Play presses firmly and Pause releases softly', (tester) async {
    final spy = HapticsSpy.install(tester);
    await _pump(
      tester,
      Consumer(
        builder: (context, ref, _) => Row(
          children: [
            TextButton(
              onPressed: () => togglePlayPause(ref, isPlaying: false),
              child: const Text('play'),
            ),
            TextButton(
              onPressed: () => togglePlayPause(ref, isPlaying: true),
              child: const Text('pause'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('play'));
    await tester.tap(find.text('pause'));
    await tester.pump();
    expect(await spy.take(tester), ['press', 'release']);
  });

  testWidgets('the shuffle toggle feels like a switch', (tester) async {
    final spy = HapticsSpy.install(tester);
    await _pump(tester, const QueueShuffleToggle());
    await tester.tap(find.byKey(QueueShuffleToggle.toggleKey));
    await tester.pump();
    expect(await spy.take(tester), ['toggleOn']);
  });

  testWidgets('Playback Buttons off silences Play, Pause and shuffle only', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    await _pump(
      tester,
      Consumer(
        builder: (context, ref, _) => Column(
          children: [
            TextButton(
              onPressed: () => togglePlayPause(ref, isPlaying: false),
              child: const Text('play'),
            ),
            const QueueShuffleToggle(),
          ],
        ),
      ),
    );
    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.playbackButtons.bit,
    );
    await tester.tap(find.text('play'));
    await tester.tap(find.byKey(QueueShuffleToggle.toggleKey));
    await tester.pump();
    expect(await spy.take(tester), isEmpty);

    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.playerGestures.bit,
    );
    await tester.tap(find.text('play'));
    await tester.pump();
    expect(await spy.take(tester), ['press']);
  });
}
