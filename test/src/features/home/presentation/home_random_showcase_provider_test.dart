import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/test_database.dart';

Future<List<HomeRandomShowcaseItem>> readHomeRandomShowcase(
  ProviderContainer container,
  ({bool downloadedOnly, bool likedOnly}) filters,
) async {
  await container.read(homeRandomAlbumShowcaseProvider(filters).future);
  return container.read(homeRandomShowcaseProvider(filters)).requireValue;
}

class _MutableLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  LibrarySyncState get value => state;

  set value(LibrarySyncState next) {
    state = next;
  }
}

class _CachedListenBrainzDiagnosticsOverridesController
    extends SyncDiagnosticsOverridesController {
  @override
  SyncDiagnosticsOverrides build() =>
      const SyncDiagnosticsOverrides(cachedListenBrainzPresentation: true);
}

Future<void> _insertAlbum(
  NavisDatabase db, {
  required String id,
  required String name,
  DateTime? starred,
  int? songCount,
}) {
  return db
      .into(db.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: id,
          name: name,
          artistName: const Value('Artist'),
          coverArt: Value('cover-$id'),
          starred: Value(starred),
          songCount: Value(songCount),
        ),
      );
}

class _FakeDiscoveryApiClient extends SubsonicApiClient {
  new(
    this._similarBySeed, {
    this.searchSongs = const <Song>[],
    this.searchGate,
    this.similarGate,
  }) : super(
         baseUrl: 'https://example.com',
         authConfig: const SubsonicAuthConfig(
           username: 'alice',
           password: 'secret',
           apiVersion: '1.16.1',
         ),
         enableLogging: false,
       );

  final Map<String, List<Song>> _similarBySeed;
  final List<Song> searchSongs;
  final Completer<void>? searchGate;
  final Completer<void>? similarGate;
  int activeSearchCalls = 0;
  int maxActiveSearchCalls = 0;
  int totalSearchCalls = 0;
  int totalSimilarSongCalls = 0;

  @override
  Future<List<Song>> getSimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    totalSimilarSongCalls++;
    final gate = similarGate;
    if (gate != null) {
      await gate.future;
    }
    return _similarBySeed[seedSongId] ?? const <Song>[];
  }

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
  }) async {
    totalSearchCalls++;
    activeSearchCalls++;
    if (activeSearchCalls > maxActiveSearchCalls) {
      maxActiveSearchCalls = activeSearchCalls;
    }
    try {
      final gate = searchGate;
      if (gate != null) {
        await gate.future;
      }
      return SearchResult3(songs: searchSongs.take(songCount).toList());
    } finally {
      activeSearchCalls--;
    }
  }
}

class _FakeListenBrainzApiClient extends ListenBrainzApiClient {
  new({
    required this.playlists,
    List<ListenBrainzPlaylist>? createdForPlaylists,
    List<ListenBrainzPlaylist>? userPlaylists,
    List<ListenBrainzPlaylist>? recommendationPlaylists,
    Map<String, ListenBrainzPlaylist>? detailsById,
    Map<String, Completer<ListenBrainzPlaylist>>? detailCompleters,
    this.recommendationCompleter,
  }) : createdForPlaylists = createdForPlaylists ?? playlists,
       userPlaylists = userPlaylists ?? const <ListenBrainzPlaylist>[],
       recommendationPlaylists =
           recommendationPlaylists ?? const <ListenBrainzPlaylist>[],
       detailsById = detailsById ?? <String, ListenBrainzPlaylist>{},
       detailCompleters =
           detailCompleters ?? <String, Completer<ListenBrainzPlaylist>>{};

  final List<ListenBrainzPlaylist> playlists;
  final List<ListenBrainzPlaylist> createdForPlaylists;
  final List<ListenBrainzPlaylist> userPlaylists;
  final List<ListenBrainzPlaylist> recommendationPlaylists;
  final Map<String, ListenBrainzPlaylist> detailsById;
  final Map<String, Completer<ListenBrainzPlaylist>> detailCompleters;
  final Completer<List<ListenBrainzPlaylist>>? recommendationCompleter;
  final List<String> detailStarts = <String>[];
  int recommendationPlaylistCalls = 0;
  int validationCalls = 0;

  @override
  Future<ListenBrainzTokenDetails> validateTokenDetails(
    String userToken, {
    bool userInitiated = false,
    CancelToken? cancelToken,
  }) async {
    validationCalls++;
    return const ListenBrainzTokenDetails(valid: true, userName: 'alice');
  }

  @override
  Future<List<ListenBrainzPlaylist>> getRecommendationPlaylists({
    required String userName,
    String? userToken,
    CancelToken? cancelToken,
  }) async {
    recommendationPlaylistCalls++;
    if (recommendationCompleter != null) {
      return await recommendationCompleter!.future;
    }
    return recommendationPlaylists;
  }

  @override
  Future<ListenBrainzPlaylist> getPlaylist(
    String playlistMbid, {
    bool fetchMetadata = true,
    String? userToken,
    CancelToken? cancelToken,
  }) async {
    detailStarts.add(playlistMbid);
    final detailCompleter = detailCompleters[playlistMbid];
    if (detailCompleter != null) {
      return await detailCompleter.future;
    }
    final allPlaylists = <ListenBrainzPlaylist>[
      ...playlists,
      ...createdForPlaylists,
      ...userPlaylists,
      ...recommendationPlaylists,
    ];
    return detailsById[playlistMbid] ??
        allPlaylists.firstWhere(
          (playlist) => playlist.identifier == playlistMbid,
        );
  }
}

class _UnreadableExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async =>
      throw const CredentialReadException();

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

class _FakeExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  const new(this.token);

  final String? token;

  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async => token;

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

/// Counts token reads: the weekly stream reads the token once per body run.
class _CountingExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  new(this.token);

  final String? token;
  int reads = 0;
  Completer<String?>? gate;

  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async {
    reads++;
    return gate == null ? token : await gate!.future;
  }

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

Override _noListenBrainzTokenOverride() =>
    externalScrobbleCredentialStoreProvider.overrideWithValue(
      const _FakeExternalScrobbleCredentialStore(null),
    );

extension _HomeRandomShowcaseItemTestX on HomeRandomShowcaseItem {
  HomeRandomShowcaseAlbum get album => this as HomeRandomShowcaseAlbum;

  HomeRandomShowcaseListenBrainz get listenBrainz =>
      this as HomeRandomShowcaseListenBrainz;
}

List<Override> withHomeShowcaseTestOverrides(
  NavisDatabase database, {
  List<Override> overrides = const <Override>[],
  Duration startupIdleDelay = Duration.zero,
}) {
  return withTestDatabase(
    database,
    overrides: <Override>[
      listenBrainzDiscoverStartupIdleDelayProvider.overrideWithValue(
        startupIdleDelay,
      ),
      ...overrides,
    ],
  );
}

List<Override> _listenBrainzWeeklyOverrides({
  required NavisDatabase database,
  required ListenBrainzApiClient listenBrainz,
  required SubsonicApiClient? subsonic,
  String userName = 'alice',
  NetworkType networkType = NetworkType.wifi,
  Duration startupIdleDelay = Duration.zero,
  Override? startupSyncStateOverride,
  Override? appSettingsOverride,
  Override? credentialStoreOverride,
}) {
  return withHomeShowcaseTestOverrides(
    database,
    startupIdleDelay: startupIdleDelay,
    overrides: <Override>[
      networkTypeProvider.overrideWith((ref) => networkType),
      startupSyncStateOverride ??
          listenBrainzDiscoverStartupSyncStateProvider.overrideWithValue(
            const LibrarySyncState.idle(),
          ),
      appSettingsOverride ??
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: userName,
              ),
            ),
          ),
      credentialStoreOverride ??
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
      listenBrainzApiClientProvider.overrideWithValue(listenBrainz),
      subsonicApiProvider.overrideWithValue(subsonic),
    ],
  );
}

_FakeListenBrainzApiClient _weeklyListenBrainzClient({
  String identifier = 'jams',
  String sourcePatch = 'weekly-jams',
  String title = 'Weekly Jams for alice, week of 2026-06-15',
  String trackTitle = 'Jam Song',
  String artist = 'Artist',
  Completer<List<ListenBrainzPlaylist>>? recommendationCompleter,
}) {
  return _FakeListenBrainzApiClient(
    playlists: const <ListenBrainzPlaylist>[],
    recommendationCompleter: recommendationCompleter,
    recommendationPlaylists: <ListenBrainzPlaylist>[
      ListenBrainzPlaylist(
        identifier: identifier,
        title: title,
        sourcePatch: sourcePatch,
        tracks: const <ListenBrainzPlaylistTrack>[],
      ),
    ],
    detailsById: <String, ListenBrainzPlaylist>{
      identifier: ListenBrainzPlaylist(
        identifier: identifier,
        title: title,
        sourcePatch: sourcePatch,
        tracks: <ListenBrainzPlaylistTrack>[
          ListenBrainzPlaylistTrack(title: trackTitle, creator: artist),
        ],
      ),
    },
  );
}

Future<void> _primeListenBrainzWeeklyCache(
  NavisDatabase database, {
  String userName = 'alice',
  String identifier = 'jams',
  String sourcePatch = 'weekly-jams',
  String title = 'Weekly Jams for alice, week of 2026-06-15',
  String trackTitle = 'Jam Song',
  String artist = 'Artist',
  String songId = 'song-jams',
  List<Song>? searchSongs,
}) async {
  final fakeApi = _FakeDiscoveryApiClient(
    {},
    searchSongs:
        searchSongs ??
        <Song>[Song(id: songId, title: trackTitle, artist: artist)],
  );
  final container = ProviderContainer(
    overrides: _listenBrainzWeeklyOverrides(
      database: database,
      listenBrainz: _weeklyListenBrainzClient(
        identifier: identifier,
        sourcePatch: sourcePatch,
        title: title,
        trackTitle: trackTitle,
        artist: artist,
      ),
      subsonic: fakeApi,
      userName: userName,
    ),
  );
  await container.read(listenBrainzDiscoverProvider.future);
  container.dispose();
  debugResetListenBrainzDiscoverSessionCacheForTests();
}

/// Makes the weekly cache look last searched [age] ago.
Future<void> _ageListenBrainzWeeklyCache(
  NavisDatabase database,
  Duration age, {
  String userName = 'alice',
}) async {
  for (final row in await database.cacheDao.getListenBrainzWeeklyCacheForUser(
    userName,
  )) {
    await database.cacheDao.upsertListenBrainzWeeklyCache(
      row
          .toCompanion(false)
          .copyWith(fetchedAt: Value(DateTime.now().subtract(age))),
    );
  }
}

Future<List<ListenBrainzDiscoverPlaylist>> _weeklyAfterLibrarySync(
  ProviderContainer container,
) {
  container
      .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
      .refreshAfterLibrarySync();
  return container.read(listenBrainzDiscoverProvider.future);
}

const Song _remoteJam = Song(
  id: 'ext-deezer-jam',
  title: 'Jam Song',
  artist: 'Artist',
  isExternal: true,
);

Future<List<ListenBrainzDiscoverPlaylist>> _firstListenBrainzEmission(
  ProviderContainer container,
) async {
  final firstData = Completer<List<ListenBrainzDiscoverPlaylist>>();
  final subscription = container
      .listen<AsyncValue<List<ListenBrainzDiscoverPlaylist>>>(
        listenBrainzDiscoverStreamProvider,
        (previous, next) {
          next.whenData((value) {
            if (!firstData.isCompleted) {
              firstData.complete(value);
            }
          });
        },
        fireImmediately: true,
      );
  try {
    return await firstData.future;
  } finally {
    subscription.close();
  }
}

/// Waits until the Home stream has finished matching (and persisting) every
/// playlist, so a test does not close the database under its writes.
Future<void> _listenBrainzStreamSettled(ProviderContainer container) async {
  final settled = Completer<void>();
  final subscription = container
      .listen<AsyncValue<List<ListenBrainzDiscoverPlaylist>>>(
        listenBrainzDiscoverStreamProvider,
        (previous, next) {
          next.whenData((value) {
            if (!settled.isCompleted &&
                value.every((playlist) => playlist.matchingComplete)) {
              settled.complete();
            }
          });
        },
        fireImmediately: true,
      );
  try {
    await settled.future;
  } finally {
    subscription.close();
  }
}

void main() {
  setUp(debugResetListenBrainzDiscoverSessionCacheForTests);

  group('weekly playlists integration gate', () {
    const filters = (downloadedOnly: false, likedOnly: false);

    Future<
      ({ProviderContainer container, _FakeListenBrainzApiClient listenBrainz})
    >
    openContainer({
      required NavisDatabase database,
      required StreamController<AppSettingsModel> settings,
    }) async {
      final listenBrainz = _weeklyListenBrainzClient();
      final container = ProviderContainer(
        overrides: <Override>[
          ..._listenBrainzWeeklyOverrides(
            database: database,
            listenBrainz: listenBrainz,
            subsonic: _FakeDiscoveryApiClient({}),
            startupIdleDelay: const Duration(milliseconds: 200),
            appSettingsOverride: appSettingsProvider.overrideWith(
              (ref) => settings.stream,
            ),
          ),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });
      return (container: container, listenBrainz: listenBrainz);
    }

    AppSettingsModel weekly({String disabled = '[]', bool master = true}) =>
        const AppSettingsModel.defaults().copyWith(
          listenBrainzScrobblingEnabled: true,
          listenBrainzTokenValid: true,
          listenBrainzUserName: 'alice',
          disabledIntegrations: disabled,
          externalIntegrationsEnabled: master,
        );

    test(
      'disabling weekly playlists during a credential read prevents validation',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final settings = StreamController<AppSettingsModel>();
        addTearDown(settings.close);
        final client = _weeklyListenBrainzClient();
        final credentials = _CountingExternalScrobbleCredentialStore('fixture')
          ..gate = Completer<String?>();
        final container = ProviderContainer(
          overrides: [
            ..._listenBrainzWeeklyOverrides(
              database: database,
              listenBrainz: client,
              subsonic: null,
              appSettingsOverride: appSettingsProvider.overrideWith(
                (ref) => settings.stream,
              ),
              credentialStoreOverride: externalScrobbleCredentialStoreProvider
                  .overrideWithValue(credentials),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(listenBrainzDiscoverStreamProvider, (_, _) {});
        settings.add(
          weekly().copyWith(
            listenBrainzTokenValid: false,
            clearListenBrainzUserName: true,
          ),
        );
        await container.read(appSettingsProvider.future);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(credentials.reads, 1);
        settings.add(
          weekly(disabled: '["listenbrainz.weeklyPlaylists"]').copyWith(
            listenBrainzTokenValid: false,
            clearListenBrainzUserName: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        credentials.gate!.complete('fixture');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.validationCalls, 0);
        expect(client.recommendationPlaylistCalls, 0);
      },
    );

    test('a closed gate yields no playlists and makes no requests', () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final settings = StreamController<AppSettingsModel>();
      addTearDown(settings.close);
      final opened = await openContainer(
        database: database,
        settings: settings,
      );
      settings.add(weekly(disabled: '["listenbrainz.weeklyPlaylists"]'));

      final playlists = await _firstListenBrainzEmission(opened.container);

      expect(playlists, isEmpty);
      expect(opened.listenBrainz.recommendationPlaylistCalls, 0);
    });

    test('settings still loading deny the stream, fail-closed', () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final settings = StreamController<AppSettingsModel>();
      addTearDown(settings.close);
      final opened = await openContainer(
        database: database,
        settings: settings,
      );

      final playlists = await _firstListenBrainzEmission(opened.container);

      expect(playlists, isEmpty);
    });

    for (final close in <String, AppSettingsModel>{
      'the feature switch': weekly(
        disabled: '["listenbrainz.weeklyPlaylists"]',
      ),
      'the ListenBrainz service switch': weekly(disabled: '["listenbrainz"]'),
      'the master switch': weekly(master: false),
    }.entries) {
      test(
        'closing ${close.key} removes the playlists from Home and Library',
        () async {
          final database = createTestDatabase();
          await _primeListenBrainzWeeklyCache(database);
          final settings = StreamController<AppSettingsModel>();
          addTearDown(settings.close);
          final opened = await openContainer(
            database: database,
            settings: settings,
          );
          final container = opened.container;
          final emissions = <List<ListenBrainzDiscoverPlaylist>>[];
          container.listen<AsyncValue<List<ListenBrainzDiscoverPlaylist>>>(
            listenBrainzDiscoverStreamProvider,
            (_, next) => next.whenData(emissions.add),
            fireImmediately: true,
          );
          settings.add(weekly());
          await Future.doWhile(() async {
            await pumpEventQueue();
            return !emissions.any((e) => e.isNotEmpty);
          });
          // Home's hero shows the weekly cards while the gate is open.
          expect(
            (await readHomeRandomShowcase(
              container,
              filters,
            )).whereType<HomeRandomShowcaseListenBrainz>(),
            isNotEmpty,
          );
          List<PlaylistLibraryItem> virtualItems() =>
              (container.read(playlistLibraryItemsProvider).asData?.value ??
                      const <PlaylistLibraryItem>[])
                  .where((item) => item.virtualPlaylist != null)
                  .toList();
          // Library > Playlists lists them too, ahead of the server's.
          expect(virtualItems(), isNotEmpty);

          settings.add(close.value);
          await Future.doWhile(() async {
            await pumpEventQueue();
            return emissions.last.isNotEmpty;
          });

          expect(emissions.last, isEmpty);
          expect(
            (await readHomeRandomShowcase(
              container,
              filters,
            )).whereType<HomeRandomShowcaseListenBrainz>(),
            isEmpty,
          );
          expect(virtualItems(), isEmpty);
        },
      );
    }
  });

  test('startup sync projection ignores same-stage progress updates', () async {
    final controller = _MutableLibrarySyncController();
    final container = ProviderContainer(
      overrides: <Override>[
        librarySyncControllerProvider.overrideWith(() => controller),
      ],
    );
    addTearDown(container.dispose);

    final observed = <LibrarySyncState>[];
    final subscription = container.listen(
      listenBrainzDiscoverStartupSyncStateProvider,
      (_, next) => observed.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    controller.value = const LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingSongs,
      processed: 1,
      total: 100,
    );
    await Future<void>.delayed(Duration.zero);
    controller.value = const LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingSongs,
      processed: 2,
      total: 100,
    );
    await Future<void>.delayed(Duration.zero);

    expect(observed, hasLength(2));
    expect(observed.last.status, LibrarySyncStatus.running);
    expect(observed.last.stage, LibrarySyncStage.fetchingSongs);
  });

  test(
    'library sync bridge defers ListenBrainz refresh invalidation',
    () async {
      final controller = _MutableLibrarySyncController();
      final container = ProviderContainer(
        overrides: <Override>[
          librarySyncControllerProvider.overrideWith(() => controller),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzTokenValid: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(listenBrainzLibrarySyncRefreshBridgeProvider);
      expect(container.read(listenBrainzDiscoverRefreshEpochProvider), 0);

      controller.value = const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.idle,
      );

      expect(container.read(listenBrainzDiscoverRefreshEpochProvider), 0);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(listenBrainzDiscoverRefreshEpochProvider), 1);
    },
  );

  test(
    'unrelated settings saves do not restart ListenBrainz weekly discovery',
    () async {
      final database = createTestDatabase();
      final credentialStore = _CountingExternalScrobbleCredentialStore('token');
      final listenBrainz = _weeklyListenBrainzClient();
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            listenBrainzDiscoverStartupSyncStateProvider.overrideWithValue(
              const LibrarySyncState.idle(),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              credentialStore,
            ),
            listenBrainzApiClientProvider.overrideWithValue(listenBrainz),
            subsonicApiProvider.overrideWithValue(
              _FakeDiscoveryApiClient(
                {},
                searchSongs: <Song>[
                  Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      // Real Drift-backed settings: every save emits a new model, as Playback
      // autosave, appearance changes and desktop volume persistence do.
      final repository = container.read(settingsRepositoryProvider);
      await repository.updateListenBrainzConnection(
        tokenValid: true,
        userName: 'alice',
        scrobblingEnabled: true,
      );
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          listenBrainzScrobblingEnabled: true,
          listenBrainzTokenValid: true,
          listenBrainzUserName: 'alice',
        ),
      );
      final settingsSubscription = container.listen(
        appSettingsProvider,
        (_, _) {},
      );
      addTearDown(settingsSubscription.close);
      await container.read(appSettingsProvider.future);

      final emissions = <List<ListenBrainzDiscoverPlaylist>>[];
      final subscription = container
          .listen<AsyncValue<List<ListenBrainzDiscoverPlaylist>>>(
            listenBrainzDiscoverStreamProvider,
            (_, next) {
              if (next case AsyncData(:final value)) {
                emissions.add(value);
              }
            },
            fireImmediately: true,
          );
      addTearDown(subscription.close);

      Future<void> settledAfter(int emissionCount) async {
        while (emissions.length <= emissionCount ||
            !emissions.last.every((playlist) => playlist.matchingComplete)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      Future<void> settingsApplied(
        bool Function(AppSettingsModel settings) applied,
      ) async {
        while (!applied(container.read(appSettingsProvider).requireValue)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await container.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      await settledAfter(0);
      expect(credentialStore.reads, 1);
      expect(listenBrainz.recommendationPlaylistCalls, 1);
      expect(emissions.last.single.playableSongs.single.id, 'song-jams');

      await database.appSettingsDao.updateGridArtworkSize('large');
      await repository.saveSettings(
        container
            .read(appSettingsProvider)
            .requireValue
            .copyWith(scrobbleEnabled: false),
      );
      await settingsApplied(
        (settings) =>
            !settings.scrobbleEnabled &&
            settings.gridArtworkSize == GridArtworkSize.large,
      );
      await repository.saveDesktopPlaybackVolume(
        volume: 0.4,
        lastAudibleVolume: 0.4,
      );
      await settingsApplied(
        (settings) => settings.desktopPlaybackVolume == 0.4,
      );

      expect(credentialStore.reads, 1);
      expect(listenBrainz.recommendationPlaylistCalls, 1);

      final emissionsBeforeUserChange = emissions.length;
      await database.appSettingsDao.updateListenBrainzScrobblingState(
        userName: 'bob',
      );
      await settingsApplied(
        (settings) => settings.listenBrainzUserName == 'bob',
      );
      await settledAfter(emissionsBeforeUserChange);

      expect(credentialStore.reads, 2);
      expect(listenBrainz.recommendationPlaylistCalls, 2);

      // Token validation refreshes through the epoch, which still restarts.
      container
          .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
          .refresh();
      await container.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(credentialStore.reads, 3);
    },
  );

  test(
    'a partly successful library sync also rechecks weekly matches',
    () async {
      final controller = _MutableLibrarySyncController();
      final container = ProviderContainer(
        overrides: <Override>[
          librarySyncControllerProvider.overrideWith(() => controller),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzTokenValid: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(listenBrainzLibrarySyncRefreshBridgeProvider);

      controller.value = const LibrarySyncState(
        status: LibrarySyncStatus.partial,
        stage: LibrarySyncStage.idle,
      );
      await Future<void>.delayed(Duration.zero);

      expect(container.read(listenBrainzDiscoverRefreshEpochProvider), 1);
    },
  );

  test('a manual weekly refresh that lands with a sync runs once', () async {
    final controller = _MutableLibrarySyncController();
    final container = ProviderContainer(
      overrides: <Override>[
        librarySyncControllerProvider.overrideWith(() => controller),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              listenBrainzTokenValid: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(listenBrainzLibrarySyncRefreshBridgeProvider);

    // Home pull-to-refresh awaits the sync, then starts a full refresh before
    // the bridge's deferred refresh runs.
    controller.value = const LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.idle,
    );
    container
        .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
        .refreshFull();
    await Future<void>.delayed(Duration.zero);

    // The full refresh already covers the sync; it is not replaced by a
    // cached re-match.
    expect(container.read(listenBrainzDiscoverRefreshEpochProvider), 1);
  });

  test('after a library sync a remote match switches to the library copy without search3', () async {
    final database = createTestDatabase();
    await _primeListenBrainzWeeklyCache(
      database,
      searchSongs: const <Song>[_remoteJam],
    );
    // The album has since landed on the server and been synced.
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'library-jam',
        title: 'Jam Song',
        artistName: const Value('Artist'),
      ),
    ]);
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: _weeklyListenBrainzClient(),
        subsonic: fakeApi,
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await _weeklyAfterLibrarySync(container);

    final recommendation = result.single.recommendations.single;
    expect(recommendation.hasServerSong, isTrue);
    expect(recommendation.tableSong!.id, 'library-jam');
    expect(fakeApi.totalSearchCalls, 0);
  });

  test(
    'a day-old weekly cache searches the server again for remote matches',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(
        database,
        searchSongs: const <Song>[_remoteJam],
      );
      await _ageListenBrainzWeeklyCache(database, const Duration(days: 2));
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          _remoteJam,
          Song(id: 'server-jam', title: 'Jam Song', artist: 'Artist'),
        ],
      );
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(fakeApi.totalSearchCalls, 1);
      // The copy on the server wins over the remote one.
      expect(result.single.playableSongs.single.id, 'server-jam');
      final row = (await database.cacheDao.getListenBrainzWeeklyCacheForUser(
        'alice',
      )).single;
      expect(
        DateTime.now().difference(row.fetchedAt),
        lessThan(const Duration(minutes: 1)),
      );
    },
  );

  test(
    'a daily recheck that finds nothing better keeps the remote match',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(
        database,
        searchSongs: const <Song>[_remoteJam],
      );
      await _ageListenBrainzWeeklyCache(database, const Duration(days: 2));
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(fakeApi.totalSearchCalls, 1);
      expect(result.single.playableSongs.single.id, 'ext-deezer-jam');
    },
  );

  test(
    'unmatched weekly tracks wait for the daily recheck to search again',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(
        database,
        searchSongs: const <Song>[],
      );
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result.single.playableSongs, isEmpty);
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test(
    'a cached weekly song deleted from the server is no longer playable',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      await (database.update(database.songsTable)
            ..where((table) => table.id.equals('song-jams')))
          .write(SongsTableCompanion(serverDeletedAt: Value(DateTime.now())));
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);
      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(first.single.playableSongs, isEmpty);
      expect(result.single.playableSongs, isEmpty);
      expect(
        result.single.recommendations.single.status,
        ListenBrainzRecommendationMatchStatus.unmatched,
      );
    },
  );

  test('ListenBrainz weekly detail requests start concurrently', () async {
    final database = createTestDatabase();
    final explorationCompleter = Completer<ListenBrainzPlaylist>();
    final jamsCompleter = Completer<ListenBrainzPlaylist>();
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailCompleters: <String, Completer<ListenBrainzPlaylist>>{
        'exploration': explorationCompleter,
        'jams': jamsCompleter,
      },
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(_FakeDiscoveryApiClient({})),
        ],
      ),
    );
    addTearDown(() async {
      if (!explorationCompleter.isCompleted) {
        explorationCompleter.complete(
          const ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        );
      }
      if (!jamsCompleter.isCompleted) {
        jamsCompleter.complete(
          const ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        );
      }
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final future = container.read(listenBrainzDiscoverProvider.future);
    for (
      var attempt = 0;
      attempt < 50 && fakeListenBrainz.detailStarts.length < 2;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      fakeListenBrainz.detailStarts,
      containsAll(<String>['exploration', 'jams']),
    );

    explorationCompleter.complete(
      const ListenBrainzPlaylist(
        identifier: 'exploration',
        title: 'Weekly Exploration',
        sourcePatch: 'weekly-exploration',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
    );
    jamsCompleter.complete(
      const ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
    );
    await future;
  });

  test('ListenBrainz remote matching is globally bounded', () async {
    final database = createTestDatabase();
    final searchGate = Completer<void>();
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchGate: searchGate,
      searchSongs: const <Song>[],
    );
    final tracks = List<ListenBrainzPlaylistTrack>.generate(
      5,
      (index) => ListenBrainzPlaylistTrack(
        title: 'Remote Song $index',
        creator: 'Remote Artist',
      ),
    );
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: <String, ListenBrainzPlaylist>{
        'exploration': ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: tracks,
        ),
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: tracks,
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      if (!searchGate.isCompleted) {
        searchGate.complete();
      }
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final future = container.read(listenBrainzDiscoverProvider.future);
    for (
      var attempt = 0;
      attempt < 50 && fakeApi.activeSearchCalls < 2;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(fakeApi.maxActiveSearchCalls, 2);
    searchGate.complete();
    await future;

    expect(fakeApi.totalSearchCalls, 10);
    expect(fakeApi.maxActiveSearchCalls, lessThanOrEqualTo(2));
  });

  test('ListenBrainz duplicate exact title and artist candidates are not ambiguous', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchSongs: const <Song>[
        Song(
          id: 'toxicity-album',
          title: 'Toxicity',
          artist: 'System Of A Down',
          album: 'Toxicity',
          duration: 219,
        ),
        Song(
          id: 'toxicity-compilation',
          title: 'Toxicity',
          artist: 'System Of A Down',
          album: 'Greatest Hits',
          duration: 219,
        ),
      ],
    );
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: const <String, ListenBrainzPlaylist>{
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[
            ListenBrainzPlaylistTrack(
              title: 'Toxicity',
              creator: 'System Of A Down',
            ),
          ],
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result, hasLength(1));
    expect(
      result.single.recommendations.single.status,
      ListenBrainzRecommendationMatchStatus.matched,
    );
    expect(result.single.recommendations.single.song!.id, 'toxicity-album');
  });

  test('ListenBrainz local matches do not call search3', () async {
    final database = createTestDatabase();
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'talking-to-the-moon',
        title: 'Talking to the Moon',
        artistName: const Value('Bruno Mars'),
        albumName: const Value('Doo-Wops & Hooligans'),
        duration: const Value(217),
      ),
    ]);
    final fakeApi = _FakeDiscoveryApiClient({}, searchSongs: const <Song>[]);
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: const <String, ListenBrainzPlaylist>{
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[
            ListenBrainzPlaylistTrack(
              title: 'Talking to the Moon',
              creator: 'Bruno Mars',
              album: 'Doo-Wops & Hooligans',
              durationMs: 217000,
            ),
          ],
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result, hasLength(1));
    expect(
      result.single.recommendations.single.status,
      ListenBrainzRecommendationMatchStatus.matched,
    );
    expect(
      result.single.recommendations.single.tableSong!.id,
      'talking-to-the-moon',
    );
    expect(fakeApi.totalSearchCalls, 0);
  });

  test('ListenBrainz manual rematch bypasses stale miss and persists search3 match', () async {
    final database = createTestDatabase();
    final searchSongs = <Song>[];
    final fakeApi = _FakeDiscoveryApiClient({}, searchSongs: searchSongs);
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: const <String, ListenBrainzPlaylist>{
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[
            ListenBrainzPlaylistTrack(
              title: 'Remote Song',
              creator: 'Remote Artist',
              album: 'Remote Album',
            ),
          ],
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final initial = await container.read(listenBrainzDiscoverProvider.future);
    expect(initial.single.matchedCount, 0);
    expect(fakeApi.totalSearchCalls, 1);

    searchSongs.add(
      const Song(
        id: 'remote-1',
        title: 'Remote Song',
        artist: 'Remote Artist',
        album: 'Remote Album',
      ),
    );
    final rematched = await container
        .read(listenBrainzPlaylistRematchControllerProvider.notifier)
        .rematch(initial.single);

    expect(rematched.matchedCount, 1);
    expect(rematched.recommendations.single.song!.id, 'remote-1');
    expect(fakeApi.totalSearchCalls, 2);

    final cacheRows = await database.cacheDao.getListenBrainzWeeklyCacheForUser(
      'alice',
    );
    expect(cacheRows, hasLength(1));
    expect(cacheRows.single.matchedCount, 1);
    final cachedRecommendations =
        jsonDecode(cacheRows.single.recommendationsJson) as List<dynamic>;
    final cachedRecommendation = Map<String, dynamic>.from(
      cachedRecommendations.single as Map,
    );
    expect(cachedRecommendation['song'], isNotNull);
  });

  test('manual rematch with an unreadable token fails retryably', () async {
    final database = createTestDatabase();
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            _UnreadableExternalScrobbleCredentialStore(),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await pumpEventQueue();
      await database.close();
    });
    const playlist = ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[],
    );
    final controller = container.read(
      listenBrainzPlaylistRematchControllerProvider.notifier,
    );

    // The Home card reports any rematch failure as a retryable error notice.
    await expectLater(
      controller.rematch(playlist),
      throwsA(isA<CredentialReadException>()),
    );
    expect(controller.isMatching('weekly-jams'), isFalse);
  });

  test('cached weekly playlists emit before remote futures complete', () async {
    final database = createTestDatabase();
    await _primeListenBrainzWeeklyCache(database);
    final recommendationCompleter = Completer<List<ListenBrainzPlaylist>>();
    final fakeListenBrainz = _weeklyListenBrainzClient(
      recommendationCompleter: recommendationCompleter,
    );
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: fakeListenBrainz,
        subsonic: fakeApi,
        startupIdleDelay: const Duration(milliseconds: 200),
      ),
    );
    addTearDown(() async {
      if (!recommendationCompleter.isCompleted) {
        recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
      }
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final first = await _firstListenBrainzEmission(container);

    expect(first, hasLength(1));
    expect(first.single.playlist.identifier, 'jams');
    expect(first.single.matchingComplete, isTrue);
    expect(first.single.playableSongs.single.id, 'song-jams');
    expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
    expect(fakeApi.totalSearchCalls, 0);
  });

  test(
    'cached weekly startup waits for idle before metadata/detail work',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final fakeListenBrainz = _weeklyListenBrainzClient();
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: fakeListenBrainz,
          subsonic: fakeApi,
          startupIdleDelay: const Duration(milliseconds: 60),
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);
      await Future<void>.delayed(Duration.zero);

      expect(first.single.playableSongs.single.id, 'song-jams');
      expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
      expect(fakeListenBrainz.detailStarts, isEmpty);
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test('unchanged weekly metadata after idle does not run search3', () async {
    final database = createTestDatabase();
    await _primeListenBrainzWeeklyCache(database);
    final fakeListenBrainz = _weeklyListenBrainzClient();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: fakeListenBrainz,
        subsonic: fakeApi,
        startupIdleDelay: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result.single.playableSongs.single.id, 'song-jams');
    expect(fakeListenBrainz.recommendationPlaylistCalls, 1);
    expect(fakeListenBrainz.detailStarts, isEmpty);
    expect(fakeApi.totalSearchCalls, 0);
  });

  test(
    'changed weekly metadata after idle resolves and persists cache',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(id: 'fresh-song', title: 'Fresh Jam', artist: 'Artist'),
        ],
      );
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(
            title: 'Weekly Jams for alice, week of 2026-06-22',
            trackTitle: 'Fresh Jam',
          ),
          subsonic: fakeApi,
          startupIdleDelay: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result.single.playableSongs.single.id, 'fresh-song');
      expect(fakeApi.totalSearchCalls, 1);

      final cacheRows = await database.cacheDao
          .getListenBrainzWeeklyCacheForUser('alice');
      final cachedRecommendations =
          jsonDecode(cacheRows.single.recommendationsJson) as List<dynamic>;
      final cachedRecommendation = Map<String, dynamic>.from(
        cachedRecommendations.single as Map,
      );
      final cachedSong = Map<String, dynamic>.from(
        cachedRecommendation['song'] as Map,
      );
      expect(cachedSong['id'], 'fresh-song');
    },
  );

  test(
    'cold weekly start emits loading cards without awaiting search3',
    () async {
      final database = createTestDatabase();
      final searchGate = Completer<void>();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchGate: searchGate,
        searchSongs: const <Song>[],
      );
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
          startupIdleDelay: const Duration(milliseconds: 60),
        ),
      );
      addTearDown(() async {
        if (!searchGate.isCompleted) {
          searchGate.complete();
        }
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);

      expect(first, hasLength(2));
      expect(first.map((playlist) => playlist.playlist.sourcePatch), <String?>[
        'weekly-exploration',
        'weekly-jams',
      ]);
      expect(
        first.every((playlist) => playlist.recommendations.isEmpty),
        isTrue,
      );
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test(
    'cold weekly start keeps loading cards visible while resolving',
    () async {
      final database = createTestDatabase();
      final searchGate = Completer<void>();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchGate: searchGate,
        searchSongs: const <Song>[],
      );
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
          startupIdleDelay: const Duration(milliseconds: 80),
        ),
      );
      addTearDown(() async {
        if (!searchGate.isCompleted) {
          searchGate.complete();
        }
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        first.every((playlist) => playlist.recommendations.isEmpty),
        isTrue,
      );
      expect(fakeApi.totalSearchCalls, 1);
    },
  );

  test(
    'automatic weekly resolver waits while startup sync is running',
    () async {
      final database = createTestDatabase();
      final fakeListenBrainz = _weeklyListenBrainzClient();
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: fakeListenBrainz,
          subsonic: fakeApi,
          startupSyncStateOverride: listenBrainzDiscoverStartupSyncStateProvider
              .overrideWithValue(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.fetchingSongs,
                ),
              ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        first.every((playlist) => playlist.recommendations.isEmpty),
        isTrue,
      );
      expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
      expect(fakeListenBrainz.detailStarts, isEmpty);
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test(
    'automatic weekly resolver starts after startup sync completes',
    () async {
      final database = createTestDatabase();
      var syncState = const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingSongs,
      );
      final fakeListenBrainz = _weeklyListenBrainzClient();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
        ],
      );
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: fakeListenBrainz,
          subsonic: fakeApi,
          startupSyncStateOverride: listenBrainzDiscoverStartupSyncStateProvider
              .overrideWith((ref) => syncState),
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);
      expect(
        first.every((playlist) => playlist.recommendations.isEmpty),
        isTrue,
      );
      expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fakeListenBrainz.recommendationPlaylistCalls, 0);

      syncState = const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      );
      container.invalidate(listenBrainzDiscoverStartupSyncStateProvider);
      container.invalidate(listenBrainzDiscoverProvider);
      container.invalidate(listenBrainzDiscoverStreamProvider);
      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result.single.playableSongs.single.id, 'song-jams');
      expect(fakeListenBrainz.recommendationPlaylistCalls, 1);
      expect(fakeApi.totalSearchCalls, 1);
    },
  );

  test('manual weekly refresh bypasses running startup sync', () async {
    final database = createTestDatabase();
    final fakeListenBrainz = _weeklyListenBrainzClient();
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchSongs: const <Song>[
        Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
      ],
    );
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: fakeListenBrainz,
        subsonic: fakeApi,
        startupSyncStateOverride: listenBrainzDiscoverStartupSyncStateProvider
            .overrideWithValue(
              const LibrarySyncState(
                status: LibrarySyncStatus.running,
                stage: LibrarySyncStage.fetchingSongs,
              ),
            ),
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    container.read(listenBrainzDiscoverRefreshEpochProvider.notifier).refresh();
    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result.single.playableSongs.single.id, 'song-jams');
    expect(fakeListenBrainz.recommendationPlaylistCalls, 1);
    expect(fakeApi.totalSearchCalls, 1);
  });

  test('weekly provider disposal before idle prevents search3', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({}, searchSongs: const <Song>[]);
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: _weeklyListenBrainzClient(),
        subsonic: fakeApi,
        startupIdleDelay: const Duration(milliseconds: 40),
      ),
    );
    final subscription = container
        .listen<AsyncValue<List<ListenBrainzDiscoverPlaylist>>>(
          listenBrainzDiscoverStreamProvider,
          (previous, next) {},
          fireImmediately: true,
        );

    await Future<void>.delayed(Duration.zero);
    subscription.close();
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await database.close();

    expect(fakeApi.totalSearchCalls, 0);
  });

  test(
    'weekly remote matches persist and seed the next provider start',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: fakeApi,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final first = await _firstListenBrainzEmission(container);

      expect(first.single.playableSongs.single.id, 'song-jams');
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test('manual weekly refresh bypasses persisted cache', () async {
    final database = createTestDatabase();
    await _primeListenBrainzWeeklyCache(database);
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchSongs: const <Song>[
        Song(id: 'fresh-song', title: 'Fresh Jam', artist: 'Artist'),
      ],
    );
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: _weeklyListenBrainzClient(
          title: 'Weekly Jams for alice, week of 2026-06-22',
          trackTitle: 'Fresh Jam',
        ),
        subsonic: fakeApi,
        startupIdleDelay: const Duration(seconds: 1),
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    container.read(listenBrainzDiscoverRefreshEpochProvider.notifier).refresh();
    final first = await _firstListenBrainzEmission(container);
    final finalResult = await container.read(
      listenBrainzDiscoverProvider.future,
    );

    // The stream the first emission came from matches on its own.
    await _listenBrainzStreamSettled(container);

    expect(first.every((playlist) => playlist.recommendations.isEmpty), isTrue);
    expect(finalResult.single.playableSongs.single.id, 'fresh-song');
    expect(fakeApi.totalSearchCalls, 1);
  });

  test(
    'offline weekly discovery uses persisted cache without remote calls',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final fakeApi = _FakeDiscoveryApiClient({});
      final fakeListenBrainz = _weeklyListenBrainzClient();
      final container = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: fakeListenBrainz,
          subsonic: fakeApi,
          networkType: NetworkType.offline,
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result.single.playableSongs.single.id, 'song-jams');
      expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
      expect(fakeApi.totalSearchCalls, 0);
    },
  );

  test(
    'clone diagnostics can present cached weekly playlists without credentials',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.offline),
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            _noListenBrainzTokenOverride(),
            syncDiagnosticsOverridesProvider.overrideWith(
              _CachedListenBrainzDiagnosticsOverridesController.new,
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result.single.playableSongs.single.id, 'song-jams');
    },
  );

  test('weekly cache is isolated by ListenBrainz user', () async {
    final database = createTestDatabase();
    await _primeListenBrainzWeeklyCache(database, userName: 'alice');
    final fakeApi = _FakeDiscoveryApiClient({});
    final fakeListenBrainz = _weeklyListenBrainzClient();
    final container = ProviderContainer(
      overrides: _listenBrainzWeeklyOverrides(
        database: database,
        listenBrainz: fakeListenBrainz,
        subsonic: fakeApi,
        userName: 'bob',
        networkType: NetworkType.offline,
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result, isEmpty);
    expect(fakeListenBrainz.recommendationPlaylistCalls, 0);
    expect(fakeApi.totalSearchCalls, 0);
  });

  test(
    'weekly cache is cleared when remote weekly targets disappear',
    () async {
      final database = createTestDatabase();
      await _primeListenBrainzWeeklyCache(database);
      final onlineContainer = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _FakeListenBrainzApiClient(
            playlists: const <ListenBrainzPlaylist>[],
            recommendationPlaylists: const <ListenBrainzPlaylist>[],
          ),
          subsonic: _FakeDiscoveryApiClient({}),
        ),
      );
      final onlineResult = await onlineContainer.read(
        listenBrainzDiscoverProvider.future,
      );
      onlineContainer.dispose();
      debugResetListenBrainzDiscoverSessionCacheForTests();

      final offlineContainer = ProviderContainer(
        overrides: _listenBrainzWeeklyOverrides(
          database: database,
          listenBrainz: _weeklyListenBrainzClient(),
          subsonic: _FakeDiscoveryApiClient({}),
          networkType: NetworkType.offline,
        ),
      );
      addTearDown(() async {
        offlineContainer.dispose();
        await database.close();
      });

      final offlineResult = await offlineContainer.read(
        listenBrainzDiscoverProvider.future,
      );

      expect(onlineResult, isEmpty);
      expect(offlineResult, isEmpty);
    },
  );

  group('random showcase song-count preference', () {
    for (final albums in <List<Album>>[
      const [
        Album(id: 'single', name: 'Single', songCount: 1),
        Album(id: 'album', name: 'Album', songCount: 10),
        Album(id: 'pair', name: 'Pair', songCount: 2),
        Album(id: 'unknown', name: 'Unknown'),
        Album(id: 'ep', name: 'EP', songCount: 3),
      ],
      const [
        Album(id: 'single', name: 'Single', songCount: 1),
        Album(id: 'pair', name: 'Pair', songCount: 2),
      ],
      [
        const Album(id: 'single', name: 'Single', songCount: 1),
        for (var i = 0; i < 12; i++)
          Album(id: 'album-$i', name: 'Album $i', songCount: 3),
      ],
    ]) {
      test(
        'server ordering and fallback with ${albums.length} candidates',
        () async {
          final database = createTestDatabase();
          final container = ProviderContainer(
            overrides: withHomeShowcaseTestOverrides(
              database,
              overrides: <Override>[
                networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
                subsonicApiProvider.overrideWithValue(
                  _FakeDiscoveryApiClient({}),
                ),
                likedSongsProvider.overrideWithValue(const AsyncData([])),
                homeRandomAlbumsProvider.overrideWith((ref) async => albums),
              ],
            ),
          );
          addTearDown(() async {
            container.dispose();
            // Let disposed providers' in-flight queries settle before closing.
            await pumpEventQueue();
            await database.close();
          });

          final result = await container.read(
            homeRandomAlbumShowcaseProvider((
              downloadedOnly: false,
              likedOnly: false,
            )).future,
          );

          final expected = switch (albums.length) {
            5 => ['album', 'unknown', 'ep', 'single', 'pair'],
            2 => ['single', 'pair'],
            _ => [for (var i = 0; i < 12; i++) 'album-$i'],
          };
          expect(result.map((album) => album.id), expected);
        },
      );
    }

    for (final filters in [
      (downloadedOnly: false, likedOnly: false),
      (downloadedOnly: true, likedOnly: false),
      (downloadedOnly: false, likedOnly: true),
      (downloadedOnly: true, likedOnly: true),
    ]) {
      test('local ordering and fallback with $filters', () async {
        final database = createTestDatabase();
        for (final (id, count) in [
          ('single', 1),
          ('ep', 3),
          ('unknown', null),
        ]) {
          await _insertAlbum(
            database,
            id: id,
            name: id,
            songCount: count,
            starred: DateTime(2026),
          );
        }
        final container = ProviderContainer(
          overrides: withHomeShowcaseTestOverrides(
            database,
            overrides: <Override>[
              networkTypeProvider.overrideWith((ref) => NetworkType.offline),
              likedSongsProvider.overrideWithValue(const AsyncData([])),
              downloadedContentIdsProvider.overrideWithValue(
                const AsyncData((
                  albumIds: <String>{'single', 'ep', 'unknown'},
                  artistIds: <String>{},
                )),
              ),
            ],
          ),
        );
        addTearDown(() async {
          container.dispose();
          // Let disposed providers' in-flight queries settle before closing.
          await pumpEventQueue();
          await database.close();
        });

        final result = await container.read(
          homeRandomAlbumShowcaseProvider(filters).future,
        );

        expect(result, hasLength(3));
        expect(
          result.take(2).map((album) => album.id),
          unorderedEquals(['ep', 'unknown']),
        );
        expect(result.last.id, 'single');
      });
    }
  });

  test('server random keeps the local artwork revision', () async {
    final database = createTestDatabase();
    await _insertAlbum(database, id: 'srv-1', name: 'Server Album');
    await database.libraryDao.bumpCoverArtRevisions(albumIds: ['srv-1']);
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          _noListenBrainzTokenOverride(),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(
                id: 'srv-1',
                name: 'Server Album',
                artist: 'Server Artist',
                coverArt: 'server-cover',
                year: 2025,
                songCount: 10,
              ),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
    expect(result.first.album.source, HomeRandomShowcaseSource.serverRandom);
    expect(result.first.album.coverArtRevision, 1);
  });

  test(
    'online unfiltered prepends weekly ListenBrainz playlists in fixed order',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(id: 'song-exploration', title: 'Explore Song', artist: 'Artist'),
          Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
        ],
      );
      final fakeListenBrainz = _FakeListenBrainzApiClient(
        playlists: const <ListenBrainzPlaylist>[],
        createdForPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'created-jams',
            title: 'Weekly Jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        userPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'owned-exploration',
            title: 'Weekly Exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        recommendationPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'daily-1',
            title: 'Daily Mix 1',
            sourcePatch: 'daily-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams for alice, week of 2026-06-15',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'monthly',
            title: 'Monthly Jams',
            sourcePatch: 'monthly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration for alice, week of 2026-06-15',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        detailsById: const <String, ListenBrainzPlaylist>{
          'jams': ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams for alice, week of 2026-06-15',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Jam Song', creator: 'Artist'),
            ],
          ),
          'exploration': ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration for alice, week of 2026-06-15',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(
                title: 'Explore Song',
                creator: 'Artist',
              ),
            ],
          ),
        },
      );
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));
      // Home's own discovery run reads the cache; let it finish before
      // the database closes.
      await _listenBrainzStreamSettled(container);

      expect(result, hasLength(3));
      expect(fakeListenBrainz.recommendationPlaylistCalls, 1);
      expect(
        result[0].listenBrainz.playlist!.displayTitle,
        'Weekly Exploration',
      );
      expect(
        result[0].listenBrainz.playlist!.playlist.identifier,
        'exploration',
      );
      expect(result[1].listenBrainz.playlist!.displayTitle, 'Weekly Jams');
      expect(result[1].listenBrainz.playlist!.playlist.identifier, 'jams');
      expect(result[2].album.id, 'srv-1');
    },
  );

  test(
    'playlist library provider includes ListenBrainz virtual playlists',
    () async {
      final virtualPlaylists = <ListenBrainzDiscoverPlaylist>[
        ListenBrainzDiscoverPlaylist(
          playlist: const ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Explore Song'),
            ],
          ),
          recommendations: const <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: 'Explore Song'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ],
        ),
        ListenBrainzDiscoverPlaylist(
          playlist: const ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Jam Song'),
            ],
          ),
          recommendations: const <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: 'Jam Song'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ],
        ),
      ];
      final container = ProviderContainer(
        overrides: <Override>[
          // Trending Now has its own test (playlist_library_items_test).
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy.denyAll(),
          ),
          playlistListProvider.overrideWithValue(
            const AsyncData<List<PlaylistsTableData>>(<PlaylistsTableData>[
              PlaylistsTableData(id: 'server-playlist', name: 'Server Mix'),
            ]),
          ),
          listenBrainzDiscoverStreamProvider.overrideWithValue(
            AsyncData<List<ListenBrainzDiscoverPlaylist>>(virtualPlaylists),
          ),
        ],
      );
      addTearDown(container.dispose);

      final libraryItems = container.read(playlistLibraryItemsProvider);

      expect(libraryItems.hasValue, isTrue);
      expect(libraryItems.requireValue.map((item) => item.id), <String>[
        listenBrainzWeeklyExplorationVirtualPlaylistId,
        listenBrainzWeeklyJamsVirtualPlaylistId,
        'server-playlist',
      ]);
    },
  );

  test(
    'online unfiltered prepends loading ListenBrainz weekly cards',
    () async {
      final database = createTestDatabase();
      final recommendationCompleter = Completer<List<ListenBrainzPlaylist>>();
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationCompleter: recommendationCompleter,
              ),
            ),
            subsonicApiProvider.overrideWithValue(_FakeDiscoveryApiClient({})),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!recommendationCompleter.isCompleted) {
          recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
        }
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));

      expect(result, hasLength(3));
      expect(result[0].stableId, 'listenbrainz:weekly-exploration');
      expect(result[0].listenBrainz.isLoading, isTrue);
      expect(result[1].stableId, 'listenbrainz:weekly-jams');
      expect(result[1].listenBrainz.isLoading, isTrue);
      expect(result[2].album.id, 'srv-1');
    },
  );

  test('online unfiltered compacts Weekly Jams to front when exploration is absent', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchSongs: const <Song>[
        Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
      ],
    );
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'jams',
                  title: 'Weekly Jams for alice, week of 2026-06-15',
                  sourcePatch: 'weekly-jams',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
              detailsById: const <String, ListenBrainzPlaylist>{
                'jams': ListenBrainzPlaylist(
                  identifier: 'jams',
                  title: 'Weekly Jams for alice, week of 2026-06-15',
                  tracks: <ListenBrainzPlaylistTrack>[
                    ListenBrainzPlaylistTrack(
                      title: 'Jam Song',
                      creator: 'Artist',
                    ),
                  ],
                ),
              },
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));
    // Home's own discovery run reads the cache; let it finish before
    // the database closes.
    await _listenBrainzStreamSettled(container);

    expect(result, hasLength(2));
    expect(result.first.listenBrainz.playlist!.playlist.identifier, 'jams');
    expect(result[1].album.id, 'srv-1');
  });

  test('online unfiltered ignores ordinary ListenBrainz playlists with weekly titles', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              createdForPlaylists: const <ListenBrainzPlaylist>[],
              userPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'jams',
                  title: 'Weekly Jams',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test('online unfiltered ignores non-target ListenBrainz playlists', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'monthly',
                  title: 'Monthly Weekly Mix',
                  sourcePatch: 'daily-jams',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test(
    'ListenBrainz card stays visible when Subsonic API cannot match tracks',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'loc-1', name: 'Local Album');
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration for alice, week of 2026-06-15',
                    sourcePatch: 'weekly-exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
                detailsById: const <String, ListenBrainzPlaylist>{
                  'exploration': ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration for alice, week of 2026-06-15',
                    tracks: <ListenBrainzPlaylistTrack>[
                      ListenBrainzPlaylistTrack(
                        title: 'Remote Song',
                        creator: 'Remote Artist',
                      ),
                    ],
                  ),
                },
              ),
            ),
            subsonicApiProvider.overrideWithValue(null),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));

      expect(result, hasLength(2));
      expect(
        result.first.listenBrainz.playlist!.displayTitle,
        'Weekly Exploration',
      );
      expect(result.first.listenBrainz.playlist!.matchedCount, 0);
      expect(result.first.listenBrainz.playlist!.totalCount, 1);
      expect(result[1].album.source, HomeRandomShowcaseSource.localFallback);
    },
  );

  test(
    'online unfiltered removes weekly playlist with zero detail tracks',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration',
                    sourcePatch: 'weekly-exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
                detailsById: const <String, ListenBrainzPlaylist>{
                  'exploration': ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                },
              ),
            ),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));

      expect(result, hasLength(1));
      expect(result.first.album.id, 'srv-1');
    },
  );

  test('online unfiltered keeps weekly playlist with zero matches', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  sourcePatch: 'weekly-exploration',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
              detailsById: const <String, ListenBrainzPlaylist>{
                'exploration': ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  tracks: <ListenBrainzPlaylistTrack>[
                    ListenBrainzPlaylistTrack(
                      title: 'Remote Song',
                      creator: 'Remote Artist',
                    ),
                  ],
                ),
              },
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(2));
    expect(
      result.first.listenBrainz.playlist!.displayTitle,
      'Weekly Exploration',
    );
    expect(result.first.listenBrainz.playlist!.matchedCount, 0);
    expect(result.first.listenBrainz.playlist!.totalCount, 1);
    expect(result[1].album.id, 'srv-1');

    final cacheRows = await database.cacheDao.getListenBrainzWeeklyCacheForUser(
      'alice',
    );
    expect(cacheRows, hasLength(1));
    expect(cacheRows.single.matchedCount, 0);
    expect(cacheRows.single.totalCount, 1);
    final cachedRecommendations =
        jsonDecode(cacheRows.single.recommendationsJson) as List<dynamic>;
    final cachedRecommendation = Map<String, dynamic>.from(
      cachedRecommendations.single as Map,
    );
    expect(cachedRecommendation['song'], isNull);
  });

  test('missing token falls back to random albums', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore(null),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test(
    'online unfiltered uses liked-song discovery before random fallback',
    () async {
      final database = createTestDatabase();
      for (var i = 0; i < 12; i++) {
        await _insertAlbum(database, id: 'disc-$i', name: 'Discovery $i');
      }

      final fakeApi = _FakeDiscoveryApiClient({
        'seed-1': const <Song>[
          Song(id: 'sim-1', title: 'Sim 1', albumId: 'disc-1', album: 'Disc 1'),
          Song(id: 'sim-2', title: 'Sim 2', albumId: 'disc-2', album: 'Disc 2'),
          Song(id: 'sim-3', title: 'Sim 3', albumId: 'disc-3', album: 'Disc 3'),
        ],
        'seed-2': const <Song>[
          Song(id: 'sim-4', title: 'Sim 4', albumId: 'disc-4', album: 'Disc 4'),
          Song(id: 'sim-5', title: 'Sim 5', albumId: 'disc-5', album: 'Disc 5'),
          Song(id: 'sim-6', title: 'Sim 6', albumId: 'disc-6', album: 'Disc 6'),
        ],
        'seed-3': const <Song>[
          Song(id: 'sim-7', title: 'Sim 7', albumId: 'disc-7', album: 'Disc 7'),
          Song(
            id: 'sim-14',
            title: 'Sim 14',
            albumId: 'disc-0',
            album: 'Disc 0',
          ),
        ],
        'seed-4': const <Song>[
          Song(id: 'sim-8', title: 'Sim 8', albumId: 'disc-8', album: 'Disc 8'),
          Song(id: 'sim-9', title: 'Sim 9', albumId: 'disc-9', album: 'Disc 9'),
          Song(
            id: 'sim-10',
            title: 'Sim 10',
            albumId: 'disc-10',
            album: 'Disc 10',
          ),
        ],
        'seed-5': const <Song>[
          Song(
            id: 'sim-11',
            title: 'Sim 11',
            albumId: 'disc-11',
            album: 'Disc 11',
          ),
          Song(
            id: 'sim-12',
            title: 'Sim 12',
            albumId: 'disc-6',
            album: 'Disc 6',
          ),
          Song(
            id: 'sim-13',
            title: 'Sim 13',
            albumId: 'disc-7',
            album: 'Disc 7',
          ),
        ],
      });

      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            _noListenBrainzTokenOverride(),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => throw StateError('discovery should be used first'),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-1',
                  title: 'Seed 1',
                  albumId: 'liked-a',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-2',
                  title: 'Seed 2',
                  albumId: 'liked-b',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-3',
                  title: 'Seed 3',
                  albumId: 'liked-c',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-4',
                  title: 'Seed 4',
                  albumId: 'liked-d',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-5',
                  title: 'Seed 5',
                  albumId: 'liked-e',
                ),
              ]),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));

      expect(result.length, greaterThanOrEqualTo(6));
      expect(
        result.every(
          (album) =>
              album.album.source == HomeRandomShowcaseSource.likedDiscovery,
        ),
        isTrue,
      );
    },
  );

  test('ListenBrainz updates do not rerun liked-song discovery', () async {
    final database = createTestDatabase();
    for (var i = 0; i < 12; i++) {
      await _insertAlbum(database, id: 'disc-$i', name: 'Discovery $i');
    }

    final fakeApi = _FakeDiscoveryApiClient({
      'seed-1': const <Song>[
        Song(id: 'sim-1', title: 'Sim 1', albumId: 'disc-1', album: 'Disc 1'),
        Song(id: 'sim-2', title: 'Sim 2', albumId: 'disc-2', album: 'Disc 2'),
      ],
      'seed-2': const <Song>[
        Song(id: 'sim-3', title: 'Sim 3', albumId: 'disc-3', album: 'Disc 3'),
        Song(id: 'sim-4', title: 'Sim 4', albumId: 'disc-4', album: 'Disc 4'),
      ],
      'seed-3': const <Song>[
        Song(id: 'sim-5', title: 'Sim 5', albumId: 'disc-5', album: 'Disc 5'),
        Song(id: 'sim-6', title: 'Sim 6', albumId: 'disc-6', album: 'Disc 6'),
      ],
      'seed-4': const <Song>[
        Song(id: 'sim-7', title: 'Sim 7', albumId: 'disc-7', album: 'Disc 7'),
        Song(id: 'sim-8', title: 'Sim 8', albumId: 'disc-8', album: 'Disc 8'),
      ],
      'seed-5': const <Song>[
        Song(id: 'sim-9', title: 'Sim 9', albumId: 'disc-9', album: 'Disc 9'),
        Song(
          id: 'sim-10',
          title: 'Sim 10',
          albumId: 'disc-10',
          album: 'Disc 10',
        ),
      ],
    });
    final recommendationCompleter = Completer<List<ListenBrainzPlaylist>>();
    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationCompleter: recommendationCompleter,
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => throw StateError('discovery should be reused'),
          ),
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'seed-1',
                title: 'Seed 1',
                albumId: 'liked-a',
              ),
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'seed-2',
                title: 'Seed 2',
                albumId: 'liked-b',
              ),
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'seed-3',
                title: 'Seed 3',
                albumId: 'liked-c',
              ),
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'seed-4',
                title: 'Seed 4',
                albumId: 'liked-d',
              ),
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'seed-5',
                title: 'Seed 5',
                albumId: 'liked-e',
              ),
            ]),
          ),
        ],
      ),
    );
    addTearDown(() async {
      if (!recommendationCompleter.isCompleted) {
        recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
      }
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    const filters = (downloadedOnly: false, likedOnly: false);
    final firstResult = await readHomeRandomShowcase(container, filters);
    final similarCallsAfterDiscovery = fakeApi.totalSimilarSongCalls;

    expect(firstResult.length, greaterThanOrEqualTo(6));
    expect(similarCallsAfterDiscovery, greaterThan(0));

    recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
    await container.read(listenBrainzDiscoverProvider.future);
    final secondResult = await readHomeRandomShowcase(container, filters);

    expect(secondResult.length, greaterThanOrEqualTo(6));
    expect(fakeApi.totalSimilarSongCalls, similarCallsAfterDiscovery);
  });

  test(
    'slow liked-song discovery falls back without waiting for completion',
    () async {
      final database = createTestDatabase();
      final similarGate = Completer<void>();
      final fakeApi = _FakeDiscoveryApiClient({
        'seed-1': const <Song>[
          Song(id: 'sim-1', title: 'Sim 1', albumId: 'disc-1', album: 'Disc 1'),
        ],
      }, similarGate: similarGate);
      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            _noListenBrainzTokenOverride(),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-1',
                  title: 'Seed 1',
                  albumId: 'liked-a',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-2',
                  title: 'Seed 2',
                  albumId: 'liked-b',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-3',
                  title: 'Seed 3',
                  albumId: 'liked-c',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-4',
                  title: 'Seed 4',
                  albumId: 'liked-d',
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'seed-5',
                  title: 'Seed 5',
                  albumId: 'liked-e',
                ),
              ]),
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!similarGate.isCompleted) {
          similarGate.complete();
        }
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: false,
        likedOnly: false,
      ));

      expect(fakeApi.totalSimilarSongCalls, 3);
      expect(result, hasLength(1));
      expect(result.first.album.id, 'srv-1');
      expect(result.first.album.source, HomeRandomShowcaseSource.serverRandom);
    },
  );

  test('offline falls back to local random pool', () async {
    final database = createTestDatabase();
    await _insertAlbum(database, id: 'loc-1', name: 'Local Album');

    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.offline),
          _noListenBrainzTokenOverride(),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-ignored', name: 'Ignored Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: false,
    ));

    expect(result, hasLength(1));
    expect(result.first.album.id, 'loc-1');
    expect(result.first.album.source, HomeRandomShowcaseSource.localFallback);
  });

  test('liked-only tops up albums from liked songs when needed', () async {
    final database = createTestDatabase();
    await _insertAlbum(
      database,
      id: 'liked-explicit',
      name: 'Explicitly Liked Album',
      starred: DateTime(2026, 1, 1),
    );
    await _insertAlbum(
      database,
      id: 'liked-song-album',
      name: 'Song-Liked Album',
    );

    final container = ProviderContainer(
      overrides: withHomeShowcaseTestOverrides(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          _noListenBrainzTokenOverride(),
          likedSongsProvider.overrideWithValue(
            AsyncData(<SongsTableData>[
              SongsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'liked-song-1',
                title: 'Liked Song',
                albumId: 'liked-song-album',
                starred: DateTime(2026, 1, 2),
              ),
            ]),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      // Let disposed providers' in-flight queries settle before closing.
      await pumpEventQueue();
      await database.close();
    });

    final result = await readHomeRandomShowcase(container, (
      downloadedOnly: false,
      likedOnly: true,
    ));

    final ids = result.map((album) => album.album.id).toSet();
    expect(ids, contains('liked-explicit'));
    expect(ids, contains('liked-song-album'));
    expect(
      result.every(
        (album) => album.album.source == HomeRandomShowcaseSource.localFallback,
      ),
      isTrue,
    );
  });

  test(
    'downloaded-only filters local random pool to downloaded albums',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'album-a', name: 'Album A');
      await _insertAlbum(database, id: 'album-b', name: 'Album B');

      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.offline),
            _noListenBrainzTokenOverride(),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData((
                albumIds: <String>{'album-b'},
                artistIds: <String>{},
              )),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: true,
        likedOnly: false,
      ));

      expect(result, hasLength(1));
      expect(result.first.album.id, 'album-b');
    },
  );

  test(
    'downloaded + liked only keeps downloaded liked-song album candidates',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'album-a', name: 'Album A');
      await _insertAlbum(database, id: 'album-b', name: 'Album B');

      final container = ProviderContainer(
        overrides: withHomeShowcaseTestOverrides(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            _noListenBrainzTokenOverride(),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData((
                albumIds: <String>{'album-a'},
                artistIds: <String>{},
              )),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{'song-a'}),
            ),
            likedSongsProvider.overrideWithValue(
              AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'song-a',
                  title: 'Downloaded liked song',
                  albumId: 'album-a',
                  starred: DateTime(2026, 1, 2),
                ),
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'song-b',
                  title: 'Non-downloaded liked song',
                  albumId: 'album-b',
                  starred: DateTime(2026, 1, 3),
                ),
              ]),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        // Let disposed providers' in-flight queries settle before closing.
        await pumpEventQueue();
        await database.close();
      });

      final result = await readHomeRandomShowcase(container, (
        downloadedOnly: true,
        likedOnly: true,
      ));

      expect(result, hasLength(1));
      expect(result.first.album.id, 'album-a');
      expect(result.first.album.source, HomeRandomShowcaseSource.localFallback);
    },
  );
}
