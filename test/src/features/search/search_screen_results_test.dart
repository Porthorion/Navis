import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
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
  });
}
