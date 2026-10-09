import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file/memory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/similar_artist_entry.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

const _artistId = 'oor';
const _key = (artistId: _artistId, name: 'ONE OK ROCK');
const _serverHost = 'music.example.org';
const _serverPhoto = 'https://$_serverHost/rest/getCoverArt.view?id=ar-oor';
const _lastFmStar =
    'https://lastfm.freetls.fastly.net/i/u/300x300/'
    '2a96cbd8b46e442fc41c2b86b821562f.png';
const _deezerPhoto =
    'https://cdn-images.dzcdn.net/images/artist/oor/1000x1000-000000-80-0-0.jpg';

/// Serves [images], fails [failing] and leaves every other URL loading.
class _ScriptedCacheManager extends Fake implements CacheManager {
  new({this.failing = const {}, this.images = const {}});

  final Set<String> failing;
  final Map<String, Uint8List> images;
  final List<String> requests = <String>[];
  final _fileSystem = MemoryFileSystem();

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requests.add(url);
    if (failing.contains(url)) {
      return Stream<FileResponse>.error(StateError('no network in tests'));
    }
    final bytes = images[url];
    if (bytes == null) return StreamController<FileResponse>().stream;
    final file = _fileSystem.file('/${url.hashCode}.png')
      ..writeAsBytesSync(bytes);
    return Stream<FileResponse>.value(
      FileInfo(file, FileSource.Cache, DateTime(2100), url),
    );
  }
}

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

AlbumsTableData _album(String id, String name, {int year = 2022}) =>
    AlbumsTableData(
      isProvisional: false,
      isExternal: false,
      id: id,
      name: name,
      artistName: 'ONE OK ROCK',
      artistId: _artistId,
      year: year,
      songsHydrated: true,
      artists: const [],
    );

DeezerAlbum _deezerAlbum(
  int id,
  String title, {
  String type = 'album',
  String date = '2017-01-11',
}) => DeezerAlbum(
  id: id,
  title: title,
  recordType: type,
  releaseDate: date,
  coverBig: 'https://cdn-images.dzcdn.net/images/cover/$id/500x500.jpg',
);

/// The router of the last [_router] call, for its location.
late GoRouter _currentRouter;

/// Pages: the artist page, any other artist (with the name it was opened
/// with), any album (with its title and artist), and search.
GoRouter _router() => _currentRouter = GoRouter(
  initialLocation: AppRoutes.artist(_artistId),
  routes: <RouteBase>[
    GoRoute(
      path: AppRoutes.library,
      builder: (_, _) => const Text('LibraryScreen'),
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.artistSegment,
          builder: (_, state) => state.pathParameters['id'] == _artistId
              ? const ArtistDetailScreen(artistId: _artistId)
              : Text(
                  'Artist ${state.pathParameters['id']} '
                  '${state.uri.queryParameters[AppRoutes.detailNameParam]}',
                ),
        ),
        GoRoute(
          path: AppRoutes.albumSegment,
          builder: (_, state) => Text(
            'Album ${state.pathParameters['id']} | '
            '${state.uri.queryParameters[AppRoutes.detailNameParam]} | '
            '${state.uri.queryParameters[AppRoutes.detailArtistParam]}',
            key: detailPageShownKey,
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

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() async {
    // A URL left loading by one test must not answer for it in the next.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await database.close();
  });

  Widget app({
    IntegrationPolicy policy = const IntegrationPolicy(),
    ArtistInfo? info,
    DeezerArtist? deezerArtist,
    List<SimilarArtistEntry> fansAlsoLike = const [],
    Future<List<SimilarArtistEntry>> Function()? loadFansAlsoLike,
    List<DeezerAlbum> deezerAlbums = const [],
    List<AlbumsTableData> albums = const [],
    CacheManager? cacheManager,
    AdaptiveContext adaptiveContext = _mobileContext,
    ThemeData? theme,
    int albumCount = 12,
    DiagnosticsPresentationController? presentation,
  }) {
    return ProviderScope(
      overrides: [
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        subsonicApiProvider.overrideWith((_) => null),
        connectivityProvider.overrideWith(
          (_) =>
              Stream.value(const <ConnectivityResult>[ConnectivityResult.wifi]),
        ),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        integrationPolicyProvider.overrideWithValue(policy),
        serverHostProvider.overrideWithValue(_serverHost),
        coverArtCacheManagerProvider.overrideWithValue(
          cacheManager ?? _ScriptedCacheManager(),
        ),
        artistTopTrackSeedsProvider.overrideWith(
          (ref, key) async => const <ArtistTopTrackSeed>[],
        ),
        artistByIdProvider(_artistId).overrideWithValue(
          AsyncData(
            ArtistsTableData(
              isProvisional: false,
              isExternal: false,
              id: _artistId,
              name: 'ONE OK ROCK',
              albumCount: albumCount,
            ),
          ),
        ),
        artistAlbumSectionsProvider(_artistId)
            .overrideWithValue(AsyncData(ArtistAlbumSections(albums: albums))),
        artistInfoProvider(_artistId).overrideWithValue(AsyncData(info)),
        // Deezer, after its feature switch (tested in the provider tests).
        artistDeezerIdProvider.overrideWith((ref, key) async => 1105),
        artistDeezerDetailsProvider(_key).overrideWith(
          (ref) async =>
              ref.watch(
                integrationPolicyProvider.select(
                  (p) => p.allows(IntegrationFeature.deezerArtistImages),
                ),
              )
              ? deezerArtist
              : null,
        ),
        artistFansAlsoLikeProvider(_key).overrideWith(
          (ref) => loadFansAlsoLike?.call() ?? Future.value(fansAlsoLike),
        ),
        artistDeezerAlbumsProvider(_key)
            .overrideWith((ref) async => deezerAlbums),
      ],
      child: (presentation?.wrap ?? (Widget child) => child)(
        AdaptiveContextScope(
          adaptiveContext: adaptiveContext,
          child: MaterialApp.router(
            theme: theme,
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: _router(),
          ),
        ),
      ),
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Finder headerImage(String url) =>
      find.byKey(ValueKey<String>('artist-header-image:$url'));
  final nameHeader = find.byKey(const ValueKey<String>('artist-name-header'));

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ArtistDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
  }

  group('header photo', () {
    testWidgets('the server photo comes first', (tester) async {
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(largeImageUrl: _serverPhoto),
          deezerArtist: const DeezerArtist(
            id: 1105,
            name: 'ONE OK ROCK',
            pictureXl: _deezerPhoto,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(headerImage(_serverPhoto), findsOneWidget);
      await dispose(tester);
    });

    for (final entry in <String, ArtistInfo?>{
      'no artist info': null,
      'an empty server URL': const ArtistInfo(
        largeImageUrl: '',
        mediumImageUrl: '',
      ),
      'the Last.fm placeholder star': const ArtistInfo(
        largeImageUrl: _lastFmStar,
        mediumImageUrl: _lastFmStar,
      ),
    }.entries) {
      testWidgets('Deezer photo with ${entry.key}', (tester) async {
        await tester.pumpWidget(
          app(
            info: entry.value,
            deezerArtist: const DeezerArtist(
              id: 1105,
              name: 'ONE OK ROCK',
              pictureXl: _deezerPhoto,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(headerImage(_deezerPhoto), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is ExternalArtworkImage && widget.url == _lastFmStar,
          ),
          findsNothing,
        );
        await dispose(tester);
      });
    }

    testWidgets('a server photo that fails hands over to Deezer', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(largeImageUrl: _serverPhoto),
          deezerArtist: const DeezerArtist(
            id: 1105,
            name: 'ONE OK ROCK',
            pictureXl: _deezerPhoto,
          ),
          cacheManager: _ScriptedCacheManager(failing: {_serverPhoto}),
        ),
      );
      await tester.pump();
      expect(headerImage(_serverPhoto), findsOneWidget);

      await tester.pumpAndSettle();
      expect(headerImage(_serverPhoto), findsNothing);
      expect(headerImage(_deezerPhoto), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('when the Deezer photo fails too, the name header shows', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(largeImageUrl: _serverPhoto),
          deezerArtist: const DeezerArtist(
            id: 1105,
            name: 'ONE OK ROCK',
            pictureXl: _deezerPhoto,
          ),
          cacheManager: _ScriptedCacheManager(
            failing: {_serverPhoto, _deezerPhoto},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(headerImage(_serverPhoto), findsNothing);
      expect(headerImage(_deezerPhoto), findsNothing);
      expect(nameHeader, findsOneWidget);
      expect(find.text('ONE OK ROCK'), findsAtLeastNWidgets(1));
      await dispose(tester);
    });

    testWidgets('pull to refresh tries a failed photo again', (tester) async {
      final images = _ScriptedCacheManager(failing: {_serverPhoto});
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(largeImageUrl: _serverPhoto),
          cacheManager: images,
        ),
      );
      await tester.pumpAndSettle();
      expect(nameHeader, findsOneWidget);
      expect(images.requests.where((url) => url == _serverPhoto), hasLength(1));

      // The failed load is not cached as an image either.
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(images.requests.where((url) => url == _serverPhoto), hasLength(2));
      await dispose(tester);
    });

    testWidgets('a failing photo without Deezer shows the name header', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(largeImageUrl: _serverPhoto),
          cacheManager: _ScriptedCacheManager(failing: {_serverPhoto}),
        ),
      );
      await tester.pumpAndSettle();

      expect(headerImage(_serverPhoto), findsNothing);
      expect(nameHeader, findsOneWidget);
      await dispose(tester);
    });

    testWidgets('with artist photos off there is no Deezer photo or fans', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          policy: const IntegrationPolicy(
            disabledKeys: {'deezer.artistImages'},
          ),
          deezerArtist: const DeezerArtist(
            id: 1105,
            name: 'ONE OK ROCK',
            pictureXl: _deezerPhoto,
            fanCount: 4100000,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(nameHeader, findsOneWidget);
      expect(headerImage(_deezerPhoto), findsNothing);
      expect(find.text('12 albums'), findsOneWidget);
      expect(find.textContaining('fans'), findsNothing);
      await dispose(tester);
    });
  });

  group('fans line', () {
    for (final (fans, line) in <(int, String)>[
      (4100000, '12 albums • 4.1M fans on Deezer'),
      (12345, '12 albums • 12.3K fans on Deezer'),
      (950, '12 albums • 950 fans on Deezer'),
      (1, '12 albums • 1 fan on Deezer'),
    ]) {
      testWidgets('$fans fans read "$line"', (tester) async {
        await tester.pumpWidget(
          app(
            deezerArtist: DeezerArtist(
              id: 1105,
              name: 'ONE OK ROCK',
              fanCount: fans,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(line), findsOneWidget);
        await dispose(tester);
      });
    }

    testWidgets('no fan count leaves the album count alone', (tester) async {
      await tester.pumpWidget(
        app(deezerArtist: const DeezerArtist(id: 1105, name: 'ONE OK ROCK')),
      );
      await tester.pumpAndSettle();

      expect(find.text('12 albums'), findsOneWidget);
      await dispose(tester);
    });
  });

  group('Fans Also Like', () {
    const serverSimilar = ArtistInfo(
      similarArtists: [Artist(id: 'server-sim', name: 'Server Similar')],
    );
    const entries = [
      SimilarArtistEntry(name: 'MY FIRST STORY', libraryArtistId: 'lib-mfs'),
      SimilarArtistEntry(
        name: 'Coldrain',
        deezerArtistId: 4321,
        imageUrl: 'https://x/c.jpg',
      ),
      SimilarArtistEntry(name: 'No Id', imageUrl: 'https://x/n.jpg'),
    ];

    testWidgets('replaces Similar Artists, library artists first', (
      tester,
    ) async {
      await tester.pumpWidget(app(info: serverSimilar, fansAlsoLike: entries));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Fans Also Like'));

      expect(find.text('Similar Artists'), findsNothing);
      expect(find.text('Server Similar'), findsNothing);
      final library = tester.getTopLeft(find.text('MY FIRST STORY'));
      final other = tester.getTopLeft(find.text('Coldrain'));
      expect(
        library.dy < other.dy || library.dx < other.dx,
        isTrue,
        reason: 'the library artist comes first',
      );
      await dispose(tester);
    });

    testWidgets('without Deezer data the server list stays', (tester) async {
      await tester.pumpWidget(app(info: serverSimilar));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Similar Artists'));

      expect(find.text('Server Similar'), findsOneWidget);
      expect(find.text('Fans Also Like'), findsNothing);
      await dispose(tester);
    });

    testWidgets('a slow Deezer gives way to the server list, which stays', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 2400));
      final deezer = Completer<List<SimilarArtistEntry>>();
      await tester.pumpWidget(
        app(info: serverSimilar, loadFansAlsoLike: () => deezer.future),
      );
      await tester.pump();

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Server Similar'), findsNothing);
      expect(find.text('Fans Also Like'), findsNothing);

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Similar Artists'), findsOneWidget);
      expect(find.text('Server Similar'), findsOneWidget);

      deezer.complete(entries);
      await tester.pumpAndSettle();
      expect(find.text('Server Similar'), findsOneWidget);
      expect(find.text('Fans Also Like'), findsNothing);
      expect(find.text('Coldrain'), findsNothing);
      await dispose(tester);
    });

    testWidgets('Deezer answering in time shows Fans Also Like', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 2400));
      final deezer = Completer<List<SimilarArtistEntry>>();
      await tester.pumpWidget(
        app(info: serverSimilar, loadFansAlsoLike: () => deezer.future),
      );
      await tester.pump(const Duration(seconds: 1));
      deezer.complete(entries);
      await tester.pumpAndSettle();

      expect(find.text('Fans Also Like'), findsOneWidget);
      expect(find.text('Server Similar'), findsNothing);
      await dispose(tester);
    });

    testWidgets('a Deezer error shows the server list at once', (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 2400));
      await tester.pumpWidget(
        app(
          info: serverSimilar,
          loadFansAlsoLike: () => Future.error(StateError('Deezer down')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Server Similar'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('an artist outside the library opens the server remote '
        'artist page, never search or "Artist Not Found"', (tester) async {
      await tester.pumpWidget(app(fansAlsoLike: entries));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Coldrain'));

      await tester.tap(find.text('Coldrain'));
      await tester.pumpAndSettle();
      expect(
        find.text('Artist ext-deezer-artist-4321 Coldrain'),
        findsOneWidget,
      );
      expect(find.text('SearchScreen'), findsNothing);
      expect(find.text('Artist Not Found'), findsNothing);
      await dispose(tester);
    });

    testWidgets('a library artist opens its page; one without a Deezer id '
        'opens search', (tester) async {
      await tester.pumpWidget(app(fansAlsoLike: entries));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('MY FIRST STORY'));
      await tester.tap(find.text('MY FIRST STORY'));
      await tester.pumpAndSettle();
      expect(find.text('Artist lib-mfs null'), findsOneWidget);
      await dispose(tester);

      await tester.pumpWidget(app(fansAlsoLike: entries));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('No Id'));
      await tester.tap(find.text('No Id'));
      await tester.pumpAndSettle();
      expect(find.text('SearchScreen'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.text('SearchScreen')),
      );
      expect(container.read(searchQueryProvider), 'No Id');
      expect(container.read(searchFilterProvider), SearchResultType.artists);
      await dispose(tester);
    });
  });

  group('Missing Albums', () {
    testWidgets('shows the missing editions with year and type', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          albums: [_album('al-1', 'Ambitions')],
          deezerAlbums: [
            _deezerAlbum(1, 'Ambitions', date: '2017-01-13'),
            _deezerAlbum(2, 'Ambitions (Japanese Version)'),
            _deezerAlbum(
              3,
              'Wasted Nights',
              type: 'single',
              date: '2019-02-01',
            ),
            _deezerAlbum(4, 'Prove', type: 'ep', date: '2021-01-01'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Missing Albums'));

      final cards = tester
          .widgetList<ExternalAlbumCard>(find.byType(ExternalAlbumCard))
          .map((card) => '${card.title} | ${card.subtitle}')
          .toList();
      expect(cards, [
        'Prove | 2021 • EP',
        'Ambitions (Japanese Version) | 2017 • Album',
      ]);
      await dispose(tester);
    });

    testWidgets('a card opens the server remote album page, named', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(deezerAlbums: [_deezerAlbum(2, 'Ambitions (Japanese Version)')]),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byType(ExternalAlbumCard));

      await tester.tap(find.byType(ExternalAlbumCard));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Album ext-deezer-album-2 | Ambitions (Japanese Version) | '
          'ONE OK ROCK',
        ),
        findsOneWidget,
      );
      await dispose(tester);
    });

    testWidgets('the diagnostics control taps a card and reports the page', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync('navis_missing_card_');
      addTearDown(() => root.deleteSync(recursive: true));
      final presentation = DiagnosticsPresentationController(
        artifactRoot: root,
        frameWaiter: () => TestWidgetsFlutterBinding.instance.pump(
          const Duration(milliseconds: 50),
        ),
      );
      await tester.pumpWidget(
        app(
          presentation: presentation,
          deezerAlbums: [_deezerAlbum(2, 'Ambitions (Japanese Version)')],
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byType(ExternalAlbumCard));

      String location() => _currentRouter.state.uri.path;
      final result = await presentation.tapReleaseCard(
        surface: 'missingAlbums',
        index: 0,
        location: location,
      );
      await tester.pumpAndSettle();
      expect(result.outcome, 'albumPage');
      expect(result.location, AppRoutes.album('ext-deezer-album-2'));
      await expectLater(
        presentation.tapReleaseCard(
          surface: 'missingAlbums',
          index: 0,
          location: location,
        ),
        // The album page now covers the artist page's shelf.
        throwsA(isA<DiagnosticsPresentationUnavailable>()),
      );
      await dispose(tester);
    });

    testWidgets('hidden when the server has remote albums for the artist', (
      tester,
    ) async {
      // Tall enough to build the whole page, down to Similar Artists.
      setAdaptiveTestViewport(tester, const Size(390, 2400));
      await tester.pumpWidget(
        app(
          info: const ArtistInfo(
            similarArtists: [Artist(id: 'sim', name: 'Server Similar')],
          ),
          albums: [
            _album('al-1', 'Ambitions'),
            _album('ext-deezer-album-9', 'Remote').copyWith(isExternal: true),
          ],
          deezerAlbums: [_deezerAlbum(2, 'Ambitions (Japanese Version)')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server Similar'), findsOneWidget);
      expect(find.text('Missing Albums'), findsNothing);
      expect(find.byType(ExternalAlbumCard), findsNothing);
      await dispose(tester);
    });
  });

  group('golden', () {
    late Map<String, Uint8List> images;

    setUpAll(() async {
      final inter = FontLoader(navisFontFamily)
        ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([inter.load(), icons.load()]);
    });

    Future<Uint8List> picture(Color background, List<Color> shapes) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = 400.0;
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, size, size),
        Paint()..color = background,
      );
      for (var i = 0; i < shapes.length; i++) {
        canvas.drawCircle(
          Offset(size * (0.25 + 0.25 * i), size * (0.35 + 0.15 * (i % 2))),
          size * 0.22,
          Paint()..color = shapes[i],
        );
      }
      final image = await recorder.endRecording().toImage(
        size.toInt(),
        size.toInt(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    }

    Future<void> renderPage(
      WidgetTester tester, {
      required Size size,
      required AdaptiveContext adaptiveContext,
    }) async {
      await tester.runAsync(() async {
        images = <String, Uint8List>{
          _deezerPhoto: await picture(const Color(0xFF2B2F3A), const [
            Color(0xFF8C6A5A),
            Color(0xFF4F6D7A),
            Color(0xFFB59B7A),
          ]),
          for (final (id, color) in <(int, Color)>[
            (2, Color(0xFF7A3B3B)),
            (3, Color(0xFF3B5B7A)),
            (4, Color(0xFF5B7A3B)),
          ])
            'https://cdn-images.dzcdn.net/images/cover/$id/500x500.jpg':
                await picture(color, const [Color(0xFFE0D6C8)]),
          'https://x/coldrain.jpg': await picture(const Color(0xFF39424E), [
            const Color(0xFF9AA5B1),
          ]),
          'https://x/crossfaith.jpg': await picture(const Color(0xFF4E3942), [
            const Color(0xFFB19AA5),
          ]),
        };
      });
      setAdaptiveTestViewport(tester, size);
      await tester.pumpWidget(
        app(
          theme: buildDarkTheme(Colors.deepPurple),
          adaptiveContext: adaptiveContext,
          cacheManager: _ScriptedCacheManager(images: images),
          info: const ArtistInfo(largeImageUrl: _lastFmStar),
          deezerArtist: const DeezerArtist(
            id: 1105,
            name: 'ONE OK ROCK',
            pictureXl: _deezerPhoto,
            fanCount: 4100000,
          ),
          albums: [
            _album('al-1', 'Luxury Disease'),
            _album('al-2', 'Eye of the Storm', year: 2019),
          ],
          deezerAlbums: [
            _deezerAlbum(
              2,
              'Luxury Disease (Japanese Version)',
              date: '2022-09-07',
            ),
            _deezerAlbum(
              3,
              'Eye of the Storm (Japanese Version)',
              date: '2019-02-15',
            ),
            _deezerAlbum(4, 'Prove', type: 'ep', date: '2021-01-01'),
          ],
          fansAlsoLike: const [
            SimilarArtistEntry(name: 'MY FIRST STORY', libraryArtistId: 'mfs'),
            SimilarArtistEntry(name: 'SiM', libraryArtistId: 'sim'),
            SimilarArtistEntry(
              name: 'Coldrain',
              imageUrl: 'https://x/coldrain.jpg',
            ),
            SimilarArtistEntry(
              name: 'Crossfaith',
              imageUrl: 'https://x/crossfaith.jpg',
            ),
          ],
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('phone artist page with Deezer header and sections', (
      tester,
    ) async {
      await renderPage(
        tester,
        size: const Size(390, 1480),
        adaptiveContext: _mobileContext,
      );

      await expectLater(
        find.byType(ArtistDetailScreen),
        matchesGoldenFile('goldens/artist_detail_phone_deezer.png'),
      );
      await dispose(tester);
    });
  });
}
