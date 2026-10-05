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
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/integrations/presentation/deezer_release_sheet.dart';
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

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<List<String>> pumpHome(
    WidgetTester tester, {
    required FutureOr<List<HomeNewRelease>> Function(Ref ref) releases,
    SubsonicApiClient? api,
    bool downloadedOnly = false,
    List<Override> overrides = const <Override>[],
    DiagnosticsPresentationController? presentation,
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
            return Scaffold(body: Text('album:$id'));
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

  testWidgets('shows each release with its artist, day and type', (
    tester,
  ) async {
    await pumpHome(tester, releases: (ref) => releases);
    expect(section, findsOneWidget);
    expect(find.text('New Releases'), findsOneWidget);
    expect(find.text('Encore'), findsOneWidget);
    expect(find.text('Artist 1'), findsOneWidget);
    expect(find.text('Oct 2 • Single'), findsOneWidget);
    expect(find.text('Sep 28 • EP'), findsOneWidget);
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

  testWidgets('a remote album the server confirms opens on the server', (
    tester,
  ) async {
    final api = _Api();
    when(
      () => api.getAlbum('ext-deezer-album-1'),
    ).thenAnswer((_) async => const Album(id: 'ext-deezer-album-1', name: 'E'));
    final opened = await pumpHome(
      tester,
      api: api,
      releases: (ref) => releases,
    );
    await tester.tap(find.text('Encore'));
    await tester.pumpAndSettle();
    expect(opened, <String>['ext-deezer-album-1']);
  });

  testWidgets('otherwise the release sheet shows its day and tracklist', (
    tester,
  ) async {
    final api = _Api();
    when(() => api.getAlbum(any())).thenThrow(
      const SubsonicApiException(code: 70, message: 'Album not found'),
    );
    final opened = await pumpHome(
      tester,
      api: api,
      releases: (ref) => releases,
      overrides: <Override>[
        deezerReleaseDetailsProvider.overrideWith(
          (ref, key) async => const DeezerAlbum(
            id: 1,
            title: 'Encore',
            recordType: 'single',
            trackCount: 2,
            tracks: <DeezerTrack>[
              DeezerTrack(
                id: 11,
                title: 'Encore',
                durationSeconds: 209,
                artist: DeezerArtist(id: 1, name: 'Artist 1'),
              ),
              DeezerTrack(
                id: 12,
                title: 'Encore (Acoustic)',
                durationSeconds: 61,
                artist: DeezerArtist(id: 1, name: 'Artist 1'),
              ),
            ],
          ),
        ),
      ],
    );
    await tester.tap(find.text('Encore'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.byType(DeezerReleaseSheetBody), findsOneWidget);
    expect(find.text('Oct 2, 2026 • Single • 2 songs'), findsOneWidget);
    final tracklist = find.byKey(
      const ValueKey<String>('deezer-release-tracklist'),
    );
    expect(
      find.descendant(of: tracklist, matching: find.text('Encore (Acoustic)')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tracklist, matching: find.text('3:29')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tracklist, matching: find.text('1:01')),
      findsOneWidget,
    );
  });

  testWidgets('without a server the release sheet opens at once', (
    tester,
  ) async {
    final opened = await pumpHome(
      tester,
      releases: (ref) => releases,
      overrides: <Override>[
        deezerReleaseDetailsProvider.overrideWith((ref, key) async => null),
      ],
    );
    await tester.tap(find.text('Side B'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('Sep 28, 2026 • EP'), findsOneWidget);
  });

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

    final failingServer = _Api();

    testWidgets('a library release reports the album page', (tester) async {
      final opened = await pumpHome(
        tester,
        api: failingServer,
        presentation: presentation,
        releases: (ref) => <HomeNewRelease>[
          _release(1, 'Encore', DateTime(2026, 10, 2), libraryAlbumId: 'lib-1'),
        ],
      );
      final result = await tap(opened);
      expect(result.outcome, 'albumPage');
      expect(opened, <String>['lib-1']);
    });

    testWidgets('a remote album the server has reports the album page', (
      tester,
    ) async {
      final api = _Api();
      when(() => api.getAlbum('ext-deezer-album-2')).thenAnswer(
        (_) async => const Album(id: 'ext-deezer-album-2', name: 'S'),
      );
      final opened = await pumpHome(
        tester,
        api: api,
        presentation: presentation,
        releases: (ref) => releases,
      );
      final result = await tap(opened, index: 1);
      expect(result.outcome, 'albumPage');
      expect(opened, <String>['ext-deezer-album-2']);
    });

    testWidgets('an unknown release opens the sheet, which can be dismissed', (
      tester,
    ) async {
      final api = _Api();
      when(() => api.getAlbum(any())).thenThrow(
        const SubsonicApiException(code: 70, message: 'Album not found'),
      );
      final opened = await pumpHome(
        tester,
        api: api,
        presentation: presentation,
        releases: (ref) => releases,
        overrides: <Override>[
          deezerReleaseDetailsProvider.overrideWith((ref, key) async => null),
        ],
      );
      final result = await tap(opened);
      expect(result.outcome, 'sheet');
      expect(opened, isEmpty);
      expect(find.byType(DeezerReleaseSheetBody), findsOneWidget);

      await presentation.dismissReleaseSheet();
      await tester.pumpAndSettle();
      expect(find.byType(DeezerReleaseSheetBody), findsNothing);
      await expectLater(
        presentation.dismissReleaseSheet(),
        throwsA(isA<DiagnosticsPresentationUnavailable>()),
      );
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
