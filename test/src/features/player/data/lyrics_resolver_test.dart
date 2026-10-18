import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';

import '../../../../helpers/test_database.dart';

class _RateLimitedLrclibClient extends LrclibClient {
  @override
  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
    bool background = false,
    CancelToken? cancelToken,
  }) async {
    throw const LrclibRateLimitedException();
  }
}

class _FakeLrclibClient extends LrclibClient {
  new(this.results, {this.direct});

  final List<LrclibLyrics> results;
  final LrclibLyrics? direct;
  int calls = 0;

  @override
  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
    bool background = false,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return results;
  }

  @override
  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
    bool background = false,
    CancelToken? cancelToken,
  }) async => direct;
}

class _FakeServer extends SubsonicApiClient {
  new(this.lyrics, {this.fail = false})
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'fixture',
          password: 'fixture',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
  final LyricsList lyrics;
  final bool fail;
  int calls = 0;
  @override
  Future<LyricsList> getLyricsBySongId(
    String songId, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    if (fail) throw const SubsonicGenericException(code: 0, message: 'fixture');
    return lyrics;
  }

  @override
  Future<LyricsList> getLyrics({
    String? artist,
    String? title,
    CancelToken? cancelToken,
  }) async => const LyricsList();
}

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  const english = LrclibLyrics(
    artistName: 'ONE OK ROCK',
    trackName: 'Wonder',
    duration: 200,
    plainLyrics: 'english words',
  );
  const japanese = LrclibLyrics(
    artistName: 'ONE OK ROCK',
    trackName: 'Wonder (Japanese Version)',
    duration: 200,
    plainLyrics: 'japanese words',
  );

  Future<String?> resolve(String title, List<LrclibLyrics> results) async {
    final resolution =
        await LyricsResolver(
          libraryDao: database.libraryDao,
          lrclibClient: _FakeLrclibClient(results),
          apiClient: null,
        ).resolve(
          songId: 'song',
          metadata: (
            artist: 'ONE OK ROCK',
            title: title,
            album: null,
            durationSeconds: 200,
          ),
          useLrclib: true,
        );
    return resolution.lyrics.value;
  }

  group('instrumental lyrics', () {
    const metadata = (
      artist: 'Artist',
      title: 'Track',
      album: null,
      durationSeconds: null,
    );
    const instrumental = LrclibLyrics(
      artistName: 'Artist',
      trackName: 'Track',
      instrumental: true,
    );
    test(
      'search caches instrumental as success and never retries externally',
      () async {
        final external = _FakeLrclibClient([instrumental]);
        final resolver = LyricsResolver(
          libraryDao: database.libraryDao,
          lrclibClient: external,
          apiClient: _FakeServer(const LyricsList()),
        );
        final result = await resolver.resolve(
          songId: 'song',
          metadata: metadata,
          useLrclib: true,
        );
        expect(result.instrumental, isTrue);
        expect(result.confirmedMiss, isFalse);
        expect(result.syncedUpgradeMiss, isFalse);
        final cache = (await database.libraryDao.getExternalLyricsCache(
          'song',
        ))!;
        expect(cache.instrumental, isTrue);
        expect(cache.failureCount, 0);
        expect(cache.lastFailedAt, isNull);
        expect(cache.syncedLyrics, isNull);
        expect(cache.plainLyrics, isNull);
        for (final enabled in [false, true]) {
          final cached = await resolver.resolve(
            songId: 'song',
            metadata: metadata,
            useLrclib: enabled,
            forceSyncedUpgrade: true,
          );
          expect(cached.instrumental, isTrue);
        }
        expect(external.calls, 1);
      },
    );
    for (final synced in ['not valid LRC', '[00:01.00]real words']) {
      test('instrumental is decided after parsing: $synced', () async {
        final result = await LyricsResolver(
          libraryDao: database.libraryDao,
          lrclibClient: _FakeLrclibClient([
            LrclibLyrics(
              artistName: 'Artist',
              trackName: 'Track',
              instrumental: true,
              syncedLyrics: synced,
            ),
          ]),
          apiClient: null,
        ).resolve(songId: 'song', metadata: metadata, useLrclib: true);
        final usable = synced.startsWith('[');
        expect(result.instrumental, !usable);
        expect(hasAnyLyrics(result.lyrics), usable);
        expect(result.confirmedMiss, isFalse);
        expect(
          (await database.libraryDao.getExternalLyricsCache('song'))!
              .instrumental,
          !usable,
        );
      });
    }
    test(
      'plain lyrics display while instrumental suppresses upgrades',
      () async {
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'serverPlain',
          plainLyrics: 'real words',
        );
        final external = _FakeLrclibClient([instrumental]);
        final resolver = LyricsResolver(
          libraryDao: database.libraryDao,
          lrclibClient: external,
          apiClient: _FakeServer(const LyricsList(value: 'real words')),
        );
        for (var run = 0; run < 2; run++) {
          final result = await resolver.resolve(
            songId: 'song',
            metadata: metadata,
            useLrclib: true,
            cacheServerLyrics: true,
            forceSyncedUpgrade: true,
          );
          expect(result.lyrics.value, 'real words');
          expect(result.instrumental, isFalse);
          expect(result.syncedUpgradeMiss, isFalse);
          final cache = (await database.libraryDao.getExternalLyricsCache(
            'song',
          ))!;
          expect(cache.instrumental, isTrue);
          expect(cache.source, 'serverPlain');
          expect(cache.plainLyrics, 'real words');
        }
        expect(external.calls, 1);
      },
    );
    test('exact fallback caches an instrumental result', () async {
      final result = await LyricsResolver(
        libraryDao: database.libraryDao,
        lrclibClient: _FakeLrclibClient([], direct: instrumental),
        apiClient: null,
      ).resolve(songId: 'song', metadata: metadata, useLrclib: true);
      expect(result.instrumental, isTrue);
      expect(
        (await database.libraryDao.getExternalLyricsCache('song'))!
            .instrumental,
        isTrue,
      );
    });
    test(
      'instrumental upsert preserves real lyrics and real upsert clears marker',
      () async {
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'lrclibPlain',
          instrumental: true,
        );
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'serverPlain',
          plainLyrics: 'real words',
        );
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'lrclibPlain',
          instrumental: true,
        );
        final cache = (await database.libraryDao.getExternalLyricsCache(
          'song',
        ))!;
        expect(cache.instrumental, isTrue);
        expect(cache.plainLyrics, 'real words');
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'serverSynced',
          syncedLyrics: '[00:01.00]real words',
        );
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'lrclibPlain',
          instrumental: true,
        );
        final syncedCache = (await database.libraryDao.getExternalLyricsCache(
          'song',
        ))!;
        expect(syncedCache.instrumental, isFalse);
        expect(syncedCache.syncedLyrics, '[00:01.00]real words');
      },
    );
    for (final synced in [false, true]) {
      test(
        'equally matching real lyrics beat instrumental: synced=$synced',
        () async {
          final external = _FakeLrclibClient([
            instrumental,
            LrclibLyrics(
              artistName: 'Artist',
              trackName: 'Track',
              plainLyrics: synced ? null : 'words',
              syncedLyrics: synced ? '[00:01.00]words' : null,
            ),
          ]);
          final result = await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: external,
            apiClient: null,
          ).resolve(songId: 'song', metadata: metadata, useLrclib: true);
          expect(result.instrumental, isFalse);
          expect(hasAnyLyrics(result.lyrics), isTrue);
        },
      );
    }
    for (final cacheServer in [false, true]) {
      test(
        'new server plain lyrics win over cached instrumental: cache=$cacheServer',
        () async {
          await database.libraryDao.upsertExternalLyricsCache(
            songId: 'song',
            source: 'lrclibPlain',
            instrumental: true,
          );
          final external = _FakeLrclibClient([]);
          final result =
              await LyricsResolver(
                libraryDao: database.libraryDao,
                lrclibClient: external,
                apiClient: _FakeServer(const LyricsList(value: 'new words')),
              ).resolve(
                songId: 'song',
                metadata: metadata,
                useLrclib: true,
                cacheServerLyrics: cacheServer,
              );
          expect(result.instrumental, isFalse);
          expect(result.lyrics.value, 'new words');
          expect(external.calls, 0);
          if (cacheServer) {
            expect(
              (await database.libraryDao.getExternalLyricsCache('song'))!
                  .instrumental,
              isFalse,
            );
          }
        },
      );
    }
  });

  group('server-first lyrics', () {
    final synced = LyricsList(
      structuredLyrics: [
        StructuredLyrics(
          synced: true,
          line: [LyricLine(start: 1000, value: 'server synced')],
        ),
      ],
    );
    final plain = LyricsList(value: 'server plain');
    const lrSynced = LrclibLyrics(
      artistName: 'Artist',
      trackName: 'Track',
      syncedLyrics: '[00:01.00]upgrade',
    );
    const lrPlain = LrclibLyrics(
      artistName: 'Artist',
      trackName: 'Track',
      plainLyrics: 'external plain',
    );
    for (final scenario in [
      (
        name: 'server synced skips LRCLIB',
        server: synced,
        external: [lrSynced],
        expected: LyricsSource.serverSynced,
        calls: 0,
        fail: false,
      ),
      (
        name: 'server plain upgrades to LRCLIB synced',
        server: plain,
        external: [lrSynced],
        expected: LyricsSource.lrclibSynced,
        calls: 1,
        fail: false,
      ),
      (
        name: 'server plain wins over LRCLIB plain',
        server: plain,
        external: [lrPlain],
        expected: LyricsSource.serverPlain,
        calls: 1,
        fail: false,
      ),
      (
        name: 'server plain survives LRCLIB miss',
        server: plain,
        external: <LrclibLyrics>[],
        expected: LyricsSource.serverPlain,
        calls: 1,
        fail: false,
      ),
      (
        name: 'server empty uses LRCLIB plain',
        server: const LyricsList(),
        external: [lrPlain],
        expected: LyricsSource.lrclibPlain,
        calls: 1,
        fail: false,
      ),
      (
        name: 'server error uses LRCLIB synced',
        server: const LyricsList(),
        external: [lrSynced],
        expected: LyricsSource.lrclibSynced,
        calls: 1,
        fail: true,
      ),
    ]) {
      test(scenario.name, () async {
        final external = _FakeLrclibClient(scenario.external);
        final server = _FakeServer(scenario.server, fail: scenario.fail);
        final result =
            await LyricsResolver(
              libraryDao: database.libraryDao,
              lrclibClient: external,
              apiClient: server,
            ).resolve(
              songId: 'song',
              metadata: (
                artist: 'Artist',
                title: 'Track',
                album: null,
                durationSeconds: null,
              ),
              useLrclib: true,
              cacheServerLyrics: true,
            );
        expect(result.source, scenario.expected);
        expect(external.calls, scenario.calls);
        final cached = (await database.libraryDao.getExternalLyricsCache(
          'song',
        ))!;
        expect(
          lyricsResolutionFromExternalCache(cached)!.source,
          scenario.expected,
        );
      });
    }
    for (final days in [0, 6, 8]) {
      for (final cacheServer in [false, true]) {
        test(
          'Now Playing plain upgrade backoff: $days days, cache=$cacheServer',
          () async {
            final failedAt = DateTime.now().subtract(Duration(days: days));
            await database.libraryDao.upsertExternalLyricsCache(
              songId: 'song',
              source: 'serverPlain',
              plainLyrics: 'retained',
              failureCount: 2,
              lastFailedAt: failedAt,
            );
            final external = _FakeLrclibClient([lrSynced]);
            final server = _FakeServer(plain);
            final result =
                await LyricsResolver(
                  libraryDao: database.libraryDao,
                  lrclibClient: external,
                  apiClient: server,
                ).resolve(
                  songId: 'song',
                  metadata: (
                    artist: 'Artist',
                    title: 'Track',
                    album: null,
                    durationSeconds: null,
                  ),
                  useLrclib: true,
                  cacheServerLyrics: cacheServer,
                );
            expect(server.calls, 1);
            expect(external.calls, days < 7 ? 0 : 1);
            expect(
              result.source,
              days < 7 ? LyricsSource.serverPlain : LyricsSource.lrclibSynced,
            );
            expect(result.syncedUpgradeMiss, isFalse);
            final row = (await database.libraryDao.getExternalLyricsCache(
              'song',
            ))!;
            expect(row.failureCount, days < 7 ? 2 : 0);
          },
        );
      }
    }

    test('Now Playing without a failed upgrade still tries LRCLIB', () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'serverPlain',
        plainLyrics: 'retained',
      );
      final external = _FakeLrclibClient([lrSynced]);
      final result =
          await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: external,
            apiClient: _FakeServer(plain),
          ).resolve(
            songId: 'song',
            metadata: (
              artist: 'Artist',
              title: 'Track',
              album: null,
              durationSeconds: null,
            ),
            useLrclib: true,
            cacheServerLyrics: false,
          );
      expect(result.source, LyricsSource.lrclibSynced);
      expect(external.calls, 1);
    });

    test(
      'Now Playing server synced wins even during failed-upgrade backoff',
      () async {
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song',
          source: 'serverPlain',
          plainLyrics: 'retained',
          failureCount: 1,
          lastFailedAt: DateTime.now(),
        );
        final external = _FakeLrclibClient([lrSynced]);
        final result =
            await LyricsResolver(
              libraryDao: database.libraryDao,
              lrclibClient: external,
              apiClient: _FakeServer(synced),
            ).resolve(
              songId: 'song',
              metadata: (
                artist: 'Artist',
                title: 'Track',
                album: null,
                durationSeconds: null,
              ),
              useLrclib: true,
              cacheServerLyrics: false,
            );
        expect(result.source, LyricsSource.serverSynced);
        expect(external.calls, 0);
      },
    );

    for (final cachedSynced in [true, false]) {
      for (final externalSynced in [true, false]) {
        test('offline cache → LRCLIB → stale: synced cache=$cachedSynced, '
            'external=$externalSynced', () async {
          await database.libraryDao.upsertExternalLyricsCache(
            songId: 'song',
            source: cachedSynced ? 'serverSynced' : 'serverPlain',
            syncedLyrics: cachedSynced ? '[00:01.00]cached' : null,
            plainLyrics: cachedSynced ? null : 'stale words',
            ttlSeconds: -1,
          );
          final external = _FakeLrclibClient(externalSynced ? [lrSynced] : []);
          final result =
              await LyricsResolver(
                libraryDao: database.libraryDao,
                lrclibClient: external,
                apiClient: null,
              ).resolve(
                songId: 'song',
                metadata: (
                  artist: 'Artist',
                  title: 'Track',
                  album: null,
                  durationSeconds: null,
                ),
                useLrclib: true,
              );
          expect(external.calls, cachedSynced ? 0 : 1);
          expect(
            result.source,
            cachedSynced
                ? LyricsSource.serverSynced
                : externalSynced
                ? LyricsSource.lrclibSynced
                : LyricsSource.serverPlain,
          );
          if (!cachedSynced && !externalSynced) {
            expect(result.lyrics.value, 'stale words');
          }
          expect(result.confirmedMiss, isFalse);
        });
      }
    }

    test('both empty confirms miss', () async {
      final result =
          await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: _FakeLrclibClient([]),
            apiClient: _FakeServer(const LyricsList()),
          ).resolve(
            songId: 'song',
            metadata: (
              artist: 'Artist',
              title: 'Track',
              album: null,
              durationSeconds: null,
            ),
            useLrclib: true,
          );
      expect(result.confirmedMiss, isTrue);
    });
    test('disabled LRCLIB never calls external source', () async {
      final external = _FakeLrclibClient([lrSynced]);
      await LyricsResolver(
        libraryDao: database.libraryDao,
        lrclibClient: external,
        apiClient: _FakeServer(plain),
      ).resolve(songId: 'song', metadata: null, useLrclib: false);
      expect(external.calls, 0);
    });
    test('cached synced short circuits both sources', () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'serverSynced',
        syncedLyrics: '[00:01.00]cached',
      );
      final server = _FakeServer(plain);
      final external = _FakeLrclibClient([lrSynced]);
      await LyricsResolver(
        libraryDao: database.libraryDao,
        lrclibClient: external,
        apiClient: server,
      ).resolve(songId: 'song', metadata: null, useLrclib: true);
      expect(server.calls, 0);
      expect(external.calls, 0);
    });
    test('late plain cache writes cannot downgrade synced lyrics', () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'lrclibSynced',
        syncedLyrics: '[00:01.00]winner',
      );
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'serverPlain',
        plainLyrics: 'late plain',
      );
      expect(
        (await database.libraryDao.getExternalLyricsCache('song'))!
            .syncedLyrics,
        '[00:01.00]winner',
      );
    });
    test('failed upgrade marker keeps plain lyrics readable', () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'serverPlain',
        plainLyrics: 'retained',
        failureCount: 2,
        lastFailedAt: DateTime.now(),
      );
      expect(
        lyricsResolutionFromExternalCache(
          (await database.libraryDao.getExternalLyricsCache('song'))!,
        )!.lyrics.value,
        'retained',
      );
    });
  });

  test(
    'rate limiting keeps cached lyrics available without surfacing an error',
    () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'lrclibPlain',
        plainLyrics: 'cached words',
        ttlSeconds: 3600,
      );
      final result =
          await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: _RateLimitedLrclibClient(),
            apiClient: null,
          ).resolve(
            songId: 'song',
            metadata: (
              artist: 'Fixture',
              title: 'Track',
              album: null,
              durationSeconds: 200,
            ),
            useLrclib: true,
          );
      expect(result.lyrics.value, 'cached words');
    },
  );

  test('LRCLIB lyrics come from the same language version', () async {
    expect(
      await resolve('Wonder (Japanese Version)', const [english, japanese]),
      'japanese words',
    );
    await database.customStatement('DELETE FROM external_lyrics_cache');
    expect(await resolve('Wonder', const [japanese, english]), 'english words');
  });

  test('another version is used when it is the only LRCLIB result', () async {
    expect(await resolve('Wonder', const [japanese]), 'japanese words');
  });

  test(
    'a negative cache row is never rendered and never blocks a lookup',
    () async {
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'lrclibPlain',
        failureCount: 1,
        lastFailedAt: DateTime.now(),
      );
      final negative = (await database.libraryDao.getExternalLyricsCache(
        'song',
      ))!;
      expect(lyricsResolutionFromExternalCache(negative), isNull);

      // When nothing is found the marker still renders no lyrics.
      final stillEmpty =
          await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: _FakeLrclibClient(const []),
            apiClient: null,
          ).resolve(
            songId: 'song',
            metadata: (
              artist: 'ONE OK ROCK',
              title: 'Wonder',
              album: null,
              durationSeconds: 200,
            ),
            useLrclib: true,
          );
      expect(stillEmpty.lyrics.value, isNull);
      expect(
        (await database.libraryDao.getExternalLyricsCache('song'))!.plainLyrics,
        isNull,
      );

      // An interactive lookup still tries the sources despite the marker, and
      // a success clears it.
      final recovered =
          await LyricsResolver(
            libraryDao: database.libraryDao,
            lrclibClient: _FakeLrclibClient(const [english]),
            apiClient: null,
          ).resolve(
            songId: 'song',
            metadata: (
              artist: 'ONE OK ROCK',
              title: 'Wonder',
              album: null,
              durationSeconds: 200,
            ),
            useLrclib: true,
          );
      expect(recovered.lyrics.value, 'english words');
      final healed = (await database.libraryDao.getExternalLyricsCache(
        'song',
      ))!;
      expect(healed.failureCount, 0);
      expect(healed.lastFailedAt, isNull);
    },
  );

  test('plainLyricsText prefers value, falls back to structured lines', () {
    final lines = [
      StructuredLyrics(
        synced: false,
        line: [
          LyricLine(value: 'a'),
          LyricLine(value: ' '),
          LyricLine(value: 'b'),
        ],
      ),
    ];
    expect(
      plainLyricsText(LyricsList(structuredLyrics: lines, value: 'v')),
      'v',
    );
    expect(plainLyricsText(LyricsList(structuredLyrics: lines)), 'a\nb');
    expect(plainLyricsText(const LyricsList()), '');
  });
}
