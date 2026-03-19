import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

Future<void> _insertAlbum(
  NavisDatabase db, {
  required String id,
  required String name,
  DateTime? starred,
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
        ),
      );
}

class _FakeDiscoveryApiClient extends SubsonicApiClient {
  _FakeDiscoveryApiClient(this._similarBySeed)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Map<String, List<Song>> _similarBySeed;

  @override
  Future<List<Song>> getSimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    return _similarBySeed[seedSongId] ?? const <Song>[];
  }
}

void main() {
  test('online unfiltered uses server random source', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
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
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.id, 'srv-1');
    expect(result.first.source, HomeRandomShowcaseSource.serverRandom);
  });

  test(
    'online unfiltered uses liked-song discovery before random fallback',
    () async {
      final database = createTestDatabase();
      for (int i = 0; i < 12; i++) {
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
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => throw StateError('discovery should be used first'),
            ),
            likedSongsProvider.overrideWithValue(
              AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'seed-1',
                    title: 'Seed 1',
                    albumId: 'liked-a',
                  ),
                  SongsTableData(
                    id: 'seed-2',
                    title: 'Seed 2',
                    albumId: 'liked-b',
                  ),
                  SongsTableData(
                    id: 'seed-3',
                    title: 'Seed 3',
                    albumId: 'liked-c',
                  ),
                  SongsTableData(
                    id: 'seed-4',
                    title: 'Seed 4',
                    albumId: 'liked-d',
                  ),
                  SongsTableData(
                    id: 'seed-5',
                    title: 'Seed 5',
                    albumId: 'liked-e',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result.length, greaterThanOrEqualTo(6));
      expect(
        result.every(
          (album) => album.source == HomeRandomShowcaseSource.likedDiscovery,
        ),
        isTrue,
      );
    },
  );

  test('offline falls back to local random pool', () async {
    final database = createTestDatabase();
    await _insertAlbum(database, id: 'loc-1', name: 'Local Album');

    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.offline),
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
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.id, 'loc-1');
    expect(result.first.source, HomeRandomShowcaseSource.localFallback);
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
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          likedSongsProvider.overrideWithValue(
            AsyncData(
              <SongsTableData>[
                SongsTableData(
                  id: 'liked-song-1',
                  title: 'Liked Song',
                  albumId: 'liked-song-album',
                  starred: DateTime(2026, 1, 2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: true,
      )).future,
    );

    final ids = result.map((album) => album.id).toSet();
    expect(ids, contains('liked-explicit'));
    expect(ids, contains('liked-song-album'));
    expect(
      result.every(
        (album) => album.source == HomeRandomShowcaseSource.localFallback,
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
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.offline),
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
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: true,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.id, 'album-b');
    },
  );

  test(
    'downloaded + liked only keeps downloaded liked-song album candidates',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'album-a', name: 'Album A');
      await _insertAlbum(database, id: 'album-b', name: 'Album B');

      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
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
              AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'song-a',
                    title: 'Downloaded liked song',
                    albumId: 'album-a',
                    starred: DateTime(2026, 1, 2),
                  ),
                  SongsTableData(
                    id: 'song-b',
                    title: 'Non-downloaded liked song',
                    albumId: 'album-b',
                    starred: DateTime(2026, 1, 3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: true,
          likedOnly: true,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.id, 'album-a');
      expect(result.first.source, HomeRandomShowcaseSource.localFallback);
    },
  );
}
