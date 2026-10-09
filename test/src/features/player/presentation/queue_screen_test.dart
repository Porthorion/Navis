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
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _QueueSpyController extends QueueController {
  new(this.ids);

  final List<String> ids;
  int removeCalls = 0;
  int playCalls = 0;

  @override
  List<String> build() => ids;

  @override
  Future<void> playFromIndex(int index) async {
    playCalls++;
  }

  @override
  Future<void> removeAt(int index) async {
    removeCalls++;
  }
}

void main() {
  testWidgets(
    'full Queue blocks item actions while the queue is still loading',
    (tester) async {
      final queueSpy = _QueueSpyController(<String>['song-1', 'song-2']);
      const snapshot = PlaybackSnapshot(
        queueSongIds: <String>['song-1', 'song-2'],
        currentSongId: 'song-1',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.loading,
        position: Duration.zero,
        duration: Duration(minutes: 3),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        isLoading: true,
        hasPendingLogicalQueue: true,
        loadingSongId: 'song-1',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerStateProvider.overrideWithValue(snapshot),
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            queueProvider.overrideWith(() => queueSpy),
            songByIdProvider.overrideWith(
              (ref, songId) => Stream.value(
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: songId,
                  title: 'Track $songId',
                  albumId: 'album',
                  artistName: 'Artist',
                  albumName: 'Album',
                  duration: 180,
                ),
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

      expect(find.byType(ReorderableDragStartListener), findsNothing);

      await tester.tap(find.text('Track song-2'));
      await tester.pump();
      await tester.fling(
        find.text('Track song-2'),
        const Offset(-500, 0),
        2000,
      );
      await tester.pump(const Duration(seconds: 2));

      expect(queueSpy.playCalls, 0);
      expect(queueSpy.removeCalls, 0);
    },
  );

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
  testWidgets('phone full Queue rendering is pinned', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final queueSpy = _QueueSpyController(<String>[
      'song-1',
      'song-2',
      'song-3',
    ]);
    const snapshot = PlaybackSnapshot(
      queueSongIds: <String>['song-1', 'song-2', 'song-3'],
      currentSongId: 'song-2',
      currentIndex: 1,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration(minutes: 3),
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(snapshot),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          queueProvider.overrideWith(() => queueSpy),
          songByIdProvider.overrideWith(
            (ref, songId) => songId == 'song-3'
                ? Stream<SongsTableData?>.error(StateError('lookup failed'))
                : Stream.value(
                    SongsTableData(
                      isProvisional: false,
                      isExternal: songId == 'song-1',
                      id: songId,
                      title: 'Track $songId',
                      albumId: 'album',
                      artistName: 'Artist',
                      albumName: 'Album',
                      duration: 180,
                    ),
                  ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RepaintBoundary(
            key: ValueKey('queue-screen-golden'),
            child: QueueScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await expectLater(
      find.byKey(const ValueKey('queue-screen-golden')),
      matchesGoldenFile('goldens/queue_screen_phone_390x844.png'),
    );
  });
}
