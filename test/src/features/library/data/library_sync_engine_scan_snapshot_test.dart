import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

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

  Future<LibrarySyncState> snapshot() => engine.executeSyncPlan(
    syncPlanForTest(LibrarySyncPlanKind.catalogSnapshot),
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

      await engine.observeServerScan();

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
    await engine.observeServerScan();
    final observation = await database.librarySyncDao.getScanObservation(
      serverId,
    );
    expect(observation!.observedToken, scan1.toIso8601String());
  }, skip: !sqliteAvailable);

  test('E3: failures and unsupported servers are swallowed', () async {
    api.onGetScanStatus = () async => throw StateError('network down');
    await engine.observeServerScan();

    api.onGetScanStatus = null;
    api.scanStatus = null;
    await engine.observeServerScan();
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
}
