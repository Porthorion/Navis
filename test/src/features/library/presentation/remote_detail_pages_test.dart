import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

const _remoteArtistId = 'ext-deezer-artist-4321';
const _remoteAlbumId = 'ext-deezer-album-302127';

const _mobileContext = AdaptiveContext(
  desktopRuntime: false,
  desktopWide: false,
  desktopLayoutClass: DesktopLayoutClass.compactDesktop,
  adaptiveLayoutClass: AdaptiveLayoutClass.phoneCompact,
  adaptiveShellMode: AdaptiveShellMode.phoneBottomNav,
  isPhoneFormFactor: true,
  useDesktopShell: false,
  useStandardRailNavigation: false,
  useCompactWideLandscape: false,
  useRailNavigation: false,
);

const _desktopContext = AdaptiveContext(
  desktopRuntime: true,
  desktopWide: true,
  desktopLayoutClass: DesktopLayoutClass.standardDesktop,
  adaptiveLayoutClass: AdaptiveLayoutClass.tabletExpanded,
  adaptiveShellMode: AdaptiveShellMode.standardRail,
  isPhoneFormFactor: false,
  useDesktopShell: true,
  useStandardRailNavigation: false,
  useCompactWideLandscape: false,
  useRailNavigation: false,
);

const _succeeded = LibrarySyncState(
  status: LibrarySyncStatus.succeeded,
  stage: LibrarySyncStage.completed,
);
const _failed = LibrarySyncState(
  status: LibrarySyncStatus.failed,
  stage: LibrarySyncStage.completed,
);

/// A sync controller whose page hydrations the test answers: each request
/// is recorded and waits on its own completer.
class _ScriptedSync extends LibrarySyncController {
  new(this.script);

  final _HydrationScript script;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState?> hydrateOpenedArtist(String artistId) =>
      script.next('open-artist:$artistId');

  @override
  Future<LibrarySyncState?> hydrateOpenedAlbum(String albumId) =>
      script.next('open-album:$albumId');

  @override
  bool artistConfirmedWithoutAlbums(String artistId) =>
      script.confirmedEmpty.contains(artistId);

  @override
  Future<LibrarySyncState> refreshArtist(String artistId) async =>
      (await script.next('refresh-artist:$artistId'))!;

  @override
  Future<LibrarySyncState> requestTarget(LibrarySyncTarget target) async =>
      (await script.next('refresh-${target.kind.name}:${target.entityId}'))!;
}

class _HydrationScript {
  final List<String> calls = <String>[];

  /// Artists the controller remembers as confirmed without albums.
  final Set<String> confirmedEmpty = <String>{};
  final List<Completer<LibrarySyncState?>> pending =
      <Completer<LibrarySyncState?>>[];

  Future<LibrarySyncState?> next(String call) {
    calls.add(call);
    final completer = Completer<LibrarySyncState?>();
    pending.add(completer);
    return completer.future;
  }

  /// Answers the oldest unanswered request.
  void answer(LibrarySyncState? result) {
    pending.removeAt(0).complete(result);
  }
}

void main() {
  late NavisDatabase database;
  late _HydrationScript script;

  setUp(() {
    database = createTestDatabase();
    script = _HydrationScript();
  });
  tearDown(() async => database.close());

  GoRouter router() => GoRouter(
    initialLocation: AppRoutes.library,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, _) => const Scaffold(body: Text('LibraryScreen')),
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.artistSegment,
            builder: (_, state) => ArtistDetailScreen(
              artistId: state.pathParameters['id']!,
              nameHint: state.uri.queryParameters[AppRoutes.detailNameParam],
            ),
          ),
          GoRoute(
            path: AppRoutes.albumSegment,
            builder: (_, state) => AlbumDetailScreen(
              albumId: state.pathParameters['id']!,
              nameHint: state.uri.queryParameters[AppRoutes.detailNameParam],
              artistNameHint:
                  state.uri.queryParameters[AppRoutes.detailArtistParam],
            ),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.search,
        builder: (_, _) => const Scaffold(body: Text('SearchScreen')),
      ),
    ],
  );

  late GoRouter currentRouter;
  late ProviderContainer container;
  late AppNoticeController notices;

  Future<void> open(
    WidgetTester tester,
    String location, {
    AdaptiveContext adaptiveContext = _mobileContext,
    List<dynamic> overrides = const <dynamic>[],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = adaptiveContext.useDesktopShell
        ? const Size(1280, 1000)
        : const Size(390, 1600);
    addTearDown(tester.view.reset);
    // The album page's refresh plays a haptic first.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    currentRouter = router();
    notices = AppNoticeController();
    addTearDown(notices.dispose);
    container = ProviderContainer(
      overrides: [
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        subsonicApiProvider.overrideWith((_) => null),
        connectivityProvider.overrideWith(
          (_) =>
              Stream.value(const <ConnectivityResult>[ConnectivityResult.wifi]),
        ),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        librarySyncControllerProvider.overrideWith(() => _ScriptedSync(script)),
        artistTopTrackSeedsProvider.overrideWith(
          (ref, key) async => const <ArtistTopTrackSeed>[],
        ),
        artistDeezerIdProvider.overrideWith((ref, key) async => null),
        // The page's album buckets stream throttles on timers that fake
        // time does not drive reliably; the artist's stored albums stand in.
        artistAlbumSectionsProvider.overrideWith(
          (ref, artistId) => database.libraryDao
              .watchAlbumsByArtist(artistId)
              .map((albums) => ArtistAlbumSections(albums: albums)),
        ),
        ...overrides.cast(),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: AdaptiveContextScope(
          adaptiveContext: adaptiveContext,
          child: AppNoticeScope(
            notifier: notices,
            child: MaterialApp.router(
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: currentRouter,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(currentRouter.push<void>(location));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Lets drift streams and the page's settle reads catch up; the loading
  /// page's spinner never settles, so frames are pumped by time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> storeRemoteArtist({bool withAlbum = true}) async {
    await database.libraryDao.upsertProvisionalArtists([
      ArtistsTableCompanion.insert(
        id: _remoteArtistId,
        name: 'Coldrain',
        albumCount: Value(withAlbum ? 1 : 0),
        isExternal: const Value(true),
      ),
    ]);
    if (!withAlbum) return;
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: _remoteAlbumId,
        name: 'The Side Effects',
        artistId: const Value(_remoteArtistId),
        artistName: const Value('Coldrain'),
        year: const Value(2019),
        isExternal: const Value(true),
      ),
    ]);
  }

  Future<void> storeRemoteAlbum({required bool withSongs}) async {
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: _remoteAlbumId,
        name: 'The Side Effects',
        artistName: const Value('Coldrain'),
        year: const Value(2019),
        isExternal: const Value(true),
        songsHydrated: Value(withSongs),
      ),
    ]);
    if (!withSongs) return;
    await database.libraryDao.upsertProvisionalSongs([
      for (var track = 1; track <= 2; track++)
        SongsTableCompanion.insert(
          id: 'ext-deezer-song-$track',
          title: track == 1 ? 'Mayday' : 'Speak',
          albumId: const Value(_remoteAlbumId),
          artistName: const Value('Coldrain'),
          track: Value(track),
          isExternal: const Value(true),
        ),
    ]);
  }

  final loading = find.byKey(DetailLoadingView.loadingKey);
  final failed = find.byKey(DetailLoadFailedView.failedKey);

  test('only a successful hydration confirms; failures are named', () {
    for (final status in LibrarySyncStatus.values) {
      final result = LibrarySyncState(
        status: status,
        stage: LibrarySyncStage.completed,
      );
      expect(
        detailHydrationConfirmed(result),
        status == LibrarySyncStatus.succeeded,
        reason: '$status',
      );
      expect(
        detailHydrationFailed(result),
        status == LibrarySyncStatus.failed ||
            status == LibrarySyncStatus.cancelled ||
            status == LibrarySyncStatus.deferred,
        reason: '$status',
      );
    }
    // No request confirms nothing and reports no failure.
    expect(detailHydrationConfirmed(null), isFalse);
    expect(detailHydrationFailed(null), isFalse);
  });

  group('remote artist page', () {
    testWidgets(
      'loads with its name, a back button and the Remote mark, never "Not Found"',
      (tester) async {
        await open(tester, AppRoutes.artist(_remoteArtistId, name: 'Coldrain'));
        await settle(tester);

        expect(loading, findsOneWidget);
        expect(find.text('Loading Remote Artist…'), findsOneWidget);
        expect(find.text('Coldrain'), findsWidgets);
        expect(find.byType(RemoteSourceIndicator), findsOneWidget);
        expect(find.text('Artist Not Found'), findsNothing);
        expect(script.calls, ['open-artist:$_remoteArtistId']);

        await tester.tap(find.byType(BackButton));
        await settle(tester);
        expect(find.text('LibraryScreen'), findsOneWidget);
        await dispose(tester);
      },
    );

    testWidgets(
      'shows the artist and albums once stored, before its other sections',
      (tester) async {
        final info = Completer<ArtistInfo?>();
        await open(
          tester,
          AppRoutes.artist(_remoteArtistId, name: 'Coldrain'),
          overrides: [
            artistInfoProvider(_remoteArtistId)
                .overrideWith((ref) => info.future),
          ],
        );
        await settle(tester);
        expect(loading, findsOneWidget);
        await storeRemoteArtist();
        script.answer(_succeeded);
        await settle(tester);
        expect(loading, findsNothing);
        expect(find.byKey(detailPageShownKey), findsOneWidget);
        expect(find.text('Albums'), findsOneWidget);
        expect(find.text('The Side Effects'), findsOneWidget);
        // The artist info is still loading: the page did not wait for it.
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        await dispose(tester);
      },
    );

    testWidgets('a remote artist the library already holds shows at once', (
      tester,
    ) async {
      await storeRemoteArtist();
      await open(tester, AppRoutes.artist(_remoteArtistId));
      await settle(tester);

      expect(loading, findsNothing);
      expect(find.text('The Side Effects'), findsOneWidget);
      expect(find.byType(RemoteSourceIndicator), findsWidgets);
      await dispose(tester);
    });

    testWidgets('Refresh fetches the artist again', (tester) async {
      await storeRemoteArtist();
      await open(tester, AppRoutes.artist(_remoteArtistId));
      script.answer(null);
      await settle(tester);

      await tester.tap(find.byKey(DetailRefreshButton.buttonKey));
      await tester.pump();
      expect(script.calls, [
        'open-artist:$_remoteArtistId',
        'refresh-artist:$_remoteArtistId',
      ]);
      script.answer(_succeeded);
      await settle(tester);
      expect(find.text('The Side Effects'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('a failure offers Retry and a search for the name', (
      tester,
    ) async {
      await open(tester, AppRoutes.artist(_remoteArtistId, name: 'Coldrain'));
      script.answer(_failed);
      await settle(tester);

      expect(loading, findsNothing);
      expect(failed, findsOneWidget);
      expect(find.text('Could Not Load This Artist'), findsOneWidget);
      expect(find.text('Artist Not Found'), findsNothing);

      // Retry fetches again and shows the artist once it is stored.
      await tester.tap(find.byKey(DetailLoadFailedView.retryKey));
      await tester.pump();
      expect(script.calls.last, 'refresh-artist:$_remoteArtistId');
      expect(loading, findsOneWidget);
      script.answer(_failed);
      await settle(tester);
      expect(failed, findsOneWidget);

      await tester.tap(find.byKey(DetailLoadFailedView.searchKey));
      await settle(tester);
      expect(find.text('SearchScreen'), findsOneWidget);
      expect(container.read(searchQueryProvider), 'Coldrain');
      expect(container.read(searchFilterProvider), SearchResultType.artists);
      await dispose(tester);
    });

    testWidgets('an artist confirmed empty earlier this session reopens '
        'empty without a request', (tester) async {
      await storeRemoteArtist(withAlbum: false);
      // An earlier open this session confirmed it; this open needs none.
      script.confirmedEmpty.add(_remoteArtistId);
      await open(tester, AppRoutes.artist(_remoteArtistId));
      script.answer(null);
      await settle(tester);

      expect(failed, findsNothing);
      expect(find.text('No Albums for This Artist'), findsOneWidget);
      expect(script.calls, <String>['open-artist:$_remoteArtistId']);
      await dispose(tester);
    });

    testWidgets('an artist the server confirms has no albums still shows', (
      tester,
    ) async {
      await open(tester, AppRoutes.artist(_remoteArtistId));
      await storeRemoteArtist(withAlbum: false);
      script.answer(_succeeded);
      await settle(tester);

      expect(loading, findsNothing);
      expect(failed, findsNothing);
      expect(find.text('No Albums for This Artist'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets(
      'a stored remote artist without albums fails rather than showing none',
      (tester) async {
        await storeRemoteArtist(withAlbum: false);
        await open(tester, AppRoutes.artist(_remoteArtistId));
        await settle(tester);
        // The stored name fills in while the albums load.
        expect(loading, findsOneWidget);
        expect(find.text('Coldrain'), findsWidgets);

        script.answer(_failed);
        await settle(tester);
        expect(failed, findsOneWidget);
        expect(find.text('No Albums for This Artist'), findsNothing);
        expect(find.text('Search for Coldrain'), findsOneWidget);
        await dispose(tester);
      },
    );

    for (final (label, result) in <(String, LibrarySyncState?)>[
      ('no request', null),
      (
        'a partial one',
        const LibrarySyncState(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
        ),
      ),
    ]) {
      testWidgets(
        'a remote artist without albums after $label is not shown as empty',
        (tester) async {
          await storeRemoteArtist(withAlbum: false);
          await open(tester, AppRoutes.artist(_remoteArtistId));
          script.answer(result);
          await settle(tester);

          expect(failed, findsOneWidget);
          expect(find.text('No Albums for This Artist'), findsNothing);
          expect(find.byKey(DetailLoadFailedView.retryKey), findsOneWidget);
          expect(find.text('Search for Coldrain'), findsOneWidget);
          await dispose(tester);
        },
      );
    }

    testWidgets('a hydration that throws shows Retry and search', (
      tester,
    ) async {
      await open(tester, AppRoutes.artist(_remoteArtistId, name: 'Coldrain'));
      script.pending.removeAt(0).completeError(StateError('engine broke'));
      await settle(tester);

      expect(failed, findsOneWidget);
      expect(find.text('Search for Coldrain'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets(
      'albums that cannot be read show Retry and search once the request ends',
      (tester) async {
        await storeRemoteArtist(withAlbum: false);
        await open(
          tester,
          AppRoutes.artist(_remoteArtistId),
          overrides: [
            artistAlbumSectionsProvider(_remoteArtistId).overrideWith(
              (ref) => Stream<ArtistAlbumSections>.error(StateError('db')),
            ),
          ],
        );
        await settle(tester);
        // The request is still running: nothing to fail yet.
        expect(loading, findsOneWidget);

        script.answer(_succeeded);
        await settle(tester);
        expect(failed, findsOneWidget);
        expect(find.text('Search for Coldrain'), findsOneWidget);
        await dispose(tester);
      },
    );

    testWidgets('an artist that cannot be read shows Retry and search', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.artist(_remoteArtistId, name: 'Coldrain'),
        overrides: [
          artistByIdProvider(_remoteArtistId).overrideWith(
            (ref) => Stream<ArtistsTableData?>.error(StateError('db')),
          ),
        ],
      );
      await settle(tester);

      expect(failed, findsOneWidget);
      expect(find.text('Search for Coldrain'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets(
      'a library artist that is not stored loads from the server, then fails',
      (tester) async {
        await open(tester, AppRoutes.artist('ar-1'));
        await settle(tester);
        expect(find.text('Loading Artist…'), findsOneWidget);
        expect(find.byType(RemoteSourceIndicator), findsNothing);

        // No server signed in: no hydration ran, and the artist is missing.
        script.answer(null);
        await settle(tester);
        expect(failed, findsOneWidget);
        // Without a name there is nothing to search for.
        expect(find.byKey(DetailLoadFailedView.searchKey), findsNothing);
        expect(find.byKey(DetailLoadFailedView.retryKey), findsOneWidget);
        await dispose(tester);
      },
    );

    testWidgets('desktop keeps the back button and Refresh while loading', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.artist(_remoteArtistId, name: 'Coldrain'),
        adaptiveContext: _desktopContext,
      );
      await settle(tester);

      expect(loading, findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byKey(DetailRefreshButton.buttonKey), findsOneWidget);
      await dispose(tester);
    });
  });

  group('remote album page', () {
    testWidgets('loads with its title, then shows its tracks once stored', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.album(
          _remoteAlbumId,
          name: 'The Side Effects',
          artistName: 'Coldrain',
        ),
      );
      await settle(tester);

      expect(loading, findsOneWidget);
      expect(find.byKey(detailPageShownKey), findsNothing);
      expect(find.text('Loading Remote Album…'), findsOneWidget);
      expect(find.text('The Side Effects'), findsWidgets);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('Album Not Found'), findsNothing);
      expect(script.calls, ['open-album:$_remoteAlbumId']);

      await storeRemoteAlbum(withSongs: true);
      script.answer(_succeeded);
      await settle(tester);

      expect(loading, findsNothing);
      // Diagnostics read this mark as the album page showing the album.
      expect(find.byKey(detailPageShownKey), findsOneWidget);
      expect(find.text('Mayday'), findsOneWidget);
      expect(find.text('Speak'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets(
      'a stored remote album without tracks waits for them on the loading page',
      (tester) async {
        await storeRemoteAlbum(withSongs: false);
        await open(tester, AppRoutes.album(_remoteAlbumId));
        await settle(tester);

        expect(loading, findsOneWidget);
        // The stored title fills in before the tracks.
        expect(find.text('The Side Effects'), findsWidgets);
        expect(find.text('No Tracks for This Album'), findsNothing);

        await storeRemoteAlbum(withSongs: true);
        script.answer(_succeeded);
        await settle(tester);
        expect(loading, findsNothing);
        expect(find.text('Mayday'), findsOneWidget);
        await dispose(tester);
      },
    );

    testWidgets('a failure offers Retry and a search for title and artist', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.album(
          _remoteAlbumId,
          name: 'The Side Effects',
          artistName: 'Coldrain',
        ),
      );
      script.answer(_failed);
      await settle(tester);

      expect(failed, findsOneWidget);
      expect(find.text('Could Not Load This Album'), findsOneWidget);
      expect(find.text('Search for The Side Effects'), findsOneWidget);

      await tester.tap(find.byKey(DetailLoadFailedView.retryKey));
      await settle(tester);
      expect(script.calls.last, 'refresh-album:$_remoteAlbumId');
      await storeRemoteAlbum(withSongs: true);
      script.answer(_succeeded);
      await settle(tester);
      expect(failed, findsNothing);
      expect(find.text('Mayday'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('an album that cannot be read shows Retry and search', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.album(_remoteAlbumId, name: 'The Side Effects'),
        overrides: [
          albumProvider(_remoteAlbumId).overrideWith(
            (ref) => Stream<AlbumWithSongs?>.error(StateError('db')),
          ),
        ],
      );
      await settle(tester);

      expect(failed, findsOneWidget);
      expect(find.text('Search for The Side Effects'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('an album artist not in the library opens with its name', (
      tester,
    ) async {
      await storeRemoteAlbum(withSongs: true);
      await database.libraryDao.upsertProvisionalAlbums([
        AlbumsTableCompanion.insert(
          id: _remoteAlbumId,
          name: 'The Side Effects',
          artists: const Value([
            ArtistRef(id: 'ext-deezer-artist-77', name: 'Collaborator'),
          ]),
          isExternal: const Value(true),
          songsHydrated: const Value(true),
        ),
      ]);
      await open(tester, AppRoutes.album(_remoteAlbumId));
      script.answer(null);
      await settle(tester);

      await tester.tap(find.text('Collaborator'));
      await settle(tester);
      expect(
        currentRouter.state.uri.queryParameters[AppRoutes.detailNameParam],
        'Collaborator',
      );
      expect(find.text('Loading Remote Artist…'), findsOneWidget);
      expect(find.text('Collaborator'), findsWidgets);
      await dispose(tester);
    });

    testWidgets('the search fallback looks for the title and artist', (
      tester,
    ) async {
      await open(
        tester,
        AppRoutes.album(
          _remoteAlbumId,
          name: 'The Side Effects',
          artistName: 'Coldrain',
        ),
      );
      script.answer(_failed);
      await settle(tester);

      await tester.tap(find.byKey(DetailLoadFailedView.searchKey));
      await settle(tester);
      expect(find.text('SearchScreen'), findsOneWidget);
      expect(container.read(searchQueryProvider), 'The Side Effects Coldrain');
      expect(container.read(searchFilterProvider), SearchResultType.albums);
      await dispose(tester);
    });

    testWidgets('a remote album with tracks only fails quietly on refresh', (
      tester,
    ) async {
      await storeRemoteAlbum(withSongs: true);
      await open(tester, AppRoutes.album(_remoteAlbumId));
      script.answer(null);
      await settle(tester);
      expect(find.text('Mayday'), findsOneWidget);

      await tester.tap(find.byTooltip('Refresh').first);
      await settle(tester);
      expect(script.calls.last, 'refresh-album:$_remoteAlbumId');
      script.answer(_failed);
      await settle(tester);
      // The page keeps the album and reports the failure.
      expect(failed, findsNothing);
      expect(find.text('Mayday'), findsOneWidget);
      expect(
        notices.notice?.message,
        'Could not refresh this album. Check your connection and try again.',
      );
      await dispose(tester);
    });
  });
}
