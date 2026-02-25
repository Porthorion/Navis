import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({bool forceFull = false}) async {
    return const LibrarySyncState.idle();
  }
}

void main() {
  testWidgets('home cards avoid RenderFlex overflow on constrained layouts', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(360, 640);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[
              SongsTableData(
                id: 'song-1',
                title: 'A very long song title that should ellipsize correctly',
                artistName:
                    'An artist with a very long display name for overflow testing',
                coverArt: 'cover-song-1',
              ),
            ]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[
              Album(
                id: 'album-1',
                name:
                    'A very long album title that should not overflow the card',
                artist:
                    'An artist with a very long display name for overflow testing',
                coverArt: 'cover-album-1',
              ),
            ]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[
              AlbumsTableData(
                id: 'album-2',
                name: 'Another very long album title for recent section',
                artistName: 'Overflow Tester',
                coverArt: 'cover-album-2',
                songsHydrated: false,
              ),
            ]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[
              Album(
                id: 'album-3',
                name: 'Random long album title for constrained card layout',
                artist: 'Overflow Tester',
                coverArt: 'cover-album-3',
              ),
            ]),
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[
              SongsTableData(
                id: 'song-2',
                title: 'A very long most-played song title to stress layout',
                artistName: 'Overflow Tester',
                coverArt: 'cover-song-2',
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            );
          },
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('Liked tracks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
