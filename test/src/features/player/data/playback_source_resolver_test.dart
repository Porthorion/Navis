import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;
import '../../../../helpers/test_database.dart';

void main() {
  group('PlaybackSourceResolver', () {
    late NavisDatabase database;
    late SubsonicApiClient apiClient;
    late Directory rollingDir;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      apiClient = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
      rollingDir = Directory.systemTemp.createTempSync(
        'navis_resolver_cache_',
      );
    });

    tearDown(() async {
      await database.close();
      if (rollingDir.existsSync()) {
        rollingDir.deleteSync(recursive: true);
      }
    });

    test(
      'prefers local cached file when present',
      () async {
        final song = await _insertSong(database, id: 'song-1', title: 'Song 1');
        final localFile = File(p.join(rollingDir.path, 'song-1.mp3'));
        await localFile.writeAsBytes(<int>[1, 2, 3]);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now().subtract(const Duration(days: 1)),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () =>
              const StreamingQuality(label: 'wifi', maxBitRate: 320),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(song);
        final track = await database.cacheDao.getCachedTrack(song.id);

        expect(resolved.kind, PlaybackSourceKind.file);
        expect(resolved.cachedFilePath, localFile.path);
        expect(resolved.uri?.scheme, 'file');
        expect(track, isNotNull);
        expect(
          track!.lastAccessedAt.isAfter(
            DateTime.now().subtract(const Duration(hours: 1)),
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'uses lock-cached stream source when cached file is unavailable',
      () async {
        final song = await _insertSong(database, id: 'song-2', title: 'Song 2');
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: '/tmp/does-not-exist/song-2.mp3',
            fileSize: 1000,
            format: 'mp3',
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () =>
              const StreamingQuality(label: 'cellular', maxBitRate: 128),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.lockCachedStream);
        expect(resolved.isLocal, isFalse);
        expect(resolved.cachedFilePath, isNotNull);
        expect(
          p.isWithin(rollingDir.path, resolved.cachedFilePath!),
          isTrue,
        );

        final audioSource = resolved.asAudioSource();
        // ignore: experimental_member_use, reason: test asserts resolver returns LockCachingAudioSource in rolling-stream mode.
        expect(audioSource, isA<LockCachingAudioSource>());

        // ignore: experimental_member_use, reason: test inspects resolved stream URL from LockCachingAudioSource for correctness.
        final lockSource = audioSource as LockCachingAudioSource;
        expect(lockSource.uri.path, '/rest/stream.view');
        expect(lockSource.uri.queryParameters['id'], 'song-2');
        expect(lockSource.uri.queryParameters['maxBitRate'], '128');
      },
      skip: !sqliteAvailable,
    );

    test(
      'builds deterministic cache path per song and quality profile',
      () async {
        final song = await _insertSong(database, id: 'song-3', title: 'Song 3');
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () =>
              const StreamingQuality(label: 'wifi', maxBitRate: 320),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final first = await resolver.resolveForSong(song);
        final second = await resolver.resolveForSong(song);

        expect(first.cachedFilePath, isNotNull);
        expect(second.cachedFilePath, first.cachedFilePath);
      },
      skip: !sqliteAvailable,
    );

    test(
      'codec matrix resolves expected source wiring for major formats',
      () async {
        const cases =
            <
              ({
                String id,
                String suffix,
                String contentType,
                String expectedExtension,
              })
            >[
              (
                id: 'codec-flac',
                suffix: 'flac',
                contentType: 'audio/flac',
                expectedExtension: '.flac',
              ),
              (
                id: 'codec-alac',
                suffix: 'm4a',
                contentType: 'audio/alac',
                expectedExtension: '.m4a',
              ),
              (
                id: 'codec-mp3',
                suffix: 'mp3',
                contentType: 'audio/mpeg',
                expectedExtension: '.mp3',
              ),
              (
                id: 'codec-aac',
                suffix: 'aac',
                contentType: 'audio/aac',
                expectedExtension: '.aac',
              ),
              (
                id: 'codec-opus',
                suffix: 'opus',
                contentType: 'audio/opus',
                expectedExtension: '.opus',
              ),
              (
                id: 'codec-vorbis',
                suffix: 'ogg',
                contentType: 'audio/vorbis',
                expectedExtension: '.ogg',
              ),
            ];

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        for (final testCase in cases) {
          final song = await _insertSong(
            database,
            id: testCase.id,
            title: testCase.id,
            suffix: testCase.suffix,
            contentType: testCase.contentType,
          );

          final lockCached = await resolver.resolveForSong(song);
          expect(lockCached.kind, PlaybackSourceKind.lockCachedStream);
          expect(
            p.extension(lockCached.cachedFilePath!),
            testCase.expectedExtension,
          );

          final direct = await resolver.resolveForSong(
            song,
            preferLockCaching: false,
          );
          expect(direct.kind, PlaybackSourceKind.directStream);
          expect(direct.uri?.path, '/rest/stream.view');
          expect(direct.uri?.queryParameters['id'], testCase.id);
        }
      },
      skip: !sqliteAvailable,
    );

    test(
      'codec matrix prefers local file source for major formats when cache exists',
      () async {
        const cases =
            <
              ({
                String id,
                String suffix,
                String contentType,
                String expectedExtension,
              })
            >[
              (
                id: 'codec-local-flac',
                suffix: 'flac',
                contentType: 'audio/flac',
                expectedExtension: '.flac',
              ),
              (
                id: 'codec-local-alac',
                suffix: 'm4a',
                contentType: 'audio/alac',
                expectedExtension: '.m4a',
              ),
              (
                id: 'codec-local-mp3',
                suffix: 'mp3',
                contentType: 'audio/mpeg',
                expectedExtension: '.mp3',
              ),
              (
                id: 'codec-local-aac',
                suffix: 'aac',
                contentType: 'audio/aac',
                expectedExtension: '.aac',
              ),
              (
                id: 'codec-local-opus',
                suffix: 'opus',
                contentType: 'audio/opus',
                expectedExtension: '.opus',
              ),
              (
                id: 'codec-local-vorbis',
                suffix: 'ogg',
                contentType: 'audio/vorbis',
                expectedExtension: '.ogg',
              ),
            ];

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        for (final testCase in cases) {
          final song = await _insertSong(
            database,
            id: testCase.id,
            title: testCase.id,
            suffix: testCase.suffix,
            contentType: testCase.contentType,
          );
          final localFile = File(
            p.join(
              rollingDir.path,
              '${testCase.id}${testCase.expectedExtension}',
            ),
          );
          await localFile.writeAsBytes(const <int>[1, 2, 3, 4]);
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: song.id,
              filePath: localFile.path,
              fileSize: 4,
              format: testCase.suffix,
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.now().subtract(const Duration(days: 1)),
            ),
          );

          final resolved = await resolver.resolveForSong(song);
          expect(resolved.kind, PlaybackSourceKind.file);
          expect(resolved.cachedFilePath, localFile.path);
          expect(
            p.extension(resolved.cachedFilePath!),
            testCase.expectedExtension,
          );
          expect(resolved.uri?.scheme, 'file');
        }
      },
      skip: !sqliteAvailable,
    );

    test(
      'prefers higher-quality cached file over lower transcoding profile',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-hq-cache',
          title: 'Song HQ',
          suffix: 'flac',
          contentType: 'audio/flac',
        );
        final localFile = File(p.join(rollingDir.path, 'song-hq-cache.flac'));
        await localFile.writeAsBytes(const <int>[9, 8, 7, 6]);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 4,
            format: 'flac',
            bitRate: const Value(900),
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-192-mp3',
            maxBitRate: 192,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.file);
        expect(resolved.cachedFilePath, localFile.path);
      },
      skip: !sqliteAvailable,
    );

    test(
      'does not use mismatched lossy rolling cache for transcode format',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-lossy-mismatch',
          title: 'Song Mismatch',
          suffix: 'aac',
          contentType: 'audio/aac',
        );
        final localFile = File(
          p.join(rollingDir.path, 'song-lossy-mismatch.aac'),
        );
        await localFile.writeAsBytes(const <int>[5, 5, 5]);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 3,
            format: 'aac',
            bitRate: const Value(256),
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-192-mp3',
            maxBitRate: 192,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, isNot(PlaybackSourceKind.file));
      },
      skip: !sqliteAvailable,
    );

    test(
      'uses same-format rolling cache when bitrate satisfies request',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-same-format-bitrate',
          title: 'Song Same Format',
          suffix: 'mp3',
          contentType: 'audio/mpeg',
        );
        final localFile = File(
          p.join(rollingDir.path, 'song-same-format-bitrate.mp3'),
        );
        await localFile.writeAsBytes(const <int>[1, 3, 3, 7]);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 4,
            format: 'mp3',
            bitRate: const Value(320),
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-192-mp3',
            maxBitRate: 192,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.file);
        expect(resolved.cachedFilePath, localFile.path);
      },
      skip: !sqliteAvailable,
    );

    test(
      'omits transcode parameters when source already satisfies profile',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-no-transcode-needed',
          title: 'Song No Transcode',
          suffix: 'mp3',
          contentType: 'audio/mpeg',
          bitRate: 192,
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-320-mp3',
            maxBitRate: 320,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(
          resolved.uri?.queryParameters.containsKey('maxBitRate'),
          isFalse,
        );
        expect(resolved.uri?.queryParameters.containsKey('format'), isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'keeps transcode parameters when bitrate or format requires conversion',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-transcode-needed',
          title: 'Song Needs Transcode',
          suffix: 'flac',
          contentType: 'audio/flac',
          bitRate: 900,
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-192-mp3',
            maxBitRate: 192,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.uri?.queryParameters['maxBitRate'], '192');
        expect(resolved.uri?.queryParameters['format'], 'mp3');
        expect(resolved.metadata.format, 'mp3');
        expect(resolved.metadata.bitRate, 192);
        expect(resolved.metadata.isTranscoded, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'marks bitrate-only transcodes without claiming original lossless format',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-bitrate-only-transcode',
          title: 'Song Bitrate Only',
          suffix: 'flac',
          contentType: 'audio/flac',
          bitRate: 900,
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(
            label: 'wifi-192-original',
            maxBitRate: 192,
          ),
          readRollingCacheDirectory: () async => rollingDir,
          readIsWifi: () => false,
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.uri?.queryParameters['maxBitRate'], '192');
        expect(resolved.uri?.queryParameters.containsKey('format'), isFalse);
        expect(resolved.metadata.isTranscoded, isTrue);
        expect(resolved.metadata.format, isNull);
        expect(resolved.metadata.bitRate, 192);
      },
      skip: !sqliteAvailable,
    );
  });
}

Future<SongsTableData> _insertSong(
  NavisDatabase database, {
  required String id,
  required String title,
  String? suffix,
  String? contentType,
  int? bitRate,
}) async {
  await database.libraryDao.upsertSongs(
    <SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: id,
        title: title,
        bitRate: Value(bitRate),
        suffix: Value(suffix),
        contentType: Value(contentType),
      ),
    ],
  );
  final songs = await database.libraryDao.getSongsByIds(<String>[id]);
  return songs.single;
}
