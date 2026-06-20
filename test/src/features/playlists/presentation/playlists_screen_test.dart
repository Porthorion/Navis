import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/playlists/presentation/playlists_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

ListenBrainzDiscoverPlaylist _virtualPlaylist({
  required String identifier,
  required String title,
  required String sourcePatch,
  List<String> coverArts = const <String>[],
}) {
  return ListenBrainzDiscoverPlaylist(
    playlist: ListenBrainzPlaylist(
      identifier: identifier,
      title: title,
      sourcePatch: sourcePatch,
      tracks: <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(title: '$title Track'),
      ],
    ),
    recommendations: coverArts.isEmpty
        ? <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: '$title Track'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ]
        : <ListenBrainzResolvedRecommendation>[
            for (var i = 0; i < coverArts.length; i++)
              ListenBrainzResolvedRecommendation(
                track: ListenBrainzPlaylistTrack(title: '$title Track $i'),
                status: ListenBrainzRecommendationMatchStatus.matched,
                song: Song(
                  id: '$identifier-$i',
                  title: '$title Track $i',
                  coverArt: coverArts[i],
                ),
              ),
          ],
    matchingComplete: true,
  );
}

Widget _buildApp({
  required NavisDatabase database,
  required List<PlaylistLibraryItem> items,
}) {
  return ProviderScope(
    overrides: [
      navisDatabaseProvider.overrideWithValue(database),
      subsonicApiProvider.overrideWithValue(null),
      playlistSyncProvider.overrideWith((ref) async {}),
      playlistLibraryItemsProvider.overrideWithValue(
        AsyncData<List<PlaylistLibraryItem>>(items),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PlaylistsScreen(),
    ),
  );
}

void main() {
  group('PlaylistsScreen', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets(
      'renders ListenBrainz playlists before normal playlists with divider',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            database: database,
            items: <PlaylistLibraryItem>[
              PlaylistLibraryItem.virtual(
                _virtualPlaylist(
                  identifier: 'jams',
                  title: 'Weekly Jams',
                  sourcePatch: 'weekly-jams',
                ),
              ),
              const PlaylistLibraryItem.normal(
                PlaylistsTableData(id: 'server-mix', name: 'Server Mix'),
              ),
            ],
          ),
        );
        await tester.pump();

        expect(find.text('Weekly Jams'), findsOneWidget);
        expect(find.text('Server Mix'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('listenBrainzPlaylistDivider')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.text('Weekly Jams')).dy,
          lessThan(tester.getTopLeft(find.text('Server Mix')).dy),
        );
      },
    );

    testWidgets('does not render divider without a following normal playlist', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          database: database,
          items: <PlaylistLibraryItem>[
            PlaylistLibraryItem.virtual(
              _virtualPlaylist(
                identifier: 'exploration',
                title: 'Weekly Exploration',
                sourcePatch: 'weekly-exploration',
                coverArts: const <String>[
                  'cover-1',
                  'cover-2',
                  'cover-3',
                  'cover-4',
                ],
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('Weekly Exploration'), findsOneWidget);
      expect(find.byType(ListenBrainzPlaylistArtwork), findsOneWidget);
      expect(find.byType(CoverArtImage), findsNWidgets(4));
      expect(
        find.byKey(const ValueKey<String>('listenBrainzPlaylistDivider')),
        findsNothing,
      );
    });
  });
}
