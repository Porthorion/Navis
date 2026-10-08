import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
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
  }) async {
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: id,
        name: name!,
        artistId: Value(artistId),
        artistName: Value(artistName),
        releaseMbid: Value(releaseMbid),
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
    int generation = 1,
  }) async {
    final companion = AlbumsTableCompanion.insert(
      id: id,
      name: name,
      artistId: Value(artistId),
      artistName: Value(artistName),
      releaseMbid: Value(releaseMbid),
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
      final aliases = await SongIdentityReconciler(database.songIdentityDao)
          .reconcileCanonicalSongs([
            (await database.libraryDao.getSongById('song-new'))!,
          ]);

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
      final aliases = await SongIdentityReconciler(database.songIdentityDao)
          .reconcileCanonicalSongs([
            (await database.libraryDao.getSongById('song-a'))!,
            (await database.libraryDao.getSongById('song-b'))!,
          ]);

      final summary = await EntityIdentityReconciler(database).reconcile(
        serverId: serverId,
        generation: 1,
        songAliases: aliases.aliases,
        provisionalSongs: provisionalBefore,
      );

      expect(summary.albumAliases, 0);
      expect(summary.reviewCount, 1);
      expect(await database.libraryDao.getAlbumById('album-old'), isNotNull);
      final review = await database.librarySyncDao.getPendingRecoveryReview(
        serverId,
      );
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
    final aliases = await SongIdentityReconciler(database.songIdentityDao)
        .reconcileCanonicalSongs([
          (await database.libraryDao.getSongById('song-new'))!,
        ]);

    final summary = await EntityIdentityReconciler(database).reconcile(
      serverId: serverId,
      generation: 1,
      songAliases: aliases.aliases,
      provisionalSongs: provisionalBefore,
    );

    expect(summary.albumAliases, 0);
    expect(summary.reviewCount, 1);
    final review = await database.librarySyncDao.getPendingRecoveryReview(
      serverId,
    );
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
      final review = await database.librarySyncDao.getPendingRecoveryReview(
        serverId,
      );
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
    expect(
      await database.librarySyncDao.getPendingRecoveryReview(serverId),
      isEmpty,
    );
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
      final review = await database.librarySyncDao.getPendingRecoveryReview(
        serverId,
      );
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
    final aliases = await SongIdentityReconciler(database.songIdentityDao)
        .reconcileCanonicalSongs([
          (await database.libraryDao.getSongById('song-new'))!,
        ]);

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
}
