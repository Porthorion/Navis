import 'package:navis/src/features/library/domain/library_sync_request.dart';

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

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
      engine = serialDriftEngine(
        api: api,
        database: database,
        repository: serverConfigRepository,
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

    // ---- #470: the guard must not fail open (scanning, unreadable, cancel) --

    ScanStatus idle(int hour) => ScanStatus(
      scanning: false,
      count: 10,
      lastScan: DateTime.utc(2026, 9, 1, hour),
    );
    const busy = ScanStatus(scanning: true, count: 10);

    /// Scripted `getScanStatus` reads, one per call (an [Exception] entry is
    /// thrown, null is "endpoint missing"); the last entry repeats.
    void scanScript(List<Object?> reads) {
      var index = 0;
      api.onGetScanStatus = () async {
        final read = reads[index < reads.length ? index++ : reads.length - 1];
        if (read is Exception) throw read;
        return read as ScanStatus?;
      };
    }

    void listAlbums(int count) {
      api.artists
        ..clear()
        ..add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = <Album>[
        for (var i = 1; i <= count; i++)
          Album(
            id: 'album-$i',
            name: 'Album $i',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
      ];
      for (var i = 1; i <= 10; i++) {
        api.albumDetails['album-$i'] = Album(
          id: 'album-$i',
          name: 'Album $i',
          songs: <Song>[
            Song(id: 'song-$i', title: 'Song $i', albumId: 'album-$i'),
          ],
        );
      }
    }

    int pageRequests() =>
        api.calls.where((c) => c.startsWith('getAlbumListPage')).length;

    Future<LibrarySyncState> runPlan([SyncExecutionPlan? plan]) =>
        engine.executeSyncPlan(
          plan ?? syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        );

    /// Committed run 1: ten albums, idle token. Returns the server id.
    Future<int> commitRunOne({List<Object?>? reads}) async {
      scanScript(reads ?? <Object?>[idle(8)]);
      listAlbums(10);
      final serverId = await saveSession();
      final state = await runPlan();
      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(10));
      return serverId;
    }

    Future<void> seedNavis(String key, String value) async {
      final config = (await serverConfigRepository.getActiveServer())!;
      final capabilities =
          jsonDecode(config.capabilitiesJson ?? '{}') as Map<String, Object?>;
      final navis = <String, Object?>{
        ...((capabilities['navis'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{}),
        key: value,
      };
      await serverConfigRepository.updateCapabilitiesJson(
        jsonEncode(<String, Object?>{...capabilities, 'navis': navis}),
      );
    }

    Future<Map<String, Object?>> navisCaps() async =>
        (jsonDecode(
                  (await serverConfigRepository.getActiveServer())!
                      .capabilitiesJson!,
                )['navis']
                as Map)
            .cast<String, Object?>();

    Future<List<String>> ledgerReasons(int serverId) async =>
        (await database.librarySyncDao.getRecentOperationLedgerEntries(
          serverId,
        )).map((e) => e.reason).toList();

    Future<void> expectCommittedCatalogKept(
      int serverId, {
      String status = 'collecting',
    }) async {
      expect(await database.select(database.albumsTable).get(), hasLength(10));
      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        status,
      );
    }

    test(
      'D1: a scan running at both observations withholds promotion',
      () async {
        final serverId = await commitRunOne();
        final freshPages = pageRequests();
        listAlbums(9);
        scanScript(<Object?>[busy]);

        final state = await runPlan();

        expect(state.freshness, LibrarySyncFreshness.repairRecommended);
        await expectCommittedCatalogKept(serverId);
        expect(
          (await ledgerReasons(serverId))
              .where((r) => r == 'scanChangedDuringCollection'),
          hasLength(1),
        );
        expect((await navisCaps())['libraryScanDeferralStreak'], '1');

        // Run 3 (idle) recollects every page; nothing from the mid-scan run is
        // reused.
        api.calls.clear();
        scanScript(<Object?>[idle(9)]);
        final third = await runPlan();
        expect(third.status, LibrarySyncStatus.succeeded);
        expect(pageRequests(), freshPages);
        expect(await database.select(database.albumsTable).get(), hasLength(9));
      },
      skip: !sqliteAvailable,
    );

    test(
      'D1b: pages collected mid-scan are not resumed by a scanning run',
      () async {
        final serverId = await commitRunOne();
        final freshPages = pageRequests();
        listAlbums(9);
        scanScript(<Object?>[busy]);
        await runPlan();

        api.calls.clear();
        await runPlan();

        expect(pageRequests(), freshPages);
        await expectCommittedCatalogKept(serverId);
      },
      skip: !sqliteAvailable,
    );

    test('D1b tokenless: a scan reading must not let a later idle run resume mid-scan pages', () async {
      const tokenless = ScanStatus(scanning: false, count: 10);
      scanScript(<Object?>[tokenless]);
      listAlbums(10);
      api.albumDetails['album-5'] = const Album(
        id: 'album-5',
        name: 'Album 5',
        songs: <Song>[
          Song(id: 'song-5', title: 'Song 5', albumId: 'album-5'),
          Song(id: 'song-5b', title: 'Song 5b', albumId: 'album-5'),
        ],
      );
      final fullAlbum5 = api.albumDetails['album-5']!;
      final serverId = await saveSession();
      await runPlan();
      expect(await database.select(database.songsTable).get(), hasLength(11));

      // Run 2 collects album-5 mid-scan, without song-5b.
      api.albumDetails['album-5'] = const Album(
        id: 'album-5',
        name: 'Album 5',
        songs: <Song>[Song(id: 'song-5', title: 'Song 5', albumId: 'album-5')],
      );
      scanScript(<Object?>[busy]);
      await runPlan();
      await expectCommittedCatalogKept(serverId);

      // Run 3 reads tokenless idle; the server really still has song-5b.
      api.albumDetails['album-5'] = fullAlbum5;
      api.calls.clear();
      scanScript(<Object?>[tokenless]);
      await runPlan();

      expect(api.calls, contains('getAlbum:album-5'));
      final songIds = (await database.select(database.songsTable).get())
          .map((song) => song.id)
          .toSet();
      expect(songIds, contains('song-5b'));
    }, skip: !sqliteAvailable);

    test('D1 held: a confirming run that defers keeps the hold', () async {
      final serverId = await commitRunOne();
      listAlbums(8);
      scanScript(<Object?>[idle(8)]);
      await runPlan();
      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        'awaitingDeletionConfirmation',
      );

      scanScript(<Object?>[busy]);
      await runPlan(await repairPlanAfterDialog(database));

      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        'awaitingDeletionConfirmation',
      );
      expect(await database.select(database.albumsTable).get(), hasLength(10));
    }, skip: !sqliteAvailable);

    final unreadableErrors = <String, Exception>{
      'connection': const SubsonicConnectionException('timeout'),
      'http 503': const SubsonicGenericException(message: 'down', code: 503),
      'auth': const SubsonicAuthException(message: 'auth'),
      'dio cancel without cancelSync': const SubsonicConnectionException(
        'The request was cancelled.',
      ),
    };
    for (final entry in unreadableErrors.entries) {
      test(
        'D2: unreadable status at promotion defers (${entry.key})',
        () async {
          final serverId = await commitRunOne();
          listAlbums(9);
          scanScript(<Object?>[idle(8), entry.value]);

          final state = await runPlan();

          expect(state.freshness, LibrarySyncFreshness.repairRecommended);
          await expectCommittedCatalogKept(serverId);
          expect(
            await ledgerReasons(serverId),
            contains('scanStatusUnreadable'),
          );
          final caps = await navisCaps();
          expect(caps['libraryScanDeferralStreak'], isNull);
          expect(caps['libraryScanUnreadableStreak'], '1');
          expect(
            (await database.librarySyncDao.getScanObservation(serverId))!
                .scanSupported,
            isTrue,
          );
        },
        skip: !sqliteAvailable,
      );
    }

    test('D3: scanning at collection, unreadable at promotion defers as scan and never releases', () async {
      final serverId = await commitRunOne();
      await seedNavis('libraryScanDeferralStreak', '2');
      listAlbums(9);
      scanScript(<Object?>[
        busy,
        const SubsonicConnectionException('x'),
        idle(8),
      ]);

      await runPlan();

      await expectCommittedCatalogKept(serverId);
      final reasons = await ledgerReasons(serverId);
      expect(reasons, contains('scanChangedDuringCollection'));
      expect(reasons, isNot(contains('scanChurnCapRelease')));
      expect((await navisCaps())['libraryScanDeferralStreak'], '3');
    }, skip: !sqliteAvailable);

    for (final atCollection in <String>['idle', 'scanning']) {
      test(
        'D4: a missing endpoint at promotion with a stored token defers ($atCollection at collection)',
        () async {
          final serverId = await commitRunOne();
          listAlbums(9);
          scanScript(<Object?>[
            if (atCollection == 'idle') idle(8) else busy,
            null,
          ]);

          await runPlan();

          await expectCommittedCatalogKept(serverId);
          expect(
            (await database.librarySyncDao.getScanObservation(serverId))!
                .scanSupported,
            isTrue,
          );
        },
        skip: !sqliteAvailable,
      );
    }

    test('D6: a permanent API error with no stored token reads unsupported and promotes every run', () async {
      const forbidden = SubsonicForbiddenException(message: 'forbidden');
      final serverId = await commitRunOne(reads: <Object?>[forbidden]);
      for (final count in <int>[9, 9, 9]) {
        listAlbums(count);
        final state = await runPlan();
        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.freshness, isNot(LibrarySyncFreshness.repairRecommended));
        expect(
          await database.select(database.albumsTable).get(),
          hasLength(count),
        );
      }
      expect(
        (await database.librarySyncDao.getScanObservation(serverId))!
            .scanSupported,
        isFalse,
      );
      expect(
        await ledgerReasons(serverId),
        isNot(contains('scanStatusUnreadable')),
      );
    }, skip: !sqliteAvailable);

    test(
      'D6: the same API error with a stored token still defers as unreadable',
      () async {
        final serverId = await commitRunOne();
        listAlbums(9);
        scanScript(<Object?>[
          const SubsonicForbiddenException(message: 'forbidden'),
        ]);

        await runPlan();

        await expectCommittedCatalogKept(serverId);
        expect(await ledgerReasons(serverId), contains('scanStatusUnreadable'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'D6: a transport error with no stored token stays unreadable',
      () async {
        final serverId = await commitRunOne(reads: <Object?>[null]);
        listAlbums(9);
        scanScript(<Object?>[const SubsonicConnectionException('timeout')]);

        await runPlan();

        await expectCommittedCatalogKept(serverId);
        expect(await ledgerReasons(serverId), contains('scanStatusUnreadable'));
      },
      skip: !sqliteAvailable,
    );

    for (final code in <int>[503, 429]) {
      test(
        'D6: HTTP $code on the status read with no stored token stays unreadable',
        () async {
          final serverId = await commitRunOne(reads: <Object?>[null]);
          listAlbums(9);
          scanScript(<Object?>[
            SubsonicGenericException(message: 'busy', code: code),
          ]);

          await runPlan();

          await expectCommittedCatalogKept(serverId);
          expect(
            await ledgerReasons(serverId),
            contains('scanStatusUnreadable'),
          );
        },
        skip: !sqliteAvailable,
      );
    }

    test('D5: unreadable at collection, idle at promotion defers', () async {
      final serverId = await commitRunOne();
      listAlbums(9);
      scanScript(<Object?>[const SubsonicConnectionException('x'), idle(8)]);

      await runPlan();

      await expectCommittedCatalogKept(serverId);
      expect(await ledgerReasons(serverId), contains('scanStatusUnreadable'));
    }, skip: !sqliteAvailable);

    test(
      'C1: cancel inside the promotion status read ends cancelled',
      () async {
        final serverId = await commitRunOne();
        final ledgerBefore = (await ledgerReasons(serverId)).length;
        listAlbums(9);
        var calls = 0;
        api.onGetScanStatus = () async {
          if (++calls == 2) engine.cancelSync();
          return idle(8);
        };

        final state = await runPlan();

        expect(state.status, LibrarySyncStatus.cancelled);
        // The collected candidate stays `ready` for a resume; nothing applied.
        await expectCommittedCatalogKept(serverId, status: 'ready');
        expect((await ledgerReasons(serverId)).length, ledgerBefore);
      },
      skip: !sqliteAvailable,
    );

    test('C2: cancel inside the analyzer stops before applying', () async {
      late DriftLibrarySyncEngine cancelling;
      cancelling = serialDriftEngine(
        api: api,
        database: database,
        repository: serverConfigRepository,
        scanSettlePollInterval: const Duration(milliseconds: 1),
        scanSettleMaxPolls: 2,
        readProtectedSongIds: () {
          cancelling.cancelSync();
          return const <String>{};
        },
      );
      final serverId = await commitRunOne();
      listAlbums(9);
      scanScript(<Object?>[idle(8)]);

      final state = await cancelling.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      expect(state.status, LibrarySyncStatus.cancelled);
      expect(await database.select(database.albumsTable).get(), hasLength(10));
      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        'ready',
      );
    }, skip: !sqliteAvailable);

    test('C3: cancel during the settle wait ends cancelled', () async {
      final serverId = await commitRunOne();
      await seedNavis('libraryScanDeferralStreak', '2');
      listAlbums(9);
      var calls = 0;
      api.onGetScanStatus = () async {
        if (++calls == 3) engine.cancelSync();
        return calls == 2 ? busy : idle(8);
      };

      final state = await runPlan();

      expect(state.status, LibrarySyncStatus.cancelled);
      expect(
        await ledgerReasons(serverId),
        isNot(contains('scanChurnCapRelease')),
      );
      expect(await database.select(database.albumsTable).get(), hasLength(10));
    }, skip: !sqliteAvailable);

    test(
      'R1: the unreadable cap releases when the final read still fails',
      () async {
        final serverId = await commitRunOne();
        await seedNavis('libraryScanUnreadableStreak', '2');
        await seedNavis('libraryScanDeferralStreak', '1');
        listAlbums(9);
        scanScript(<Object?>[idle(8), const SubsonicConnectionException('x')]);

        final state = await runPlan();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(await database.select(database.albumsTable).get(), hasLength(9));
        expect(
          await ledgerReasons(serverId),
          contains('scanStatusUnreadableCapRelease'),
        );
        final caps = await navisCaps();
        expect(caps.containsKey('libraryScanUnreadableStreak'), isFalse);
        expect(caps.containsKey('libraryScanDeferralStreak'), isFalse);
        expect(
          (await database.librarySyncDao.getScanObservation(serverId))!
              .scanSupported,
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test('R1b: at the unreadable cap a final idle read with the collection token promotes', () async {
      final serverId = await commitRunOne();
      await seedNavis('libraryScanUnreadableStreak', '2');
      listAlbums(9);
      scanScript(<Object?>[
        idle(8),
        const SubsonicConnectionException('x'),
        idle(8),
      ]);

      final state = await runPlan();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(9));
      expect(
        await ledgerReasons(serverId),
        isNot(contains('scanStatusUnreadableCapRelease')),
      );
      expect(
        (await navisCaps()).containsKey('libraryScanUnreadableStreak'),
        isFalse,
      );
    }, skip: !sqliteAvailable);

    test(
      'R1c: at the unreadable cap a final scanning read defers as scan',
      () async {
        final serverId = await commitRunOne();
        await seedNavis('libraryScanUnreadableStreak', '2');
        listAlbums(9);
        scanScript(<Object?>[
          idle(8),
          const SubsonicConnectionException('x'),
          busy,
        ]);

        await runPlan();

        await expectCommittedCatalogKept(serverId);
        expect(
          await ledgerReasons(serverId),
          contains('scanChangedDuringCollection'),
        );
      },
      skip: !sqliteAvailable,
    );

    test('R2: scan deferrals do not release an unreadable status', () async {
      final serverId = await commitRunOne();
      await seedNavis('libraryScanDeferralStreak', '2');
      listAlbums(9);
      scanScript(<Object?>[idle(8), const SubsonicConnectionException('x')]);

      await runPlan();

      await expectCommittedCatalogKept(serverId);
      expect(await ledgerReasons(serverId), contains('scanStatusUnreadable'));
      expect((await navisCaps())['libraryScanDeferralStreak'], '2');
    }, skip: !sqliteAvailable);

    test(
      'R3: a settled server does not release a promotion collected mid-scan',
      () async {
        final serverId = await commitRunOne();
        await seedNavis('libraryScanDeferralStreak', '2');
        listAlbums(9);
        scanScript(<Object?>[busy, busy, idle(8)]);

        await runPlan();

        await expectCommittedCatalogKept(serverId);
        final reasons = await ledgerReasons(serverId);
        expect(reasons, contains('scanChangedDuringCollection'));
        expect(reasons, isNot(contains('scanChurnCapRelease')));
      },
      skip: !sqliteAvailable,
    );

    test('G1: a tokenless idle server still promotes', () async {
      const tokenless = ScanStatus(scanning: false, count: 10);
      await commitRunOne(reads: <Object?>[tokenless]);
      listAlbums(9);
      scanScript(<Object?>[tokenless]);

      final state = await runPlan();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.select(database.albumsTable).get(), hasLength(9));
    }, skip: !sqliteAvailable);

    test(
      'G2: with no committed rows a scan at both observations still promotes',
      () async {
        scanScript(<Object?>[busy]);
        listAlbums(10);
        await saveSession();

        final state = await runPlan();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          await database.select(database.albumsTable).get(),
          hasLength(10),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'G3: a never-supported endpoint promotes and records unsupported',
      () async {
        final serverId = await commitRunOne(reads: <Object?>[null]);
        listAlbums(9);
        scanScript(<Object?>[null]);

        final state = await runPlan();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(await database.select(database.albumsTable).get(), hasLength(9));
        expect(
          (await database.librarySyncDao.getScanObservation(serverId))!
              .scanSupported,
          isFalse,
        );
      },
      skip: !sqliteAvailable,
    );
  });
}
