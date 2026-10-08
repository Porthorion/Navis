import 'package:navis/src/features/library/domain/library_sync_request.dart';

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

void main() {
  group('DriftLibrarySyncEngine scan guard', () {
    late NavisDatabase database;
    late ServerConfigRepository serverConfigRepository;
    late FakeSyncCredentialStore credentials;
    late FakeLibrarySyncApi api;
    late DriftLibrarySyncEngine engine;

    Future<int> saveSession({String? capabilitiesJson}) async {
      await serverConfigRepository.save(
        ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
          capabilitiesJson: capabilitiesJson,
        ),
      );
      return (await serverConfigRepository.getActiveServer())!.id!;
    }

    void seedTwoAlbumCatalog() {
      api.artists.addAll(const <Artist>[
        Artist(id: 'artist-1', name: 'Artist 1'),
        Artist(id: 'artist-2', name: 'Artist 2'),
      ]);
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
        ),
        Album(
          id: 'album-2',
          name: 'Album 2',
          artist: 'Artist 2',
          artistId: 'artist-2',
        ),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[Song(id: 'song-1', title: 'Song 1', albumId: 'album-1')],
      );
      api.albumDetails['album-2'] = const Album(
        id: 'album-2',
        name: 'Album 2',
        songs: <Song>[Song(id: 'song-2', title: 'Song 2', albumId: 'album-2')],
      );
    }

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      credentials = FakeSyncCredentialStore();
      serverConfigRepository = ServerConfigRepository(
        database,
        credentials: credentials,
      );
      api = FakeLibrarySyncApi();
      engine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
        scanSettlePollInterval: const Duration(milliseconds: 1),
        scanSettleMaxPolls: 2,
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('a scan running at collection start withholds promotion', () async {
      final promotionScanAt = DateTime.utc(2026, 9, 1, 9);
      api.scanStatusQueue.addAll(<ScanStatus?>[
        const ScanStatus(scanning: true, count: 10),
        ScanStatus(scanning: false, count: 10, lastScan: promotionScanAt),
      ]);
      seedTwoAlbumCatalog();
      final serverId = await saveSession();

      final state = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      // The committed catalog stays visible; the candidate returns to
      // collection instead of replacing it with incomplete evidence.
      expect(state.freshness, LibrarySyncFreshness.repairRecommended);
      final syncState = await database.librarySyncDao.getOrCreateState(
        serverId,
      );
      expect(syncState.candidateStatus, 'collecting');
      expect(syncState.currentGeneration, 0);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      expect(await database.select(database.songsTable).get(), isEmpty);

      final ledger = await database.librarySyncDao
          .getRecentOperationLedgerEntries(serverId);
      final deferred = ledger
          .where((entry) => entry.reason == 'scanChangedDuringCollection')
          .toList();
      expect(deferred, hasLength(1));
      final details =
          jsonDecode(deferred.single.detailsJson) as Map<String, Object?>;
      expect(details['tokenAtCollection'], isNull);
      expect(details['tokenAtPromotion'], promotionScanAt.toIso8601String());

      expect(
        jsonDecode(
          (await serverConfigRepository.getActiveServer())!.capabilitiesJson!,
        )['navis']['libraryScanDeferralStreak'],
        '1',
      );
    }, skip: !sqliteAvailable);

    test('a changed scan token at promotion defers, then a stable run promotes and reconciles', () async {
      final firstScanAt = DateTime.utc(2026, 9, 2, 8);
      final secondScanAt = DateTime.utc(2026, 9, 2, 9);
      api.scanStatusQueue.addAll(<ScanStatus?>[
        ScanStatus(scanning: false, count: 10, lastScan: firstScanAt),
        ScanStatus(scanning: false, count: 11, lastScan: secondScanAt),
      ]);
      seedTwoAlbumCatalog();
      final serverId = await saveSession();

      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      var syncState = await database.librarySyncDao.getOrCreateState(serverId);
      expect(syncState.currentGeneration, 0);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      final ledger = await database.librarySyncDao
          .getRecentOperationLedgerEntries(serverId);
      final deferred = ledger
          .where((entry) => entry.reason == 'scanChangedDuringCollection')
          .toList();
      expect(deferred, hasLength(1));
      final details =
          jsonDecode(deferred.single.detailsJson) as Map<String, Object?>;
      expect(details['tokenAtCollection'], firstScanAt.toIso8601String());
      expect(details['tokenAtPromotion'], secondScanAt.toIso8601String());

      // The resumable candidate recollects under a stable token, promotes,
      // and marks the covered scan token reconciled.
      api.scanStatus = ScanStatus(
        scanning: false,
        count: 11,
        lastScan: secondScanAt,
      );
      final state = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(2));
      syncState = await database.librarySyncDao.getOrCreateState(serverId);
      expect(syncState.currentGeneration, 1);
      final observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.reconciledToken, secondScanAt.toIso8601String());
      expect(observation.pendingReconciliation, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'repeated scan churn accrues a deferral streak in the ledger',
      () async {
        var scanCalls = 0;
        var scanTimes = <DateTime>[
          DateTime.utc(2026, 9, 2, 8),
          DateTime.utc(2026, 9, 2, 9),
        ];
        api.onGetScanStatus = () async {
          final token = scanTimes.length > scanCalls
              ? scanTimes[scanCalls]
              : scanTimes.last;
          scanCalls++;
          return ScanStatus(scanning: false, count: 10, lastScan: token);
        };
        seedTwoAlbumCatalog();
        final serverId = await saveSession();

        await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        );
        scanCalls = 0;
        scanTimes = <DateTime>[
          DateTime.utc(2026, 9, 2, 10),
          DateTime.utc(2026, 9, 2, 11),
        ];
        await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        );

        final ledger = await database.librarySyncDao
            .getRecentOperationLedgerEntries(serverId);
        final deferred = ledger
            .where((entry) => entry.reason == 'scanChangedDuringCollection')
            .toList();
        expect(deferred, hasLength(2));
        // Recent-first ordering: the newest deferral carries the higher streak.
        expect(jsonDecode(deferred.first.detailsJson)['deferralStreak'], 2);
        expect(jsonDecode(deferred.last.detailsJson)['deferralStreak'], 1);
        expect(
          jsonDecode(
            (await serverConfigRepository.getActiveServer())!.capabilitiesJson!,
          )['navis']['libraryScanDeferralStreak'],
          '2',
        );
      },
      skip: !sqliteAvailable,
    );

    test('a settled server releases promotion at the deferral cap', () async {
      var scanCalls = 0;
      final scanTimes = <DateTime>[
        DateTime.utc(2026, 9, 2, 8),
        DateTime.utc(2026, 9, 2, 9),
      ];
      api.onGetScanStatus = () async {
        if (scanCalls >= 2) {
          // Settle-wait polls observe a quiet server.
          return ScanStatus(
            scanning: false,
            count: 10,
            lastScan: DateTime.utc(2026, 9, 2, 9),
          );
        }
        final token = scanTimes.length > scanCalls
            ? scanTimes[scanCalls]
            : scanTimes.last;
        scanCalls++;
        return ScanStatus(scanning: false, count: 10, lastScan: token);
      };
      seedTwoAlbumCatalog();
      final serverId = await saveSession(
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{'libraryScanDeferralStreak': '2'},
        }),
      );

      // Third consecutive churn: the cap is reached, the settle poll finds
      // a quiet server, and the freshest completed snapshot is promoted.
      final state = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(2));
      final ledger = await database.librarySyncDao
          .getRecentOperationLedgerEntries(serverId);
      final released = ledger
          .where((entry) => entry.reason == 'scanChurnCapRelease')
          .toList();
      expect(released, hasLength(1));
      expect(jsonDecode(released.single.detailsJson)['deferralStreak'], 3);
      final capabilities =
          jsonDecode(
                (await serverConfigRepository.getActiveServer())!
                    .capabilitiesJson!,
              )['navis']
              as Map;
      expect(capabilities.containsKey('libraryScanDeferralStreak'), isFalse);
    }, skip: !sqliteAvailable);

    test(
      'a server that keeps scanning through the settle window stays deferred',
      () async {
        var scanCalls = 0;
        api.onGetScanStatus = () async {
          scanCalls++;
          if (scanCalls == 1) {
            return ScanStatus(
              scanning: false,
              count: 10,
              lastScan: DateTime.utc(2026, 9, 2, 8),
            );
          }
          // Promotion observation and every settle poll see an active scan.
          return const ScanStatus(scanning: true, count: 10);
        };
        seedTwoAlbumCatalog();
        final serverId = await saveSession(
          capabilitiesJson: jsonEncode(<String, Object?>{
            'navis': <String, Object?>{'libraryScanDeferralStreak': '2'},
          }),
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        );

        expect(state.freshness, LibrarySyncFreshness.repairRecommended);
        expect(await database.select(database.albumsTable).get(), isEmpty);
        final ledger = await database.librarySyncDao
            .getRecentOperationLedgerEntries(serverId);
        final deferred = ledger
            .where((entry) => entry.reason == 'scanChangedDuringCollection')
            .toList();
        expect(deferred, hasLength(1));
        expect(jsonDecode(deferred.single.detailsJson)['deferralStreak'], 3);
        expect(
          jsonDecode(
            (await serverConfigRepository.getActiveServer())!.capabilitiesJson!,
          )['navis']['libraryScanDeferralStreak'],
          '3',
        );
        // Collection + promotion observations plus the two settle polls.
        expect(
          api.calls.where((call) => call == 'getScanStatus').length,
          greaterThanOrEqualTo(4),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'an unsupported scan-status endpoint never blocks promotion',
      () async {
        seedTwoAlbumCatalog();
        final serverId = await saveSession();

        final state = await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getScanStatus'));
        expect(await database.select(database.albumsTable).get(), hasLength(2));
        final observation = await database.librarySyncDao.getScanObservation(
          serverId,
        );
        expect(observation!.scanSupported, isFalse);
        final ledger = await database.librarySyncDao
            .getRecentOperationLedgerEntries(serverId);
        expect(
          ledger.where(
            (entry) => entry.reason == 'scanChangedDuringCollection',
          ),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test('admission opens one reconciliation window per token and promotion closes it', () async {
      final cursor = FakeLibrarySyncApi.defaultIndexesCursor;
      final scanAt = DateTime.utc(2026, 9, 3, 8);
      api.scanStatus = ScanStatus(scanning: false, count: 10, lastScan: scanAt);
      seedTwoAlbumCatalog();
      final serverId = await saveSession(
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesCursor': cursor.toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      api.indexes = Indexes(lastModified: cursor);

      // A newly completed scan rides the scheduled probe: one resumable
      // snapshot is indicated through the same channel as an index change.
      final firstProbe = await engine.probeCatalog();
      expect(firstProbe.probeIndexChanged, isTrue);
      var observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.observedToken, scanAt.toIso8601String());
      expect(observation.pendingReconciliation, isTrue);
      expect(observation.reconciledToken, isNull);

      // Repeated probes coalesce on the same token instead of reopening
      // the window.
      await engine.probeCatalog();
      observation = await database.librarySyncDao.getScanObservation(serverId);
      expect(observation!.observedToken, scanAt.toIso8601String());
      expect(observation.reconciledToken, isNull);

      // Promotion covers the observed token and closes the window.
      final state = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(state.status, LibrarySyncStatus.succeeded);
      observation = await database.librarySyncDao.getScanObservation(serverId);
      expect(observation!.reconciledToken, scanAt.toIso8601String());
      expect(observation.pendingReconciliation, isFalse);

      final finalProbe = await engine.probeCatalog();
      expect(finalProbe.probeIndexChanged, isFalse);
    }, skip: !sqliteAvailable);

    test('a failure inside the promotion transaction rolls back and stays retryable', () async {
      seedTwoAlbumCatalog();
      final serverId = await saveSession();
      await database.customStatement(
        'CREATE TRIGGER fail_promotion_album2 BEFORE INSERT ON albums '
        "WHEN NEW.id = 'album-2' BEGIN "
        "SELECT RAISE(ABORT, 'injected promotion failure'); END;",
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      expect(state.status, LibrarySyncStatus.failed);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      expect(await database.select(database.songsTable).get(), isEmpty);
      final syncState = await database.librarySyncDao.getOrCreateState(
        serverId,
      );
      expect(syncState.candidateStatus, 'applying');
      expect(syncState.currentGeneration, 0);
      expect(syncState.candidateGeneration, 1);

      await database.customStatement('DROP TRIGGER fail_promotion_album2');
      final retried = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(retried.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(2));
      final ledger = await database.librarySyncDao
          .getRecentOperationLedgerEntries(serverId);
      expect(
        ledger.where((entry) => entry.reason == 'validatedFullCandidate'),
        isNotEmpty,
      );
      final recovered = await database.librarySyncDao.getOrCreateState(
        serverId,
      );
      expect(recovered.candidateStatus, isNull);
      expect(recovered.currentGeneration, 1);
    }, skip: !sqliteAvailable);
  });
}
