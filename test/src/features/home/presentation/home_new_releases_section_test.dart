import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _Api extends Mock implements SubsonicApiClient;

class _DownloadedOnly extends DownloadedOnlyFilterController {
  new({required this.enabled});

  @override
  bool enabled;

  @override
  bool build() => enabled;
}

class _IdleSync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async => const LibrarySyncState.idle();
}

HomeNewRelease _release(
  int id,
  String title,
  DateTime day, {
  String type = 'single',
  String? libraryAlbumId,
}) => HomeNewRelease(
  album: DeezerAlbum(
    id: id,
    title: title,
    releaseDate:
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}',
    recordType: type,
  ),
  releasedOn: day,
  artistId: 'artist-$id',
  artistName: 'Artist $id',
  libraryAlbumId: libraryAlbumId,
);

void main() {
  late NavisDatabase database;

  Uri? lastAlbumUri;

  setUp(() {
    database = createTestDatabase();
    lastAlbumUri = null;
  });
  tearDown(() => database.close());

  Future<List<String>> pumpHome(
    WidgetTester tester, {
    required FutureOr<List<HomeNewRelease>> Function(Ref ref) releases,
    SubsonicApiClient? api,
    bool downloadedOnly = false,
    List<Override> overrides = const <Override>[],
    DiagnosticsPresentationController? presentation,
    Widget Function(String albumId)? albumPage,
  }) async {
    final openedAlbums = <String>[];
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '${AppRoutes.library}/${AppRoutes.albumSegment}',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            openedAlbums.add(id);
            lastAlbumUri = state.uri;
            return albumPage?.call(id) ?? Scaffold(body: Text('album:$id'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  homeSectionOrder: const <String>[HomeSectionIds.newReleases],
                  homeSectionsHidden: <String>[
                    for (final id in HomeSectionIds.defaultOrder)
                      if (id != HomeSectionIds.newReleases) id,
                  ],
                ),
              ),
            ),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData<ServerConfigModel?>(null),
            ),
            subsonicApiProvider.overrideWithValue(api),
            librarySyncControllerProvider.overrideWith(_IdleSync.new),
            downloadedOnlyFilterProvider.overrideWith(
              () => _DownloadedOnly(enabled: downloadedOnly),
            ),
            homeNewReleasesProvider.overrideWith(releases),
            ...overrides,
          ],
        ),
        child: (presentation?.wrap ?? (Widget child) => child)(
          MaterialApp.router(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return openedAlbums;
  }

  final section = find.byKey(const ValueKey<String>('home-new-releases'));
  final releases = <HomeNewRelease>[
    _release(1, 'Encore', DateTime(2026, 10, 2)),
    _release(2, 'Side B', DateTime(2026, 9, 28), type: 'ep'),
  ];

  testWidgets('shows each release as a title and artist, with no date line', (
    tester,
  ) async {
    await pumpHome(tester, releases: (ref) => releases);
    expect(section, findsOneWidget);
    expect(find.text('New Releases'), findsOneWidget);
    expect(find.text('Encore'), findsOneWidget);
    expect(find.text('Artist 1'), findsOneWidget);
    expect(find.text('Side B'), findsOneWidget);
    expect(find.text('Artist 2'), findsOneWidget);
    // The card is a two-line label like other album carousels.
    expect(find.text('Oct 2 • Single'), findsNothing);
    expect(find.text('Sep 28 • EP'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-new-release-1')),
        matching: find.byType(Text),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('hides itself while loading, empty, failed or filtered', (
    tester,
  ) async {
    final pending = Completer<List<HomeNewRelease>>();
    await pumpHome(tester, releases: (ref) => pending.future);
    expect(section, findsNothing);
    await pumpHome(tester, releases: (ref) => const <HomeNewRelease>[]);
    expect(section, findsNothing);
    await pumpHome(tester, releases: (ref) => throw StateError('offline'));
    expect(section, findsNothing);
    await pumpHome(tester, releases: (ref) => releases, downloadedOnly: true);
    expect(section, findsNothing);
    pending.complete(const <HomeNewRelease>[]);
  });

  testWidgets('a release in the library opens that album', (tester) async {
    final api = _Api();
    final opened = await pumpHome(
      tester,
      api: api,
      releases: (ref) => <HomeNewRelease>[
        _release(1, 'Encore', DateTime(2026, 10, 2), libraryAlbumId: 'lib-1'),
      ],
    );
    await tester.tap(find.text('Encore'));
    await tester.pumpAndSettle();
    expect(opened, <String>['lib-1']);
    verifyNever(() => api.getAlbum(any()));
  });

  testWidgets(
    'a release the library lacks opens the server remote album, named',
    (tester) async {
      final api = _Api();
      final opened = await pumpHome(
        tester,
        api: api,
        releases: (ref) => releases,
      );
      await tester.tap(find.text('Encore'));
      await tester.pumpAndSettle();
      expect(opened, <String>['ext-deezer-album-1']);
      // The page shows and searches for these while it loads the album.
      expect(lastAlbumUri?.queryParameters, <String, String>{
        AppRoutes.detailNameParam: 'Encore',
        AppRoutes.detailArtistParam: 'Artist 1',
      });
      // The album page asks the server; the tap itself does not wait on it.
      verifyNever(() => api.getAlbum(any()));
    },
  );

  group('diagnostics release card control', () {
    late DiagnosticsPresentationController presentation;

    setUp(() {
      final root = Directory.systemTemp.createTempSync('navis_release_card_');
      addTearDown(() => root.deleteSync(recursive: true));
      presentation = DiagnosticsPresentationController(
        artifactRoot: root,
        frameWaiter: () => TestWidgetsFlutterBinding.instance.pump(
          const Duration(milliseconds: 50),
        ),
      );
    });

    Future<DiagnosticsReleaseCardResult> tap(
      List<String> opened, {
      String surface = 'newReleases',
      int index = 0,
      Duration timeout = const Duration(seconds: 8),
    }) => presentation.tapReleaseCard(
      surface: surface,
      index: index,
      location: () => opened.join(','),
      timeout: timeout,
    );

    testWidgets('a library release reports the album page', (tester) async {
      final opened = await pumpHome(
        tester,
        presentation: presentation,
        releases: (ref) => <HomeNewRelease>[
          _release(1, 'Encore', DateTime(2026, 10, 2), libraryAlbumId: 'lib-1'),
        ],
      );
      final result = await tap(opened);
      expect(result.outcome, 'albumPage');
      expect(opened, <String>['lib-1']);
    });

    testWidgets('a remote album the page shows reports the album page', (
      tester,
    ) async {
      final opened = await pumpHome(
        tester,
        presentation: presentation,
        releases: (ref) => releases,
      );
      final result = await tap(opened, index: 1);
      expect(result.outcome, 'albumPage');
      expect(result.location, 'ext-deezer-album-2');
    });

    testWidgets('a remote album the server cannot provide reports failed', (
      tester,
    ) async {
      final opened = await pumpHome(
        tester,
        presentation: presentation,
        releases: (ref) => releases,
        albumPage: (id) => const Scaffold(
          body: Text('Retry', key: DetailLoadFailedView.failedKey),
        ),
      );
      final result = await tap(opened);
      expect(result.outcome, 'failed');
      expect(opened, <String>['ext-deezer-album-1']);
    });

    testWidgets('a page still loading at the end of the wait reports loading', (
      tester,
    ) async {
      final opened = await pumpHome(
        tester,
        presentation: presentation,
        releases: (ref) => releases,
        albumPage: (id) => const Scaffold(
          body: Text('Loading', key: DetailLoadingView.loadingKey),
        ),
      );
      final result = await tap(
        opened,
        timeout: const Duration(milliseconds: 200),
      );
      expect(result.outcome, 'loading');
    });

    testWidgets('rejects an index past the cards and unknown surfaces', (
      tester,
    ) async {
      final opened = await pumpHome(
        tester,
        presentation: presentation,
        releases: (ref) => releases,
      );
      await expectLater(
        presentation.tapReleaseCard(
          surface: 'newReleases',
          index: 2,
          location: () => null,
        ),
        throwsA(
          isA<DiagnosticsPresentationOutOfRange>().having(
            (error) => error.count,
            'count',
            2,
          ),
        ),
      );
      await expectLater(
        presentation.tapReleaseCard(
          surface: 'artists',
          index: 0,
          location: () => null,
        ),
        throwsFormatException,
      );
      // The artist page's shelf is not mounted on Home.
      await expectLater(
        presentation.tapReleaseCard(
          surface: 'missingAlbums',
          index: 0,
          location: () => null,
        ),
        throwsA(isA<DiagnosticsPresentationUnavailable>()),
      );
      expect(opened, isEmpty);
    });
  });
}
