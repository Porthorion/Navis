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
import 'package:navis/src/features/player/domain/streaming_quality.dart';
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

    PlaybackSourceResolver resolverFor({
      StreamingQuality Function()? quality,
      bool offlineApi = false,
      bool withLibrary = false,
      bool Function()? canStream,
      bool Function()? cachedFirst,
      bool Function()? supportsLockCaching,
      bool Function()? usesSidecar,
    }) => PlaybackSourceResolver(
      cacheDao: database.cacheDao,
      libraryDao: withLibrary ? database.libraryDao : null,
      rollingCacheManager: DriftRollingCacheManager(
        cacheDao: database.cacheDao,
      ),
      readApiClient: () => offlineApi ? null : apiClient,
      readStreamingQuality:
          quality ?? () => const StreamingQuality(label: 'wifi'),
      readRollingCacheDirectory: () async => rollingDir,
      readCanStream: canStream,
      readCachedPlaybackFirst: cachedFirst,
      readSupportsLockCaching: supportsLockCaching,
      readUsesSidecarRollingCache: usesSidecar,
    );

    /// Writes a [size]-byte file under [rollingDir] and registers it as the
    /// completed cached track of [song].
    Future<File> seedCached(
      SongsTableData song,
      String fileName, {
      required String format,
      int? bitRate,
      CacheType cacheType = CacheType.rolling,
      int size = 3,
      Duration age = Duration.zero,
    }) async {
      final file = File(p.join(rollingDir.path, fileName));
      await file.writeAsBytes(List<int>.filled(size, 1));
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: song.id,
          filePath: file.path,
          fileSize: size,
          format: format,
          bitRate: Value(bitRate),
          cacheType: cacheType,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now().subtract(age),
        ),
      );
      return file;
    }

    for (final suffix in ['x/../../evil', '../a', 'mp3\u0000', r'a\..\b']) {
      test('rolling cache contains hostile id and suffix $suffix', () async {
        final song = await _insertSong(
          database,
          id: '../../id/song',
          title: 'Song',
          suffix: suffix,
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
        expect(
          p.isWithin(rollingDir.path, resolved.sidecarCacheFilePath!),
          isTrue,
        );
        expect(
          p.basename(resolved.sidecarCacheFilePath!),
          matches(r'^[a-f0-9]{40}\.bin$'),
        );
      }, skip: !sqliteAvailable);
    }

    for (final contentType in ['audio/x/../../evil', 'audio/mp3\u0000']) {
      for (final format in [null, '../evil']) {
        test(
          'rolling extension rejects MIME $contentType and requested format $format',
          () async {
            final song = await _insertSong(
              database,
              id: '../hostile/song',
              title: 'Song',
              contentType: contentType,
            );
            final resolver = PlaybackSourceResolver(
              cacheDao: database.cacheDao,
              rollingCacheManager: DriftRollingCacheManager(
                cacheDao: database.cacheDao,
              ),
              readApiClient: () => apiClient,
              readStreamingQuality: () =>
                  StreamingQuality(label: 'wifi', format: format),
              readRollingCacheDirectory: () async => rollingDir,
              readUsesSidecarRollingCache: () => true,
            );
            final resolved = await resolver.resolveForSong(song);
            expect(
              p.isWithin(rollingDir.path, resolved.sidecarCacheFilePath!),
              isTrue,
            );
            expect(p.extension(resolved.sidecarCacheFilePath!), '.bin');
          },
          skip: !sqliteAvailable,
        );
      }
    }

    test('prefers local cached file when present', () async {
      final song = await _insertSong(
        database,
        id: 'song-1',
        title: 'Song 1',
        suffix: 'mp3',
        contentType: 'audio/mpeg',
        bitRate: 320,
      );
      final localFile = await seedCached(
        song,
        'song-1.mp3',
        format: 'mp3',
        bitRate: 320,
        cacheType: CacheType.permanent,
        age: const Duration(days: 1),
      );
      final resolver = resolverFor(
        quality: () =>
            const StreamingQuality(label: 'wifi-320-mp3', maxBitRate: 320),
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

    test(
      'permanent download wins over a mismatched streaming profile',
      () async {
        final song = await _insertSong(
          database,
          id: 'permanent-lossy',
          title: 'Permanent lossy',
          suffix: 'flac',
          contentType: 'audio/flac',
          bitRate: 900,
        );
        final file = await seedCached(
          song,
          'permanent.mp3',
          format: 'mp3',
          bitRate: 192,
          cacheType: CacheType.permanent,
        );
        for (final canStream in <bool>[true, false]) {
          for (final cachedFirst in <bool>[true, false]) {
            final resolver = resolverFor(
              quality: () => const StreamingQuality(label: 'Original'),
              canStream: () => canStream,
              cachedFirst: () => cachedFirst,
            );
            final resolved = await resolver.resolveForSong(song);
            expect(resolved.kind, PlaybackSourceKind.file);
            expect(resolved.cachedFilePath, file.path);
            expect(resolved.metadata.bitRate, 192);
          }
        }
      },
      skip: !sqliteAvailable,
    );

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
      final resolver = resolverFor(
        quality: () => const StreamingQuality(label: 'original'),
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
        final localFile = await seedCached(
          song,
          'song-local-only.mp3',
          format: 'mp3',
          cacheType: CacheType.permanent,
        );
        final resolver = resolverFor(
          quality: () => const StreamingQuality(label: 'wifi', maxBitRate: 320),
          offlineApi: true,
          withLibrary: true,
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
        final resolver = resolverFor(withLibrary: true);

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
        final resolver = resolverFor(
          quality: () =>
              const StreamingQuality(label: 'cellular', maxBitRate: 128),
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
        final resolver = resolverFor(supportsLockCaching: () => false);

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
        final resolver = resolverFor(usesSidecar: () => true);

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
        final resolver = resolverFor(usesSidecar: () => true);

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
        final resolver = resolverFor(
          quality: () => const StreamingQuality(label: 'wifi', maxBitRate: 320),
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
        final resolver = resolverFor(quality: () => quality);

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
        final resolver = resolverFor();

        for (final codec in _codecs) {
          final song = await _insertSong(
            database,
            id: 'codec-${codec.name}',
            title: codec.name,
            suffix: codec.suffix,
            contentType: codec.contentType,
          );

          final lockCached = await resolver.resolveForSong(song);
          expect(lockCached.kind, PlaybackSourceKind.lockCachedStream);
          expect(p.extension(lockCached.cachedFilePath!), codec.extension);

          final direct = await resolver.resolveForSong(
            song,
            preferLockCaching: false,
          );
          expect(direct.kind, PlaybackSourceKind.directStream);
          expect(direct.uri?.path, '/rest/stream.view');
          expect(direct.uri?.queryParameters['id'], song.id);
        }
      },
      skip: !lockCachingAvailable,
    );

    test('codec matrix prefers local file source for major formats when cache exists', () async {
      final resolver = resolverFor();

      for (final codec in _codecs) {
        final song = await _insertSong(
          database,
          id: 'codec-local-${codec.name}',
          title: codec.name,
          suffix: codec.suffix,
          contentType: codec.contentType,
        );
        final localFile = await seedCached(
          song,
          '${song.id}${codec.extension}',
          format: codec.suffix,
          cacheType: CacheType.permanent,
          size: 4,
          age: const Duration(days: 1),
        );

        final resolved = await resolver.resolveForSong(song);
        expect(resolved.kind, PlaybackSourceKind.file);
        expect(resolved.cachedFilePath, localFile.path);
        expect(p.extension(resolved.cachedFilePath!), codec.extension);
        expect(resolved.uri?.scheme, 'file');
      }
    }, skip: !sqliteAvailable);

    // Rolling-cache policy: permanent downloads always win elsewhere; here a
    // rolling file is used only when it matches the active profile, Cached
    // First is on, or the server is unreachable.
    for (final (index, c) in _rollingCacheCases.indexed) {
      test(c.name, () async {
        final song = await _insertSong(
          database,
          id: 'rolling-case-$index',
          title: c.name,
          suffix: c.songSuffix,
          contentType: c.songContentType,
          bitRate: c.songBitRate,
        );
        final file = await seedCached(
          song,
          '$index-cached.${c.cachedFormat}',
          format: c.cachedFormat,
          bitRate: c.cachedBitRate,
        );
        final resolver = resolverFor(
          quality: () => c.quality,
          offlineApi: c.offline,
          cachedFirst: c.cachedFirst == null ? null : () => c.cachedFirst!,
          canStream: c.offline ? () => false : null,
        );

        final resolved = await resolver.resolveForSong(
          song,
          preferLockCaching: !c.direct,
        );

        if (c.expectedKind == null) {
          expect(resolved.kind, isNot(PlaybackSourceKind.file));
        } else {
          expect(resolved.kind, c.expectedKind);
        }
        if (c.expectedKind == PlaybackSourceKind.file) {
          expect(resolved.cachedFilePath, file.path);
        }
        for (final entry in c.params.entries) {
          expect(
            resolved.uri?.queryParameters[entry.key],
            entry.value,
            reason: 'query parameter ${entry.key}',
          );
        }
      }, skip: !sqliteAvailable);
    }

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
        final resolver = resolverFor(
          quality: () => const StreamingQuality(
            label: 'wifi-320-mp3',
            maxBitRate: 320,
            format: 'mp3',
          ),
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
        final resolver = resolverFor(quality: () => _wifi192Mp3);

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
        final resolver = resolverFor(
          quality: () => const StreamingQuality(
            label: 'wifi-192-original',
            maxBitRate: 192,
          ),
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

const _wifi192Mp3 = StreamingQuality(
  label: 'wifi-192-mp3',
  maxBitRate: 192,
  format: 'mp3',
);

typedef _Codec = ({
  String name,
  String suffix,
  String contentType,
  String extension,
});

const List<_Codec> _codecs = <_Codec>[
  (name: 'flac', suffix: 'flac', contentType: 'audio/flac', extension: '.flac'),
  (name: 'alac', suffix: 'm4a', contentType: 'audio/alac', extension: '.m4a'),
  (name: 'mp3', suffix: 'mp3', contentType: 'audio/mpeg', extension: '.mp3'),
  (name: 'aac', suffix: 'aac', contentType: 'audio/aac', extension: '.aac'),
  (name: 'opus', suffix: 'opus', contentType: 'audio/opus', extension: '.opus'),
  (
    name: 'vorbis',
    suffix: 'ogg',
    contentType: 'audio/vorbis',
    extension: '.ogg',
  ),
];

typedef _RollingCase = ({
  String name,
  String songSuffix,
  String songContentType,
  int? songBitRate,
  String cachedFormat,
  int cachedBitRate,
  StreamingQuality quality,
  bool direct,
  bool? cachedFirst,
  bool offline,
  // Null means "anything but the cached file".
  PlaybackSourceKind? expectedKind,
  // Expected stream query parameters; a null value means absent.
  Map<String, String?> params,
});

const List<_RollingCase> _rollingCacheCases = <_RollingCase>[
  (
    name:
        'skips higher-quality cached file for lower active transcoding profile',
    songSuffix: 'flac',
    songContentType: 'audio/flac',
    songBitRate: null,
    cachedFormat: 'flac',
    cachedBitRate: 900,
    quality: _wifi192Mp3,
    direct: false,
    cachedFirst: null,
    offline: false,
    expectedKind: null,
    params: <String, String?>{},
  ),
  (
    name: 'does not use mismatched lossy rolling cache for transcode format',
    songSuffix: 'aac',
    songContentType: 'audio/aac',
    songBitRate: null,
    cachedFormat: 'aac',
    cachedBitRate: 256,
    quality: _wifi192Mp3,
    direct: false,
    cachedFirst: null,
    offline: false,
    expectedKind: null,
    params: <String, String?>{},
  ),
  (
    name: 'skips same-format rolling cache when bitrate differs from request',
    songSuffix: 'mp3',
    songContentType: 'audio/mpeg',
    songBitRate: null,
    cachedFormat: 'mp3',
    cachedBitRate: 320,
    quality: _wifi192Mp3,
    direct: true,
    cachedFirst: null,
    offline: false,
    expectedKind: PlaybackSourceKind.directStream,
    params: <String, String?>{'maxBitRate': '192'},
  ),
  (
    name: 'Wi-Fi original skips existing transcoded rolling cache',
    songSuffix: 'flac',
    songContentType: 'audio/flac',
    songBitRate: 900,
    cachedFormat: 'mp3',
    cachedBitRate: 192,
    quality: StreamingQuality(label: 'wifi-original'),
    direct: true,
    cachedFirst: null,
    offline: false,
    expectedKind: PlaybackSourceKind.directStream,
    params: <String, String?>{'maxBitRate': null, 'format': null},
  ),
  (
    name:
        'changed bitrate and format skips older cache and requests new params',
    songSuffix: 'flac',
    songContentType: 'audio/flac',
    songBitRate: 900,
    cachedFormat: 'opus',
    cachedBitRate: 128,
    quality: StreamingQuality(
      label: 'cellular-profile',
      maxBitRate: 192,
      format: 'mp3',
    ),
    direct: true,
    cachedFirst: null,
    offline: false,
    expectedKind: PlaybackSourceKind.directStream,
    params: <String, String?>{'maxBitRate': '192', 'format': 'mp3'},
  ),
  (
    name: 'Cached First uses mismatched cached file',
    songSuffix: 'flac',
    songContentType: 'audio/flac',
    songBitRate: 900,
    cachedFormat: 'aac',
    cachedBitRate: 256,
    quality: _wifi192Mp3,
    direct: false,
    cachedFirst: true,
    offline: false,
    expectedKind: PlaybackSourceKind.file,
    params: <String, String?>{},
  ),
  (
    name: 'offline fallback uses existing cache with Cached First off',
    songSuffix: 'flac',
    songContentType: 'audio/flac',
    songBitRate: 900,
    cachedFormat: 'mp3',
    cachedBitRate: 128,
    quality: StreamingQuality(label: 'wifi-original'),
    direct: false,
    cachedFirst: false,
    offline: true,
    expectedKind: PlaybackSourceKind.file,
    params: <String, String?>{},
  ),
];

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
