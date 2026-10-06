import 'package:drift/drift.dart' show Value;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/library_sync_fakes.dart';

/// Routes artist and album targets to the real Drift engine.
class _TargetEngine extends LibrarySyncEngine {
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
    return switch (target.kind) {
      LibrarySyncTargetKind.artist => await _drift.hydrateArtist(
        target.entityId!,
      ),
      LibrarySyncTargetKind.album => await _drift.hydrateAlbum(
        target.entityId!,
      ),
      _ => _skipped,
    };
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

void main() {
  late NavisDatabase database;
  late FakeLibrarySyncApi api;
  late ProviderContainer container;
  late Directory directory;

  setUp(() async {
    // The app's own file database: WAL with a read pool, as on devices.
    // Streams there re-read on a separate reader connection, which an
    // in-memory database does not have.
    directory = Directory.systemTemp.createTempSync('remote_page_runtime_');
    database = NavisDatabase.atPath('${directory.path}/navis.sqlite');
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
    final drift = DriftLibrarySyncEngine(
      api: api,
      database: database,
      serverConfigRepository: repository,
    );
    container = ProviderContainer(
      overrides: [
        syncIntervalMinutesProvider.overrideWithValue(0),
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        serverReachabilityControllerProvider.overrideWith(
          _OnlineReachability.new,
        ),
        librarySyncEngineProvider.overrideWithValue(_TargetEngine(drift)),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    directory.deleteSync(recursive: true);
  });

  test('a remote artist opened by id alone stores the artist and its albums '
      'for the page', () async {
    const id = 'ext-deezer-artist-4690857';
    api.artistDetails[id] = Artist(
      id: id,
      name: 'coldrain',
      albumCount: 25,
      albums: <Album>[
        for (var i = 0; i < 25; i++)
          Album(
            id: 'ext-deezer-album-${1000 + i}',
            name: 'Release $i',
            artist: 'coldrain',
            artistId: id,
            year: 2000 + i,
          ),
      ],
    );
    container.listen(artistAlbumSectionsProvider(id), (_, _) {});
    container.listen(artistByIdProvider(id), (_, _) {});

    final result = await container
        .read(librarySyncControllerProvider.notifier)
        .hydrateOpenedArtist(id);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(result?.status, LibrarySyncStatus.succeeded, reason: '$result');
    expect((await database.libraryDao.getArtistById(id))?.name, 'coldrain');
    expect(
      await database.libraryDao.watchAlbumsByArtist(id).first,
      hasLength(25),
    );
    expect(
      container.read(artistAlbumSectionsProvider(id)).value?.albums,
      hasLength(25),
    );
    // The artist page's own artist stream sees the stored row.
    expect(container.read(artistByIdProvider(id)).value?.name, 'coldrain');
  });

  test(
    'a remote album whose song the library also holds lists that song',
    () async {
      // The library has the same song on a local album.
      await database.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'oor', name: 'ONE OK ROCK'),
      ]);
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'detox-jp',
          name: 'DETOX (Japanese version)',
          artistId: const Value('oor'),
          songsHydrated: const Value(true),
        ),
      ]);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: '3eqjYFNn2qX941HhG1pXl0',
          title: 'Dystopia',
          albumId: const Value('detox-jp'),
          artistId: const Value('oor'),
          artistName: const Value('ONE OK ROCK'),
        ),
      ]);
      const id = 'ext-deezer-album-656896781';
      // The server's getAlbum for it, as Octo-Fiesta answers.
      api.albumDetails[id] = const Album(
        id: id,
        name: 'Dystopia (Japanese Version)',
        artist: 'ONE OK ROCK',
        artistId: 'ext-deezer-artist-469713',
        songCount: 1,
        duration: 189,
        year: 2024,
        songs: <Song>[
          Song(
            id: 'ext-deezer-song-3045812481',
            title: 'Dystopia (Japanese Version)',
            album: 'Dystopia (Japanese Version)',
            albumId: id,
            artist: 'ONE OK ROCK',
            artistId: 'ext-deezer-artist-469713',
            duration: 189,
            track: 1,
            discNumber: 1,
            year: 2024,
            isExternal: true,
          ),
        ],
      );
      // Opened from the artist page: the artist's getArtist stored the remote
      // album first, with Octo-Fiesta's songCount 0.
      api.artistDetails['oor'] = const Artist(
        id: 'oor',
        name: 'ONE OK ROCK',
        albumCount: 2,
        isExternal: false,
        albums: <Album>[
          Album(
            id: 'detox-jp',
            name: 'DETOX (Japanese version)',
            artist: 'ONE OK ROCK',
            artistId: 'oor',
            songCount: 11,
            isExternal: false,
          ),
          Album(
            id: id,
            name: 'Dystopia (Japanese Version)',
            artist: 'ONE OK ROCK',
            artistId: 'oor',
            songCount: 0,
            year: 2024,
            isExternal: true,
          ),
        ],
      );
      expect(
        (await container
                .read(librarySyncControllerProvider.notifier)
                .hydrateOpenedArtist('oor'))
            ?.status,
        LibrarySyncStatus.succeeded,
      );
      container.listen(albumProvider(id), (_, _) {});

      final result = await container
          .read(librarySyncControllerProvider.notifier)
          .hydrateOpenedAlbum(id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(result?.status, LibrarySyncStatus.succeeded, reason: '$result');
      final stored = container.read(albumProvider(id)).value;
      expect(stored?.album.songsHydrated, isTrue);
      expect(stored?.songs.map((song) => song.id), <String>[
        'ext-deezer-song-3045812481',
      ]);
    },
  );

  test('a remote album marked hydrated without tracks is fetched again on '
      'open', () async {
    const id = 'ext-deezer-album-656896781';
    // As found at runtime: the album row says its songs are stored, but none
    // are.
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: id,
        name: 'Dystopia (Japanese Version)',
        artistName: const Value('ONE OK ROCK'),
        songCount: const Value(0),
        isExternal: const Value(true),
        songsHydrated: const Value(true),
      ),
    ]);
    api.albumDetails[id] = const Album(
      id: id,
      name: 'Dystopia (Japanese Version)',
      artist: 'ONE OK ROCK',
      artistId: 'ext-deezer-artist-469713',
      songCount: 1,
      songs: <Song>[
        Song(
          id: 'ext-deezer-song-3045812481',
          title: 'Dystopia (Japanese Version)',
          albumId: id,
          artist: 'ONE OK ROCK',
          artistId: 'ext-deezer-artist-469713',
          duration: 189,
          track: 1,
          isExternal: true,
        ),
      ],
    );
    container.listen(albumProvider(id), (_, _) {});

    final result = await container
        .read(librarySyncControllerProvider.notifier)
        .hydrateOpenedAlbum(id);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(api.calls, contains('getAlbum:$id'));
    expect(result?.status, LibrarySyncStatus.succeeded, reason: '$result');
    expect(
      container.read(albumProvider(id)).value?.songs.map((song) => song.id),
      <String>['ext-deezer-song-3045812481'],
    );
  });
}
