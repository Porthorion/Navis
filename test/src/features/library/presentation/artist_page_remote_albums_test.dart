import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/library_sync_fakes.dart';

/// Routes artist targets to the real Drift engine's `getArtist` hydration,
/// as the adaptive coordinator does, so the test sees the rows it writes.
class _ArtistHydrationEngine extends LibrarySyncEngine {
  new(this._drift);

  final DriftLibrarySyncEngine _drift;

  static const _skipped = LibrarySyncState(
    status: LibrarySyncStatus.skipped,
    stage: LibrarySyncStage.completed,
  );

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final target = request.target;
    if (target.kind == LibrarySyncTargetKind.artist) {
      return await _drift.hydrateArtist(
        target.entityId!,
        onProgress: onProgress,
      );
    }
    return _skipped;
  }

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _skipped;

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _skipped;

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _skipped;

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _skipped;

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) async => _skipped;
}

class _OnlineReachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);
}

class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
  }) async => const [DeezerArtist(id: 1105, name: 'ONE OK ROCK')];

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async => const [
    DeezerAlbum(
      id: 302127,
      title: 'Ambitions (Japanese Version)',
      recordType: 'album',
      releaseDate: '2017-01-11',
    ),
  ];
}

const _key = (artistId: 'oor', name: 'ONE OK ROCK');

void main() {
  late NavisDatabase database;
  late FakeLibrarySyncApi api;
  late DriftLibrarySyncEngine drift;
  late Directory cacheRoot;

  setUp(() async {
    database = NavisDatabase(NativeDatabase.memory());
    final repository = ServerConfigRepository(
      database,
      credentials: FakeSyncCredentialStore(),
    );
    await repository.save(
      ServerConfigModel(
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
        lastSynced: DateTime.now(),
      ),
    );
    api = FakeLibrarySyncApi();
    drift = DriftLibrarySyncEngine(
      api: api,
      database: database,
      serverConfigRepository: repository,
    );
    cacheRoot = Directory.systemTemp.createTempSync('artist_remote_albums_');

    // Octo-Fiesta's artist list counts local albums only, so the synced
    // artist looks complete: one album stored, album count one.
    await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(
        id: 'oor',
        name: 'ONE OK ROCK',
        albumCount: const Value(1),
      ),
    ]);
    await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'al-1',
        name: 'Ambitions',
        artistId: const Value('oor'),
      ),
    ]);
    // getArtist adds the remote catalogue under the same artist id.
    api.artistDetails['oor'] = const Artist(
      id: 'oor',
      name: 'ONE OK ROCK',
      albumCount: 2,
      albums: <Album>[
        Album(
          id: 'al-1',
          name: 'Ambitions',
          artist: 'ONE OK ROCK',
          artistId: 'oor',
        ),
        Album(
          id: 'ext-deezer-album-302127',
          name: 'Ambitions (Japanese Version)',
          artist: 'ONE OK ROCK',
          artistId: 'oor',
        ),
      ],
    );
  });

  tearDown(() async {
    await database.close();
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  test('opening a complete-looking artist stores its remote albums in Albums '
      'and Missing albums hides itself', () async {
    final root = cacheRoot;
    final container = ProviderContainer(
      overrides: [
        syncIntervalMinutesProvider.overrideWithValue(0),
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        serverReachabilityControllerProvider.overrideWith(
          _OnlineReachability.new,
        ),
        librarySyncEngineProvider.overrideWithValue(
          _ArtistHydrationEngine(drift),
        ),
        integrationPolicyProvider.overrideWithValue(const IntegrationPolicy()),
        integrationJsonCacheProvider.overrideWithValue(
          IntegrationJsonCache(readRootDirectory: () async => root),
        ),
        deezerApiClientProvider.overrideWithValue(_FakeDeezer()),
      ],
    );
    addTearDown(container.dispose);
    container.listen(artistMissingAlbumsProvider(_key), (_, _) {});
    container.listen(artistAlbumSectionsProvider('oor'), (_, _) {});
    await container.read(artistDeezerAlbumsProvider(_key).future);
    await pumpEventQueue();

    // Before the open, the Japanese edition reads as missing.
    expect(
      container.read(artistMissingAlbumsProvider(_key)).map((a) => a.title),
      ['Ambitions (Japanese Version)'],
    );

    container
        .read(librarySyncControllerProvider.notifier)
        .registerArtistInteraction('oor');
    // The artist page's album buckets re-read at most four times a second.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await pumpEventQueue();

    expect(api.calls, <String>['getArtist:oor']);
    final sections = container.read(artistAlbumSectionsProvider('oor')).value!;
    expect(
      sections.albums.map((album) => (album.id, album.isExternal)),
      unorderedEquals(<(String, bool)>[
        ('al-1', false),
        ('ext-deezer-album-302127', true),
      ]),
    );
    expect(container.read(artistMissingAlbumsProvider(_key)), isEmpty);
  });
}
