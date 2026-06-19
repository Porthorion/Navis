import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

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

class _StaticGroupListeningSessionController
    extends GroupListeningSessionController {
  _StaticGroupListeningSessionController(this._state);

  final GroupListeningSessionState _state;

  @override
  GroupListeningSessionState build() => _state;
}

const _disabledGroupListeningSessionState =
    GroupListeningSessionState.disabled();

class _QueueSpyController extends QueueController {
  List<String>? lastReplaceIds;
  int? lastStartIndex;
  bool? lastAutoPlay;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
    bool syncGroupListening = true,
  }) async {
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    state = List<String>.unmodifiable(ids);
  }

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool syncGroupListening = true,
  }) async {
    final ids = songs.map((s) => s.id).toList(growable: false);
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    state = List<String>.unmodifiable(ids);
  }
}

SongsTableData _songRow({
  required String id,
  required String title,
  required String albumId,
  String artist = 'Artist',
  int? discNumber,
  int? track,
}) {
  return SongsTableData(
    id: id,
    title: title,
    albumId: albumId,
    artistName: artist,
    albumName: 'Album',
    discNumber: discNumber,
    track: track,
    duration: 210,
    coverArt: 'cover-$albumId',
  );
}

AlbumWithSongs _albumWithSongs(
  String albumId,
  String albumName,
  List<SongsTableData> songs,
) {
  return AlbumWithSongs(
    album: AlbumsTableData(
      id: albumId,
      name: albumName,
      artistName: 'Album Artist',
      coverArt: 'cover-$albumId',
      songsHydrated: true,
      artists: const <ArtistRef>[],
    ),
    songs: songs,
  );
}

Future<void> _pumpHomeWithSyncState(
  WidgetTester tester,
  LibrarySyncState syncState,
  NavisDatabase database, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          groupListeningSessionControllerProvider.overrideWith(
            () => _StaticGroupListeningSessionController(
              _disabledGroupListeningSessionState,
            ),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
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
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: theme,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
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
  required NavisDatabase database,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          groupListeningSessionControllerProvider.overrideWith(
            () => _StaticGroupListeningSessionController(
              _disabledGroupListeningSessionState,
            ),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
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
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpRandomSectionHome(
  WidgetTester tester, {
  required List<HomeRandomShowcaseAlbum> randomAlbums,
  required NavisDatabase database,
  List<Override> overrides = const <Override>[],
}) async {
  final sectionOverrides = withTestDatabase(
    database,
    overrides: <Override>[
      appSettingsProvider.overrideWithValue(
        AsyncData(
          const AppSettingsModel.defaults().copyWith(
            homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
            homeSectionsHidden: <String>[],
          ),
        ),
      ),
      groupListeningSessionControllerProvider.overrideWith(
        () => _StaticGroupListeningSessionController(
          _disabledGroupListeningSessionState,
        ),
      ),
      serverConfigStateProvider.overrideWithValue(
        const AsyncData<ServerConfigModel?>(null),
      ),
      librarySyncControllerProvider.overrideWith(
        _StaticLibrarySyncController.new,
      ),
      subsonicApiProvider.overrideWithValue(null),
      homeRandomShowcaseProvider.overrideWith(
        (ref, filters) async => randomAlbums,
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
      ...overrides,
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: sectionOverrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpHomeWithAppSettings(
  WidgetTester tester, {
  required NavisDatabase database,
  AppSettingsModel appSettings = const AppSettingsModel.defaults(),
  List<SongsTableData> homeLikedSongs = const <SongsTableData>[],
  List<SongsTableData> likedSongs = const <SongsTableData>[],
  List<Override> overrides = const <Override>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(AsyncData(appSettings)),
          groupListeningSessionControllerProvider.overrideWith(
            () => _StaticGroupListeningSessionController(
              _disabledGroupListeningSessionState,
            ),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeLikedSongsProvider.overrideWithValue(AsyncData(homeLikedSongs)),
          likedSongsProvider.overrideWithValue(AsyncData(likedSongs)),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          downloadedContentIdsProvider.overrideWithValue(
            const AsyncData((albumIds: <String>{}, artistIds: <String>{})),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeDownloadedRecentlyAddedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeDownloadedRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeDownloadedRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) async => const <HomeRandomShowcaseAlbum>[],
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeDownloadedLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeDownloadedMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          ...overrides,
        ],
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late NavisDatabase database;

  setUpAll(() {
    database = createTestDatabase();
  });

  tearDownAll(() async {
    await database.close();
  });

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
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            groupListeningSessionControllerProvider.overrideWith(
              () => _StaticGroupListeningSessionController(
                _disabledGroupListeningSessionState,
              ),
            ),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData<ServerConfigModel?>(null),
            ),
            subsonicApiProvider.overrideWithValue(null),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  id: 'song-1',
                  title:
                      'A very long song title that should ellipsize correctly',
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
                  artists: const <ArtistRef>[],
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
                  artists: const <ArtistRef>[],
                ),
              ]),
            ),
          ],
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            return MediaQuery(
              data:
                  MediaQuery.of(
                    context,
                  ).copyWith(
                    textScaler: const TextScaler.linear(1.3),
                    disableAnimations: true,
                  ),
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
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            groupListeningSessionControllerProvider.overrideWith(
              () => _StaticGroupListeningSessionController(
                _disabledGroupListeningSessionState,
              ),
            ),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData<ServerConfigModel?>(null),
            ),
            subsonicApiProvider.overrideWithValue(null),
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
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home applies desktop framing only at desktop-wide width boundaries',
    (tester) async {
      const desktopBrandRow = ValueKey<String>('homeDesktopBrandRow');
      setAdaptiveTestViewport(tester, const Size(599, 1000));
      await _pumpHomeWithSyncState(
        tester,
        const LibrarySyncState.idle(),
        database,
      );

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(desktopBrandRow), findsNothing);
      expect(tester.takeException(), isNull);

      final transitions = <({Size size, bool desktopHeader})>[
        (size: const Size(700, 1000), desktopHeader: false),
        (size: const Size(840, 1000), desktopHeader: false),
        (size: const Size(1200, 1000), desktopHeader: true),
        (size: const Size(900, 420), desktopHeader: false),
      ];

      for (final step in transitions) {
        tester.view.physicalSize = step.size;
        await tester.pumpAndSettle();
        expect(
          find.byKey(desktopBrandRow),
          step.desktopHeader ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('home switches header treatment by adaptive mode', (
    tester,
  ) async {
    const desktopBrandRow = ValueKey<String>('homeDesktopBrandRow');
    const compactWideHeaderRow = ValueKey<String>('homeCompactWideHeaderRow');
    const centeredLogoHeader = ValueKey<String>('homeCenteredLogoHeader');
    const mobileActionRow = ValueKey<String>('homeMobileActionRow');

    setAdaptiveTestViewport(tester, const Size(1000, 420));
    await _pumpHomeWithAppSettings(tester, database: database);

    expect(find.byKey(compactWideHeaderRow), findsOneWidget);
    expect(find.byKey(centeredLogoHeader), findsNothing);
    expect(find.byKey(mobileActionRow), findsNothing);
    expect(find.byKey(desktopBrandRow), findsNothing);

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();

    expect(find.byKey(desktopBrandRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);
    expect(find.byKey(centeredLogoHeader), findsNothing);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    expect(find.byKey(centeredLogoHeader), findsOneWidget);
    expect(find.byKey(mobileActionRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);

    tester.view.physicalSize = const Size(700, 1000);
    await tester.pumpAndSettle();

    expect(find.byKey(centeredLogoHeader), findsOneWidget);
    expect(find.byKey(mobileActionRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);
  });

  testWidgets('compact-wide home actions toggle filters and disable radio', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 420));
    await _pumpHomeWithAppSettings(tester, database: database);

    expect(
      find.byKey(const ValueKey<String>('homeCompactWideActionRow')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);

    final radioButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.radio_rounded),
    );
    expect(radioButton.onPressed, isNull);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
  });

  testWidgets(
    'compact-wide song sections use two columns only above the width threshold',
    (tester) async {
      final songs = List<SongsTableData>.generate(
        6,
        (index) => _songRow(
          id: 'liked-${index + 1}',
          title: 'Liked Song ${index + 1}',
          albumId: 'liked-album',
        ),
      );
      final settings = const AppSettingsModel.defaults().copyWith(
        homeSectionOrder: <String>[HomeSectionIds.likedTracks],
        homeSectionsHidden: <String>[],
      );

      setAdaptiveTestViewport(tester, const Size(1000, 420));
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: settings,
        homeLikedSongs: songs,
        likedSongs: songs,
      );

      expect(
        find.byKey(const ValueKey<String>('homeSongListTwoColumnGrid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('homeSongListSingleColumn')),
        findsNothing,
      );

      tester.view.physicalSize = const Size(840, 420);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('homeSongListTwoColumnGrid')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('homeSongListSingleColumn')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'default home shows default-on sections and keeps optional sections hidden',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              appSettingsProvider.overrideWithValue(
                const AsyncData(AppSettingsModel.defaults()),
              ),
              groupListeningSessionControllerProvider.overrideWith(
                () => _StaticGroupListeningSessionController(
                  _disabledGroupListeningSessionState,
                ),
              ),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
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
          ),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const HomeScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Quick Actions are now always-visible icon toggles + Instant Radio button
      // below the logo, not a section.
      expect(find.text('Quick actions'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget); // Instant Radio
      await tester.scrollUntilVisible(
        find.text('Recently liked albums'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Recently liked albums'), findsOneWidget);
      expect(find.text('Recently played tracks'), findsNothing);
    },
  );

  testWidgets('random section renders dedicated hero carousel', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                  homeSectionsHidden: <String>[],
                ),
              ),
            ),
            groupListeningSessionControllerProvider.overrideWith(
              () => _StaticGroupListeningSessionController(
                _disabledGroupListeningSessionState,
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
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
            child: child!,
          ),
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

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
          overrides: withTestDatabase(
            database,
            overrides: [
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  const AppSettingsModel.defaults().copyWith(
                    homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                    homeSectionsHidden: <String>[],
                  ),
                ),
              ),
              groupListeningSessionControllerProvider.overrideWith(
                () => _StaticGroupListeningSessionController(
                  _disabledGroupListeningSessionState,
                ),
              ),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
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
          ),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: child!,
            ),
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

  testWidgets(
    'desktop-wide random section uses desktop pager and compact widths keep hero carousel',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseAlbum>[
        HomeRandomShowcaseAlbum(
          id: 'desk-1',
          name: 'Desktop Album',
          artist: 'Desk Artist',
          coverArtId: 'cover-desk-1',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(1200, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          albumProvider.overrideWith(
            (ref, albumId) => Stream.value(
              albumId == 'desk-1'
                  ? _albumWithSongs(
                      'desk-1',
                      'Desktop Album',
                      <SongsTableData>[
                        _songRow(
                          id: 'desk-song-1',
                          title: 'Desktop Song',
                          albumId: 'desk-1',
                          discNumber: 1,
                          track: 1,
                        ),
                      ],
                    )
                  : null,
            ),
          ),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
      );

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        findsNothing,
      );

      tester.view.physicalSize = const Size(840, 900);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'desktop random pager supports manual paging and expands rows when height allows',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseAlbum>[
        HomeRandomShowcaseAlbum(
          id: 'desk-a',
          name: 'Album A',
          artist: 'Artist A',
          coverArtId: 'cover-desk-a',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'desk-b',
          name: 'Album B',
          artist: 'Artist B',
          coverArtId: 'cover-desk-b',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(1366, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          albumProvider.overrideWith((ref, albumId) {
            final songsA = List<SongsTableData>.generate(
              6,
              (index) => _songRow(
                id: 'desk-a-song-${index + 1}',
                title: 'A Song ${index + 1}',
                albumId: 'desk-a',
                discNumber: 1,
                track: index + 1,
              ),
            );
            final songsB = List<SongsTableData>.generate(
              3,
              (index) => _songRow(
                id: 'desk-b-song-${index + 1}',
                title: 'B Song ${index + 1}',
                albumId: 'desk-b',
                discNumber: 1,
                track: index + 1,
              ),
            );
            final data = switch (albumId) {
              'desk-a' => _albumWithSongs('desk-a', 'Album A', songsA),
              'desk-b' => _albumWithSongs('desk-b', 'Album B', songsB),
              _ => null,
            };
            return Stream.value(data);
          }),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
      );

      Finder visibleRows() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('home-random-desktop-song-row-');
      });

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-page-0')),
        findsOneWidget,
      );
      expect(visibleRows(), findsNWidgets(6));

      await tester.tap(
        find.byKey(const ValueKey<String>('home-random-desktop-mini-cover-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-page-1')),
        findsOneWidget,
      );
      expect(visibleRows(), findsNWidgets(3));

      await tester.tap(find.byIcon(Icons.chevron_left_rounded).first);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-page-0')),
        findsOneWidget,
      );
      expect(visibleRows(), findsNWidgets(6));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'desktop random rows trigger queue replace, like toggle, and menu actions',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseAlbum>[
        HomeRandomShowcaseAlbum(
          id: 'desk-interact',
          name: 'Interactive Album',
          artist: 'Artist',
          coverArtId: 'cover-desk-interact',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(1280, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          queueProvider.overrideWith(_QueueSpyController.new),
          albumProvider.overrideWith(
            (ref, albumId) => Stream.value(
              albumId == 'desk-interact'
                  ? _albumWithSongs(
                      'desk-interact',
                      'Interactive Album',
                      List<SongsTableData>.generate(
                        6,
                        (index) => _songRow(
                          id: 'interaction-song-${index + 1}',
                          title: 'Song ${index + 1}',
                          albumId: 'desk-interact',
                          discNumber: 1,
                          track: index + 1,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(songId == 'interaction-song-1'),
          ),
        ],
      );

      await tester.tap(find.text('Song 3'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final queueSpy =
          container.read(queueProvider.notifier) as _QueueSpyController;
      expect(queueSpy.lastReplaceIds, hasLength(6));
      expect(queueSpy.lastStartIndex, 2);
      expect(queueSpy.lastAutoPlay, isTrue);

      final heartButton = tester.widget<IconButton>(
        find.byKey(
          const ValueKey<String>(
            'home-random-desktop-heart-interaction-song-1',
          ),
        ),
      );
      final heartIcon = heartButton.icon as Icon;
      expect(heartIcon.icon, Icons.favorite);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('home-random-desktop-menu-interaction-song-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Play now'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('desktop random pager avoids overflow at key desktop widths', (
    tester,
  ) async {
    const randomAlbums = <HomeRandomShowcaseAlbum>[
      HomeRandomShowcaseAlbum(
        id: 'desk-overflow',
        name:
            'A very long desktop album title that should still fit without overflow',
        artist: 'Overflow Artist',
        coverArtId: 'cover-desk-overflow',
        source: HomeRandomShowcaseSource.serverRandom,
      ),
    ];

    setAdaptiveTestViewport(tester, const Size(1200, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: randomAlbums,
      overrides: <Override>[
        albumProvider.overrideWith(
          (ref, albumId) => Stream.value(
            albumId == 'desk-overflow'
                ? _albumWithSongs(
                    'desk-overflow',
                    'A very long desktop album title that should still fit without overflow',
                    List<SongsTableData>.generate(
                      6,
                      (index) => _songRow(
                        id: 'overflow-song-${index + 1}',
                        title:
                            'A long desktop song title ${index + 1} that should ellipsize cleanly',
                        albumId: 'desk-overflow',
                        discNumber: 1,
                        track: index + 1,
                        artist:
                            'An artist name with extended text to stress desktop layout spacing',
                      ),
                    ),
                  )
                : null,
          ),
        ),
        songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
        songStarredProvider.overrideWith((ref, songId) => Stream.value(false)),
      ],
    );

    final widths = <Size>[
      const Size(1200, 900),
      const Size(1366, 900),
      const Size(1600, 900),
    ];

    for (final size in widths) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

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
      database,
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

  testWidgets('home logo and sync ring use exact safe brand accent', (
    tester,
  ) async {
    const selectedAccent = Color(0xFF005BBB);
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
      ),
      database,
      theme: buildLightTheme(selectedAccent),
    );

    final context = tester.element(find.byType(HomeScreen));
    final accent = NavisAccentColors.of(context);
    final icon = tester.widget<NavisIcon>(find.byType(NavisIcon).first);
    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    final indicator = tester.widget<CircularProgressIndicator>(ring);

    expect(icon.tintWithAccent, isTrue);
    expect(icon.tintColor, isNull);
    expect(accent.brand, selectedAccent);
    expect(indicator.color, selectedAccent);
    expect(indicator.backgroundColor, selectedAccent.withValues(alpha: 0.14));
  });

  testWidgets('unsafe white-on-light brand accent falls back visibly', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
      ),
      database,
      theme: buildLightTheme(defaultColorSchemeSeedColor),
    );

    final context = tester.element(find.byType(HomeScreen));
    final accent = NavisAccentColors.of(context);
    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    final indicator = tester.widget<CircularProgressIndicator>(ring);

    expect(accent.source, defaultColorSchemeSeedColor);
    expect(accent.brand, isNot(defaultColorSchemeSeedColor));
    expect(indicator.color, accent.brand);
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
      database,
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
      database,
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
      await _pumpHomeWithSyncState(tester, state, database);
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
        database: database,
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
          HomeSectionIds.recentlyLikedAlbums,
          HomeSectionIds.likedTracks,
          HomeSectionIds.listenBrainzDiscover,
          HomeSectionIds.recentlyAdded,
          HomeSectionIds.recentlyPlayed,
          HomeSectionIds.randomAlbums,
          HomeSectionIds.mostPlayed,
          HomeSectionIds.recentlyPlayedTracks,
          HomeSectionIds.frequentAlbums,
        ]),
      );
      // quickActions is no longer a section — it's always-visible chips below
      // the home logo.
      expect(
        HomeSectionIds.defaultOrder,
        isNot(contains(HomeSectionIds.quickActions)),
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
