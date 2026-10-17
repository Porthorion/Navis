import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/downloads/domain/backfill_progress.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_database.dart';

class _TrackingDio extends DioForNative {
  new(super.baseOptions);

  bool closed = false;

  @override
  void close({bool force = false}) {
    closed = true;
    super.close(force: force);
  }
}

class _Api extends Mock implements SubsonicApiClient;

class _Sync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  void emit(LibrarySyncStatus status) {
    state = LibrarySyncState(status: status, stage: LibrarySyncStage.completed);
  }
}

class _Network extends Notifier<NetworkType> {
  @override
  NetworkType build() => NetworkType.wifi;
  NetworkType get value => state;
  set value(NetworkType next) => state = next;
}

final _network = NotifierProvider<_Network, NetworkType>(_Network.new);

class _Artwork extends PermanentArtworkStore {
  new(Directory dir) : super(readApplicationSupportDirectory: () async => dir);
  int calls = 0;
  @override
  Future<ArtworkEnsureResult> ensureWithResult(
    String? id,
    SubsonicApiClient api,
  ) async {
    calls++;
    return ArtworkEnsureResult.failed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final trigger in [
    'launch',
    'resume',
    'sync',
    'reconnect',
    'reconciliation',
  ]) {
    for (final missing in [true, false]) {
      test(
        '$trigger re-arms one pass only when metadata is missing: $missing',
        () async {
          final db = createTestDatabase();
          final dir = await Directory.systemTemp.createTemp(
            'navis-backfill-trigger-',
          );
          final artwork = _Artwork(dir);
          final api = _Api();
          when(() => api.getLyricsBySongId(any())).thenAnswer(
            (_) async => const LyricsList(
              structuredLyrics: [
                StructuredLyrics(
                  synced: true,
                  line: [LyricLine(start: 1000, value: 'words')],
                ),
              ],
            ),
          );
          final container = ProviderContainer(
            overrides: [
              navisDatabaseProvider.overrideWithValue(db),
              permanentArtworkStoreProvider.overrideWithValue(artwork),
              librarySyncControllerProvider.overrideWith(_Sync.new),
              networkTypeProvider.overrideWith((ref) => ref.watch(_network)),
              subsonicApiProvider.overrideWithValue(api),
              useLrclibProvider.overrideWithValue(false),
              customDownloadFolderEnabledProvider.overrideWithValue(true),
              customDownloadFolderPathProvider.overrideWithValue(dir.path),
              appSettingsProvider.overrideWith(
                (ref) => Stream.value(const AppSettingsModel.defaults()),
              ),
              playerStateProvider.overrideWithValue(
                const PlaybackSnapshot.idle(),
              ),
              externalDioFactoryProvider.overrideWithValue(
                (service, {options}) => _TrackingDio(options),
              ),
            ],
          );
          DownloadService? ownedService;
          addTearDown(() async {
            await ownedService?.stopAndWait();
            container.dispose();
            await ownedService?.dispose();
            await db.close();
            await dir.delete(recursive: true);
          });
          Future<void> seed() async {
            final file = File(p.join(dir.path, 'one.mp3'));
            await file.writeAsBytes([1]);
            await db.libraryDao.upsertSongs([
              SongsTableCompanion.insert(
                id: 'one',
                title: 'Track',
                coverArt: const Value('cover'),
              ),
            ]);
            await db.cacheDao.upsertCachedTrack(
              CachedTracksTableCompanion.insert(
                songId: 'one',
                filePath: file.path,
                fileSize: 1,
                format: 'mp3',
                cacheType: CacheType.permanent,
                downloadStatus: DownloadStatus.complete,
                lastAccessedAt: DateTime.now(),
              ),
            );
            if (!missing) {
              await db.libraryDao.upsertExternalLyricsCache(
                songId: 'one',
                source: 'server',
                syncedLyrics: '[00:01.00]words',
              );
              await artwork.storeBytes('cover', [
                0x89,
                0x50,
                0x4e,
                0x47,
                0x0d,
                0x0a,
                0x1a,
                0x0a,
                1,
              ]);
            }
          }

          if (trigger == 'launch') await seed();
          // The shell keeps this owner listened to, including derived network state.
          final serviceSubscription = container.listen(
            downloadServiceProvider,
            (_, _) {},
          );
          addTearDown(serviceSubscription.close);
          final service = serviceSubscription.read();
          ownedService = service;
          if (trigger != 'launch') {
            await service.start();
            await service.runBackfillNow();
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await seed();
          }
          final phases = <BackfillPhase>[];
          final sub = service.backfillProgress
              .map((p) => p.phase)
              .distinct()
              .listen(phases.add);
          addTearDown(sub.cancel);
          final finished = missing
              ? service.backfillProgress.firstWhere(
                  (p) => p.phase == BackfillPhase.artwork && p.done == 1,
                )
              : null;
          if (trigger == 'resume') {
            final foreground = container.read(
              librarySyncForegroundProvider.notifier,
            );
            foreground.setForeground(false);
            foreground.setForeground(true);
            foreground.setForeground(true);
          } else if (trigger == 'sync') {
            final sync =
                container.read(librarySyncControllerProvider.notifier) as _Sync;
            sync.emit(LibrarySyncStatus.running);
            sync.emit(LibrarySyncStatus.succeeded);
            sync.emit(LibrarySyncStatus.succeeded);
          } else if (trigger == 'reconnect') {
            final network = container.read(_network.notifier);
            final connected = network.value;
            network.value = NetworkType.offline;
            await container.pump();
            network.value = connected;
            await container.pump();
            network.value = connected;
          } else if (trigger == 'reconciliation') {
            container.read(networkReconcilingProvider.notifier).begin();
            container.read(networkReconcilingProvider.notifier).end();
            container.read(networkReconcilingProvider.notifier).end();
          }
          if (missing) {
            await finished!.timeout(const Duration(seconds: 3));
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await service.stopAndWait();
          await sub.cancel();
          expect(
            phases.where((p) => p == BackfillPhase.lyrics),
            hasLength(missing ? 1 : 0),
          );
          expect(artwork.calls, missing ? 1 : 0);
          if (missing) {
            verify(() => api.getLyricsBySongId('one')).called(1);
          } else {
            verifyNever(() => api.getLyricsBySongId(any()));
          }
          await service.dispose();
        },
        skip: !sqliteAvailable,
      );
    }
  }

  test(
    'provider disposal closes artwork Dio before service teardown awaits',
    () async {
      final db = createTestDatabase();
      final clients = <_TrackingDio>[];
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [
            networkTypeProvider.overrideWith((_) => NetworkType.offline),
            subsonicApiProvider.overrideWithValue(null),
            playerStateProvider.overrideWithValue(
              const PlaybackSnapshot.idle(),
            ),
            externalDioFactoryProvider.overrideWithValue((service, {options}) {
              final dio = _TrackingDio(options);
              clients.add(dio);
              return dio;
            }),
          ],
        ),
      );
      final service = container.read(downloadServiceProvider);
      // The artwork transport is created before the shared Deezer API client.
      final artworkDio = clients.first;
      await service.stopAndWait();
      addTearDown(() async {
        for (final dio in clients) {
          dio.close(force: true);
        }
        await service.dispose();
        await db.close();
      });
      container.dispose();
      expect(artworkDio.closed, isTrue);
    },
    skip: !sqliteAvailable,
  );
}
