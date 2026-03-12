import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  _FakeLibrarySyncController(this._initialState, {this.onSyncNow});

  final LibrarySyncState _initialState;
  final VoidCallback? onSyncNow;

  @override
  LibrarySyncState build() => _initialState;

  @override
  Future<LibrarySyncState> syncIfStale() async => _initialState;

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) async {
    onSyncNow?.call();
    return _initialState;
  }
}

class _ShowRadioToggle extends Notifier<bool> {
  @override
  bool build() => true;
}

Widget _buildLibraryScreen({required List<Object?> overrides}) {
  final mergedOverrides = <Object?>[
    showRadioPageProvider.overrideWithValue(false),
    showArtistsPageProvider.overrideWithValue(true),
    showPlaylistsPageProvider.overrideWithValue(false),
    artistViewModeProvider.overrideWithValue('list'),
    ...overrides,
  ];
  return ProviderScope(
    overrides: mergedOverrides.cast(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const LibraryScreen(),
    ),
  );
}

Future<void> _switchToArtistsTab(WidgetTester tester) async {
  if (find.byKey(const Key('artistAlphabetRail')).evaluate().isNotEmpty) {
    return;
  }
  await tester.tap(find.text('Artists'));
  await tester.pumpAndSettle();
}

void main() {
  group('grid column resolver', () {
    test('computeGridCrossAxisCount uses available pane width', () {
      expect(computeGridCrossAxisCount(null, 320), 1);
      expect(computeGridCrossAxisCount(null, 520), 2);
      expect(computeGridCrossAxisCount(null, 720), 4);
      expect(computeGridCrossAxisCount(null, 980), 5);
    });

    test('density override is clamped', () {
      expect(computeGridCrossAxisCount(0, 980), 1);
      expect(computeGridCrossAxisCount(3, 980), 3);
      expect(computeGridCrossAxisCount(8, 980), 5);
    });
  });

  group('LibraryScreen', () {
    testWidgets('renders two tabs and switches between local data lists', (
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
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Artists'), findsOneWidget);
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Songs'), findsNothing);
      expect(find.text('Genres'), findsNothing);
      expect(find.text('Album 1'), findsOneWidget);

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('Artist 1'), findsOneWidget);
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
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No albums found'), findsOneWidget);

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('No artists found'), findsOneWidget);
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
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _switchToArtistsTab(tester);
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
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
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
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
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

    testWidgets('artist alphabet rail drag jumps to later sections', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        for (var i = 0; i < 26; i++)
          ArtistsTableData(
            id: 'artist-$i',
            name: '${String.fromCharCode(65 + i)} Artist',
            albumCount: 1,
          ),
      ];

      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _switchToArtistsTab(tester);

      final rail = find.byKey(const Key('artistAlphabetRail'));
      final railTopLeft = tester.getTopLeft(rail);
      final railSize = tester.getSize(rail);
      final railCenterX = railTopLeft.dx + (railSize.width / 2);
      final start = Offset(railCenterX, railTopLeft.dy + 4);
      final end = Offset(
        railCenterX,
        railTopLeft.dy + railSize.height - 4,
      );

      final gesture = await tester.startGesture(start);
      await gesture.moveTo(end);
      await gesture.up();
      await tester.pumpAndSettle();

      final jumpedToLateSection =
          find.text('X Artist').evaluate().isNotEmpty ||
          find.text('Y Artist').evaluate().isNotEmpty ||
          find.text('Z Artist').evaluate().isNotEmpty;
      expect(jumpedToLateSection, isTrue);
    });

    testWidgets('artist alphabet rail shows scrub overlay while dragging', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        for (var i = 0; i < 10; i++)
          ArtistsTableData(
            id: 'artist-$i',
            name: '${String.fromCharCode(65 + i)} Artist',
            albumCount: 1,
          ),
      ];

      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _switchToArtistsTab(tester);

      final rail = find.byKey(const Key('artistAlphabetRail'));
      final railTopLeft = tester.getTopLeft(rail);
      final railSize = tester.getSize(rail);
      final railCenterX = railTopLeft.dx + (railSize.width / 2);
      final start = Offset(railCenterX, railTopLeft.dy + 4);

      final gesture = await tester.startGesture(start);
      await tester.pump();
      expect(find.byKey(const Key('artistAlphabetOverlay')), findsOneWidget);

      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(find.byKey(const Key('artistAlphabetOverlay')), findsOneWidget);

      await gesture.up();
      await tester.pump();
      expect(find.byKey(const Key('artistAlphabetOverlay')), findsNothing);
    });

    testWidgets('artist alphabet rail only shows available artist initials', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        const ArtistsTableData(id: 'artist-a', name: 'A Artist', albumCount: 1),
        const ArtistsTableData(id: 'artist-m', name: 'M Artist', albumCount: 1),
      ];

      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _switchToArtistsTab(tester);

      expect(find.text('A'), findsWidgets);
      expect(find.text('M'), findsWidgets);
      expect(find.text('B'), findsNothing);
    });

    testWidgets('manual artist scroll updates active rail letter', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        for (var i = 0; i < 26; i++)
          ArtistsTableData(
            id: 'artist-$i',
            name: '${String.fromCharCode(65 + i)} Artist',
            albumCount: 1,
          ),
      ];

      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _switchToArtistsTab(tester);

      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();

      final active = tester.widget<Text>(
        find.byKey(const Key('artistRailActiveLetter')),
      );
      expect(active.data, isNot('A'));
    });

    testWidgets('tapping an artist rail letter jumps to its section', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        for (var i = 0; i < 26; i++)
          ArtistsTableData(
            id: 'artist-$i',
            name: '${String.fromCharCode(65 + i)} Artist',
            albumCount: 1,
          ),
      ];

      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _switchToArtistsTab(tester);

      final rail = find.byKey(const Key('artistAlphabetRail'));
      final railM = find.descendant(of: rail, matching: find.text('M'));
      expect(railM, findsOneWidget);

      await tester.tap(railM);
      await tester.pumpAndSettle();

      final active = tester.widget<Text>(
        find.byKey(const Key('artistRailActiveLetter')),
      );
      expect(active.data, 'M');
      expect(find.text('M Artist'), findsWidgets);
    });

    testWidgets('shows radio tab when enabled by settings', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            showRadioPageProvider.overrideWithValue(true),
            showArtistsPageProvider.overrideWithValue(true),
            showPlaylistsPageProvider.overrideWithValue(false),
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
            radioStationsProvider.overrideWith(
              (ref) async => const <InternetRadioStation>[],
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Radio'), findsOneWidget);
    });

    testWidgets(
      'removing radio tab while selected clamps tab index without crashing',
      (tester) async {
        final showRadioToggleProvider =
            NotifierProvider<_ShowRadioToggle, bool>(
              _ShowRadioToggle.new,
            );
        final container = ProviderContainer(
          overrides: [
            showRadioPageProvider.overrideWith(
              (ref) => ref.watch(showRadioToggleProvider),
            ),
            showArtistsPageProvider.overrideWithValue(true),
            showPlaylistsPageProvider.overrideWithValue(false),
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
            radioStationsProvider.overrideWith(
              (ref) async => const <InternetRadioStation>[],
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LibraryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Radio'), findsOneWidget);

        await tester.tap(find.text('Radio'));
        await tester.pumpAndSettle();

        container.read(showRadioToggleProvider.notifier).state = false;
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text('Radio'), findsNothing);
        expect(find.text('Artists'), findsOneWidget);
        expect(find.text('Albums'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('liked songs render desktop list rows on desktop runtime', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        _buildLibraryScreen(
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
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
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            likedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  id: 'liked-song-1',
                  title: 'Desktop Liked Song',
                  artistName: 'Desktop Artist',
                  albumName: 'Desktop Album',
                  duration: 245,
                ),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Liked'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopListRow), findsOneWidget);
      expect(find.text('Desktop Liked Song'), findsOneWidget);
    });
  });

  group('computeGridCrossAxisCount', () {
    test('returns override when provided', () {
      expect(computeGridCrossAxisCount(3, 600), 3);
    });

    test('clamps override to [1, 5]', () {
      expect(computeGridCrossAxisCount(0, 600), 1);
      expect(computeGridCrossAxisCount(10, 600), 5);
    });

    test('auto-computes from width when override is null', () {
      // 360px / 180 = 2
      expect(computeGridCrossAxisCount(null, 360), 2);
      // 900px / 180 = 5
      expect(computeGridCrossAxisCount(null, 900), 5);
    });

    test('clamps auto-computed to at least 1', () {
      expect(computeGridCrossAxisCount(null, 100), 1);
    });

    test('clamps auto-computed to at most 5', () {
      expect(computeGridCrossAxisCount(null, 2000), 5);
    });
  });
}
