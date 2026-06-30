import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';

class _QueueSpyController extends QueueController {
  _QueueSpyController(this.ids);

  final List<String> ids;
  int removeCalls = 0;
  int playCalls = 0;

  @override
  List<String> build() => ids;

  @override
  Future<void> removeAt(int index) async {
    removeCalls++;
  }

  @override
  Future<void> playFromIndex(int index) async {
    playCalls++;
  }
}

const _pendingSnapshot = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2', 'song-3'],
  currentSongId: 'song-2',
  currentIndex: 1,
  playing: true,
  processingState: AudioProcessingState.loading,
  position: Duration.zero,
  duration: Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
  isLoading: true,
  hasPendingLogicalQueue: true,
  loadingSongId: 'song-2',
);

SongsTableData _song(String id, String title) {
  return SongsTableData(
    id: id,
    title: title,
    albumId: 'album',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  );
}

Future<_QueueSpyController> _pumpQueueSheet(
  WidgetTester tester, {
  required PlaybackSnapshot snapshot,
}) async {
  final queueSpy = _QueueSpyController(snapshot.queueSongIds);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(snapshot),
        queueProvider.overrideWith(() => queueSpy),
        currentQueueSongIdProvider.overrideWithValue(snapshot.currentSongId),
        songByIdProvider.overrideWith(
          (ref, songId) => Stream.value(_song(songId, 'Track $songId')),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: QueueSheet(scrollController: ScrollController()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return queueSpy;
}

void main() {
  testWidgets('pending logical queue disables item actions while visible', (
    tester,
  ) async {
    final queueSpy = await _pumpQueueSheet(
      tester,
      snapshot: _pendingSnapshot,
    );

    expect(find.text('Track song-1'), findsOneWidget);
    expect(find.text('Track song-2'), findsOneWidget);
    expect(find.text('Track song-3'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsNothing);

    await tester.tap(find.text('Track song-2'));
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    expect(queueSpy.playCalls, 0);
    expect(queueSpy.removeCalls, 0);
  });
}
