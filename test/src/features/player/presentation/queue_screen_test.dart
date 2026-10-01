import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

class _QueueSpyController extends QueueController {
  new(this.ids);

  final List<String> ids;
  int removeCalls = 0;

  @override
  List<String> build() => ids;

  @override
  Future<void> removeAt(int index) async {
    removeCalls++;
  }
}

void main() {
  testWidgets('full Queue uses safe load-error copy and permits removal', (
    tester,
  ) async {
    final queueSpy = _QueueSpyController(<String>['failed-song']);
    const snapshot = PlaybackSnapshot(
      queueSongIds: <String>['failed-song'],
      currentSongId: 'failed-song',
      currentIndex: 0,
      playing: false,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(snapshot),
          queueProvider.overrideWith(() => queueSpy),
          currentQueueSongIdProvider.overrideWithValue(snapshot.currentSongId),
          songByIdProvider.overrideWith(
            (ref, songId) => Stream<SongsTableData?>.error(
              StateError('Local metadata lookup failed.'),
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const QueueScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Error loading track'), findsOneWidget);
    expect(
      find.text(
        "This track couldn't be loaded. You can remove it from the queue or try again later.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Local metadata lookup failed'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(queueSpy.removeCalls, 1);
  });
}
