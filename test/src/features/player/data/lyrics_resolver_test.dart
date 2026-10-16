import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lrclib_client.dart';
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

  @override
  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
  }) async => results;

  @override
  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
  }) async => null;
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
