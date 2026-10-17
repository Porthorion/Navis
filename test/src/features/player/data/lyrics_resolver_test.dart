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
  }) async {
    throw const LrclibRateLimitedException();
  }
}

class _FakeLrclibClient extends LrclibClient {
  new(this.results);

  final List<LrclibLyrics> results;
  int calls = 0;

  @override
  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
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
  }) async => null;
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
}
