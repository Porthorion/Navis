import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import '../../../../helpers/test_database.dart';

Widget _buildApp({
  required Widget child,
  required NavisDatabase database,
  required List<dynamic> overrides,
}) {
  return ProviderScope(
    overrides: [
      navisDatabaseProvider.overrideWithValue(database),
      serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
      subsonicApiProvider.overrideWith((_) => null),
      ...overrides.cast(),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drift stream disposal can schedule microtask/zero-delay timers; flush them.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  group('library detail screens', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('artist detail renders artist info and local albums', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          child: const ArtistDetailScreen(artistId: 'artist-1'),
          database: database,
          overrides: [
            artistByIdProvider('artist-1').overrideWithValue(
              const AsyncData(
                ArtistsTableData(
                  id: 'artist-1',
                  name: 'Artist 1',
                  albumCount: 1,
                ),
              ),
            ),
            albumsByArtistProvider('artist-1').overrideWithValue(
              const AsyncData(<AlbumsTableData>[
                AlbumsTableData(
                  id: 'album-1',
                  name: 'Album 1',
                  artistId: 'artist-1',
                  songsHydrated: true,
                ),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Artist'), findsOneWidget);
      expect(find.text('Artist 1'), findsOneWidget);
      expect(find.text('1 albums'), findsOneWidget);
      expect(find.text('Album 1'), findsOneWidget);
      await _disposeApp(tester);
    });

    testWidgets('album detail renders album info and local track list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          child: const AlbumDetailScreen(albumId: 'album-1'),
          database: database,
          overrides: [
            albumProvider('album-1').overrideWithValue(
              const AsyncData(
                AlbumWithSongs(
                  album: AlbumsTableData(
                    id: 'album-1',
                    name: 'Album 1',
                    artistName: 'Artist 1',
                    year: 2025,
                    songsHydrated: true,
                  ),
                  songs: <SongsTableData>[
                    SongsTableData(id: 'song-1', title: 'Song 1', track: 1),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Album'), findsOneWidget);
      expect(find.text('Album 1'), findsOneWidget);
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.textContaining('Artist 1'), findsOneWidget);
      await _disposeApp(tester);
    });
  });
}
