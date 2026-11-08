import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

/// Pins what a scan-triggered `catalogSnapshot` does to an existing library:
/// the coordinator queues it whenever a completed scan is unreconciled, so tag
/// changes and removals must land through it without Repair Library.
void main() {
  late NavisDatabase database;
  late ServerConfigRepository repository;
  late FakeLibrarySyncApi api;
  late DriftLibrarySyncEngine engine;
  late int serverId;

  final scan1 = DateTime.utc(2026, 11, 7, 4);
  final scan2 = DateTime.utc(2026, 11, 7, 12);

  Album albumRow(String id, String artist, int songCount) => Album(
    id: id,
    name: 'Album $id',
    artist: 'Artist $artist',
    artistId: 'artist-$artist',
    songCount: songCount,
  );

  Song song(
    String id,
    String albumId, {
    String? title,
    String artist = '1',
    double? trackGain,
    List<String> genres = const [],
    int track = 1,
  }) => Song(
    id: id,
    title: title ?? 'Song $id',
    albumId: albumId,
    artistId: 'artist-$artist',
    artist: 'Artist $artist',
    track: track,
    genres: genres,
    replayGain: trackGain == null ? null : ReplayGain(trackGain: trackGain),
  );

  /// Twelve single-song albums by two artists: enough for the bulk song path.
  List<Song> baseSongs() => [
    for (var n = 1; n <= 12; n++) song('s$n', 'a$n', trackGain: -6.0 - n),
    song('s5b', 'a5', track: 2),
    song('s2b', 'a2', track: 2),
  ];

  void serve(List<Song> songs, List<Album> albums, DateTime scan) {
    api.bulkSongPages
      ..clear()
      ..[0] = songs;
    api.fastPathPages
      ..clear()
      ..[0] = albums;
    api.scanStatus = ScanStatus(scanning: false, count: 12, lastScan: scan);
  }

  List<Album> baseAlbums() => [
    for (var n = 1; n <= 12; n++)
      albumRow('a$n', '1', n == 5 || n == 2 ? 2 : 1),
  ];

  Future<Map<String, SongsTableData>> songsById() async => {
    for (final row in await database.select(database.songsTable).get())
      row.id: row,
  };

  /// The plan of the dialog's explicit confirmation: a full repair that
  /// carries what the dialog showed (the server, the held generation, item
  /// count and removal set); each can be overridden to model a stale dialog.
  Future<SyncExecutionPlan> confirmPlan({
    int? count,
    int? generation,
    int? server,
    String? fingerprint,
  }) async {
    final state = await database.librarySyncDao.getOrCreateState(serverId);
    return syncPlanForTest(
      LibrarySyncPlanKind.fullRepair,
      confirms: HeldDeletionConfirmation(
        serverId: server ?? serverId,
        generation: generation ?? state.candidateGeneration!,
        count: count ?? state.deletionCandidateCount,
        fingerprint: fingerprint ?? state.deletionCandidateFingerprint!,
      ),
    );
  }

  setUp(() async {
    database = NavisDatabase(NativeDatabase.memory());
    repository = await seedSyncSession(database);
    serverId = (await repository.getActiveServer())!.id!;
    api = FakeLibrarySyncApi();
    api.artists
      ..add(const Artist(id: 'artist-1', name: 'Artist 1'))
      ..add(const Artist(id: 'artist-2', name: 'Artist 2'));
    engine = serialDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );
    serve(baseSongs(), baseAlbums(), scan1);
    await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );
  });
  tearDown(() => database.close());

  Future<LibrarySyncState> snapshot({bool scanTriggered = false}) =>
      engine.executeSyncPlan(
        syncPlanForTest(
          LibrarySyncPlanKind.catalogSnapshot,
          scanTriggered: scanTriggered,
        ),
      );

  test(
    'E1: a ReplayGain-only change lands and reconciles the new scan',
    () async {
      final before = await songsById();
      expect(before['s1']!.replayGainTrackGain, -7.0);
      final retagged = [
        for (final s in baseSongs())
          s.id == 's1'
              ? s.copyWith(replayGain: const ReplayGain(trackGain: -3.5))
              : s.id == 's4'
              ? s.copyWith(replayGain: const ReplayGain(trackGain: null))
              : s,
      ];
      serve(retagged, baseAlbums(), scan2);

      final state = await snapshot();

      expect(state.status, LibrarySyncStatus.succeeded);
      final after = await songsById();
      expect(after['s1']!.replayGainTrackGain, -3.5);
      expect(after['s4']!.replayGainTrackGain, isNull);
      expect(
        after['s2']!.replayGainTrackGain,
        before['s2']!.replayGainTrackGain,
      );
      expect(after, hasLength(14));
      final observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.reconciledToken, scan2.toIso8601String());
      expect(observation.pendingReconciliation, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test('E2: removals, moves and tag edits reach the library', () async {
    // s2 moves a2 -> a3; s5 is removed from its album; a7 is deleted outright
    // (one album of twelve stays under the large-deletion confirmation);
    // s8 gets a new title and artist; s9 gets a genre.
    final songs = [
      for (final s in baseSongs())
        switch (s.id) {
          's5' || 's7' => null,
          's2' => song('s2', 'a3', trackGain: -8.0, track: 2),
          's8' => song(
            's8',
            'a8',
            title: 'Renamed',
            artist: '2',
            trackGain: -14.0,
          ),
          's9' => song('s9', 'a9', trackGain: -15.0, genres: const ['Jazz']),
          _ => s,
        },
    ].nonNulls.toList();
    final albums = [
      for (final a in baseAlbums())
        switch (a.id) {
          'a7' => null,
          'a2' => a.copyWith(songCount: 1),
          'a3' => a.copyWith(songCount: 2),
          'a5' => a.copyWith(songCount: 1),
          'a8' => albumRow('a8', '2', 1),
          _ => a,
        },
    ].nonNulls.toList();
    serve(songs, albums, scan2);
    // User state on a removed song (s7).
    await (database.update(database.songsTable)
          ..where((t) => t.id.isIn(const ['s7'])))
        .write(SongsTableCompanion(starred: Value(DateTime.utc(2026, 10, 1))));

    final state = await snapshot();
    expect(state.status, LibrarySyncStatus.succeeded);
    final rows = await songsById();
    expect(rows.containsKey('s5'), isFalse);
    // A removed song that owns user state is kept as confirmed missing.
    expect(rows['s7']!.catalogAvailability, 'confirmedMissing');
    expect(rows['s7']!.serverDeletedAt, isNotNull);
    expect(rows['s7']!.albumId, isNull);
    // The moved song keeps its id, so references to it stay valid.
    expect(rows['s2']!.serverDeletedAt, isNull);
    expect(rows['s2']!.albumId, 'a3');
    expect(rows['s8']!.title, 'Renamed');
    expect(rows['s8']!.artistId, 'artist-2');
    expect(rows['s9']!.genres, ['Jazz']);
    final albumIds = {
      for (final row in await database.select(database.albumsTable).get())
        row.id,
    };
    expect(albumIds.contains('a7'), isFalse);
    expect(albumIds.contains('a2'), isTrue);
    expect(albumIds, containsAll(['a1', 'a2', 'a3', 'a8', 'a9']));
  }, skip: !sqliteAvailable);

  test(
    'E3: observeServerScan records the token without a request scope',
    () async {
      expect(SyncRequestScope.current, isNull);
      api.scanStatus = ScanStatus(scanning: false, count: 12, lastScan: scan2);
      api.calls.clear();

      await engine.observeServerScan(serverId);

      expect(api.calls, ['getScanStatus']);
      final observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.observedToken, scan2.toIso8601String());
      expect(observation.pendingReconciliation, isTrue);
      expect(observation.reconciledToken, scan1.toIso8601String());
    },
    skip: !sqliteAvailable,
  );

  test('E3: a running scan records no token and nothing is thrown', () async {
    api.scanStatus = const ScanStatus(scanning: true, count: 12);
    await engine.observeServerScan(serverId);
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.observedToken, scan1.toIso8601String());
  }, skip: !sqliteAvailable);

  test('E3: failures and unsupported servers are swallowed', () async {
    api.onGetScanStatus = () async => throw StateError('network down');
    await engine.observeServerScan(serverId);

    api.onGetScanStatus = null;
    api.scanStatus = null;
    await engine.observeServerScan(serverId);
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    // An already observed server stays as it was; the call never throws.
    expect(observation!.observedToken, scan1.toIso8601String());
  }, skip: !sqliteAvailable);

  test('E4: promotion clears the pending artist walk', () async {
    final config = (await repository.getActiveServer())!;
    final capabilities = jsonDecode(config.capabilitiesJson ?? '{}') as Map;
    final navis = {...(capabilities['navis'] as Map? ?? {})}
      ..['libraryPendingIndexesCursor'] = DateTime.utc(
        2026,
        11,
        1,
      ).toIso8601String()
      ..['libraryPendingIndexesOffset'] = '24'
      ..['libraryPendingIndexesArtistIds'] = jsonEncode(['artist-1']);
    await repository.updateCapabilitiesJson(
      jsonEncode({...capabilities, 'navis': navis}),
    );
    serve(baseSongs(), baseAlbums(), scan2);

    await snapshot();

    final after =
        jsonDecode(
              (await repository.getActiveServer())!.capabilitiesJson!,
            )['navis']
            as Map;
    expect(after['libraryPendingIndexesCursor'], isNull);
    expect(after['libraryPendingIndexesOffset'], isNull);
    expect(after['libraryPendingIndexesArtistIds'], isNull);
  }, skip: !sqliteAvailable);

  test('E5: a large removal holds the whole pass, retag included, for confirmation', () async {
    // Two of twelve albums disappear (over 10%) while s1 is retagged.
    final songs = [
      for (final s in baseSongs())
        if (s.albumId != 'a7' && s.albumId != 'a8')
          s.id == 's1'
              ? s.copyWith(replayGain: const ReplayGain(trackGain: -3.5))
              : s,
    ];
    final albums = [
      for (final a in baseAlbums())
        if (a.id != 'a7' && a.id != 'a8') a,
    ];
    serve(songs, albums, scan2);

    final state = await snapshot();

    expect(state.status, isNot(LibrarySyncStatus.failed));
    final syncState = await database.librarySyncDao.getOrCreateState(serverId);
    expect(syncState.candidateStatus, 'awaitingDeletionConfirmation');
    final rows = await songsById();
    expect(rows.containsKey('s7'), isTrue);
    expect(rows['s1']!.replayGainTrackGain, -7.0);
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.reconciledToken, scan1.toIso8601String());
    expect(observation.pendingReconciliation, isTrue);
  }, skip: !sqliteAvailable);

  List<Song> withGain(double gain) => [
    for (final s in baseSongs())
      s.id == 's1' ? s.copyWith(replayGain: ReplayGain(trackGain: gain)) : s,
  ];

  test('W1: a candidate collected under an older scan is not resumed', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    // Run 1 collects under scan2; the server rescans (scan3) before promotion.
    serve(withGain(-3.5), baseAlbums(), scan3);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan2),
    );
    await snapshot(scanTriggered: true);
    var state = await database.librarySyncDao.getOrCreateState(serverId);
    expect(state.candidateStatus, 'collecting');
    expect((await songsById())['s1']!.replayGainTrackGain, -7.0);

    // The retag finished during that scan and the server is quiet at scan3.
    serve(withGain(-1.0), baseAlbums(), scan3);
    api.calls.clear();
    await snapshot(scanTriggered: true);

    expect((await songsById())['s1']!.replayGainTrackGain, -1.0);
    expect(
      api.calls.where((call) => call.startsWith('searchSongsPage')),
      isNotEmpty,
      reason: 'the song pages are collected again',
    );
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.reconciledToken, scan3.toIso8601String());
    expect(observation.pendingReconciliation, isFalse);
  }, skip: !sqliteAvailable);

  test('W1: a cap-release promotion never reconciles a newer scan', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    final server = (await repository.getActiveServer())!;
    final capabilities = jsonDecode(server.capabilitiesJson ?? '{}') as Map;
    await repository.updateCapabilitiesJson(
      jsonEncode({
        ...capabilities,
        'navis': {
          ...(capabilities['navis'] as Map? ?? {}),
          'libraryScanDeferralStreak': '2',
        },
      }),
    );
    serve(withGain(-3.5), baseAlbums(), scan3);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan2),
    );

    await snapshot(scanTriggered: true);

    // The cap released a promotion of the data collected in this run...
    expect((await songsById())['s1']!.replayGainTrackGain, -3.5);
    // ...but only the scan it was collected under may be reconciled, and the
    // newer scan stays pending for the next pass.
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.reconciledToken, isNot(scan3.toIso8601String()));
    expect(observation.pendingReconciliation, isTrue);
  }, skip: !sqliteAvailable);

  test(
    'W4: a scan-triggered promotion that waits is reported as deferred',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      serve(withGain(-3.5), baseAlbums(), scan3);
      api.scanStatusQueue.add(
        ScanStatus(scanning: false, count: 12, lastScan: scan2),
      );

      final state = await snapshot(scanTriggered: true);

      expect(state.status, LibrarySyncStatus.deferred);
      expect(state.failureCategory, 'scanChanged');
      expect(state.candidateStatus, 'collecting');
    },
    skip: !sqliteAvailable,
  );

  test('W4: a repair that waits keeps reporting success', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    serve(withGain(-3.5), baseAlbums(), scan3);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan2),
    );

    final state = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );

    expect(state.status, LibrarySyncStatus.succeeded);
  }, skip: !sqliteAvailable);

  group('W5 cover art revisions', () {
    Future<Map<String, int?>> revisions() async => {
      for (final entry in (await songsById()).entries)
        entry.key: entry.value.coverArtRevision,
    };

    test(
      'a ReplayGain or play-count change leaves the revision alone',
      () async {
        final before = await revisions();
        serve(
          [
            for (final s in baseSongs())
              s.id == 's1'
                  ? s.copyWith(
                      replayGain: const ReplayGain(trackGain: -3.5),
                      playCount: 42,
                    )
                  : s,
          ],
          baseAlbums(),
          scan2,
        );

        await snapshot(scanTriggered: true);

        expect((await songsById())['s1']!.replayGainTrackGain, -3.5);
        expect(await revisions(), before);
      },
      skip: !sqliteAvailable,
    );

    test('a changed coverArt id bumps only that song', () async {
      final before = await revisions();
      serve(
        [
          for (final s in baseSongs())
            s.id == 's2' ? s.copyWith(coverArt: 'cover-new') : s,
        ],
        baseAlbums(),
        scan2,
      );

      await snapshot(scanTriggered: true);

      final after = await revisions();
      expect(after['s2'], (before['s2'] ?? 0) + 1);
      expect(after['s1'], before['s1']);
    }, skip: !sqliteAvailable);

    test('Repair Library still bumps every changed song', () async {
      final before = await revisions();
      serve(withGain(-3.5), baseAlbums(), scan2);

      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      expect((await revisions())['s1'], (before['s1'] ?? 0) + 1);
    }, skip: !sqliteAvailable);
  });

  test(
    'observeServerScan on an idle engine clears an earlier cancel',
    () async {
      engine.cancelSync();
      api.scanStatus = ScanStatus(scanning: false, count: 12, lastScan: scan2);
      await engine.observeServerScan(serverId);
      expect(api.activeRequestsCancelled, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'W2: the engine stops a scan-triggered snapshot on metered data',
    () async {
      // "Unmetered only" is off, so plain admission allows the pass; the
      // scan-triggered snapshot still needs the one-time broad grant.
      final metered = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.cellular,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: true,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        fallbackArtistConcurrency: 1,
        writeChunkSize: 4,
      );
      serve(withGain(-3.5), baseAlbums(), scan2);
      api.calls.clear();

      final stopped = await metered.executeSyncPlan(
        syncPlanForTest(
          LibrarySyncPlanKind.catalogSnapshot,
          scanTriggered: true,
          networkType: NetworkType.cellular,
        ),
      );

      expect(stopped.status, LibrarySyncStatus.deferred);
      expect(
        api.calls.where((call) => call.startsWith('searchSongsPage')),
        isEmpty,
      );
      expect((await songsById())['s1']!.replayGainTrackGain, -7.0);

      final granted = await metered.executeSyncPlan(
        syncPlanForTest(
          LibrarySyncPlanKind.catalogSnapshot,
          scanTriggered: true,
          grant: SyncNetworkGrant.broadMeteredOnce,
          networkType: NetworkType.cellular,
        ),
      );
      expect(granted.status, isNot(LibrarySyncStatus.deferred));
      expect((await songsById())['s1']!.replayGainTrackGain, -3.5);
    },
    skip: !sqliteAvailable,
  );

  /// A run collects under [collected], then the server reports [now]: a
  /// different scan defers the promotion and leaves the candidate behind.
  Future<void> deferredSnapshot(
    List<Song> songs, {
    required DateTime collected,
    required DateTime now,
  }) async {
    serve(songs, baseAlbums(), now);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: collected),
    );
    await snapshot(scanTriggered: true);
  }

  test(
    'W1: a deferred candidate resumes only while the scan is unchanged',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);
      final waiting = await database.librarySyncDao.getOrCreateState(serverId);
      expect(waiting.candidateStatus, 'collecting');

      // The server is back at the scan the candidate was collected under:
      // its completed newest-feed work is kept, not fetched again.
      serve(withGain(-3.5), baseAlbums(), scan2);
      api.calls.clear();
      await snapshot(scanTriggered: true);
      expect(
        api.calls.where((call) => call.startsWith('getAlbumListPage:0:100')),
        isEmpty,
        reason: 'resumed',
      );
      expect((await songsById())['s1']!.replayGainTrackGain, -3.5);

      // Another deferral, then a different scan: everything is collected again.
      final scan4 = DateTime.utc(2026, 11, 7, 14);
      await deferredSnapshot(withGain(-3.0), collected: scan3, now: scan4);
      serve(withGain(-2.0), baseAlbums(), DateTime.utc(2026, 11, 7, 15));
      api.calls.clear();
      await snapshot(scanTriggered: true);
      expect(
        api.calls.where((call) => call.startsWith('getAlbumListPage:0:100')),
        isNotEmpty,
        reason: 'collected again',
      );
      expect((await songsById())['s1']!.replayGainTrackGain, -2.0);
    },
    skip: !sqliteAvailable,
  );

  List<Song> removalSongs() => [
    for (final s in withGain(-3.5))
      if (s.albumId != 'a7' && s.albumId != 'a8') s,
  ];
  List<Album> removalAlbums() => [
    for (final a in baseAlbums())
      if (a.id != 'a7' && a.id != 'a8') a,
  ];

  test('X1: a held deletion is confirmed even after a new scan', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );

    // A quiet watcher scan completes before the user presses Repair Library.
    serve(removalSongs(), removalAlbums(), scan3);
    await engine.executeSyncPlan(await confirmPlan());

    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      isNull,
    );
    final rows = await songsById();
    expect(rows.containsKey('s7'), isFalse);
    expect(rows['s1']!.replayGainTrackGain, -3.5);
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.reconciledToken, scan3.toIso8601String());
  }, skip: !sqliteAvailable);

  test('R3: a held deletion is confirmed after a scan that changed the newest albums', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );
    // The new scan also added an album at the top of the feed.
    serve(
      [...removalSongs(), song('s99', 'a99')],
      [albumRow('a99', '1', 1), ...removalAlbums()],
      scan3,
    );
    await engine.executeSyncPlan(await confirmPlan());
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      isNull,
    );
    expect((await songsById()).containsKey('s7'), isFalse);
  }, skip: !sqliteAvailable);

  test('V4: a scan that is still running is a known, different scan', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);
    serve(withGain(-2.0), baseAlbums(), scan3);
    api.onGetScanStatus = () async => ScanStatus(scanning: true, count: 12);
    api.calls.clear();
    await snapshot(scanTriggered: true);
    api.onGetScanStatus = null;
    // The deferral proved scan3 landed after the scan2 pages: they are not
    // reused, and the newest data is what gets promoted.
    expect(
      api.calls.where((c) => c.startsWith('getAlbumListPage:0:100')),
      isNotEmpty,
      reason: 'collected again',
    );
    expect((await songsById())['s1']!.replayGainTrackGain, -2.0);
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.pendingReconciliation, isTrue);
  }, skip: !sqliteAvailable);

  test('V1: a scan that lands during the confirming run keeps the confirmation', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    final scan4 = DateTime.utc(2026, 11, 7, 14);
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );

    // The confirming press collects under scan3; scan4 lands before promotion.
    serve(removalSongs(), removalAlbums(), scan4);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan3),
    );
    final press = await engine.executeSyncPlan(await confirmPlan());
    expect(press.status, LibrarySyncStatus.deferred, reason: 'not a success');
    expect(press.candidateStatus, 'awaitingDeletionConfirmation');
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );
    expect((await songsById()).containsKey('s7'), isTrue);

    // The server is quiet again: the retry confirms without a second hold.
    serve(removalSongs(), removalAlbums(), scan4);
    final retry = await engine.executeSyncPlan(await confirmPlan());
    expect(retry.status, LibrarySyncStatus.succeeded);
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      isNull,
    );
    expect((await songsById()).containsKey('s7'), isFalse);
  }, skip: !sqliteAvailable);

  test('X6: a failed status read keeps a resumable candidate', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);

    api.onGetScanStatus = () async =>
        throw const SubsonicConnectionException('status unavailable');
    api.calls.clear();
    await snapshot(scanTriggered: true);
    api.onGetScanStatus = null;

    expect(
      api.calls.where((call) => call.startsWith('getAlbumListPage:0:100')),
      isEmpty,
      reason: 'the candidate resumed',
    );
    expect((await songsById())['s1']!.replayGainTrackGain, -3.5);
    // Only the scan the pages were collected under may be reconciled.
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.reconciledToken, isNot(scan3.toIso8601String()));
    expect(observation.pendingReconciliation, isTrue);
  }, skip: !sqliteAvailable);

  test(
    'R3: a failed status read still reconciles the collection scan',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);
      // The server is observed at scan2 again (e.g. an interrupted pass), then
      // the status read fails on the resume.
      await database.librarySyncDao.recordScanObservation(
        serverId: serverId,
        scanInProgress: false,
        supported: true,
        providerScanToken: scan2.toIso8601String(),
      );
      api.onGetScanStatus = () async =>
          throw const SubsonicConnectionException('status unavailable');
      await snapshot(scanTriggered: true);
      api.onGetScanStatus = null;
      expect((await songsById())['s1']!.replayGainTrackGain, -3.5);
      final observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.reconciledToken, scan2.toIso8601String());
      expect(observation.pendingReconciliation, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'R3: an expired candidate with an unknown scan reconciles nothing',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);
      await database.librarySyncDao.recordScanObservation(
        serverId: serverId,
        scanInProgress: false,
        supported: true,
        providerScanToken: scan2.toIso8601String(),
      );
      // The candidate is older than the 24 h resume window: it collects afresh.
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          candidateStartedAt: Value(
            DateTime.now().subtract(const Duration(hours: 30)),
          ),
        ),
      );
      api.onGetScanStatus = () async =>
          throw const SubsonicConnectionException('status unavailable');
      await snapshot(scanTriggered: true);
      api.onGetScanStatus = null;
      final observation = await database.librarySyncDao.getScanObservation(
        serverId,
      );
      expect(observation!.reconciledToken, isNot(scan2.toIso8601String()));
      expect(observation.pendingReconciliation, isTrue);
    },
    skip: !sqliteAvailable,
  );

  test(
    'X8: a candidate that cannot resume costs no boundary requests',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      await deferredSnapshot(withGain(-3.5), collected: scan2, now: scan3);

      serve(withGain(-2.0), baseAlbums(), scan3);
      api.calls.clear();
      await snapshot(scanTriggered: true);

      // One page fetch to collect again; a boundary check would add a second.
      expect(
        api.calls.where((call) => call.startsWith('getAlbumListPage:0:500')),
        hasLength(1),
      );
    },
    skip: !sqliteAvailable,
  );

  test('X3: a waiting scan-triggered promotion is not a repair hint', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    serve(withGain(-3.5), baseAlbums(), scan3);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan2),
    );
    final state = await snapshot(scanTriggered: true);
    expect(state.freshness, LibrarySyncFreshness.verificationPending);

    serve(withGain(-3.5), baseAlbums(), scan3);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan2),
    );
    final repair = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );
    expect(repair.freshness, LibrarySyncFreshness.repairRecommended);
  }, skip: !sqliteAvailable);

  test('X3: a snapshot leaves album and artist covers alone and a new song unbumped', () async {
    Future<Map<String, int?>> albumRevisions() async => {
      for (final row in await database.select(database.albumsTable).get())
        row.id: row.coverArtRevision,
    };
    Future<Map<String, int?>> artistRevisions() async => {
      for (final row in await database.select(database.artistsTable).get())
        row.id: row.coverArtRevision,
    };
    final albumsBefore = await albumRevisions();
    final artistsBefore = await artistRevisions();
    final renamed = [
      for (final a in baseAlbums())
        a.id == 'a1' ? a.copyWith(name: 'Album a1 renamed') : a,
      albumRow('a13', '1', 1),
    ];
    api.artists
      ..clear()
      ..add(const Artist(id: 'artist-1', name: 'Artist 1 renamed'))
      ..add(const Artist(id: 'artist-2', name: 'Artist 2'));
    serve(
      [...withGain(-3.5), song('s13', 'a13').copyWith(coverArt: 'cover-13')],
      renamed,
      scan2,
    );

    await snapshot(scanTriggered: true);

    expect((await albumRevisions())['a1'], albumsBefore['a1']);
    expect((await artistRevisions())['artist-1'], artistsBefore['artist-1']);
    expect((await songsById())['s13']!.coverArtRevision, isNull);
    expect(
      (await database.select(database.albumsTable).get())
          .firstWhere((a) => a.id == 'a1')
          .name,
      'Album a1 renamed',
    );

    // Repair Library keeps refetching changed albums and artists.
    api.artists
      ..clear()
      ..add(const Artist(id: 'artist-1', name: 'Artist 1 again'))
      ..add(const Artist(id: 'artist-2', name: 'Artist 2'));
    serve(
      [...withGain(-3.5), song('s13', 'a13')],
      [
        for (final a in renamed)
          a.id == 'a1' ? a.copyWith(name: 'Album a1 again') : a,
      ],
      scan2,
    );
    await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );
    expect((await albumRevisions())['a1'], (albumsBefore['a1'] ?? 0) + 1);
    expect(
      (await artistRevisions())['artist-1'],
      (artistsBefore['artist-1'] ?? 0) + 1,
    );
  }, skip: !sqliteAvailable);

  test(
    'X1: a re-held candidate remembers the scan it was collected under',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      serve(removalSongs(), removalAlbums(), scan2);
      await snapshot(scanTriggered: true);

      // A different removal after a new scan is a new observation: it is held
      // again, and its pages belong to the new scan.
      serve(
        [
          for (final s in withGain(-3.5))
            if (s.albumId != 'a6' && s.albumId != 'a9') s,
        ],
        [
          for (final a in baseAlbums())
            if (a.id != 'a6' && a.id != 'a9') a,
        ],
        scan3,
      );
      await engine.executeSyncPlan(await confirmPlan());

      final state = await database.librarySyncDao.getOrCreateState(serverId);
      expect(state.candidateStatus, 'awaitingDeletionConfirmation');
      final capabilities =
          jsonDecode(
                (await repository.getActiveServer())!.capabilitiesJson!,
              )['navis']
              as Map;
      expect(
        capabilities['libraryCandidateScanToken'],
        scan3.toIso8601String(),
      );
    },
    skip: !sqliteAvailable,
  );

  Future<LibrarySyncState> confirmingPressThatWaits() async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    final scan4 = DateTime.utc(2026, 11, 7, 14);
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    serve(removalSongs(), removalAlbums(), scan4);
    api.scanStatusQueue.add(
      ScanStatus(scanning: false, count: 12, lastScan: scan3),
    );
    final press = await engine.executeSyncPlan(await confirmPlan());
    expect(press.status, LibrarySyncStatus.deferred);
    return press;
  }

  /// Makes the hold look [age] old: its start moves back and the stored
  /// fingerprint (which pins generation, start second and the removed ids) is
  /// recomputed for that start, as if the hold had been written then.
  Future<void> ageHold(Duration age) async {
    final state = await database.librarySyncDao.getOrCreateState(serverId);
    final start = DateTime.now().subtract(age);
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              state.candidateGeneration,
              start.millisecondsSinceEpoch ~/ 1000,
              <String>[],
              ['a7', 'a8'],
              ['s7', 's8'],
            ]),
          ),
        )
        .toString();
    await database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        candidateStartedAt: Value(start),
        deletionCandidateFingerprint: Value(fingerprint),
      ),
    );
  }

  test(
    'Y1: a deferred confirmation applies even when the retry comes after 24 h',
    () async {
      await confirmingPressThatWaits();
      await ageHold(const Duration(hours: 25));

      final scan4 = DateTime.utc(2026, 11, 7, 14);
      serve(removalSongs(), removalAlbums(), scan4);
      await engine.executeSyncPlan(await confirmPlan());

      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        isNull,
      );
      expect((await songsById()).containsKey('s7'), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'Y1: a retry after 24 h whose removal set changed still holds',
    () async {
      await confirmingPressThatWaits();
      await ageHold(const Duration(hours: 25));

      final scan4 = DateTime.utc(2026, 11, 7, 14);
      serve(
        [
          for (final s in removalSongs())
            if (s.albumId != 'a9') s,
        ],
        [
          for (final a in removalAlbums())
            if (a.id != 'a9') a,
        ],
        scan4,
      );
      await engine.executeSyncPlan(await confirmPlan());

      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        'awaitingDeletionConfirmation',
      );
      final rows = await songsById();
      expect(rows.containsKey('s7'), isTrue);
      expect(rows.containsKey('s9'), isTrue);
    },
    skip: !sqliteAvailable,
  );

  test('Y3: a confirming run that failed keeps the confirmation through a new scan', () async {
    final scan3 = DateTime.utc(2026, 11, 7, 13);
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);

    api.throwOnFastPath = const SubsonicConnectionException('connection drop');
    await engine.executeSyncPlan(await confirmPlan());
    api.throwOnFastPath = null;
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
      reason: 'the failed press leaves the hold visible',
    );

    serve(removalSongs(), removalAlbums(), scan3);
    await engine.executeSyncPlan(await confirmPlan());
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      isNull,
    );
    expect((await songsById()).containsKey('s7'), isFalse);
  }, skip: !sqliteAvailable);

  test(
    'Y4: a deletion that no longer applies is not restored as a hold',
    () async {
      final scan3 = DateTime.utc(2026, 11, 7, 13);
      final scan4 = DateTime.utc(2026, 11, 7, 14);
      serve(removalSongs(), removalAlbums(), scan2);
      await snapshot(scanTriggered: true);
      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .deletionCandidateCount,
        greaterThan(0),
      );

      // The removed albums came back; a scan lands during the press.
      serve(withGain(-3.5), baseAlbums(), scan4);
      api.scanStatusQueue.add(
        ScanStatus(scanning: false, count: 12, lastScan: scan3),
      );
      await engine.executeSyncPlan(await confirmPlan());

      final state = await database.librarySyncDao.getOrCreateState(serverId);
      expect(state.candidateStatus, isNot('awaitingDeletionConfirmation'));
      expect(state.deletionCandidateCount, 0);
      expect(state.deletionCandidateFingerprint, isNull);
    },
    skip: !sqliteAvailable,
  );

  Future<void> expectStillHeld() async {
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );
    final rows = await songsById();
    expect(rows.containsKey('s7'), isTrue, reason: 'nothing was deleted');
    expect(rows.containsKey('s8'), isTrue);
  }

  for (final age in [const Duration(hours: 2), const Duration(days: 30)]) {
    test(
      'Z1: a scan snapshot never applies a held deletion (hold aged $age)',
      () async {
        serve(removalSongs(), removalAlbums(), scan2);
        await snapshot(scanTriggered: true);
        await ageHold(age);
        final agedFingerprint = (await database.librarySyncDao.getOrCreateState(
          serverId,
        )).deletionCandidateFingerprint;

        serve(removalSongs(), removalAlbums(), DateTime.utc(2026, 11, 7, 13));
        await snapshot(scanTriggered: true);

        await expectStillHeld();
        // Inside the 24 h window the hold resumes with its start time; past it
        // a run that carries no confirmation starts a new candidate (the
        // fingerprint pins the start), and the dialog asks again.
        final after = (await database.librarySyncDao.getOrCreateState(serverId))
            .deletionCandidateFingerprint;
        expect(after == agedFingerprint, age < const Duration(hours: 24));
      },
      skip: !sqliteAvailable,
    );
  }

  test('Z1: Force rescan (a repair with no confirmation) never applies a held deletion', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    await ageHold(const Duration(days: 30));

    serve(removalSongs(), removalAlbums(), scan2);
    await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );

    await expectStillHeld();
  }, skip: !sqliteAvailable);

  test(
    'Z1: the dialog confirmation applies the held deletion, at any age',
    () async {
      serve(removalSongs(), removalAlbums(), scan2);
      await snapshot(scanTriggered: true);
      await ageHold(const Duration(days: 30));

      serve(removalSongs(), removalAlbums(), scan2);
      await engine.executeSyncPlan(await confirmPlan());

      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .candidateStatus,
        isNull,
      );
      expect((await songsById()).containsKey('s7'), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'Z1: a confirmation of another count or generation holds again',
    () async {
      serve(removalSongs(), removalAlbums(), scan2);
      await snapshot(scanTriggered: true);
      final held = await database.librarySyncDao.getOrCreateState(serverId);

      await engine.executeSyncPlan(
        await confirmPlan(count: held.deletionCandidateCount + 1),
      );
      await expectStillHeld();

      await engine.executeSyncPlan(
        await confirmPlan(generation: held.candidateGeneration! + 1),
      );
      await expectStillHeld();
    },
    skip: !sqliteAvailable,
  );

  List<Song> otherRemovalSongs() => [
    for (final s in withGain(-3.5))
      if (s.albumId != 'a9' && s.albumId != 'a10') s,
  ];
  List<Album> otherRemovalAlbums() => [
    for (final a in baseAlbums())
      if (a.id != 'a9' && a.id != 'a10') a,
  ];

  test('F1: a stale dialog (same generation and count, another removal set) holds again', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    final shown = await database.librarySyncDao.getOrCreateState(serverId);
    // The dialog opens here and captures what it shows.
    final dialog = await confirmPlan();

    // Within 24 h a plain run finds the server now lacks a9 and a10 instead:
    // the same generation and item count, a different set.
    serve(
      otherRemovalSongs(),
      otherRemovalAlbums(),
      DateTime.utc(2026, 11, 7, 13),
    );
    await snapshot(scanTriggered: true);
    final reheld = await database.librarySyncDao.getOrCreateState(serverId);
    expect(reheld.candidateGeneration, shown.candidateGeneration);
    expect(reheld.deletionCandidateCount, shown.deletionCandidateCount);
    expect(
      reheld.deletionCandidateFingerprint,
      isNot(shown.deletionCandidateFingerprint),
    );

    await engine.executeSyncPlan(dialog);

    final rows = await songsById();
    expect(rows.containsKey('s9'), isTrue, reason: 'the unseen set survives');
    expect(rows.containsKey('s10'), isTrue);
    expect(rows.containsKey('s7'), isTrue);
    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      'awaitingDeletionConfirmation',
    );
  }, skip: !sqliteAvailable);

  test('F1: a confirmation of another server holds again', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);

    await engine.executeSyncPlan(await confirmPlan(server: serverId + 1));

    await expectStillHeld();
  }, skip: !sqliteAvailable);

  test('F3: a confirmation survives the coordinator\'s metered-grant rebuild and applies', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    final request = LibrarySyncRequest(
      origin: SyncRunOrigin.settingsRepair,
      intent: SyncRunIntent.repairLibrary,
      confirmsHeldDeletion: (await confirmPlan()).request.confirmsHeldDeletion,
    );
    final sync = AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.cellular,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );

    // The user confirmed the deletion dialog and then the mobile-data dialog:
    // the repair session carries the grant and the coordinator rebuilds the
    // request with it.
    sync.beginRepairSession(serverId: serverId, allowMetered: true);
    await sync.requestSync(request);
    sync.endRepairSession(serverId: serverId);

    expect(
      (await database.librarySyncDao.getOrCreateState(serverId))
          .candidateStatus,
      isNull,
    );
    expect((await songsById()).containsKey('s7'), isFalse);
  }, skip: !sqliteAvailable);

  test(
    'G1: the coordinator result after a hold lets the dialog confirm it',
    () async {
      final sync = AdaptiveLibrarySyncCoordinator(
        executor: engine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
      );
      serve(removalSongs(), removalAlbums(), scan2);
      await snapshot(scanTriggered: true);
      // A plain Force rescan re-holds; its result is what the controller shows.
      final shown = await sync.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      final stored = await database.librarySyncDao.getOrCreateState(serverId);
      expect(shown.candidateStatus, 'awaitingDeletionConfirmation');
      final confirmation = shown.heldDeletionConfirmation(serverId);
      expect(
        confirmation,
        isNotNull,
        reason: 'the dialog must be able to confirm',
      );
      expect(confirmation!.fingerprint, stored.deletionCandidateFingerprint);
      // The press built from that result applies the shown set.
      await sync.requestSync(
        LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
          confirmsHeldDeletion: confirmation,
        ),
      );
      expect((await songsById()).containsKey('s7'), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test('Z1: a confirmation on anything but a full repair is ignored', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    final held = await database.librarySyncDao.getOrCreateState(serverId);

    await engine.executeSyncPlan(
      syncPlanForTest(
        LibrarySyncPlanKind.catalogSnapshot,
        scanTriggered: true,
        confirms: HeldDeletionConfirmation(
          serverId: serverId,
          generation: held.candidateGeneration!,
          count: held.deletionCandidateCount,
          fingerprint: held.deletionCandidateFingerprint!,
        ),
      ),
    );

    await expectStillHeld();
  }, skip: !sqliteAvailable);

  test('Z1: an aged held candidate that a plain run abandons leaves no phantom hold', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    await ageHold(const Duration(days: 30));

    api.throwOnFastPath = Exception('server down');
    await snapshot(scanTriggered: true);
    api.throwOnFastPath = null;

    final state = await database.librarySyncDao.getOrCreateState(serverId);
    expect(state.candidateStatus, isNot('awaitingDeletionConfirmation'));
  }, skip: !sqliteAvailable);

  test('Z3: a Discard during a confirming run is not overridden', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    final held = await database.librarySyncDao.getOrCreateState(serverId);
    final plan = await confirmPlan();
    final gate = Completer<void>();
    api.pageGates[0] = gate;
    api.calls.clear();
    final run = engine.executeSyncPlan(plan);
    for (
      var n = 0;
      n < 500 && !api.calls.any((c) => c.startsWith('getAlbumListPage:0'));
      n++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    // The user declines while the run is collecting.
    final discarded = await database.librarySyncDao
        .discardAwaitingRepairCandidate(
          serverId: serverId,
          generation: held.candidateGeneration!,
        );
    gate.complete();
    await run;
    api.pageGates.clear();

    expect(discarded, isTrue);
    expect((await songsById()).containsKey('s7'), isTrue);
    final after = await database.librarySyncDao.getOrCreateState(serverId);
    expect(after.candidateStatus, isNull);
    expect(after.candidateGeneration, isNull);
  }, skip: !sqliteAvailable);

  test('Z5: a confirming run protects local ratings made since the run began, not since the hold', () async {
    serve(removalSongs(), removalAlbums(), scan2);
    await snapshot(scanTriggered: true);
    await ageHold(const Duration(days: 30));
    // A rating the user set 10 days ago and that already reached the server
    // value must not still shield the song from the fresh server data.
    await database
        .into(database.librarySyncLocalMutationsTable)
        .insert(
          LibrarySyncLocalMutationsTableCompanion.insert(
            entityType: 'song',
            entityId: 's1',
            operation: 'rating',
            createdAt: DateTime.now().subtract(const Duration(days: 10)),
          ),
        );
    final server = [
      for (final s in removalSongs())
        s.id == 's1' ? s.copyWith(userRating: 5) : s,
    ];
    serve(server, removalAlbums(), scan2);

    await engine.executeSyncPlan(await confirmPlan());

    expect((await songsById())['s1']!.userRating, 5);
  }, skip: !sqliteAvailable);

  test(
    'Z6: a hold caused by songs alone (more than 500) is confirmed too',
    () async {
      List<Song> big() => [
        ...baseSongs(),
        for (var n = 0; n < 600; n++) song('big$n', 'a1', track: 10 + n),
      ];
      List<Album> albums(int a1Songs) => [
        albumRow('a1', '1', a1Songs),
        for (final a in baseAlbums().skip(1)) a,
      ];
      serve(big(), albums(601), scan2);
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect((await songsById()).containsKey('big599'), isTrue);

      final scan3 = DateTime.utc(2026, 11, 7, 13);
      serve(baseSongs(), albums(1), scan3);
      await snapshot(scanTriggered: true);
      final held = await database.librarySyncDao.getOrCreateState(serverId);
      expect(held.candidateStatus, 'awaitingDeletionConfirmation');
      expect(held.deletionCandidateCount, 600);
      expect((await songsById()).containsKey('big599'), isTrue);

      await engine.executeSyncPlan(await confirmPlan());
      expect((await songsById()).containsKey('big599'), isFalse);
    },
    skip: !sqliteAvailable,
  );
}
