import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/library_artist_name_index.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/test_database.dart';

/// Records every Deezer endpoint asked for.
class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  final List<String> calls = <String>[];
  List<DeezerArtist> related = const [];
  List<DeezerAlbum> albums = const [];

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('search/artist');
    return const [DeezerArtist(id: 1105, name: 'ONE OK ROCK')];
  }

  @override
  Future<DeezerArtist?> getArtist(
    int artistId, {
    CancelToken? cancelToken,
  }) async {
    calls.add('artist');
    return DeezerArtist(
      id: artistId,
      name: 'ONE OK ROCK',
      pictureXl: 'https://cdn-images.dzcdn.net/images/artist/h/1000x1000.jpg',
      fanCount: 4100000,
    );
  }

  @override
  Future<List<DeezerArtist>> getRelatedArtists(
    int artistId, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    calls.add('related');
    return related;
  }

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('albums');
    return albums;
  }
}

const _key = (artistId: 'oor', name: 'ONE OK ROCK');

const _artist = ArtistsTableData(
  isProvisional: false,
  isExternal: false,
  id: 'oor',
  name: 'ONE OK ROCK',
  albumCount: 2,
);

AlbumsTableData _album(String id, String name, {bool isExternal = false}) =>
    AlbumsTableData(
      isProvisional: false,
      isExternal: isExternal,
      id: id,
      name: name,
      songsHydrated: true,
      artists: const [],
    );

void main() {
  late Directory cacheRoot;
  late _FakeDeezer deezer;

  setUp(() {
    cacheRoot = Directory.systemTemp.createTempSync('artist_deezer_test_');
    deezer = _FakeDeezer();
  });

  tearDown(() {
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  ProviderContainer container({
    IntegrationPolicy policy = const IntegrationPolicy(),
    ArtistsTableData artist = _artist,
    List<AlbumsTableData> albums = const [],
    List<AlbumsTableData> featuredIn = const [],
    NavisDatabase? database,
    List<Override> extra = const [],
  }) {
    final db = database ?? createTestDatabase();
    if (database == null) addTearDown(db.close);
    final root = cacheRoot;
    final container = ProviderContainer(
      overrides: withTestDatabase(
        db,
        overrides: <Override>[
          integrationPolicyProvider.overrideWithValue(policy),
          integrationJsonCacheProvider.overrideWithValue(
            IntegrationJsonCache(readRootDirectory: () async => root),
          ),
          deezerApiClientProvider.overrideWithValue(deezer),
          artistByIdProvider(_key.artistId)
              .overrideWith((ref) => Stream.value(artist)),
          artistAlbumSectionsProvider(_key.artistId).overrideWith(
            (ref) => Stream.value(
              ArtistAlbumSections(albums: albums, featuredIn: featuredIn),
            ),
          ),
          ...extra,
        ],
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<T> read<T>(
    ProviderContainer container,
    FutureProvider<T> Function(ArtistPageKey) provider,
  ) {
    container.listen(provider(_key), (_, _) {});
    return container.read(provider(_key).future);
  }

  /// Settles the missing-albums provider's sources, then reads it.
  Future<List<DeezerAlbum>> missingAlbums(ProviderContainer container) async {
    container.listen(artistMissingAlbumsProvider(_key), (_, _) {});
    await pumpEventQueue();
    await container.read(artistDeezerAlbumsProvider(_key).future);
    await pumpEventQueue();
    final missing = container.read(artistMissingAlbumsProvider(_key));
    return missing;
  }

  group('switches', () {
    for (final entry in <String, IntegrationPolicy>{
      'every artist-page feature is off': const IntegrationPolicy(
        disabledKeys: {
          'deezer.artistImages',
          'deezer.similarArtists',
          'deezer.missingAlbums',
        },
      ),
      'the Deezer service is off': const IntegrationPolicy(
        disabledKeys: {'deezer'},
      ),
      'the master switch is off': const IntegrationPolicy(masterEnabled: false),
      'settings are still loading': const IntegrationPolicy.denyAll(),
    }.entries) {
      test('no Deezer call when ${entry.key}', () async {
        final c = container(policy: entry.value);

        expect(await read(c, artistDeezerDetailsProvider.call), isNull);
        expect(await read(c, artistFansAlsoLikeProvider.call), isEmpty);
        expect(await missingAlbums(c), isEmpty);
        expect(deezer.calls, isEmpty);
      });
    }

    test('each feature asks only for its own data', () async {
      final c = container(
        policy: const IntegrationPolicy(
          disabledKeys: {'deezer.similarArtists', 'deezer.missingAlbums'},
        ),
      );

      final details = await read(c, artistDeezerDetailsProvider.call);
      await read(c, artistFansAlsoLikeProvider.call);
      await missingAlbums(c);

      expect(details?.fanCount, 4100000);
      expect(deezer.calls, ['search/artist', 'artist']);
    });

    test('the sections share one artist resolution', () async {
      final c = container();

      await read(c, artistDeezerDetailsProvider.call);
      await read(c, artistFansAlsoLikeProvider.call);
      await missingAlbums(c);

      expect(
        deezer.calls.where((call) => call == 'search/artist'),
        hasLength(1),
      );
      expect(
        deezer.calls,
        containsAll(<String>['artist', 'related', 'albums']),
      );
    });
  });

  group('Fans Also Like', () {
    test('library artists come first and keep their library id', () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      await db
          .into(db.artistsTable)
          .insert(
            ArtistsTableCompanion.insert(id: 'lib-mfs', name: 'MY FIRST STORY'),
          );
      deezer.related = const [
        DeezerArtist(id: 1, name: 'Coldrain', pictureXl: 'https://x/c.jpg'),
        DeezerArtist(id: 2, name: 'My First Story'),
      ];

      final entries = await read(
        container(database: db),
        artistFansAlsoLikeProvider.call,
      );

      expect(entries.map((entry) => entry.name), [
        'MY FIRST STORY',
        'Coldrain',
      ]);
      expect(entries.first.libraryArtistId, 'lib-mfs');
      expect(entries.last.libraryArtistId, isNull);
      expect(entries.last.imageUrl, 'https://x/c.jpg');
    });

    test('a second artist page reuses the library name index', () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      await db
          .into(db.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'lib-sim', name: 'SiM'));
      var scans = 0;
      deezer.related = const [DeezerArtist(id: 4, name: 'SiM')];
      final c = container(
        database: db,
        extra: [
          libraryArtistNameIndexProvider.overrideWithValue(
            LibraryArtistNameIndexCache(
              loadArtists: () {
                scans++;
                return db.libraryDao.getAllArtists();
              },
            ),
          ),
        ],
      );
      const other = (artistId: 'ext-deezer-artist-77', name: 'Coldrain');

      final first = await read(c, artistFansAlsoLikeProvider.call);
      c.listen(artistFansAlsoLikeProvider(other), (_, _) {});
      final second = await c.read(artistFansAlsoLikeProvider(other).future);

      expect(first.single.libraryArtistId, 'lib-sim');
      expect(second.single.libraryArtistId, 'lib-sim');
      expect(scans, 1);
    });

    test('no related artists reads as empty', () async {
      expect(await read(container(), artistFansAlsoLikeProvider.call), isEmpty);
    });
  });

  group('Missing Albums', () {
    const deezerAlbums = [
      DeezerAlbum(
        id: 1,
        title: 'Ambitions',
        recordType: 'album',
        releaseDate: '2017-01-13',
      ),
      DeezerAlbum(
        id: 2,
        title: 'Ambitions (Japanese Version)',
        recordType: 'album',
        releaseDate: '2017-01-11',
      ),
    ];

    test('lists the editions the library lacks', () async {
      deezer.albums = deezerAlbums;
      final c = container(albums: [_album('al-1', 'Ambitions')]);

      final missing = await missingAlbums(c);

      expect(missing.map((album) => album.title), [
        'Ambitions (Japanese Version)',
      ]);
    });

    test('hidden, without asking Deezer, when the server has remote albums '
        'for the artist', () async {
      deezer.albums = deezerAlbums;
      final c = container(
        albums: [
          _album('al-1', 'Ambitions'),
          _album('ext-deezer-album-9', 'Remote', isExternal: true),
        ],
      );

      c.listen(artistMissingAlbumsProvider(_key), (_, _) {});
      await pumpEventQueue();

      expect(c.read(artistMissingAlbumsProvider(_key)), isEmpty);
      expect(deezer.calls, isNot(contains('albums')));
    });

    test('hidden, without asking Deezer, when an album the artist is '
        'featured on is remote', () async {
      deezer.albums = deezerAlbums;
      final c = container(
        albums: [_album('al-1', 'Ambitions')],
        featuredIn: [_album('ext-deezer-album-7', 'Feat', isExternal: true)],
      );

      c.listen(artistMissingAlbumsProvider(_key), (_, _) {});
      await pumpEventQueue();

      expect(c.read(artistMissingAlbumsProvider(_key)), isEmpty);
      expect(deezer.calls, isNot(contains('albums')));
    });

    test('hidden, without asking Deezer, for a remote artist', () async {
      deezer.albums = deezerAlbums;
      final c = container(
        artist: const ArtistsTableData(
          isProvisional: false,
          isExternal: true,
          id: 'oor',
          name: 'ONE OK ROCK',
        ),
      );

      c.listen(artistMissingAlbumsProvider(_key), (_, _) {});
      await pumpEventQueue();

      expect(c.read(artistMissingAlbumsProvider(_key)), isEmpty);
      expect(deezer.calls, isNot(contains('albums')));
    });
  });
}
