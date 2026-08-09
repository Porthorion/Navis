import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _FakeSearchApiClient extends SubsonicApiClient {
  _FakeSearchApiClient(this._handler)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Future<SearchResult3> Function(String query) _handler;

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) {
    return _handler(query);
  }
}

ProviderContainer _createContainerWithDatabase(
  NavisDatabase database, {
  required SubsonicApiClient api,
  List<Override> overrides = const <Override>[],
}) {
  return ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        subsonicApiProvider.overrideWithValue(api),
        ...overrides,
      ],
    ),
  );
}

Future<void> _insertArtist(
  NavisDatabase database, {
  required String id,
  required String name,
}) {
  return database
      .into(database.artistsTable)
      .insert(ArtistsTableCompanion.insert(id: id, name: name));
}

Future<void> _pumpSearchScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SearchScreen(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _enterSearchQuery(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int count = 1,
}) async {
  for (var i = 0; i < 20; i++) {
    if (finder.evaluate().length == count) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    if (finder.evaluate().isEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('SearchScreen results', () {
    testWidgets('marks the current song returned by search', (tester) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            songs: <Song>[
              Song(id: 'current-song', title: 'Current Search Song'),
              Song(id: 'other-song', title: 'Other Search Song'),
            ],
          ),
        ),
        overrides: <Override>[
          playerStateProvider.overrideWithValue(
            const PlaybackSnapshot(
              queueSongIds: <String>['current-song'],
              currentSongId: 'current-song',
              currentIndex: 0,
              playing: false,
              processingState: AudioProcessingState.ready,
              position: Duration.zero,
              duration: Duration(minutes: 3),
              bufferedPosition: Duration.zero,
              shuffleMode: AudioServiceShuffleMode.none,
              repeatMode: AudioServiceRepeatMode.none,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Search');
      await _pumpUntilFound(tester, find.text('Current Search Song'));

      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.selected == true &&
              widget.properties.value == 'Now Playing',
        ),
        findsOneWidget,
      );
    });

    testWidgets('badges only external artist album and song results', (
      tester,
    ) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            artists: <Artist>[
              Artist(
                id: 'external-artist',
                name: 'Remote Artist',
                isExternal: true,
              ),
              Artist(
                id: 'server-artist',
                name: 'Server Artist',
                isExternal: false,
              ),
            ],
            albums: <Album>[
              Album(id: 'pl-deezer-album', name: 'Remote Album'),
            ],
            songs: <Song>[
              Song(
                id: 'remote-song',
                title: 'Remote Song',
                isExternal: true,
              ),
            ],
          ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Remote');
      await _pumpUntilFound(tester, find.text('Remote Song'));

      expect(
        find.byKey(RemoteSourceIndicator.semanticsKey),
        findsNWidgets(3),
      );
      expect(find.text('Server Artist'), findsOneWidget);
    });

    testWidgets('renders relevance-first local-first artist order', (
      tester,
    ) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(
        database,
        id: 'server-prefix',
        name: 'Aurora Local',
      );
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            artists: <Artist>[
              Artist(
                id: 'remote-prefix',
                name: 'Aurora Remote',
                isExternal: true,
              ),
              Artist(
                id: 'remote-exact',
                name: 'Aurora',
                isExternal: true,
              ),
            ],
          ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Aurora');
      await _pumpUntilFound(tester, find.text('Aurora Remote'));

      final exactY = tester
          .getTopLeft(
            find.byWidgetPredicate(
              (widget) => widget is Text && widget.data == 'Aurora',
            ),
          )
          .dy;
      final localY = tester.getTopLeft(find.text('Aurora Local')).dy;
      final remoteY = tester.getTopLeft(find.text('Aurora Remote')).dy;
      expect(exactY, lessThan(localY));
      expect(localY, lessThan(remoteY));
    });

    testWidgets('cached results appear without waiting for API', (
      tester,
    ) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'local-artist', name: 'Cache Artist');
      final apiCompleter = Completer<SearchResult3>();
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient((_) => apiCompleter.future),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Cache');
      await _pumpUntilFound(tester, find.text('Cache Artist'));

      expect(find.text('Cache Artist'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

      apiCompleter.complete(const SearchResult3());
      await tester.pump();
      await _pumpUntilGone(tester, find.byType(LinearProgressIndicator));

      expect(find.text('Cache Artist'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets(
      'pending API indicator only appears while remote is in flight',
      (
        tester,
      ) async {
        if (!sqliteAvailable) return;

        final database = createTestDatabase();
        await _insertArtist(database, id: 'local-artist', name: 'Cache Artist');
        final apiCompleter = Completer<SearchResult3>();
        final container = _createContainerWithDatabase(
          database,
          api: _FakeSearchApiClient((_) => apiCompleter.future),
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        await _pumpSearchScreen(tester, container);
        expect(find.byType(LinearProgressIndicator), findsNothing);

        await _enterSearchQuery(tester, 'Cache');
        await _pumpUntilFound(
          tester,
          find.byType(LinearProgressIndicator),
          count: 2,
        );
        expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

        apiCompleter.complete(
          const SearchResult3(
            artists: <Artist>[
              Artist(id: 'remote-artist', name: 'Cache Remote'),
            ],
          ),
        );
        await tester.pump();
        await _pumpUntilGone(tester, find.byType(LinearProgressIndicator));

        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('Cache Remote'), findsOneWidget);
      },
    );

    testWidgets('empty local results keep loading until API finishes', (
      tester,
    ) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      final apiCompleter = Completer<SearchResult3>();
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient((_) => apiCompleter.future),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Remote');

      expect(find.byType(ShimmerListPage), findsOneWidget);
      expect(find.text('Remote Artist'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      apiCompleter.complete(
        const SearchResult3(
          artists: <Artist>[Artist(id: 'remote-artist', name: 'Remote Artist')],
        ),
      );
      await tester.pump();
      await _pumpUntilGone(tester, find.byType(ShimmerListPage));

      expect(find.byType(ShimmerListPage), findsNothing);
      expect(find.text('Remote Artist'), findsOneWidget);
    });

    testWidgets('songs filter hides mixed artist and album API results', (
      tester,
    ) async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      final container = _createContainerWithDatabase(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            artists: <Artist>[
              Artist(id: 'remote-artist', name: 'Remote Artist'),
            ],
            albums: <Album>[Album(id: 'remote-album', name: 'Remote Album')],
            songs: <Song>[Song(id: 'remote-song', title: 'Remote Song')],
          ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      container
          .read(searchFilterProvider.notifier)
          .select(SearchResultType.songs);
      await _pumpSearchScreen(tester, container);
      await _enterSearchQuery(tester, 'Remote');
      await _pumpUntilFound(tester, find.text('Remote Song'));

      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.text('Remote Artist'), findsNothing);
      expect(find.text('Remote Album'), findsNothing);
    });
  });
}
