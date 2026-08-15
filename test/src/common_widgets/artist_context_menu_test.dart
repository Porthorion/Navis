import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
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
  testWidgets('artist actions expose playback and library controls', (
    tester,
  ) async {
    if (!sqliteAvailable) return;
    final database = createTestDatabase();
    await database
        .into(database.artistsTable)
        .insert(
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Night Harbour'),
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
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Like'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play')).enabled,
      isTrue,
    );

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(queue.replacedSongIds, <String>['song-1']);

    await tester.tap(find.text('Desktop artist actions'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Open artist'), findsOneWidget);
  });
}
