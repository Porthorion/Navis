import 'dart:math';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart'
    show QueueDropReason, QueueInsertRun, QueueSongsDropped;
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

const succeeded = LibrarySyncState(
  status: LibrarySyncStatus.succeeded,
  stage: LibrarySyncStage.completed,
);
const failed = LibrarySyncState(
  status: LibrarySyncStatus.failed,
  stage: LibrarySyncStage.completed,
);

class _Api extends Mock implements SubsonicApiClient;

class QueueSpy extends QueueController {
  List<String> ids = ['previous'];
  int replacements = 0;
  int appends = 0;
  Future<void> Function(List<SongsTableData>)? onReplace;
  Set<String> skippedAppendIds = {};

  /// Batches containing one of these ids fail as a native timeout would.
  Set<String> throwingAppendIds = {};
  final List<(int, int)> moves = [];
  @override
  Future<void> reorder(int oldIndex, int newIndex) async {
    moves.add((oldIndex, newIndex));
    final id = ids.removeAt(oldIndex);
    ids.insert(oldIndex < newIndex ? newIndex - 1 : newIndex, id);
    state = List.of(ids);
  }

  void edit(List<String> values) {
    ids = List.of(values);
    state = List.of(ids);
  }

  @override
  List<String> build() => ids;
  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    reserveSelection();
    ref.read(regularQueueReplacementEpochProvider.notifier).bump();
    replacements++;
    await onReplace?.call(songs);
    ids = songs.map((song) => song.id).toList();
    state = List.of(ids);
  }

  /// Runs applied by [insertRuns], as (index, inserted ids).
  final List<(int, List<String>)> insertedRuns = [];

  @override
  Future<List<String>> insertRuns(List<QueueInsertRun> runs) async {
    appends++;
    if (runs.any(
      (run) => run.songs.any((song) => throwingAppendIds.contains(song.id)),
    )) {
      throw TimeoutException('native insert timed out');
    }
    final skipped = <String>[];
    final ordered = List.of(runs)..sort((a, b) => b.index.compareTo(a.index));
    for (final run in ordered) {
      final accepted = <String>[];
      for (final song in run.songs) {
        (skippedAppendIds.contains(song.id) ? skipped : accepted).add(song.id);
      }
      ids.insertAll(run.index.clamp(0, ids.length), accepted);
      insertedRuns.add((run.index, accepted));
    }
    state = List.of(ids);
    return skipped;
  }

  @override
  Future<List<String>> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    Random? random,
  }) async {
    appends++;
    final skipped = <String>[];
    final source = random ?? Random();
    for (final song in songs) {
      if (skippedAppendIds.contains(song.id)) {
        skipped.add(song.id);
        continue;
      }
      final start = notBefore.clamp(0, ids.length);
      ids.insert(start + source.nextInt(ids.length - start + 1), song.id);
    }
    state = List.of(ids);
    return skipped;
  }

  @override
  Future<void> addTableData(List<SongsTableData> songs) async {
    appends++;
    ids.addAll(
      songs
          .where((s) => !skippedAppendIds.contains(s.id))
          .map((song) => song.id),
    );
    state = List.of(ids);
  }
}

void main() {
  late NavisDatabase database;
  late List<String> requests;
  late ArtistPlaybackResolver resolver;

  Future<void> addTrack(
    String albumId, {
    String? id,
    String? artistId,
    int disc = 1,
    int track = 1,
  }) async {
    await database
        .into(database.songsTable)
        .insert(
          SongsTableCompanion.insert(
            id: id ?? 'track-$albumId',
            title: id ?? 'Track',
            albumId: Value(albumId),
            artistId: Value(artistId),
            discNumber: Value(disc),
            track: Value(track),
          ),
        );
  }

  setUp(() async {
    database = createTestDatabase();
    requests = [];
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(
        id: 'artist',
        name: 'Artist',
        albumCount: const Value(3),
      ),
      ArtistsTableCompanion.insert(id: 'other', name: 'Other'),
    ]);
    await database.libraryDao.upsertAlbums([
      for (var i = 1; i <= 3; i++)
        AlbumsTableCompanion.insert(
          id: 'album-$i',
          name: 'Album',
          artistId: const Value('artist'),
          year: Value(2020 + i),
          songCount: const Value(1),
          songsHydrated: Value(i == 1),
        ),
    ]);
    await addTrack('album-1');
    resolver = ArtistPlaybackResolver(
      readSnapshot: database.libraryDao.getArtistPlaybackSnapshot,
      hydrate: (target) async {
        requests.add('${target.kind.name}:${target.entityId}');
        if (target.kind == LibrarySyncTargetKind.album) {
          await addTrack(target.entityId!);
          await database.libraryDao.markAlbumSongsHydrated(target.entityId!);
        }
        return succeeded;
      },
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
    );
  });
  tearDown(() => database.close());

  Future<ArtistPlaybackSelection?> resolve(
    ArtistPlaybackResolver service, {
    bool Function()? current,
  }) => service.resolve(
    'artist',
    isCurrent: current ?? () => true,
    onProgress: (_) {},
  );

  ProviderContainer containerFor(
    ArtistPlaybackResolver service,
    QueueSpy queue, {
    SubsonicApiClient? Function()? readApi,
    Stream<QueueSongsDropped>? drops,
  }) {
    final container = ProviderContainer(
      overrides: [
        if (drops != null) queueSongsDroppedProvider.overrideWithValue(drops),
        artistPlaybackResolverProvider.overrideWithValue(service),
        queueProvider.overrideWith(() => queue),
        playerStateProvider.overrideWithValue(const PlaybackSnapshot.idle()),
        subsonicApiProvider.overrideWith((ref) => readApi?.call()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('coalesces fast release hydrations into one publication', () async {
    final selections = <int>[];
    final coalescing = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: resolver.hydrate,
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
      publishInterval: const Duration(minutes: 1),
    );
    final result = await coalescing.resolve(
      'artist',
      isCurrent: () => true,
      onProgress: (_) {},
      onSelection: (selection) async => selections.add(selection.songs.length),
    );

    // The cached release publishes immediately; the two hydrated releases are
    // published together instead of once each.
    expect(result!.songs, hasLength(3));
    expect(selections.first, 1);
    expect(selections.where((count) => count == 2), isEmpty);
    expect(requests, ['album:album-2', 'album:album-3', 'artist:artist']);
  });

  test(
    'starts available audio while metadata is held, and cancel stops refills',
    () async {
      final entered = Completer<void>();
      final gate = Completer<LibrarySyncState>();
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) {
          if (target.kind == LibrarySyncTargetKind.album) {
            entered.complete();
            return gate.future;
          }
          return resolver.hydrate(target);
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final pending = controller.prepare('artist', ArtistPlaybackAction.play);
      await entered.future;
      expect(queue.ids, ['track-album-1']);
      expect(container.read(artistPlaybackControllerProvider).busy, isTrue);
      controller.cancel();
      gate.complete(succeeded);
      await pending;
      expect(queue.ids, ['track-album-1']);
      expect(queue.appends, 0);
    },
  );

  test(
    'queue clear after early playback prevents a late background append',
    () async {
      final entered = Completer<void>();
      final gate = Completer<LibrarySyncState>();
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) {
          entered.complete();
          return gate.future;
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final pending = controller.prepare('artist', ArtistPlaybackAction.play);
      await entered.future;
      expect(queue.ids, ['track-album-1']);
      queue.reserveSelection();
      queue.edit([]);
      container.read(regularQueueReplacementEpochProvider.notifier).bump();
      await addTrack('album-2');
      await database.libraryDao.markAlbumSongsHydrated('album-2');
      gate.complete(succeeded);
      await pending;
      expect(queue.ids, isEmpty);
      expect(queue.appends, 0);
      expect(
        container.read(artistPlaybackControllerProvider).stage,
        ArtistPlaybackStage.cancelled,
      );
    },
  );

  test(
    'a new artist action remains available during background filling',
    () async {
      final entered = Completer<void>();
      final gate = Completer<LibrarySyncState>();
      var held = false;
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) {
          if (!held && target.kind == LibrarySyncTargetKind.album) {
            held = true;
            entered.complete();
            return gate.future;
          }
          return resolver.hydrate(target);
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final old = controller.prepare('artist', ArtistPlaybackAction.play);
      await entered.future;
      await controller.prepare('artist', ArtistPlaybackAction.shuffle);
      expect(
        queue.ids,
        unorderedEquals(['track-album-1', 'track-album-2', 'track-album-3']),
      );
      final after = List.of(queue.ids);
      gate.complete(succeeded);
      await old;
      expect(queue.ids, after);
      expect(queue.replacements, 2);
      expect(
        container.read(artistPlaybackControllerProvider).action,
        ArtistPlaybackAction.shuffle,
      );
    },
  );

  test(
    'an empty snapshot starts its first release before artist metadata',
    () async {
      await database.delete(database.songsTable).go();
      await database
          .update(database.albumsTable)
          .write(const AlbumsTableCompanion(songsHydrated: Value(false)));
      final queue = QueueSpy();
      final changed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) {
          if (target.kind == LibrarySyncTargetKind.artist) {
            expect(queue.ids, [
              'track-album-1',
              'track-album-2',
              'track-album-3',
            ]);
          }
          return resolver.hydrate(target);
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final container = containerFor(changed, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      expect(queue.replacements, 1);
      expect(queue.appends, 2);
    },
  );

  test('new earlier tracks join the future queue without restarting the current track', () async {
    await database.delete(database.songsTable).go();
    await database
        .update(database.albumsTable)
        .write(const AlbumsTableCompanion(songsHydrated: Value(false)));
    await addTrack('album-3');
    await database.libraryDao.markAlbumSongsHydrated('album-3');
    final queue = QueueSpy();
    final container = containerFor(resolver, queue);
    await container
        .read(artistPlaybackControllerProvider.notifier)
        .prepare('artist', ArtistPlaybackAction.play);
    expect(queue.replacements, 1);
    expect(queue.ids, ['track-album-3', 'track-album-1', 'track-album-2']);
  });

  test(
    'new disc tracks insert chronologically before upcoming releases',
    () async {
      await resolve(resolver);
      final changed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) async {
          if (target.kind == LibrarySyncTargetKind.artist) {
            await (database.update(database.albumsTable)
                  ..where((a) => a.id.equals('album-1')))
                .write(const AlbumsTableCompanion(songCount: Value(2)));
            return succeeded;
          }
          await addTrack('album-1', id: 'disc-two', disc: 2);
          return succeeded;
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(changed, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      expect(queue.replacements, 1);
      expect(queue.ids, [
        'track-album-1',
        'disc-two',
        'track-album-2',
        'track-album-3',
      ]);
      // One batched run at the album's chronological place; no moves.
      expect(queue.moves, isEmpty);
      expect(
        [
          for (final (index, ids) in queue.insertedRuns) [index, ids],
        ],
        [
          [
            1,
            ['disc-two'],
          ],
        ],
      );
    },
  );

  test('background growth preserves manual removals and order', () async {
    await resolve(resolver);
    final queue = QueueSpy();
    final changed = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: (target) async {
        queue.edit(['track-album-1', 'track-album-3']);
        await (database.update(database.albumsTable)
              ..where((a) => a.id.equals('album-1')))
            .write(const AlbumsTableCompanion(songCount: Value(2)));
        if (target.kind == LibrarySyncTargetKind.album) {
          await addTrack('album-1', id: 'disc-two', disc: 2);
        }
        return succeeded;
      },
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
    );
    final container = containerFor(changed, queue);
    await container
        .read(artistPlaybackControllerProvider.notifier)
        .prepare('artist', ArtistPlaybackAction.play);
    expect(queue.ids, ['track-album-1', 'track-album-3', 'disc-two']);
    expect(queue.moves, isEmpty);
  });

  test('one hydrated release resolves all three without filtering track artist IDs', () async {
    final result = (await resolve(resolver))!;
    expect(result.complete, isTrue);
    expect(result.songs.map((song) => song.id), [
      'track-album-1',
      'track-album-2',
      'track-album-3',
    ]);
    expect(requests, ['album:album-2', 'album:album-3', 'artist:artist']);
    expect(result.completedAlbumCount, 3);
  });

  for (final action in [
    ArtistPlaybackAction.play,
    ArtistPlaybackAction.shuffle,
  ]) {
    test(
      '$action starts once and grows the queue with all release tracks',
      () async {
        final queue = QueueSpy();
        final container = containerFor(resolver, queue);
        await container
            .read(artistPlaybackControllerProvider.notifier)
            .prepare('artist', action);
        expect(queue.replacements, 1);
        expect(
          queue.ids,
          unorderedEquals(['track-album-1', 'track-album-2', 'track-album-3']),
        );
        expect(
          container.read(artistPlaybackControllerProvider).stage,
          ArtistPlaybackStage.completed,
        );
      },
    );
  }

  test('zero hydrated releases hydrates every album', () async {
    await database.delete(database.songsTable).go();
    await database
        .update(database.albumsTable)
        .write(const AlbumsTableCompanion(songsHydrated: Value(false)));
    final result = (await resolve(resolver))!;
    expect(result.complete, isTrue);
    expect(result.songs, hasLength(3));
    expect(requests, hasLength(4));
  });

  test('complete snapshots only refresh artist metadata', () async {
    await resolve(resolver);
    requests.clear();
    expect((await resolve(resolver))!.complete, isTrue);
    expect(requests, ['artist:artist']);
  });

  test('membership includes entire featured releases, remote editions, and ordered loose tracks', () async {
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'featured',
        name: 'Featured',
        artistId: const Value('other'),
        year: const Value(2020),
        artists: const Value([ArtistRef(id: 'artist', name: 'Artist')]),
        songsHydrated: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: 'remote',
        name: 'Album',
        artistId: const Value('artist'),
        isExternal: const Value(true),
        songsHydrated: const Value(true),
      ),
    ]);
    await addTrack('featured', artistId: 'other', id: 'disc-2', disc: 2);
    await addTrack(
      'featured',
      artistId: 'other',
      id: 'disc-1-track-2',
      track: 2,
    );
    await addTrack('featured', artistId: 'other', id: 'disc-1-track-1');
    await database.libraryDao.upsertProvisionalSongs([
      SongsTableCompanion.insert(
        id: 'remote-track',
        title: 'Track',
        albumId: const Value('remote'),
        isExternal: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'loose',
        title: 'Loose',
        artistId: const Value('artist'),
      ),
    ]);
    final snapshot = await database.libraryDao.getArtistPlaybackSnapshot(
      'artist',
    );
    expect(snapshot.albums.map((album) => album.id), [
      'featured',
      'album-1',
      'album-2',
      'album-3',
      'remote',
    ]);
    expect(snapshot.songs.map((song) => song.id), [
      'disc-1-track-1',
      'disc-1-track-2',
      'disc-2',
      'track-album-1',
      'remote-track',
      'loose',
    ]);
    expect(
      snapshot.songs.firstWhere((song) => song.id == 'remote-track').isExternal,
      isTrue,
    );
  });

  test(
    'a larger advertised count rehydrates a previously complete album',
    () async {
      await (database.update(database.albumsTable)
            ..where((a) => a.id.equals('album-1')))
          .write(const AlbumsTableCompanion(songCount: Value(2)));
      final changed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (target) async {
          if (target.entityId == 'album-1') {
            requests.add('album:album-1');
            await addTrack('album-1', id: 'new-track', track: 2);
            return succeeded;
          }
          return resolver.hydrate(target);
        },
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final selection = (await resolve(changed))!;
      expect(requests, contains('album:album-1'));
      expect(selection.songs.map((s) => s.id), [
        'track-album-1',
        'new-track',
        'track-album-2',
        'track-album-3',
      ]);
      expect(selection.complete, isTrue);
    },
  );

  test('zero and unknown years sort after known years', () async {
    await (database.update(database.albumsTable)
          ..where((a) => a.id.equals('album-1')))
        .write(const AlbumsTableCompanion(year: Value(0)));
    await (database.update(database.albumsTable)
          ..where((a) => a.id.equals('album-2')))
        .write(const AlbumsTableCompanion(year: Value(null)));
    final selection = (await resolve(resolver))!;
    expect(selection.songs.map((s) => s.id), [
      'track-album-3',
      'track-album-1',
      'track-album-2',
    ]);
  });

  test('album failure automatically queues the known tracks', () async {
    final partial = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: (target) => target.entityId == 'album-3'
          ? Future.value(failed)
          : resolver.hydrate(target),
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
    );
    final queue = QueueSpy();
    final container = containerFor(partial, queue);
    final controller = container.read(
      artistPlaybackControllerProvider.notifier,
    );
    await controller.prepare('artist', ArtistPlaybackAction.play);
    final state = container.read(artistPlaybackControllerProvider);
    expect(state.stage, ArtistPlaybackStage.completed);
    expect(state.selection!.unresolvedAlbumIds, {'album-3'});
    expect(queue.ids, ['track-album-1', 'track-album-2']);
  });

  test('online remote tracks stream without a verified local file', () async {
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'ext-release',
        name: 'Remote',
        artistId: const Value('artist'),
        isExternal: const Value(true),
        isProvisional: const Value(true),
        songsHydrated: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'ext-track',
        title: 'Remote track',
        albumId: const Value('ext-release'),
        isExternal: const Value(true),
        isProvisional: const Value(true),
      ),
    ]);
    final online = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: resolver.hydrate,
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async =>
          throw StateError('online streams need no file'),
    );
    final queue = QueueSpy();
    final container = containerFor(online, queue);
    await container
        .read(artistPlaybackControllerProvider.notifier)
        .prepare('artist', ArtistPlaybackAction.play);
    expect(queue.ids, contains('ext-track'));
    expect(container.read(retainedArtistQueueProvider), isEmpty);
  });

  test(
    'failed starting source automatically advances and retains its metadata',
    () async {
      final queue = QueueSpy()
        ..onReplace = (songs) async {
          if (songs.first.id == 'track-album-1') {
            throw StateError('source unavailable');
          }
        };
      final container = containerFor(resolver, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      expect(queue.replacements, 2);
      expect(queue.ids, ['track-album-2', 'track-album-3']);
      expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
        'track-album-1',
      ]);
    },
  );

  test(
    'new selection during source preparation prevents automatic fallback',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final queue = QueueSpy()
        ..onReplace = (_) {
          entered.complete();
          return gate.future;
        };
      final container = containerFor(resolver, queue);
      final pending = container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      await entered.future;
      queue.reserveSelection();
      container.read(regularQueueReplacementEpochProvider.notifier).bump();
      gate.completeError(StateError('old source failed'));
      await pending;
      expect(queue.replacements, 1);
      expect(
        container.read(artistPlaybackControllerProvider).stage,
        ArtistPlaybackStage.cancelled,
      );
    },
  );

  test(
    'offline with no playable content retains rows and preserves playback',
    () async {
      final offline = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) async => throw StateError('no network'),
        canHydrate: () => false,
        isOffline: () => true,
        isLocallyPlayable: (_) async => false,
      );
      final queue = QueueSpy();
      final container = containerFor(offline, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      expect(queue.ids, ['previous']);
      expect(queue.replacements, 0);
      expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
        'track-album-1',
      ]);
      container.read(regularQueueReplacementEpochProvider.notifier).bump();
      expect(container.read(retainedArtistQueueProvider), isEmpty);
    },
  );

  test(
    'failed artist metadata cannot be mistaken for a complete cached selection',
    () async {
      await resolve(resolver);
      final partial = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) async => failed,
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final result = (await resolve(partial))!;
      expect(result.metadataComplete, isFalse);
      expect(result.complete, isFalse);
      expect(result.songs, hasLength(3));
    },
  );

  test(
    'offline retains identified unavailable tracks without streaming them',
    () async {
      await resolve(resolver);
      final offline = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) async => throw StateError('must not fetch'),
        canHydrate: () => false,
        isOffline: () => true,
        isLocallyPlayable: (song) async => song.id == 'track-album-1',
      );
      final result = (await resolve(offline))!;
      expect(result.songs, hasLength(3));
      expect(result.unavailableSongIds, {'track-album-2', 'track-album-3'});
      final queue = QueueSpy();
      final container = containerFor(offline, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      expect(queue.ids, ['track-album-1']);
      expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
        'track-album-2',
        'track-album-3',
      ]);
      expect(result.complete, isFalse);
      expect(result.unresolvedAlbumIds, {'album-2', 'album-3'});
    },
  );

  test(
    'valid empty album is complete and cannot clear the current queue',
    () async {
      await database.delete(database.songsTable).go();
      await database
          .update(database.albumsTable)
          .write(
            const AlbumsTableCompanion(
              songsHydrated: Value(true),
              songCount: Value(0),
            ),
          );
      final queue = QueueSpy();
      final container = containerFor(resolver, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      await controller.prepare('artist', ArtistPlaybackAction.play);
      expect(queue.ids, ['previous']);
      expect(
        container.read(artistPlaybackControllerProvider).selection!.complete,
        isTrue,
      );
    },
  );

  test(
    'cancel stops scheduling new targets and never commits a late result',
    () async {
      final gate = Completer<LibrarySyncState>();
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) => gate.future,
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final pending = controller.prepare('artist', ArtistPlaybackAction.play);
      controller.cancel();
      gate.complete(succeeded);
      await pending;
      expect(queue.replacements, 0);
      expect(
        container.read(artistPlaybackControllerProvider).stage,
        ArtistPlaybackStage.cancelled,
      );
    },
  );

  test('new queue selection invalidates pending preparation', () async {
    final gate = Completer<LibrarySyncState>();
    final delayed = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: (_) => gate.future,
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
    );
    final queue = QueueSpy();
    final container = containerFor(delayed, queue);
    final controller = container.read(
      artistPlaybackControllerProvider.notifier,
    );
    final pending = controller.prepare('artist', ArtistPlaybackAction.play);
    queue.reserveSelection();
    container.read(regularQueueReplacementEpochProvider.notifier).bump();
    gate.complete(succeeded);
    await pending;
    expect(queue.replacements, 0);
    expect(
      container.read(artistPlaybackControllerProvider).stage,
      ArtistPlaybackStage.cancelled,
    );
  });

  test(
    'recommendation activation cancels pending artist preparation',
    () async {
      final gate = Completer<LibrarySyncState>();
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) => gate.future,
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final pending = controller.prepare('artist', ArtistPlaybackAction.play);
      container
          .read(recommendationSessionProvider.notifier)
          .start(RecommendationMode.personalRadio);
      gate.complete(succeeded);
      await pending;
      expect(queue.replacements, 0);
    },
  );

  test(
    'add uses progressive batches and retains existing occurrences',
    () async {
      final queue = QueueSpy()..ids = ['previous', 'track-album-1'];
      final container = containerFor(resolver, queue);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.add);
      expect(queue.appends, 3);
      expect(queue.ids, [
        'previous',
        'track-album-1',
        'track-album-1',
        'track-album-2',
        'track-album-3',
      ]);
    },
  );
  group('songs the player drops later', () {
    Future<(ProviderContainer, StreamController<QueueSongsDropped>)>
    prepared() async {
      final drops = StreamController<QueueSongsDropped>.broadcast();
      addTearDown(drops.close);
      final container = containerFor(resolver, QueueSpy(), drops: drops.stream);
      // The app shell keeps this alive.
      container.read(artistQueueDropRetentionProvider);
      await container
          .read(artistPlaybackControllerProvider.notifier)
          .prepare('artist', ArtistPlaybackAction.play);
      return (container, drops);
    }

    test(
      "are retained as unavailable while the queue is the artist's",
      () async {
        final (container, drops) = await prepared();
        expect(container.read(retainedArtistQueueProvider), isEmpty);

        drops.add(
          const QueueSongsDropped(
            songIds: ['track-album-2', 'someone-else'],
            reason: QueueDropReason.release,
          ),
        );
        drops.add(
          const QueueSongsDropped(
            songIds: ['track-album-2'],
            reason: QueueDropReason.rebuild,
          ),
        );
        await pumpEventQueue();

        expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
          'track-album-2',
        ]);
      },
    );

    test('are ignored once another queue replaced it', () async {
      final (container, drops) = await prepared();
      container.read(queueProvider.notifier).reserveSelection();

      drops.add(
        const QueueSongsDropped(
          songIds: ['track-album-2'],
          reason: QueueDropReason.release,
        ),
      );
      await pumpEventQueue();

      expect(container.read(retainedArtistQueueProvider), isEmpty);
    });
  });

  test('a batch that throws is retained as unavailable, not lost', () async {
    final queue = QueueSpy()..throwingAppendIds = {'track-album-2'};
    final container = containerFor(resolver, queue);
    await container
        .read(artistPlaybackControllerProvider.notifier)
        .prepare('artist', ArtistPlaybackAction.add);
    expect(queue.ids, ['previous', 'track-album-1', 'track-album-3']);
    expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
      'track-album-2',
    ]);
  });

  test('failed appended occurrence remains visible even if its ID is already queued', () async {
    final queue = QueueSpy()
      ..ids = ['track-album-1']
      ..skippedAppendIds = {'track-album-1'};
    final container = containerFor(resolver, queue);
    await container
        .read(artistPlaybackControllerProvider.notifier)
        .prepare('artist', ArtistPlaybackAction.add);
    expect(queue.ids, ['track-album-1', 'track-album-2', 'track-album-3']);
    expect(container.read(retainedArtistQueueProvider).map((s) => s.id), [
      'track-album-1',
    ]);
  });
  test('missing advertised counts remain compatible after successful metadata loading', () async {
    await database
        .update(database.artistsTable)
        .write(const ArtistsTableCompanion(albumCount: Value(null)));
    expect((await resolve(resolver))!.complete, isTrue);
  });

  test('late first preparation cannot overwrite a second selection', () async {
    final first = Completer<LibrarySyncState>();
    final entered = Completer<void>();
    var metadataCalls = 0;
    final delayed = ArtistPlaybackResolver(
      readSnapshot: resolver.readSnapshot,
      hydrate: (target) {
        if (target.kind == LibrarySyncTargetKind.artist &&
            ++metadataCalls == 1) {
          entered.complete();
          return first.future;
        }
        return resolver.hydrate(target);
      },
      canHydrate: () => true,
      isOffline: () => false,
      isLocallyPlayable: (_) async => true,
    );
    final queue = QueueSpy();
    final container = containerFor(delayed, queue);
    final controller = container.read(
      artistPlaybackControllerProvider.notifier,
    );
    final old = controller.prepare('artist', ArtistPlaybackAction.play);
    await entered.future;
    await controller.prepare('artist', ArtistPlaybackAction.shuffle);
    first.complete(succeeded);
    await old;
    expect(queue.replacements, inInclusiveRange(1, 2));
    expect(
      container.read(artistPlaybackControllerProvider).action,
      ArtistPlaybackAction.shuffle,
    );
  });

  test(
    'account change cancels pending preparation before late metadata returns',
    () async {
      final gate = Completer<LibrarySyncState>();
      SubsonicApiClient? api;
      final delayed = ArtistPlaybackResolver(
        readSnapshot: resolver.readSnapshot,
        hydrate: (_) => gate.future,
        canHydrate: () => true,
        isOffline: () => false,
        isLocallyPlayable: (_) async => true,
      );
      final queue = QueueSpy();
      final container = containerFor(delayed, queue, readApi: () => api);
      final controller = container.read(
        artistPlaybackControllerProvider.notifier,
      );
      final pending = controller.prepare('artist', ArtistPlaybackAction.play);
      final nextApi = _Api();
      when(() => nextApi.connectionIdentity).thenReturn('next-session');
      api = nextApi;
      container.invalidate(subsonicApiProvider);
      container.read(subsonicApiProvider);
      gate.complete(succeeded);
      await pending;
      expect(queue.replacements, 0);
      expect(
        container.read(artistPlaybackControllerProvider).stage,
        ArtistPlaybackStage.cancelled,
      );
    },
  );
}
