import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/test_database.dart';

/// Synthetic promotion measurement (plan §4 56k fixture row).
///
/// The default size keeps the regular suite fast; the 56k-song measurement
/// run scales the fixture with compile-time defines:
/// `flutter test --dart-define=NAVIS_PERF_SONG_COUNT=56000
/// --dart-define=NAVIS_PERF_ALBUM_COUNT=1000 ...`
const _perfSongCount = int.fromEnvironment(
  'NAVIS_PERF_SONG_COUNT',
  defaultValue: 5000,
);
const _perfAlbumCount = int.fromEnvironment(
  'NAVIS_PERF_ALBUM_COUNT',
  defaultValue: 100,
);

/// Albums (and artists) renamed by the id-rebuild measurement:
/// `flutter test --dart-define=NAVIS_PERF_REBUILD_ALBUM_COUNT=2000 ...`.
const _perfRebuildAlbumCount = int.fromEnvironment(
  'NAVIS_PERF_REBUILD_ALBUM_COUNT',
  defaultValue: 100,
);

void main() {
  group('DriftLibrarySyncEngine promotion measurement', () {
    test(
      'promotion of a large catalog stays indexed and records timings',
      () async {
        final database = NavisDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final credentials = FakeSyncCredentialStore();
        final serverConfigRepository = ServerConfigRepository(
          database,
          credentials: credentials,
        );
        await serverConfigRepository.save(
          ServerConfigModel(
            url: 'https://example.com',
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
        );
        final serverId = (await serverConfigRepository.getActiveServer())!.id!;

        final songCount = _perfSongCount < _perfAlbumCount
            ? _perfAlbumCount
            : _perfSongCount;
        final songsPerAlbum = (songCount / _perfAlbumCount).ceil();
        final api = FakeLibrarySyncApi();

        final artists = List<Artist>.generate(
          _perfAlbumCount,
          (index) => Artist(id: 'artist-$index', name: 'Artist $index'),
        );
        api.artists.addAll(artists);
        var songSeq = 0;
        final albumPages = <Album>[];
        for (var albumIndex = 0; albumIndex < _perfAlbumCount; albumIndex++) {
          final songs = List<Song>.generate(songsPerAlbum, (songIndex) {
            songSeq++;
            return Song(
              id: 'song-$songSeq',
              title: 'Track $songSeq',
              albumId: 'album-$albumIndex',
              artistId: 'artist-$albumIndex',
              musicBrainzId: 'rec-$songSeq',
            );
          });
          albumPages.add(
            Album(
              id: 'album-$albumIndex',
              name: 'Album $albumIndex',
              artist: 'Artist $albumIndex',
              artistId: 'artist-$albumIndex',
              songCount: songsPerAlbum,
              songs: songs,
            ),
          );
        }
        // The fake serves the whole snapshot from the first page so the
        // measurement exercises promotion, not pagination bookkeeping.
        api.fastPathPages[0] = albumPages;
        for (final album in albumPages) {
          api.albumDetails[album.id] = album;
        }

        final engine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 8,
          wifiAlbumConcurrency: 8,
          cellularAlbumConcurrency: 8,
          otherAlbumConcurrency: 8,
          writeChunkSize: 512,
          isolateThreshold: 1000,
        );

        final watch = Stopwatch()..start();
        final result = await engine.forceFullSync();
        watch.stop();

        expect(result.status, LibrarySyncStatus.succeeded);
        final counts = await database.libraryDao.getCatalogCounts();
        expect(counts.songs, _perfAlbumCount * songsPerAlbum);
        expect(counts.albums, _perfAlbumCount);

        // Indexed matching: exactly one detail request per album — no
        // all-pairs or rescan behavior as the catalog grows.
        final albumFetches = api.calls
            .where((call) => call.startsWith('getAlbum:'))
            .length;
        expect(albumFetches, _perfAlbumCount);

        // Promotion diagnostics are recorded for the release evidence.
        final syncState = await database.librarySyncDao.getOrCreateState(
          serverId,
        );
        expect(syncState.lastApplyDurationMs, isNotNull);
        expect(syncState.lastApplyDurationMs, greaterThan(0));
        final diagnostics = jsonDecode(
          syncState.lastPromotionDiagnosticsJson ?? '{}',
        ) as Map<String, Object?>;
        expect(diagnostics['changed'], greaterThan(0));
        expect(diagnostics['pages'], greaterThan(0));
        // Generous wall-clock bound; the recorded numbers are the evidence.
        expect(watch.elapsed, lessThan(const Duration(minutes: 10)));
        // ignore: avoid_print
        print(
          'promotion measurement: songs=${counts.songs} '
          'applyMs=${syncState.lastApplyDurationMs} '
          'analysisMs=${diagnostics['analysisDurationMs']} '
          'wallMs=${watch.elapsedMilliseconds} '
          'rssGrowth=${diagnostics['rssGrowthBytes']}',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
      skip: !sqliteAvailable,
    );
    test(
      'promotion after a whole-library id rebuild records timings',
      () async {
        // Every album and artist gets a new id with the same MusicBrainz
        // identifiers, and one song per album is downloaded, so each old
        // album and artist stays provisional and goes through identity
        // reconciliation against every candidate.
        final database = NavisDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final serverConfigRepository = ServerConfigRepository(
          database,
          credentials: FakeSyncCredentialStore(),
        );
        await serverConfigRepository.save(
          ServerConfigModel(
            url: 'https://example.com',
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
        );
        final api = FakeLibrarySyncApi();
        final engine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 8,
          wifiAlbumConcurrency: 8,
          cellularAlbumConcurrency: 8,
          otherAlbumConcurrency: 8,
          writeChunkSize: 512,
          isolateThreshold: 1000,
        );
        const albums = _perfRebuildAlbumCount;
        void serve(String prefix) {
          api.artists
            ..clear()
            ..addAll([
              for (var i = 0; i < albums; i++)
                Artist(
                  id: '$prefix-artist-$i',
                  name: 'Artist $i',
                  musicBrainzId: 'artist-mbid-$i',
                ),
            ]);
          final pages = [
            for (var i = 0; i < albums; i++)
              Album(
                id: '$prefix-album-$i',
                name: 'Album $i',
                artistId: '$prefix-artist-$i',
                songCount: 2,
                musicBrainzId: 'release-mbid-$i',
                songs: [
                  for (var t = 0; t < 2; t++)
                    Song(
                      id: '$prefix-song-$i-$t',
                      title: 'Track $i $t',
                      albumId: '$prefix-album-$i',
                      artistId: '$prefix-artist-$i',
                      track: t + 1,
                      musicBrainzId: 'rec-$i-$t',
                    ),
                ],
              ),
          ];
          api.fastPathPages
            ..clear()
            ..[0] = pages;
          api.albumDetails
            ..clear()
            ..addAll({for (final album in pages) album.id: album});
        }

        serve('v1');
        expect(
          (await engine.forceFullSync()).status,
          LibrarySyncStatus.succeeded,
        );
        for (var i = 0; i < albums; i++) {
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: 'v1-song-$i-0',
              filePath: '/nonexistent/v1-song-$i-0.mp3',
              fileSize: 3,
              format: 'mp3',
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.utc(2026),
            ),
          );
        }
        serve('v2');
        final timings = <int>[];
        for (var run = 0; run < 3; run++) {
          final watch = Stopwatch()..start();
          await engine.forceFullSync();
          timings.add(watch.elapsedMilliseconds);
        }
        final aliases = await database
            .customSelect(
              "SELECT COUNT(*) AS n FROM entity_identity_aliases "
              "WHERE entity_type IN ('album', 'artist')",
            )
            .getSingle();
        // Every old album and artist is matched by MusicBrainz id.
        expect(aliases.read<int>('n'), 2 * albums);
        // ignore: avoid_print
        print(
          'rebuild measurement: albums=$albums runMs=${timings.join(',')}',
        );
      },
      timeout: const Timeout(Duration(minutes: 20)),
      skip: !sqliteAvailable,
    );
  });
}
