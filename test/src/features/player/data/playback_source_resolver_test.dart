import 'dart:io';

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
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

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
      skip: !_sqliteAvailable,
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
      skip: !_sqliteAvailable,
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
      skip: !_sqliteAvailable,
    );
  });
}

Future<SongsTableData> _insertSong(
  NavisDatabase database, {
  required String id,
  required String title,
}) async {
  await database.libraryDao.upsertSongs(
    <SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: id,
        title: title,
      ),
    ],
  );
  final songs = await database.libraryDao.getSongsByIds(<String>[id]);
  return songs.single;
}
