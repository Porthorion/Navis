import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  _FakeLibrarySyncController(this._initialState, {this.onSyncNow});

  final LibrarySyncState _initialState;
  final VoidCallback? onSyncNow;

  @override
  LibrarySyncState build() => _initialState;

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
  }) async => _initialState;

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    Iterable<String> priorityAlbumIds = const <String>[],
  }) async {
    onSyncNow?.call();
    return _initialState;
  }
}

Widget _buildLibraryScreen({required List<dynamic> overrides}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const LibraryScreen(),
    ),
  );
}

void main() {
  group('LibraryScreen', () {
    testWidgets('renders four tabs and switches between local data lists', (
      tester,
    ) async {
      var syncNowCalls = 0;
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onSyncNow: () => syncNowCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[
                ArtistsTableData(
                  id: 'artist-1',
                  name: 'Artist 1',
                  albumCount: 1,
                ),
              ]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(1)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(
                const <AlbumsTableData>[
                  AlbumsTableData(
                    id: 'album-1',
                    name: 'Album 1',
                    artistName: 'Artist 1',
                    songsHydrated: true,
                  ),
                ],
              ),
            ),
            songsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  id: 'song-1',
                  title: 'Song 1',
                  albumName: 'Album 1',
                  artistName: 'Artist 1',
                ),
              ]),
            ),
            genresProvider.overrideWithValue(
              const AsyncData(<GenresTableData>[
                GenresTableData(name: 'Rock', albumCount: 1, songCount: 1),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Artists'), findsOneWidget);
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Songs'), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
      expect(find.text('Artist 1'), findsOneWidget);

      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(find.text('Album 1'), findsOneWidget);

      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(find.text('Song 1'), findsOneWidget);

      await tester.tap(find.text('Genres'));
      await tester.pumpAndSettle();
      expect(find.text('Rock'), findsOneWidget);
      expect(syncNowCalls, 0);
    });

    testWidgets('shows empty states across all tabs', (tester) async {
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            genresProvider.overrideWithValue(
              const AsyncData(<GenresTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No artists found'), findsOneWidget);

      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(find.text('No albums found'), findsOneWidget);

      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(find.text('No songs found'), findsOneWidget);

      await tester.tap(find.text('Genres'));
      await tester.pumpAndSettle();
      expect(find.text('No genres found'), findsOneWidget);
    });

    testWidgets('shows error state and retry action triggers syncNow', (
      tester,
    ) async {
      var syncNowCalls = 0;
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onSyncNow: () => syncNowCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              AsyncError<List<ArtistsTableData>>(
                Exception('artists failed'),
                StackTrace.empty,
              ),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            genresProvider.overrideWithValue(
              const AsyncData(<GenresTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ErrorState), findsOneWidget);
      expect(find.text('Could not load artists'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(syncNowCalls, 1);
    });

    testWidgets('pull-to-refresh dispatches syncNow', (tester) async {
      var syncNowCalls = 0;
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onSyncNow: () => syncNowCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[
                ArtistsTableData(
                  id: 'artist-1',
                  name: 'Artist 1',
                  albumCount: 1,
                ),
              ]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            genresProvider.overrideWithValue(
              const AsyncData(<GenresTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final refreshIndicator = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator).first,
      );
      await refreshIndicator.onRefresh();

      expect(syncNowCalls, 1);
    });

    testWidgets('sync banner shows metadata-ready hydration progress', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.fetchingSongs,
                  metadataReady: true,
                  processed: 5,
                  total: 10,
                  pendingHydrationCount: 5,
                  hydrationThroughputAlbumsPerSecond: 2.5,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            genresProvider.overrideWithValue(
              const AsyncData(<GenresTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Metadata ready. Hydrating songs (5/10, 5 remaining, 2.5 albums/s)',
        ),
        findsOneWidget,
      );
    });
  });
}
