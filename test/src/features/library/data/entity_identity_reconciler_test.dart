import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/entity_identity_reconciler.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  Future<int> saveServer() async {
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    final server = await database.serverDao.getActiveServer();
    return server!.id;
  }

  setUp(() {
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> seedProvisionalAlbum(
    String id, {
    String? name = 'Album',
    String? artistId,
    String? artistName,
    String? releaseMbid,
    DateTime? starred,
    int? userRating,
    int? songCount,
    int? year,
  }) async {
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: id,
        name: name!,
        artistId: Value(artistId),
        artistName: Value(artistName),
        releaseMbid: Value(releaseMbid),
        songCount: Value(songCount),
        year: Value(year),
        starred: Value(starred),
        userRating: Value(userRating),
      ),
    ]);
  }

  Future<void> seedProvisionalArtist(
    String id, {
    String name = 'Artist',
    String? artistMbid,
    DateTime? starred,
  }) async {
    await database.libraryDao.upsertProvisionalArtists([
      ArtistsTableCompanion.insert(
        id: id,
        name: name,
        artistMbid: Value(artistMbid),
        starred: Value(starred),
      ),
    ]);
  }

  Future<void> seedCandidateAlbum(
    String id, {
    String name = 'Album',
    String? artistId,
    String? artistName,
    String? releaseMbid,
    int? songCount,
    int? year,
    int generation = 1,
  }) async {
    final companion = AlbumsTableCompanion.insert(
      id: id,
      name: name,
      artistId: Value(artistId),
      artistName: Value(artistName),
      releaseMbid: Value(releaseMbid),
      songCount: Value(songCount),
      year: Value(year),
    );
    await database.librarySyncCandidateDao.upsertAlbums(
      serverId: 1,
      generation: generation,
      albums: [companion],
    );
    // Promotion writes the candidate into the committed catalog before the
    // reconciler runs; mirror that so song foreign keys resolve.
    await database.libraryDao.upsertAlbums([companion]);
  }

  Future<void> seedCandidateArtist(
    String id, {
    String name = 'Artist',
    String? artistMbid,
    int generation = 1,
  }) async {
    final companion = ArtistsTableCompanion.insert(
      id: id,
      name: name,
      artistMbid: Value(artistMbid),
    );
    await database.librarySyncCandidateDao.replaceArtists(
      serverId: 1,
      generation: generation,
      artists: [companion],
    );
    await database.libraryDao.upsertArtists([companion]);
  }

  Future<void> seedCanonicalSong(
    String id, {
    required String title,
    String? albumId,
    String? artistId,
    String? recordingMbid,
  }) async {
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: id,
        title: title,
        albumId: Value(albumId),
        artistId: Value(artistId),
        recordingMbid: Value(recordingMbid),
      ),
    ]);
  }

  Future<void> seedProvisionalSong(
    String id, {
    required String title,
    String? albumId,
    String? artistId,
    String? recordingMbid,
  }) async {
    await database.libraryDao.upsertProvisionalSongs([
      SongsTableCompanion.insert(
        id: id,
        title: title,
        albumId: Value(albumId),
        artistId: Value(artistId),
        recordingMbid: Value(recordingMbid),
      ),
    ]);
  }

  for (final artist in [false, true]) {
    test(
      '${artist ? 'artist' : 'album'} MBID matching ignores case and whitespace',
      () async {
        final serverId = await saveServer();
        if (artist) {
          await seedProvisionalArtist('old', artistMbid: '  ARTIST-MBID  ');
          await seedCandidateArtist('new', artistMbid: 'artist-mbid');
        } else {
          await seedProvisionalAlbum('old', releaseMbid: '  RELEASE-MBID  ');
          await seedCandidateAlbum('new', releaseMbid: 'release-mbid');
        }
        final summary = await EntityIdentityReconciler(database).reconcile(
          serverId: serverId,
          generation: 1,
          songAliases: const [],
          provisionalSongs: const [],
        );
        expect(artist ? summary.artistAliases : summary.albumAliases, 1);
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'a unique release MBID on both sides remaps the album and moves its songs',
    () async {
      final serverId = await saveServer();
      final starredAt = DateTime.utc(2026, 9, 1);
      await seedProvisionalAlbum(
        'album-old',
        releaseMbid: 'rel-1',
        starred: starredAt,
      );
      await seedCandidateAlbum('album-new', releaseMbid: 'rel-1');
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-canonical',
          title: 'Track',
          albumId: const Value('album-new'),
        ),
      ]);
      await seedProvisionalSong(
        'song-old',
        title: 'Retained Track',
        albumId: 'album-old',
      );

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: const [],
        provisionalSongs: const [],
      );

      expect(summary.albumAliases, 1);
      expect(summary.albumRestoredLikes, 1);
      expect(await database.libraryDao.getAlbumById('album-old'), isNull);
      final canonical = await database.libraryDao.getAlbumById('album-new');
      expect(canonical!.starred!.isAtSameMomentAs(starredAt), isTrue);
      // The retained song follows its album.
      final song = await database.libraryDao.getSongById('song-old');
      expect(song!.albumId, 'album-new');
      final aliasRows = await database
          .customSelect(
            'SELECT old_id, new_id FROM entity_identity_aliases '
            "WHERE entity_type = 'album';",
          )
          .get();
      expect(aliasRows, hasLength(1));
      expect(aliasRows.single.read<String>('old_id'), 'album-old');
      expect(aliasRows.single.read<String>('new_id'), 'album-new');
      // The restored like is queued for server dispatch.
      final pending = await database.starSyncDao.getPendingActions();
      expect(
        pending.where(
          (action) =>
              action.itemType == 'album' &&
              action.itemId == 'album-new' &&
              action.operation == 'star',
        ),
        isNotEmpty,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'unambiguous song membership with a compatible name remaps the album',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum('album-old');
      await seedCandidateAlbum('album-new', name: 'album');
      await seedCanonicalSong(
        'song-new',
        title: 'Track',
        albumId: 'album-new',
        recordingMbid: 'rec-1',
      );
      await seedProvisionalSong(
        'song-old',
        title: 'Track',
        albumId: 'album-old',
        recordingMbid: 'rec-1',
      );
      final provisionalBefore = await database.songIdentityDao
          .getProvisionalSongs();
      final session = await SongIdentityReconciler(database.songIdentityDao)
          .startSession();
      await session.reconcile([
        (await database.libraryDao.getSongById('song-new'))!,
      ]);
      await session.finalize();
      final aliases = session.summary;

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: aliases.aliases,
        provisionalSongs: provisionalBefore,
      );

      expect(summary.albumAliases, 1);
      expect(await database.libraryDao.getAlbumById('album-old'), isNull);
      expect(await database.libraryDao.getAlbumById('album-new'), isNotNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'conflicting membership targets send the album to review without remapping',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum(
        'album-old',
        name: 'Split',
        starred: DateTime.utc(2026, 9, 4),
      );
      await seedCandidateAlbum('album-target-a', name: 'Split');
      await seedCandidateAlbum('album-target-b', name: 'Split');
      // Two relinked songs of the old album now disagree about the album.
      await seedCanonicalSong(
        'song-a',
        title: 'A',
        albumId: 'album-target-a',
        recordingMbid: 'rec-a',
      );
      await seedCanonicalSong(
        'song-b',
        title: 'B',
        albumId: 'album-target-b',
        recordingMbid: 'rec-b',
      );
      await seedProvisionalSong(
        'song-old-a',
        title: 'A',
        albumId: 'album-old',
        recordingMbid: 'rec-a',
      );
      await seedProvisionalSong(
        'song-old-b',
        title: 'B',
        albumId: 'album-old',
        recordingMbid: 'rec-b',
      );
      final provisionalBefore = await database.songIdentityDao
          .getProvisionalSongs();
      final session = await SongIdentityReconciler(database.songIdentityDao)
          .startSession();
      await session.reconcile([
        (await database.libraryDao.getSongById('song-a'))!,
        (await database.libraryDao.getSongById('song-b'))!,
      ]);
      await session.finalize();
      final aliases = session.summary;

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: aliases.aliases,
        provisionalSongs: provisionalBefore,
      );

      expect(summary.albumAliases, 0);
      expect(summary.reviewCount, 1);
      expect(await database.libraryDao.getAlbumById('album-old'), isNotNull);
      final review = await pendingRecoveryReviews(database, serverId);
      final entry = review.single;
      expect(entry.entityType, 'album');
      expect(entry.reason, 'ambiguousMatch');
      expect(entry.savedTitle, 'Split');
    },
    skip: !sqliteAvailable,
  );

  test('a name conflict between the evidence target and the old album defers to review', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum(
      'album-old',
      name: 'Old Name',
      starred: DateTime.utc(2026, 9, 4),
    );
    await seedCandidateAlbum('album-new', name: 'Different Album');
    await seedCanonicalSong(
      'song-new',
      title: 'Track',
      albumId: 'album-new',
      recordingMbid: 'rec-1',
    );
    await seedProvisionalSong(
      'song-old',
      title: 'Track',
      albumId: 'album-old',
      recordingMbid: 'rec-1',
    );
    final provisionalBefore = await database.songIdentityDao
        .getProvisionalSongs();
    final session = await SongIdentityReconciler(database.songIdentityDao)
        .startSession();
    await session.reconcile([
      (await database.libraryDao.getSongById('song-new'))!,
    ]);
    await session.finalize();
    final aliases = session.summary;

    final summary = await EntityIdentityReconciler(database).reconcile(
      serverId: serverId,
      generation: 1,
      songAliases: aliases.aliases,
      provisionalSongs: provisionalBefore,
    );

    expect(summary.albumAliases, 0);
    expect(summary.reviewCount, 1);
    final review = await pendingRecoveryReviews(database, serverId);
    expect(review.single.reason, 'ambiguousMatch');
  }, skip: !sqliteAvailable);

  test(
    'an owned album without evidence becomes a missingFromCatalog review entry',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum(
        'album-lost',
        name: 'Vanished',
        starred: DateTime.utc(2026, 9, 2),
      );

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: const [],
        provisionalSongs: const [],
      );

      expect(summary.albumAliases, 0);
      expect(summary.reviewCount, 1);
      expect(await database.libraryDao.getAlbumById('album-lost'), isNotNull);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.single.reason, 'missingFromCatalog');
      expect(review.single.entityType, 'album');
      expect(review.single.savedTitle, 'Vanished');
    },
    skip: !sqliteAvailable,
  );

  test('an unowned album without evidence is not reviewed', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum('album-ephemeral');

    final summary = await EntityIdentityReconciler(database).reconcile(
      serverId: serverId,
      generation: 1,
      songAliases: const [],
      provisionalSongs: const [],
    );

    expect(summary.reviewCount, 0);
    expect(await pendingRecoveryReviews(database, serverId), isEmpty);
  }, skip: !sqliteAvailable);

  test(
    'duplicate release MBIDs in the snapshot produce a conflictingMbid review',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum(
        'album-old',
        releaseMbid: 'rel-dup',
        starred: DateTime.utc(2026, 9, 4),
      );
      await seedCandidateAlbum('album-copy-a', releaseMbid: 'rel-dup');
      await seedCandidateAlbum('album-copy-b', releaseMbid: 'rel-dup');

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: const [],
        provisionalSongs: const [],
      );

      expect(summary.albumAliases, 0);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.single.reason, 'conflictingMbid');
    },
    skip: !sqliteAvailable,
  );

  test('an artist remaps through song membership, moves albums, and queues the restored like', () async {
    final serverId = await saveServer();
    final starredAt = DateTime.utc(2026, 9, 3);
    await seedProvisionalArtist('artist-old', starred: starredAt);
    await seedCandidateArtist('artist-new', name: 'Artist');
    await seedProvisionalAlbum('album-old', artistId: 'artist-old');
    await seedCanonicalSong(
      'song-new',
      title: 'Track',
      artistId: 'artist-new',
      recordingMbid: 'rec-1',
    );
    await seedProvisionalSong(
      'song-old',
      title: 'Track',
      artistId: 'artist-old',
      recordingMbid: 'rec-1',
    );
    final provisionalBefore = await database.songIdentityDao
        .getProvisionalSongs();
    final session = await SongIdentityReconciler(database.songIdentityDao)
        .startSession();
    await session.reconcile([
      (await database.libraryDao.getSongById('song-new'))!,
    ]);
    await session.finalize();
    final aliases = session.summary;

    final summary = await EntityIdentityReconciler(database).reconcile(
      serverId: serverId,
      generation: 1,
      songAliases: aliases.aliases,
      provisionalSongs: provisionalBefore,
    );

    expect(summary.artistAliases, 1);
    expect(summary.artistRestoredLikes, 1);
    expect(await database.libraryDao.getArtistById('artist-old'), isNull);
    final artist = await database.libraryDao.getArtistById('artist-new');
    expect(artist!.starred!.isAtSameMomentAs(starredAt), isTrue);
    // The retained album follows its artist.
    final album = await database.libraryDao.getAlbumById('album-old');
    expect(album!.artistId, 'artist-new');
    final pending = await database.starSyncDao.getPendingActions();
    expect(
      pending.where(
        (action) =>
            action.itemType == 'artist' &&
            action.itemId == 'artist-new' &&
            action.operation == 'star',
      ),
      isNotEmpty,
    );
  }, skip: !sqliteAvailable);

  test(
    'an in-snapshot provisional artist is skipped rather than remapped',
    () async {
      final serverId = await saveServer();
      // A lightweight parent row (e.g. created from playback) whose ID the
      // snapshot still carries: the promotion upsert refreshes it in place.
      await database.libraryDao.upsertProvisionalArtists([
        ArtistsTableCompanion.insert(id: 'artist-same', name: 'Artist'),
      ]);
      await seedCandidateArtist('artist-same', name: 'Artist');

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: const [],
        provisionalSongs: const [],
      );

      expect(summary.artistAliases, 0);
      expect(summary.reviewCount, 0);
      expect(await database.libraryDao.getArtistById('artist-same'), isNotNull);
    },
    skip: !sqliteAvailable,
  );

  // --- #709 phase 2: smarter automatic matching ---------------------------

  Future<EntityIdentityReconciliationSummary> reconcileAlbums(
    int serverId, {
    Set<String> newAlbumIds = const {'new'},
    List<SongIdentityAlias> aliases = const [],
    List<SongsTableData> provisionalSongs = const [],
  }) => EntityIdentityReconciler(database).reconcile(
    serverId: serverId,
    generation: 1,
    songAliases: aliases,
    provisionalSongs: provisionalSongs,
    newAlbumIds: newAlbumIds,
  );

  /// Seeds [count] provisional songs on [oldAlbum] that relink onto canonical
  /// songs of [newAlbum]; returns the relink session summary after running it.
  Future<(List<SongIdentityAlias>, List<SongsTableData>)> relinkSongs(
    String oldAlbum,
    String newAlbum,
    int count, {
    String? oldArtist,
    String? newArtist,
  }) async {
    final canonical = <SongsTableData>[];
    for (var i = 0; i < count; i++) {
      await seedCanonicalSong(
        '$newAlbum-s$i',
        title: 'T$i',
        albumId: newAlbum,
        artistId: newArtist,
        recordingMbid: '$newAlbum-rec$i',
      );
      await seedProvisionalSong(
        '$oldAlbum-s$i',
        title: 'T$i',
        albumId: oldAlbum,
        artistId: oldArtist,
        recordingMbid: '$newAlbum-rec$i',
      );
      canonical.add((await database.libraryDao.getSongById('$newAlbum-s$i'))!);
    }
    final provisional = await database.songIdentityDao.getProvisionalSongs();
    final session = await SongIdentityReconciler(database.songIdentityDao)
        .startSession();
    await session.reconcile(canonical);
    await session.finalize();
    return (session.summary.aliases, provisional);
  }

  test('a unique-MBID candidate whose name differs only by case and accents '
      'remaps as stableMbid', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum(
      'old',
      name: 'Café del Mar',
      releaseMbid: 'rel-1',
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedCandidateAlbum('new', name: 'CAFE DEL MAR', releaseMbid: 'rel-1');

    final summary = await reconcileAlbums(serverId);

    expect(summary.albumAliases, 1);
    final alias = await database
        .customSelect(
          "SELECT match_reason FROM entity_identity_aliases WHERE old_id = 'old'",
        )
        .getSingle();
    expect(alias.read<String>('match_reason'), 'stableMbid');
  }, skip: !sqliteAvailable);

  for (final (oldName, newName) in [
    ('Vol. 1', 'Vol. 2'),
    ('Greatest Hits', 'Other Record'),
    ('', ''),
    ('  ', ' '),
  ]) {
    test(
      'MBID match with names "$oldName" vs "$newName" goes to review',
      () async {
        final serverId = await saveServer();
        await seedProvisionalAlbum(
          'old',
          name: oldName,
          releaseMbid: 'rel-1',
          starred: DateTime.utc(2026, 9, 1),
        );
        await seedCandidateAlbum('new', name: newName, releaseMbid: 'rel-1');

        final summary = await reconcileAlbums(serverId);

        expect(summary.albumAliases, 0);
        final review = await pendingRecoveryReviews(database, serverId);
        expect(review.single.reason, 'ambiguousMatch');
      },
      skip: !sqliteAvailable,
    );
  }

  Future<EntityIdentityReconciliationSummary> membershipCase(
    int serverId, {
    required int? oldSongCount,
    required int mapped,
    required int? targetSongCount,
  }) async {
    await seedProvisionalAlbum(
      'old',
      name: 'Old Name',
      songCount: oldSongCount,
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedCandidateAlbum(
      'new',
      name: 'Different Name',
      songCount: targetSongCount,
    );
    final (aliases, provisional) = await relinkSongs('old', 'new', mapped);
    return await reconcileAlbums(
      serverId,
      aliases: aliases,
      provisionalSongs: provisional,
    );
  }

  test('membership full coverage with a name mismatch remaps as '
      'membershipFullCoverage', () async {
    final serverId = await saveServer();
    final summary = await membershipCase(
      serverId,
      oldSongCount: 3,
      mapped: 3,
      targetSongCount: 3,
    );
    expect(summary.albumAliases, 1);
    final alias = await database
        .customSelect(
          "SELECT match_reason FROM entity_identity_aliases WHERE old_id = 'old'",
        )
        .getSingle();
    expect(alias.read<String>('match_reason'), 'membershipFullCoverage');
  }, skip: !sqliteAvailable);

  for (final c in [
    (name: '1 retained of 12', old: 12, mapped: 1, target: 12),
    (name: '3-track EP into a 20-track target', old: 3, mapped: 3, target: 20),
    (name: 'unknown old song count', old: null, mapped: 3, target: 3),
    (name: 'single-song album', old: 1, mapped: 1, target: 1),
  ]) {
    test('membership name mismatch stays in review: ${c.name}', () async {
      final serverId = await saveServer();
      final summary = await membershipCase(
        serverId,
        oldSongCount: c.old,
        mapped: c.mapped,
        targetSongCount: c.target,
      );
      expect(summary.albumAliases, 0);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.single.reason, 'ambiguousMatch');
    }, skip: !sqliteAvailable);
  }

  test('an artist membership name mismatch still goes to review', () async {
    final serverId = await saveServer();
    await seedProvisionalArtist(
      'artist-old',
      name: 'Old Name',
      starred: DateTime.utc(2026, 9, 3),
    );
    await seedCandidateArtist('artist-new', name: 'Different');
    await seedCanonicalSong(
      'song-new',
      title: 'Track',
      artistId: 'artist-new',
      recordingMbid: 'rec-1',
    );
    await seedProvisionalSong(
      'song-old',
      title: 'Track',
      artistId: 'artist-old',
      recordingMbid: 'rec-1',
    );
    final provisional = await database.songIdentityDao.getProvisionalSongs();
    final session = await SongIdentityReconciler(database.songIdentityDao)
        .startSession();
    await session.reconcile([
      (await database.libraryDao.getSongById('song-new'))!,
    ]);
    await session.finalize();

    final summary = await reconcileAlbums(
      serverId,
      aliases: session.summary.aliases,
      provisionalSongs: provisional,
    );

    expect(summary.artistAliases, 0);
    final review = await pendingRecoveryReviews(database, serverId);
    expect(review.single.entityType, 'artist');
    expect(review.single.reason, 'ambiguousMatch');
  }, skip: !sqliteAvailable);

  test('two old albums merge into one target through membership', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum('old-a', starred: DateTime.utc(2026, 9, 1));
    await seedProvisionalAlbum('old-b', starred: DateTime.utc(2026, 9, 1));
    await seedCandidateAlbum('new');
    final (a1, p1) = await relinkSongs('old-a', 'new', 2);
    // Second disc shares the target album; use distinct recording ids.
    for (var i = 0; i < 2; i++) {
      await seedCanonicalSong(
        'new-b$i',
        title: 'B$i',
        albumId: 'new',
        recordingMbid: 'rec-b$i',
      );
      await seedProvisionalSong(
        'old-b-s$i',
        title: 'B$i',
        albumId: 'old-b',
        recordingMbid: 'rec-b$i',
      );
    }
    final provisional = await database.songIdentityDao.getProvisionalSongs();
    final session = await SongIdentityReconciler(database.songIdentityDao)
        .startSession();
    await session.reconcile([
      for (var i = 0; i < 2; i++)
        (await database.libraryDao.getSongById('new-b$i'))!,
    ]);
    await session.finalize();

    final summary = await reconcileAlbums(
      serverId,
      aliases: [...a1, ...session.summary.aliases],
      provisionalSongs: [...p1, ...provisional],
    );

    expect(summary.albumAliases, 2);
    expect(await database.libraryDao.getAlbumById('old-a'), isNull);
    expect(await database.libraryDao.getAlbumById('old-b'), isNull);
  }, skip: !sqliteAvailable);

  Future<void> foldedCase(
    int serverId, {
    String oldName = 'Album',
    String newName = 'Album',
    String oldArtist = 'Artist',
    String newArtist = 'Artist',
    int? oldYear,
    int? newYear,
    int? oldCount,
    int? newCount,
    String? oldMbid,
    String? newMbid,
    Set<String> newAlbumIds = const {'new'},
  }) async {
    await seedProvisionalAlbum(
      'old',
      name: oldName,
      artistName: oldArtist,
      year: oldYear,
      songCount: oldCount,
      releaseMbid: oldMbid,
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedCandidateAlbum(
      'new',
      name: newName,
      artistName: newArtist,
      year: newYear,
      songCount: newCount,
      releaseMbid: newMbid,
    );
    await reconcileAlbums(serverId, newAlbumIds: newAlbumIds);
  }

  Future<bool> oldRemapped() async =>
      await database.libraryDao.getAlbumById('old') == null;

  for (final c in [
    (
      name: 'same folded name, artist and year',
      args: (oy: 2001, ny: 2001, oc: null, nc: null, on: 'Café', nn: 'CAFE'),
      remap: true,
    ),
    (
      name: 'year missing on one side with equal song count',
      args: (oy: null, ny: 2001, oc: 10, nc: 10, on: 'Album', nn: 'Album'),
      remap: true,
    ),
    (
      name: 'year 0 is missing: equal song count matches',
      args: (oy: 0, ny: 0, oc: 10, nc: 10, on: 'Album', nn: 'Album'),
      remap: true,
    ),
    (
      name: 'Weezer: same name, artist and song count, years differ',
      args: (oy: 1994, ny: 2001, oc: 10, nc: 10, on: 'Weezer', nn: 'Weezer'),
      remap: false,
    ),
    (
      name: 'year 0 both sides and no song count',
      args: (oy: 0, ny: 0, oc: null, nc: null, on: 'Album', nn: 'Album'),
      remap: false,
    ),
    (
      name: 'song count 0 is missing',
      args: (oy: null, ny: null, oc: 0, nc: 0, on: 'Album', nn: 'Album'),
      remap: false,
    ),
    (
      name: 'different folded names',
      args: (oy: 2001, ny: 2001, oc: 10, nc: 10, on: 'Vol. 1', nn: 'Vol. 2'),
      remap: false,
    ),
  ]) {
    test('foldedName: ${c.name}', () async {
      final serverId = await saveServer();
      await foldedCase(
        serverId,
        oldName: c.args.on,
        newName: c.args.nn,
        oldYear: c.args.oy,
        newYear: c.args.ny,
        oldCount: c.args.oc,
        newCount: c.args.nc,
      );
      expect(await oldRemapped(), c.remap);
      if (!c.remap) {
        final review = await pendingRecoveryReviews(database, serverId);
        expect(review.single.reason, 'missingFromCatalog');
      }
    }, skip: !sqliteAvailable);
  }

  for (final (oldArtist, newArtist) in [
    ('Artist', 'Other'),
    ('', ''),
    ('Artist', ''),
  ]) {
    test(
      'foldedName: artists "$oldArtist" vs "$newArtist" do not match',
      () async {
        final serverId = await saveServer();
        await foldedCase(
          serverId,
          oldYear: 2001,
          newYear: 2001,
          oldArtist: oldArtist,
          newArtist: newArtist,
        );
        expect(await oldRemapped(), isFalse);
      },
      skip: !sqliteAvailable,
    );
  }

  test('foldedName: differing release MBIDs veto the match', () async {
    final serverId = await saveServer();
    await foldedCase(
      serverId,
      oldYear: 2001,
      newYear: 2001,
      oldMbid: 'rel-a',
      newMbid: 'rel-b',
    );
    expect(await oldRemapped(), isFalse);
  }, skip: !sqliteAvailable);

  test(
    'foldedName: a candidate that was already live is never matched',
    () async {
      final serverId = await saveServer();
      await foldedCase(
        serverId,
        oldYear: 2001,
        newYear: 2001,
        newAlbumIds: const <String>{},
      );
      expect(await oldRemapped(), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'foldedName: an old album with unrelinked provisional songs goes to review',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum(
        'old',
        artistName: 'Artist',
        year: 2001,
        starred: DateTime.utc(2026, 9, 1),
      );
      await seedProvisionalSong('left-behind', title: 'Orphan', albumId: 'old');
      await seedCandidateAlbum('new', artistName: 'Artist', year: 2001);

      await reconcileAlbums(serverId);

      expect(await oldRemapped(), isFalse);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.single.reason, 'missingFromCatalog');
    },
    skip: !sqliteAvailable,
  );

  test(
    'foldedName: two qualifying candidates go to review with both ids',
    () async {
      final serverId = await saveServer();
      await seedProvisionalAlbum(
        'old',
        artistName: 'Artist',
        year: 2001,
        starred: DateTime.utc(2026, 9, 1),
      );
      await seedCandidateAlbum('new', artistName: 'Artist', year: 2001);
      await seedCandidateAlbum('new2', artistName: 'Artist', year: 2001);

      await reconcileAlbums(serverId, newAlbumIds: const {'new', 'new2'});

      expect(await oldRemapped(), isFalse);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.single.reason, 'ambiguousMatch');
      expect(
        review.single.candidateJson,
        allOf(contains('new'), contains('new2')),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'foldedName: two old albums claiming one candidate both go to review',
    () async {
      final serverId = await saveServer();
      for (final id in ['old-1', 'old-2']) {
        await seedProvisionalAlbum(
          id,
          artistName: 'Artist',
          year: 2001,
          starred: DateTime.utc(2026, 9, 1),
        );
      }
      await seedCandidateAlbum('new', artistName: 'Artist', year: 2001);

      final summary = await reconcileAlbums(serverId);

      expect(summary.albumAliases, 0);
      final review = await pendingRecoveryReviews(database, serverId);
      expect(review.map((r) => r.reason), ['ambiguousMatch', 'ambiguousMatch']);
    },
    skip: !sqliteAvailable,
  );

  test('a stableMbid match and a foldedName claim on the same candidate: only '
      'the foldedName row goes to review', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum(
      'old-mbid',
      artistName: 'Artist',
      year: 2001,
      releaseMbid: 'rel-1',
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedProvisionalAlbum(
      'old-name',
      artistName: 'Artist',
      year: 2001,
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedCandidateAlbum(
      'new',
      artistName: 'Artist',
      year: 2001,
      releaseMbid: 'rel-1',
    );

    final summary = await reconcileAlbums(serverId);

    expect(summary.albumAliases, 1);
    expect(await database.libraryDao.getAlbumById('old-mbid'), isNull);
    expect(await database.libraryDao.getAlbumById('old-name'), isNotNull);
    final review = await pendingRecoveryReviews(database, serverId);
    expect(review.single.oldId, 'old-name');
    expect(review.single.reason, 'ambiguousMatch');
  }, skip: !sqliteAvailable);

  test(
    'a foldedName remap moves the like and rating and queues the like',
    () async {
      final serverId = await saveServer();
      final starredAt = DateTime.utc(2026, 9, 1);
      await seedProvisionalAlbum(
        'old',
        artistName: 'Artist',
        year: 2001,
        starred: starredAt,
        userRating: 4,
      );
      await seedCandidateAlbum('new', artistName: 'Artist', year: 2001);

      final summary = await reconcileAlbums(serverId);

      expect(summary.albumAliases, 1);
      expect(summary.albumRestoredLikes, 1);
      final album = await database.libraryDao.getAlbumById('new');
      expect(album!.starred!.isAtSameMomentAs(starredAt), isTrue);
      expect(album.userRating, 4);
      final pending = await database.starSyncDao.getPendingActions();
      expect(
        pending.where((a) => a.itemType == 'album' && a.itemId == 'new'),
        isNotEmpty,
      );
    },
    skip: !sqliteAvailable,
  );

  test('a review row with a user disposition is not overridden', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum(
      'old',
      name: 'Lost',
      starred: DateTime.utc(2026, 9, 1),
    );
    await database.librarySyncDao.recordRecoveryReview(
      serverId: serverId,
      entityType: 'album',
      oldId: 'old',
      savedTitle: 'Lost',
      reason: 'ambiguousMatch',
    );
    final row =
        (await database.select(database.libraryRecoveryReviewTable).get())
            .single;
    await database.librarySyncDao.setRecoveryReviewDisposition(
      id: row.id,
      disposition: 'keptForLater',
    );

    await reconcileAlbums(serverId);

    final after =
        (await database.select(database.libraryRecoveryReviewTable).get())
            .single;
    expect(after.disposition, 'keptForLater');
    expect(after.reason, 'ambiguousMatch');
    expect(await pendingRecoveryReviews(database, serverId), isEmpty);
  }, skip: !sqliteAvailable);

  test('an automatic remap keeps a row the user already decided on', () async {
    final serverId = await saveServer();
    await seedProvisionalAlbum(
      'old',
      releaseMbid: 'rel-1',
      starred: DateTime.utc(2026, 9, 1),
    );
    await seedCandidateAlbum('new', releaseMbid: 'rel-1');
    await database.librarySyncDao.recordRecoveryReview(
      serverId: serverId,
      entityType: 'album',
      oldId: 'old',
      reason: 'ambiguousMatch',
    );
    final row =
        (await database.select(database.libraryRecoveryReviewTable).get())
            .single;
    await database.librarySyncDao.setRecoveryReviewDisposition(
      id: row.id,
      disposition: 'keptForLater',
    );

    await reconcileAlbums(serverId);

    final after = await database
        .select(database.libraryRecoveryReviewTable)
        .get();
    expect(after.single.disposition, 'keptForLater');
  }, skip: !sqliteAvailable);
}
