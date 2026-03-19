import 'dart:async';

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
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

class _FixedLibrarySyncController extends LibrarySyncController {
  _FixedLibrarySyncController(this._fixedState);

  final LibrarySyncState _fixedState;

  @override
  LibrarySyncState build() => _fixedState;

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return _fixedState;
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) async {
    return _fixedState;
  }
}

class _PendingRefreshLibrarySyncController extends LibrarySyncController {
  int syncNowCalls = 0;
  Completer<LibrarySyncState> _completer = Completer<LibrarySyncState>();

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) {
    syncNowCalls++;
    return _completer.future;
  }

  void complete([LibrarySyncState state = const LibrarySyncState.idle()]) {
    if (!_completer.isCompleted) {
      _completer.complete(state);
    }
    _completer = Completer<LibrarySyncState>();
  }
}

Future<void> _pumpHomeWithSyncState(
  WidgetTester tester,
  LibrarySyncState syncState,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        librarySyncControllerProvider.overrideWith(
          () => _FixedLibrarySyncController(syncState),
        ),
        homeLikedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        likedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRecentlyPlayedAlbumsProvider.overrideWithValue(
          const AsyncData(<AlbumsTableData>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomShowcaseProvider.overrideWith(
          (ref, filters) async => const <HomeRandomShowcaseAlbum>[],
        ),
        homeMostPlayedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        likedAlbumsRecentProvider.overrideWithValue(
          const AsyncData(<AlbumsTableData>[]),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpHomeWithControllerOverride(
  WidgetTester tester, {
  required LibrarySyncController Function() createController,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        librarySyncControllerProvider.overrideWith(createController),
        homeLikedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        likedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRecentlyPlayedAlbumsProvider.overrideWithValue(
          const AsyncData(<AlbumsTableData>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomShowcaseProvider.overrideWith(
          (ref, filters) async => const <HomeRandomShowcaseAlbum>[],
        ),
        homeMostPlayedSongsProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        likedAlbumsRecentProvider.overrideWithValue(
          const AsyncData(<AlbumsTableData>[]),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
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
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
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
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
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
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) async => const <HomeRandomShowcaseAlbum>[
              HomeRandomShowcaseAlbum(
                id: 'album-3',
                name: 'Random long album title for constrained card layout',
                artist: 'Overflow Tester',
                coverArtId: 'cover-album-3',
                source: HomeRandomShowcaseSource.serverRandom,
              ),
            ],
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
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[
              AlbumsTableData(
                id: 'album-4',
                name: 'Liked album title',
                artistName: 'Favorite Artist',
                coverArt: 'cover-album-4',
                songsHydrated: false,
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

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -640));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home renders tablet layout without overflow', (tester) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) async => const <HomeRandomShowcaseAlbum>[],
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'default home shows default-on sections and keeps optional sections hidden',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            homeRecentlyAddedProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRecentlyPlayedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            homeRandomAlbumsProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRandomShowcaseProvider.overrideWith(
              (ref, filters) async => const <HomeRandomShowcaseAlbum>[],
            ),
            homeMostPlayedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const HomeScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Recently liked albums'), findsOneWidget);
      expect(find.text('Quick actions'), findsOneWidget);
      expect(find.text('Recently played tracks'), findsNothing);
    },
  );

  testWidgets('random section renders dedicated hero carousel', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                homeSectionsHidden: <String>[],
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) async => const <HomeRandomShowcaseAlbum>[
              HomeRandomShowcaseAlbum(
                id: 'hero-1',
                name: 'Hero One',
                artist: 'Artist One',
                coverArtId: 'cover-hero-1',
                source: HomeRandomShowcaseSource.serverRandom,
              ),
              HomeRandomShowcaseAlbum(
                id: 'hero-2',
                name: 'Hero Two',
                artist: 'Artist Two',
                coverArtId: 'cover-hero-2',
                source: HomeRandomShowcaseSource.serverRandom,
              ),
            ],
          ),
          homeLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home-random-hero-carousel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-random-hero-carousel-page-0')),
      findsOneWidget,
    );
  });

  testWidgets(
    'random hero carousel auto-advances and pauses after interaction',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                  homeSectionsHidden: <String>[],
                ),
              ),
            ),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeRandomShowcaseProvider.overrideWith(
              (ref, filters) async => const <HomeRandomShowcaseAlbum>[
                HomeRandomShowcaseAlbum(
                  id: 'hero-1',
                  name: 'Hero One',
                  artist: 'Artist One',
                  coverArtId: 'cover-hero-1',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
                HomeRandomShowcaseAlbum(
                  id: 'hero-2',
                  name: 'Hero Two',
                  artist: 'Artist Two',
                  coverArtId: 'cover-hero-2',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
                HomeRandomShowcaseAlbum(
                  id: 'hero-3',
                  name: 'Hero Three',
                  artist: 'Artist Three',
                  coverArtId: 'cover-hero-3',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
              ],
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            homeRecentlyAddedProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRecentlyPlayedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            homeMostPlayedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const HomeScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      Finder pageKeyFinder() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('home-random-hero-carousel-page-');
      });
      String currentPageKey() {
        final widget = tester.widget(pageKeyFinder());
        final key = widget.key;
        expect(key, isA<ValueKey<String>>());
        return (key! as ValueKey<String>).value;
      }

      final initialPage = currentPageKey();
      expect(initialPage, 'home-random-hero-carousel-page-0');

      await tester.pump(const Duration(milliseconds: 4700));
      await tester.pump(const Duration(milliseconds: 520));
      final afterAutoAdvance = currentPageKey();
      expect(afterAutoAdvance, isNot(initialPage));

      await tester.drag(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        const Offset(-260, 0),
      );
      await tester.pumpAndSettle();
      final afterDrag = currentPageKey();

      await tester.pump(const Duration(milliseconds: 1500));
      expect(currentPageKey(), afterDrag);

      await tester.pump(const Duration(milliseconds: 3000));
      await tester.pump(const Duration(milliseconds: 520));
      expect(currentPageKey(), isNot(afterDrag));
    },
  );

  testWidgets('shows determinate sync ring around logo while syncing', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
        processed: 3,
        total: 10,
      ),
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, closeTo(0.3, 0.001));

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    expect(
      find.bySemanticsLabel(l10n.librarySyncRunningWithProgress(3, 10)),
      findsOneWidget,
    );
  });

  testWidgets('shows indeterminate sync ring when progress is unknown', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.preparing,
      ),
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, isNull);

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    expect(find.bySemanticsLabel(l10n.librarySyncRunning), findsOneWidget);
  });

  testWidgets('shows subtle failure ring on sync failure', (tester) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.completed,
      ),
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, 1);

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    expect(
      indicator.color,
      theme.colorScheme.error.withValues(alpha: 0.65),
    );
    expect(
      find.bySemanticsLabel(l10n.syncSettingsStatusFailed),
      findsOneWidget,
    );
  });

  testWidgets('hides sync ring when idle, succeeded, or skipped', (
    tester,
  ) async {
    final states = <LibrarySyncState>[
      const LibrarySyncState.idle(),
      const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      ),
      const LibrarySyncState(
        status: LibrarySyncStatus.skipped,
        stage: LibrarySyncStage.completed,
      ),
    ];

    for (final state in states) {
      await _pumpHomeWithSyncState(tester, state);
      final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
      expect(ring, findsOneWidget);
      final ringOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: ring,
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(ringOpacity.opacity, 0);
    }
  });

  testWidgets(
    'shows immediate indeterminate ring when pull-to-refresh triggers before sync state updates',
    (tester) async {
      if (isDesktopRuntime) {
        // Home custom pull-to-refresh is mobile/tablet-only.
        return;
      }
      final controller = _PendingRefreshLibrarySyncController();
      await _pumpHomeWithControllerOverride(
        tester,
        createController: () => controller,
      );

      await tester.drag(find.byType(ListView).first, const Offset(0, 340));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(controller.syncNowCalls, 1);
      final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
      expect(ring, findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(ring);
      expect(indicator.value, isNull);

      final ringOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: ring,
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(ringOpacity.opacity, 1);

      controller.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      final ringOpacityAfter = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: ring,
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(ringOpacityAfter.opacity, 0);
    },
  );

  group('HomeSectionIds', () {
    test('defaultOrder contains all section IDs', () {
      expect(
        HomeSectionIds.defaultOrder,
        containsAll(<String>[
          HomeSectionIds.quickActions,
          HomeSectionIds.recentlyLikedAlbums,
          HomeSectionIds.likedTracks,
          HomeSectionIds.recentlyAdded,
          HomeSectionIds.recentlyPlayed,
          HomeSectionIds.randomAlbums,
          HomeSectionIds.mostPlayed,
          HomeSectionIds.recentlyPlayedTracks,
          HomeSectionIds.frequentAlbums,
        ]),
      );
    });

    test('random albums is first in defaultOrder', () {
      expect(HomeSectionIds.defaultOrder.first, HomeSectionIds.randomAlbums);
    });

    test('defaultOrder has no duplicates', () {
      expect(
        HomeSectionIds.defaultOrder.toSet().length,
        HomeSectionIds.defaultOrder.length,
      );
    });

    test('defaultHidden marks optional sections as hidden', () {
      expect(
        HomeSectionIds.defaultHidden,
        containsAll(<String>[
          HomeSectionIds.recentlyPlayedTracks,
          HomeSectionIds.frequentAlbums,
        ]),
      );
      expect(
        HomeSectionIds.defaultHidden,
        isNot(contains(HomeSectionIds.quickActions)),
      );
    });
  });
}
