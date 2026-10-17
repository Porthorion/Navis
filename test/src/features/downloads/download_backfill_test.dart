import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/downloads/domain/backfill_progress.dart';
import 'package:navis/src/features/downloads/domain/download_metadata_gaps.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';

import '../../../helpers/test_database.dart';

class _Api extends Mock implements SubsonicApiClient;

class _Cache extends Mock implements BaseCacheManager;

class _Deezer extends Mock implements DeezerApiClient;

class _External extends LrclibClient {
  int calls = 0;
  bool limited = false;
  @override
  bool get isRateLimited => limited;
  @override
  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
  }) async {
    calls++;
    return [];
  }

  @override
  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
  }) async => null;
}

class _Artwork extends PermanentArtworkStore {
  new(Future<Directory> Function() read)
    : super(readApplicationSupportDirectory: read);
  int calls = 0;
  ArtworkEnsureResult result = ArtworkEnsureResult.serverMissing;
  @override
  Future<ArtworkEnsureResult> ensureWithResult(
    String? id,
    SubsonicApiClient api,
  ) async {
    calls++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NavisDatabase db;
  late Directory dir;
  late _Api api;
  late _External external;
  late _Artwork artwork;
  late _Deezer deezer;
  late Dio imageDio;
  late DownloadService service;
  var wifiOnly = false;
  var online = true;
  var signedOut = false;
  var allowed = true;
  final bytes = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1];
  var imageCalls = 0;
  var uriAllowed = true;
  final matches = <DeezerTrack>[];

  setUp(() async {
    db = createTestDatabase();
    await db.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(id: 'album', name: 'Album'),
    ]);
    dir = await Directory.systemTemp.createTemp('navis-backfill39-');
    api = _Api();
    external = _External();
    artwork = _Artwork(() async => dir);
    deezer = _Deezer();
    wifiOnly = false;
    online = true;
    signedOut = false;
    allowed = true;
    uriAllowed = true;
    imageCalls = 0;
    matches.clear();
    when(() => api.getLyricsBySongId(any()))
        .thenAnswer((_) async => const LyricsList(value: 'server words'));
    when(() => deezer.searchTracks(any())).thenAnswer((_) async => matches);
    imageDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            imageCalls++;
            h.resolve(
              Response<List<int>>(
                requestOptions: o,
                data: bytes,
                statusCode: 200,
              ),
            );
          },
        ),
      );
    service = DownloadService(
      appSettingsDao: db.appSettingsDao,
      cacheDao: db.cacheDao,
      downloadQueueDao: db.downloadQueueDao,
      libraryDao: db.libraryDao,
      readApiClient: () => signedOut ? null : api,
      readWifiOnly: () => wifiOnly,
      readIsWifi: () => false,
      readIsOnline: () => online,
      readCustomDownloadFolderEnabled: () => false,
      readCustomDownloadFolderPath: () => null,
      lrclibClient: external,
      readCoverArtCacheManager: _Cache.new,
      artworkStore: artwork,
      readApplicationSupportDirectory: () async => dir,
      readDeezerArtworkAllowed: () => allowed,
      deezerClient: deezer,
      deezerDio: imageDio,
      allowsArtworkUri: (_) => uriAllowed,
    );
  });
  tearDown(() async {
    await service.dispose();
    imageDio.close();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> seed(
    String id, {
    CacheType type = CacheType.permanent,
    String? cover = 'cover',
  }) async {
    await db.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: id,
        title: 'Track',
        artistName: const Value('Artist'),
        albumName: const Value('Album'),
        albumId: const Value('album'),
        duration: const Value(200),
        coverArt: Value(cover),
      ),
    ]);
    await db.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: id,
        filePath: '/fixture/$id.mp3',
        fileSize: 1,
        format: 'mp3',
        cacheType: type,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime.now(),
      ),
    );
  }

  DeezerTrack match(int id, {String album = 'Album', String title = 'Track'}) =>
      DeezerTrack(
        id: id,
        title: title,
        artist: const DeezerArtist(id: 1, name: 'Artist'),
        durationSeconds: 200,
        album: DeezerAlbum(
          id: id,
          title: album,
          coverXl: 'https://cdn.dzcdn.net/cover.png',
        ),
      );

  test(
    'UI providers expose gaps and seeded progress without a server request',
    () async {
      await seed('song');
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(db),
          permanentArtworkStoreProvider.overrideWithValue(artwork),
          downloadServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        downloadBackfillProgressProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final gaps = await container.read(downloadMetadataGapsProvider.future);
      expect(gaps.songsMissingLyrics, hasLength(1));
      expect(gaps.albumsMissingArtwork, hasLength(1));
      expect(
        (await container.read(downloadBackfillProgressProvider.future)).phase,
        BackfillPhase.idle,
      );
      expect(external.calls, 0);
    },
  );
  test(
    'manual run shares a run, ignores upgrade backoff, emits counts',
    () async {
      await seed('song');
      await db.libraryDao.upsertExternalLyricsCache(
        songId: 'song',
        source: 'serverPlain',
        plainLyrics: 'retained',
        failureCount: 1,
        lastFailedAt: DateTime.now(),
      );
      final progress = <BackfillProgress>[];
      final subscription = service.backfillProgress.listen(progress.add);
      final first = service.runBackfillNow();
      await Future.wait([first, service.runBackfillNow()]);
      expect(external.calls, 1);
      expect(service.currentBackfillProgress.phase, BackfillPhase.idle);
      expect(service.currentBackfillProgress.lastResult.lyricsResolved, 1);
      expect(
        progress.any(
          (p) => p.phase == BackfillPhase.lyrics && p.done == 1 && p.total == 1,
        ),
        isTrue,
      );
      final cached = (await db.libraryDao.getExternalLyricsCache('song'))!;
      expect(cached.failureCount, 2);
      expect(
        lyricsResolutionFromExternalCache(cached)!.lyrics.value,
        'server words',
      );
      await subscription.cancel();
      await service.processQueuedDownloads();
      await service.stopAndWait();
      expect(external.calls, 1);
    },
  );
  test('automatic pass skips a recent plain failed upgrade', () async {
    await seed('song');
    await db.libraryDao.upsertExternalLyricsCache(
      songId: 'song',
      source: 'serverPlain',
      plainLyrics: 'retained',
      failureCount: 1,
      lastFailedAt: DateTime.now(),
    );
    await service.processQueuedDownloads();
    await service.stopAndWait();
    expect(external.calls, 0);
    expect(
      lyricsResolutionFromExternalCache(
        (await db.libraryDao.getExternalLyricsCache('song'))!,
      )!.lyrics.value,
      'retained',
    );
  });
  test('manual run repeats a completed automatic pass', () async {
    await seed('song');
    await service.processQueuedDownloads();
    for (
      var i = 0;
      i < 100 && service.currentBackfillProgress.phase != BackfillPhase.idle;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await service.runBackfillNow();
    expect(external.calls, 2);
  });
  test(
    'Wi-Fi-only and offline report blocked reasons without requests',
    () async {
      await seed('song');
      wifiOnly = true;
      await service.runBackfillNow();
      expect(
        service.currentBackfillProgress.blockedReason,
        BackfillBlockedReason.wifiOnly,
      );
      online = false;
      await service.runBackfillNow();
      expect(
        service.currentBackfillProgress.blockedReason,
        BackfillBlockedReason.offline,
      );
      expect(external.calls, 0);
      expect(artwork.calls, 0);
    },
  );
  test(
    'signed-out manual work is blocked while gaps remain readable',
    () async {
      await seed('song');
      signedOut = true;
      await service.runBackfillNow();
      expect(
        service.currentBackfillProgress.blockedReason,
        BackfillBlockedReason.offline,
      );
      expect(
        (await DownloadMetadataGaps.load(db.cacheDao, artwork)).totalSongs,
        1,
      );
      expect(external.calls, 0);
    },
  );

  test('a download removed during the playback hold is skipped', () async {
    await seed('song');
    service.yieldToPlayback(loading: true, songId: 'playing');
    final started = service.backfillProgress.firstWhere(
      (p) => p.phase == BackfillPhase.lyrics && p.total == 1,
    );
    final run = service.runBackfillNow();
    await started;
    await db.cacheDao.removeCachedTrack('song');
    service.yieldToPlayback(loading: false);
    await run;
    expect(external.calls, 0);
    expect(artwork.calls, 0);
  });

  test(
    'integration disabled during search prevents the image request',
    () async {
      await seed('song');
      matches.add(match(1));
      when(() => deezer.searchTracks(any())).thenAnswer((_) async {
        allowed = false;
        return matches;
      });
      await service.runBackfillNow();
      expect(imageCalls, 0);
    },
  );

  test('cooldown remains visible after artwork phase', () async {
    await seed('song');
    external.limited = true;
    await service.runBackfillNow();
    expect(
      service.currentBackfillProgress.blockedReason,
      BackfillBlockedReason.rateLimited,
    );
    expect(external.calls, 0);
  });
  test(
    'confident fallback persists under server key and survives prune',
    () async {
      await seed('song');
      matches.add(match(1));
      await service.runBackfillNow();
      expect(await artwork.fileFor('cover'), isNotNull);
      expect(imageCalls, 1);
      expect(service.currentBackfillProgress.lastResult.artworkStored, 1);
      await service.runBackfillNow();
      expect(await artwork.fileFor('cover'), isNotNull);
      expect(imageCalls, 1);
      expect(artwork.calls, 1);
    },
  );
  for (final reason in [
    'off',
    'uri',
    'mismatch',
    'ambiguous',
    'server',
    'failed',
    'empty key',
  ]) {
    test('fallback refuses $reason', () async {
      await seed('song', cover: reason == 'empty key' ? '' : 'cover');
      matches.add(match(1));
      if (reason == 'off') allowed = false;
      if (reason == 'uri') uriAllowed = false;
      if (reason == 'mismatch') {
        matches
          ..clear()
          ..add(match(1, album: 'Unrelated'));
      }
      // Fuzzy equal scores without exact-title equivalence must remain ambiguous.
      if (reason == 'ambiguous') {
        matches
          ..clear()
          ..add(match(1, title: 'Track live'))
          ..add(match(2, title: 'Track remix'));
      }
      if (reason == 'server') artwork.result = ArtworkEnsureResult.stored;
      if (reason == 'failed') artwork.result = ArtworkEnsureResult.failed;
      await service.runBackfillNow();
      expect(imageCalls, 0);
      if (const {'off', 'server', 'failed', 'empty key'}.contains(reason)) {
        verifyNever(() => deezer.searchTracks(any()));
      }
    });
  }
  test('one joined metadata query excludes rolling and orphan rows, keeps plain lyrics', () async {
    await seed('plain');
    await seed('missing');
    await seed('rolling', type: CacheType.rolling);
    await seed('empty', cover: '');
    await db.libraryDao.upsertExternalLyricsCache(
      songId: 'plain',
      source: 'serverPlain',
      plainLyrics: 'words',
      failureCount: 2,
    );
    await db.libraryDao.upsertExternalLyricsCache(
      songId: 'missing',
      source: 'lrclibPlain',
      plainLyrics: ' \n\t ',
      syncedLyrics: '',
    );
    await db.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: 'orphan',
        filePath: '/fixture/orphan.mp3',
        fileSize: 1,
        format: 'mp3',
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime.now(),
      ),
    );
    final rows = await db.cacheDao.getPermanentDownloadMetadata();
    expect(
      rows.map((s) => s.songId),
      unorderedEquals(['plain', 'missing', 'empty']),
    );
    expect(rows.singleWhere((s) => s.songId == 'plain').hasPlainLyrics, isTrue);
    await artwork.storeBytes('cover', bytes);
    final gaps = await DownloadMetadataGaps.load(db.cacheDao, artwork);
    expect(
      gaps.songsMissingLyrics.map((s) => s.songId),
      unorderedEquals(['missing', 'empty']),
    );
    expect(gaps.albumsMissingArtwork, hasLength(1));
    expect(gaps.totalSongs, 3);
    // An externally removed file must be missing even with a warm store index.
    await (await artwork.fileFor('cover'))!.delete();
    expect(
      (await DownloadMetadataGaps.load(
        db.cacheDao,
        artwork,
      )).albumsMissingArtwork,
      hasLength(2),
    );
  });
}
