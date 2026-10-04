import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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

bool get lockCachingAvailable => sqliteAvailable;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      rollingDir = Directory.systemTemp.createTempSync('navis_resolver_cache_');
    });

    tearDown(() async {
      await database.close();
      if (rollingDir.existsSync()) {
        rollingDir.deleteSync(recursive: true);
      }
    });

    test('prefers local cached file when present', () async {
      final song = await _insertSong(
        database,
        id: 'song-1',
        title: 'Song 1',
        suffix: 'mp3',
        contentType: 'audio/mpeg',
        bitRate: 320,
      );
      final localFile = File(p.join(rollingDir.path, 'song-1.mp3'));
      await localFile.writeAsBytes(<int>[1, 2, 3]);

      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: song.id,
          filePath: localFile.path,
          fileSize: 3,
          format: 'mp3',
          bitRate: const Value(320),
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
            const StreamingQuality(label: 'wifi-320-mp3', maxBitRate: 320),
        readRollingCacheDirectory: () async => rollingDir,
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
    }, skip: !sqliteAvailable);

    test('resolves a permanent SAF document through its content URI', () async {
      const channel = MethodChannel(
        'com.navis.app/permanent_download_playback',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'exists') return true;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final song = await _insertSong(
        database,
        id: 'saf-song',
        title: 'SAF song',
        suffix: 'flac',
      );
      const locator = 'content://navis.test/document/root%3Asaf-song.flac';
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: song.id,
          filePath: locator,
          storageKind: const Value('androidSaf'),
          fileSize: 3,
          format: 'flac',
          cacheType: CacheType.permanent,
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
        readStreamingQuality: () => const StreamingQuality(label: 'original'),
        readRollingCacheDirectory: () async => rollingDir,
      );

      final resolved = await resolver.resolveForSong(song);

      expect(resolved.kind, PlaybackSourceKind.file);
      expect(resolved.uri, Uri.parse(locator));
      expect(resolved.cachedFilePath, locator);
    }, skip: !sqliteAvailable);

    test(
      'local-only deleted song resolves only from permanent cached file',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-local-only',
          title: 'Local Only Song',
          serverDeletedAt: DateTime.now(),
        );
        final localFile = File(p.join(rollingDir.path, 'song-local-only.mp3'));
        await localFile.writeAsBytes(<int>[1, 2, 3]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          libraryDao: database.libraryDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => null,
          readStreamingQuality: () =>
              const StreamingQuality(label: 'wifi', maxBitRate: 320),
          readRollingCacheDirectory: () async => rollingDir,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.file);
        expect(resolved.cachedFilePath, localFile.path);
      },
      skip: !sqliteAvailable,
    );

    test(
      'local-only deleted song with missing file is unavailable and pruned',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-local-missing',
          title: 'Local Missing Song',
          serverDeletedAt: DateTime.now(),
        );
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: p.join(rollingDir.path, 'missing.mp3'),
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          libraryDao: database.libraryDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
        );

        await expectLater(
          resolver.resolveForSong(song),
          throwsA(isA<PlaybackSourceUnavailableException>()),
        );
        expect(await database.cacheDao.getCachedTrack(song.id), isNull);
        expect(await database.libraryDao.getSongById(song.id), isNull);
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
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.lockCachedStream);
        expect(resolved.isLocal, isFalse);
        expect(resolved.cachedFilePath, isNotNull);
        expect(resolved.sidecarCacheFilePath, isNull);
        expect(await database.cacheDao.getCachedTrack(song.id), isNull);
        expect(p.isWithin(rollingDir.path, resolved.cachedFilePath!), isTrue);

        final audioSource = resolved.asAudioSource();
        // ignore: experimental_member_use, reason: test asserts resolver returns LockCachingAudioSource in rolling-stream mode.
        expect(audioSource, isA<LockCachingAudioSource>());

        // ignore: experimental_member_use, reason: test inspects resolved stream URL from LockCachingAudioSource for correctness.
        final lockSource = audioSource as LockCachingAudioSource;
        expect(lockSource.uri.path, '/rest/stream.view');
        expect(lockSource.uri.queryParameters['id'], 'song-2');
        expect(lockSource.uri.queryParameters['maxBitRate'], '128');

        final inactiveDeckSource = resolved.asClonedAudioSource();
        // ignore: experimental_member_use, reason: the inactive crossfade deck must not clone an experimental lock-cached source with the same cache path.
        expect(inactiveDeckSource, isNot(isA<LockCachingAudioSource>()));
        expect(inactiveDeckSource, isA<UriAudioSource>());
        expect(
          (inactiveDeckSource as UriAudioSource).uri,
          resolved.lockCachingStreamUri,
        );
      },
      skip: !lockCachingAvailable,
    );

    test(
      'uses direct stream when native lock caching is unavailable',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-no-native-cache',
          title: 'No Native Cache',
        );
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
          readSupportsLockCaching: () => false,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.cachedFilePath, isNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'desktop sidecar mode uses direct stream with rolling cache path',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-sidecar',
          title: 'Sidecar',
          suffix: 'mp3',
          contentType: 'audio/mpeg',
        );
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
          readUsesSidecarRollingCache: () => true,
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.uri?.path, '/rest/stream.view');
        expect(resolved.sidecarCacheFilePath, isNotNull);
        expect(
          p.isWithin(rollingDir.path, resolved.sidecarCacheFilePath!),
          isTrue,
        );
        expect(resolved.asAudioSource(), isA<UriAudioSource>());
      },
      skip: !sqliteAvailable,
    );

    test(
      'desktop sidecar mode keeps the rolling cache path for direct streams',
      () async {
        // Seek recovery, crossfade decks and bypassed songs ask for a direct
        // stream. Desktop always plays one, so the sidecar must still cache
        // it rather than cancel the download already running.
        final song = await _insertSong(
          database,
          id: 'song-sidecar-direct',
          title: 'Sidecar Direct',
          suffix: 'mp3',
          contentType: 'audio/mpeg',
        );
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => rollingDir,
          readUsesSidecarRollingCache: () => true,
        );

        final preferred = await resolver.resolveForSong(song);
        final direct = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(direct.kind, PlaybackSourceKind.directStream);
        expect(direct.sidecarCacheFilePath, isNotNull);
        expect(direct.sidecarCacheFilePath, preferred.sidecarCacheFilePath);
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
        );

        final first = await resolver.resolveForSong(song);
        final second = await resolver.resolveForSong(song);

        expect(first.cachedFilePath, isNotNull);
        expect(second.cachedFilePath, first.cachedFilePath);
      },
      skip: !lockCachingAvailable,
    );

    test(
      'cache path changes when format changes under same quality label',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-3b',
          title: 'Song 3B',
        );
        var quality = const StreamingQuality(
          label: 'profile',
          maxBitRate: 192,
          format: 'mp3',
        );
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          rollingCacheManager: DriftRollingCacheManager(
            cacheDao: database.cacheDao,
          ),
          readApiClient: () => apiClient,
          readStreamingQuality: () => quality,
          readRollingCacheDirectory: () async => rollingDir,
        );

        final first = await resolver.resolveForSong(song);
        quality = const StreamingQuality(
          label: 'profile',
          maxBitRate: 192,
          format: 'opus',
        );
        final second = await resolver.resolveForSong(song);

        expect(first.cachedFilePath, isNotNull);
        expect(second.cachedFilePath, isNot(first.cachedFilePath));
      },
      skip: !lockCachingAvailable,
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
      skip: !lockCachingAvailable,
    );

    test('codec matrix prefers local file source for major formats when cache exists', () async {
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
    }, skip: !sqliteAvailable);

    test(
      'skips higher-quality cached file for lower active transcoding profile',
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
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, isNot(PlaybackSourceKind.file));
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
        );

        final resolved = await resolver.resolveForSong(song);

        expect(resolved.kind, isNot(PlaybackSourceKind.file));
      },
      skip: !sqliteAvailable,
    );

    test(
      'skips same-format rolling cache when bitrate differs from request',
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
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.uri?.queryParameters['maxBitRate'], '192');
      },
      skip: !sqliteAvailable,
    );

    test('Wi-Fi original skips existing transcoded rolling cache', () async {
      final song = await _insertSong(
        database,
        id: 'song-wifi-original',
        title: 'Song Wi-Fi Original',
        suffix: 'flac',
        contentType: 'audio/flac',
        bitRate: 900,
      );
      final localFile = File(p.join(rollingDir.path, 'song-wifi.mp3'));
      await localFile.writeAsBytes(const <int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: song.id,
          filePath: localFile.path,
          fileSize: 3,
          format: 'mp3',
          bitRate: const Value(192),
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
            const StreamingQuality(label: 'wifi-original'),
        readRollingCacheDirectory: () async => rollingDir,
      );

      final resolved = await resolver.resolveForSong(
        song,
        preferLockCaching: false,
      );

      expect(resolved.kind, PlaybackSourceKind.directStream);
      expect(resolved.uri?.queryParameters.containsKey('maxBitRate'), isFalse);
      expect(resolved.uri?.queryParameters.containsKey('format'), isFalse);
    }, skip: !sqliteAvailable);

    test(
      'changed bitrate and format skips older cache and requests new params',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-changed-profile',
          title: 'Song Changed Profile',
          suffix: 'flac',
          contentType: 'audio/flac',
          bitRate: 900,
        );
        final localFile = File(p.join(rollingDir.path, 'song-old-opus.opus'));
        await localFile.writeAsBytes(const <int>[4, 5, 6]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 3,
            format: 'opus',
            bitRate: const Value(128),
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
            label: 'cellular-profile',
            maxBitRate: 192,
            format: 'mp3',
          ),
          readRollingCacheDirectory: () async => rollingDir,
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: false,
        );

        expect(resolved.kind, PlaybackSourceKind.directStream);
        expect(resolved.uri?.queryParameters['maxBitRate'], '192');
        expect(resolved.uri?.queryParameters['format'], 'mp3');
      },
      skip: !sqliteAvailable,
    );

    test('Cached First uses mismatched cached file', () async {
      final song = await _insertSong(
        database,
        id: 'song-cached-first',
        title: 'Song Cached First',
        suffix: 'flac',
        contentType: 'audio/flac',
        bitRate: 900,
      );
      final localFile = File(p.join(rollingDir.path, 'cached-first.aac'));
      await localFile.writeAsBytes(const <int>[7, 8, 9]);
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
        readCachedPlaybackFirst: () => true,
      );

      final resolved = await resolver.resolveForSong(song);

      expect(resolved.kind, PlaybackSourceKind.file);
      expect(resolved.cachedFilePath, localFile.path);
    }, skip: !sqliteAvailable);

    test(
      'offline fallback uses existing cache with Cached First off',
      () async {
        final song = await _insertSong(
          database,
          id: 'song-offline-cache',
          title: 'Song Offline Cache',
          suffix: 'flac',
          contentType: 'audio/flac',
          bitRate: 900,
        );
        final localFile = File(p.join(rollingDir.path, 'offline-cache.mp3'));
        await localFile.writeAsBytes(const <int>[3, 2, 1]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: song.id,
            filePath: localFile.path,
            fileSize: 3,
            format: 'mp3',
            bitRate: const Value(128),
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
          readApiClient: () => null,
          readStreamingQuality: () =>
              const StreamingQuality(label: 'wifi-original'),
          readRollingCacheDirectory: () async => rollingDir,
          readCachedPlaybackFirst: () => false,
          readCanStream: () => false,
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
  DateTime? serverDeletedAt,
}) async {
  await database.libraryDao.upsertSongs(<SongsTableCompanion>[
    SongsTableCompanion.insert(
      id: id,
      title: title,
      bitRate: Value(bitRate),
      suffix: Value(suffix),
      contentType: Value(contentType),
    ),
  ]);
  if (serverDeletedAt != null) {
    await (database.update(database.songsTable)
          ..where((table) => table.id.equals(id)))
        .write(SongsTableCompanion(serverDeletedAt: Value(serverDeletedAt)));
  }
  final songs = await database.libraryDao.getSongsByIds(<String>[id]);
  return songs.single;
}
