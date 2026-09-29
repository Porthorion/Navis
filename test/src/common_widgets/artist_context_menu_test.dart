import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';

class _QueueSpyController extends QueueController {
  List<String> replacedSongIds = const <String>[];

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    replacedSongIds = songs.map((song) => song.id).toList(growable: false);
  }
}

void main() {
  testWidgets('desktop artist actions open before local artist streams emit', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        subsonicApiProvider.overrideWithValue(null),
        playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        artistByIdProvider.overrideWith((ref, artistId) => Stream.value(null)),
      ],
    );
    addTearDown(() async {
      container.dispose();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => showArtistContextMenu(
                context,
                ref,
                'artist-1',
                anchor: const Offset(400, 200),
              ),
              child: const Text('Open desktop artist actions'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open desktop artist actions'));
    await tester.pumpAndSettle();

    expect(find.text('Open artist'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('artist actions expose playback and library controls', (
    tester,
  ) async {
    if (!sqliteAvailable) return;
    final database = createTestDatabase();
    await database
        .into(database.artistsTable)
        .insert(
          ArtistsTableCompanion.insert(
            id: 'artist-1',
            name: 'Night Harbour',
            albumCount: const Value(0),
          ),
        );
    await database
        .into(database.songsTable)
        .insert(
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Tide Lines',
            artistId: const Value('artist-1'),
          ),
        );
    late _QueueSpyController queue;
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          artistPlaybackResolverProvider.overrideWithValue(
            ArtistPlaybackResolver(
              readSnapshot: database.libraryDao.getArtistPlaybackSnapshot,
              hydrate: (_) => throw StateError('fixture is already hydrated'),
              canHydrate: () => false,
              isOffline: () => false,
              isLocallyPlayable: (_) async => true,
            ),
          ),
          queueProvider.overrideWith(() {
            queue = _QueueSpyController();
            return queue;
          }),
          subsonicApiProvider.overrideWithValue(null),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ElevatedButton(
                  onPressed: () => showArtistContextMenu(
                    context,
                    ref,
                    'artist-1',
                  ),
                  child: const Text('Artist actions'),
                ),
                ElevatedButton(
                  onPressed: () => showArtistContextMenu(
                    context,
                    ref,
                    'artist-1',
                    anchor: const Offset(120, 120),
                  ),
                  child: const Text('Desktop artist actions'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Artist actions'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 20; attempt++) {
      final playTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Play'),
      );
      if (playTile.enabled == true) break;
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(find.text('Open artist'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
    expect(find.text('Add to Queue'), findsOneWidget);
    expect(find.text('Like'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play')).enabled,
      isTrue,
    );

    await tester.tap(find.text('Play'));
    await tester.runAsync(() async {
      final done = Completer<void>();
      final subscription = container.listen(artistPlaybackControllerProvider, (
        _,
        next,
      ) {
        if (next.stage == ArtistPlaybackStage.completed && !done.isCompleted)
          done.complete();
      }, fireImmediately: true);
      await done.future.timeout(const Duration(seconds: 5));
      subscription.close();
    });
    await tester.pumpAndSettle();
    expect(queue.replacedSongIds, <String>['song-1']);

    await tester.tap(find.text('Desktop artist actions'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Open artist'), findsOneWidget);
  });
}
