import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart'
    show QueueInsertRun, QueueSongsDropped;
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

enum ArtistPlaybackAction { play, shuffle, add }

enum ArtistPlaybackStage {
  idle,
  loading,
  committing,
  completed,
  cancelled,
  failed,
}

class ArtistPlaybackSelection {
  const ArtistPlaybackSelection({
    required this.songs,
    required this.albumCount,
    required this.completedAlbumCount,
    required this.unresolvedAlbumIds,
    required this.metadataComplete,
    this.offline = false,
    this.unavailableSongIds = const {},
  });

  final List<SongsTableData> songs;
  final int albumCount;
  final int completedAlbumCount;
  final Set<String> unresolvedAlbumIds;
  final bool metadataComplete;
  final bool offline;
  final Set<String> unavailableSongIds;
  bool get complete =>
      metadataComplete &&
      unresolvedAlbumIds.isEmpty &&
      unavailableSongIds.isEmpty;
}

class ArtistPlaybackProgress {
  const ArtistPlaybackProgress({this.completed = 0, this.total = 0});
  final int completed;
  final int total;
}

/// Publishes available artist tracks while resolving the remaining releases.
class ArtistPlaybackResolver {
  const ArtistPlaybackResolver({
    required this.readSnapshot,
    required this.hydrate,
    required this.canHydrate,
    required this.isOffline,
    required this.isLocallyPlayable,
    this.publishInterval = Duration.zero,
    this.readAlbum,
  });

  final Future<ArtistPlaybackSnapshot> Function(String) readSnapshot;

  /// Reads one album's row and songs. When set, a hydrated release updates
  /// the snapshot in place instead of re-reading the artist's whole catalogue
  /// (which also loaded every album in the library).
  final Future<({AlbumsTableData? album, List<SongsTableData> songs})> Function(
    String albumId,
  )?
  readAlbum;
  final Future<LibrarySyncState> Function(LibrarySyncTarget) hydrate;
  final bool Function() canHydrate;
  final bool Function() isOffline;
  final Future<bool> Function(SongsTableData) isLocallyPlayable;

  /// Minimum interval between progressive publications while releases are
  /// hydrated. A publication that would start an empty queue is never held.
  final Duration publishInterval;

  Future<ArtistPlaybackSelection?> resolve(
    String artistId, {
    required bool Function() isCurrent,
    required void Function(ArtistPlaybackProgress) onProgress,
    Future<void> Function(ArtistPlaybackSelection)? onSelection,
  }) async {
    var snapshot = await readSnapshot(artistId);
    if (!isCurrent()) return null;
    var metadataComplete = false;
    final failedAlbums = <String>{};
    final attemptedCounts = <String, int?>{};

    Future<ArtistPlaybackSelection?> publish() async {
      if (!isCurrent()) return null;
      final complete = _completeAlbumIds(snapshot);
      final unresolved = <String>{
        ...failedAlbums,
        ...snapshot.albums
            .where((album) => !complete.contains(album.id))
            .map((album) => album.id),
      };
      final unavailable = <String>{};
      final offline = isOffline();
      for (final song in snapshot.songs) {
        if (!isCurrent()) return null;
        if (offline && !await isLocallyPlayable(song)) {
          unavailable.add(song.id);
          if (song.albumId != null) unresolved.add(song.albumId!);
        }
      }
      if (!isCurrent()) return null;
      final selection = ArtistPlaybackSelection(
        songs: List.unmodifiable(snapshot.songs),
        unavailableSongIds: Set.unmodifiable(unavailable),
        albumCount: snapshot.albums.length,
        completedAlbumCount: snapshot.albums
            .where((a) => complete.contains(a.id) && !unresolved.contains(a.id))
            .length,
        unresolvedAlbumIds: Set.unmodifiable(unresolved),
        metadataComplete: metadataComplete,
        offline: offline,
      );
      onProgress(
        ArtistPlaybackProgress(
          completed: selection.completedAlbumCount,
          total: selection.albumCount,
        ),
      );
      await onSelection?.call(selection);
      return selection;
    }

    // Re-reading the snapshot loads the artist's whole catalog in a
    // transaction, and each publish may mutate the queue. With hundreds of
    // releases, doing that after every album saturated the database, so
    // hydrated albums are published at most once per interval, and at the end.
    Future<ArtistPlaybackSnapshot> refreshed(Set<String> albumIds) async {
      final read = readAlbum;
      if (read == null) return readSnapshot(artistId);
      var next = snapshot;
      for (final albumId in albumIds) {
        final album = await read(albumId);
        next = next.withAlbum(albumId, album.album, album.songs);
      }
      return next;
    }

    Future<void> hydrateAlbums() async {
      final albums = List.of(snapshot.albums);
      final sincePublish = Stopwatch()..start();
      var unpublished = false;
      final hydratedSinceRead = <String>{};
      var snapshotWasEmpty = snapshot.songs.isEmpty;
      for (final album in albums) {
        if (!isCurrent()) return;
        if (_completeAlbumIds(snapshot).contains(album.id) ||
            (attemptedCounts.containsKey(album.id) &&
                attemptedCounts[album.id] == album.songCount)) {
          continue;
        }
        attemptedCounts[album.id] = album.songCount;
        var success = false;
        if (canHydrate()) {
          try {
            final result = await hydrate(LibrarySyncTarget.album(album.id));
            success = result.status == LibrarySyncStatus.succeeded;
          } on Object {
            success = false;
          }
        }
        if (!isCurrent()) return;
        if (success) {
          failedAlbums.remove(album.id);
        } else {
          failedAlbums.add(album.id);
        }
        unpublished = true;
        hydratedSinceRead.add(album.id);
        if (snapshotWasEmpty || sincePublish.elapsed >= publishInterval) {
          snapshot = await refreshed(hydratedSinceRead);
          hydratedSinceRead.clear();
          await publish();
          snapshotWasEmpty = snapshot.songs.isEmpty;
          unpublished = false;
          sincePublish
            ..reset()
            ..start();
        }
      }
      if (unpublished && isCurrent()) {
        snapshot = await refreshed(hydratedSinceRead);
        await publish();
      }
    }

    // Cached rows and the first missing release must not wait for a slower
    // artist metadata refresh. Both passes use the coordinator's target lane.
    await publish();
    if (!isCurrent()) return null;
    await hydrateAlbums();
    if (!isCurrent()) return null;
    if (canHydrate()) {
      try {
        final result = await hydrate(LibrarySyncTarget.artist(artistId));
        metadataComplete = result.status == LibrarySyncStatus.succeeded;
      } on Object {
        metadataComplete = false;
      }
      if (!isCurrent()) return null;
      snapshot = await readSnapshot(artistId);
      await publish();
      if (!isCurrent()) return null;
      // Metadata can introduce a release or enlarge an advertised track count.
      await hydrateAlbums();
    } else {
      final expected = snapshot.artist?.albumCount;
      metadataComplete = expected != null && snapshot.albums.length >= expected;
    }
    return publish();
  }

  Set<String> _completeAlbumIds(ArtistPlaybackSnapshot snapshot) {
    final counts = <String, int>{};
    for (final song in snapshot.songs) {
      final id = song.albumId;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    return snapshot.albums
        .where((album) {
          // Mixed local/external responses may legitimately contain more rows
          // than the server's local count; a larger advertised count is incomplete.
          return album.songsHydrated &&
              (album.songCount == null ||
                  (counts[album.id] ?? 0) >= album.songCount!);
        })
        .map((album) => album.id)
        .toSet();
  }
}

/// Minimum interval between progressive artist-queue publications while
/// releases are hydrated in the app.
const Duration artistPlaybackPublishInterval = Duration(seconds: 1);

final artistPlaybackResolverProvider = Provider<ArtistPlaybackResolver>((ref) {
  final container = ref.container;
  return ArtistPlaybackResolver(
    readSnapshot: (id) => container
        .read(navisDatabaseProvider)
        .libraryDao
        .getArtistPlaybackSnapshot(id),
    hydrate: (target) => container
        .read(librarySyncControllerProvider.notifier)
        .requestTarget(target),
    canHydrate: () =>
        container.read(librarySyncEngineProvider) != null &&
        container.read(syncNetworkPolicyProvider).allowsInteractiveHydration,
    isOffline: () => container.read(syncNetworkPolicyProvider).isOffline,
    publishInterval: artistPlaybackPublishInterval,
    readAlbum: (albumId) => container
        .read(navisDatabaseProvider)
        .libraryDao
        .getArtistPlaybackAlbum(albumId),
    isLocallyPlayable: (song) async {
      final cache = await container
          .read(navisDatabaseProvider)
          .cacheDao
          .getCachedTrack(song.id);
      if (cache == null || cache.downloadStatus != DownloadStatus.complete) {
        return false;
      }
      return storedAudioExists(
        locator: cache.filePath,
        storageKind: cache.storageKind,
      );
    },
  );
});

class ArtistPlaybackState {
  const ArtistPlaybackState({
    this.artistId,
    this.stage = ArtistPlaybackStage.idle,
    this.action = ArtistPlaybackAction.play,
    this.progress = const ArtistPlaybackProgress(),
    this.selection,
    this.elapsedMilliseconds = 0,
  });
  final String? artistId;
  final ArtistPlaybackStage stage;
  final ArtistPlaybackAction action;
  final ArtistPlaybackProgress progress;
  final ArtistPlaybackSelection? selection;
  final int elapsedMilliseconds;
  bool get busy =>
      stage == ArtistPlaybackStage.loading ||
      stage == ArtistPlaybackStage.committing;

  Map<String, Object?> diagnostics() => {
    'stage': stage.name,
    'action': action.name,
    'completedAlbums': progress.completed,
    'totalAlbums': progress.total,
    'availableTracks':
        (selection?.songs.length ?? 0) -
        (selection?.unavailableSongIds.length ?? 0),
    'unavailableTracks': selection?.unavailableSongIds.length ?? 0,
    'unresolvedAlbums': selection?.unresolvedAlbumIds.length ?? 0,
    'metadataComplete': selection?.metadataComplete ?? false,
    'offline': selection?.offline ?? false,
    'elapsedMilliseconds': elapsedMilliseconds,
  };
}

/// Keeps [ArtistPlaybackController] informed of songs the player drops.
/// Watched by the app shell: a direct stream subscription, because a
/// provider nobody listens to has its listeners paused.
final artistQueueDropRetentionProvider = Provider<void>((ref) {
  final subscription = ref
      .watch(queueSongsDroppedProvider)
      .listen(
        (event) => ref
            .read(artistPlaybackControllerProvider.notifier)
            .retainDroppedSongs(event),
      );
  ref.onDispose(subscription.cancel);
});

final artistPlaybackControllerProvider =
    NotifierProvider<ArtistPlaybackController, ArtistPlaybackState>(
      ArtistPlaybackController.new,
    );

class ArtistPlaybackController extends Notifier<ArtistPlaybackState> {
  int _generation = 0;
  int? _queueSelection;

  /// The songs of the latest artist queue, so songs the handler drops later
  /// (for example when a deferred song cannot be prepared) can still be
  /// shown as unavailable instead of silently disappearing.
  final Map<String, SongsTableData> _queuedSongs = <String, SongsTableData>{};
  final Set<String> _retainedDrops = <String>{};
  bool _submitting = false;
  Stopwatch? _timer;

  @override
  ArtistPlaybackState build() {
    ref.listen<int>(regularQueueReplacementEpochProvider, (_, next) {
      if (!_submitting) cancel();
    });
    ref.listen<int>(
      recommendationSessionProvider.select((value) => value.generation),
      (_, next) {
        if (!_submitting) cancel();
      },
    );
    ref.listen<Object?>(
      subsonicApiProvider.select((api) => api?.connectionIdentity),
      (previous, next) {
        if (previous != next) {
          cancel();
          ref.read(retainedArtistQueueProvider.notifier).clear();
        }
      },
    );
    ref.listen<bool>(playerStateProvider.select((value) => value.isRadioMode), (
      previous,
      next,
    ) {
      if (next) cancel();
    });
    ref.onDispose(() => _generation++);
    return const ArtistPlaybackState();
  }

  bool _owns(int generation) =>
      ref.mounted &&
      generation == _generation &&
      _queueSelection != null &&
      ref.read(queueProvider.notifier).ownsSelection(_queueSelection!);

  Future<void> prepare(String artistId, ArtistPlaybackAction action) async {
    if (state.busy && state.artistId == artistId && state.action == action) {
      return;
    }
    final generation = ++_generation;
    final queue = ref.read(queueProvider.notifier);
    _queueSelection = queue.reserveSelection();
    if (action != ArtistPlaybackAction.add) _queuedSongs.clear();
    _retainedDrops.clear();
    final timer = Stopwatch()..start();
    _timer = timer;
    final attempted = <String>{};
    final failures = <String, SongsTableData>{};
    final publishedFailures = <String>{};
    final random = Random();
    final appendBoundary = action == ArtistPlaybackAction.add
        ? ref.read(queueProvider).length
        : 0;
    var started = false;
    var preserveOrder = true;
    List<String>? expectedQueue;
    state = ArtistPlaybackState(
      artistId: artistId,
      stage: ArtistPlaybackStage.loading,
      action: action,
    );

    Future<void> admit(ArtistPlaybackSelection selection) async {
      if (!_owns(generation)) return;
      final before = List<String>.of(ref.read(queueProvider));
      if (expectedQueue != null && !listEquals(before, expectedQueue)) {
        // Manual edits and automatic source recovery own the existing order.
        preserveOrder = false;
      }
      final incoming = selection.songs
          .where((song) => attempted.add(song.id))
          .toList();
      for (final song in incoming) {
        _queuedSongs[song.id] = song;
      }
      for (final song in incoming) {
        if (selection.unavailableSongIds.contains(song.id)) {
          failures[song.id] = song;
        }
      }
      final songs = incoming
          .where((song) => !selection.unavailableSongIds.contains(song.id))
          .toList();
      if (action == ArtistPlaybackAction.shuffle) songs.shuffle(random);
      final append =
          started || (action == ArtistPlaybackAction.add && before.isNotEmpty);
      if (songs.isNotEmpty) {
        state = ArtistPlaybackState(
          artistId: artistId,
          stage: ArtistPlaybackStage.committing,
          action: action,
          selection: selection,
          progress: state.progress,
        );
        if (append) {
          // One batched edit per admit. Shuffle merges new songs at random
          // upcoming positions and Play inserts each album where its rank
          // belongs; neither moves songs one at a time, and songs the player
          // already holds keep their order.
          final ids = ref.read(queueProvider);
          final current = ref.read(playerStateProvider).currentIndex ?? 0;
          final firstUpcoming = max(current + 1, appendBoundary);
          final ranks = {
            for (var i = 0; i < selection.songs.length; i++)
              selection.songs[i].id: i,
          };
          var skipped = const <String>[];
          try {
            if (!preserveOrder) {
              // Manual edits and automatic source recovery own the existing
              // order: only append.
              skipped = await queue.insertRuns(<QueueInsertRun>[
                QueueInsertRun(ids.length, songs),
              ]);
            } else if (action == ArtistPlaybackAction.shuffle) {
              skipped = await queue.mergeIntoUpcoming(
                songs,
                notBefore: firstUpcoming,
                random: random,
              );
            } else {
              skipped = await queue.insertRuns(
                _rankedRuns(
                  songs: songs,
                  queueIds: ids,
                  firstUpcoming: firstUpcoming,
                  ranks: ranks,
                ),
              );
            }
          } on Object catch (error, stackTrace) {
            AppLogger.warning(
              'Artist queue batch could not finish. $error\n$stackTrace',
            );
            // The handler keeps whatever part of the batch it committed;
            // every other song is retained as unavailable, not lost.
            final added = <String, int>{};
            for (final id in ref.read(queueProvider)) {
              added[id] = (added[id] ?? 0) + 1;
            }
            for (final id in before) {
              added[id] = (added[id] ?? 0) - 1;
            }
            final lost = <String>[];
            for (final song in songs) {
              final count = added[song.id] ?? 0;
              if (count > 0) {
                added[song.id] = count - 1;
              } else {
                lost.add(song.id);
              }
            }
            skipped = lost;
          }
          if (!_owns(generation)) return;
          final byId = {for (final song in songs) song.id: song};
          for (final id in skipped) {
            final song = byId[id];
            if (song != null) failures[id] = song;
          }
        } else {
          while (songs.isNotEmpty && _owns(generation)) {
            Future<void> replacement;
            _submitting = true;
            try {
              replacement = queue.replaceWithTableData(
                songs,
                expandMatchFlows: false,
              );
              _queueSelection = queue.selectionGeneration;
            } finally {
              _submitting = false;
            }
            publishedFailures.clear();
            try {
              await replacement;
              if (!_owns(generation)) return;
              started = ref.read(queueProvider).isNotEmpty;
              break;
            } on Object {
              if (!_owns(generation)) return;
              final failed = songs.removeAt(0);
              failures[failed.id] = failed;
            }
          }
          if (!_owns(generation)) return;
          final missing = _unqueuedSongs(
            _withSongs(selection, songs),
            const <String>[],
          );
          for (final song in missing) {
            failures[song.id] = song;
          }
        }
      }
      if (!_owns(generation)) return;
      expectedQueue = List.of(ref.read(queueProvider));
      final newlyUnavailable = failures.values
          .where((song) => publishedFailures.add(song.id))
          .toList();
      if (newlyUnavailable.isNotEmpty) {
        ref
            .read(retainedArtistQueueProvider.notifier)
            .retain(
              newlyUnavailable,
              append: true,
            );
      }
      state = ArtistPlaybackState(
        artistId: artistId,
        stage: ArtistPlaybackStage.loading,
        action: action,
        selection: _withUnavailableSongs(selection, failures.values.toList()),
        progress: ArtistPlaybackProgress(
          completed: selection.completedAlbumCount,
          total: selection.albumCount,
        ),
        elapsedMilliseconds: timer.elapsedMilliseconds,
      );
    }

    try {
      final selection = await ref
          .read(artistPlaybackResolverProvider)
          .resolve(
            artistId,
            isCurrent: () => _owns(generation),
            onProgress: (_) {},
            onSelection: admit,
          );
      if (!_owns(generation) || selection == null) {
        if (generation == _generation) cancel();
        return;
      }
      state = ArtistPlaybackState(
        artistId: artistId,
        stage: ArtistPlaybackStage.completed,
        action: action,
        selection: _withUnavailableSongs(selection, failures.values.toList()),
        progress: state.progress,
        elapsedMilliseconds: timer.elapsedMilliseconds,
      );
      _recordOutcome();
    } on Object {
      if (_owns(generation)) {
        state = ArtistPlaybackState(
          artistId: artistId,
          stage: ArtistPlaybackStage.failed,
          action: action,
          selection: state.selection,
          progress: state.progress,
          elapsedMilliseconds: timer.elapsedMilliseconds,
        );
        _recordOutcome();
      }
    }
  }

  /// Groups [songs] (in album order) into contiguous runs, each inserted at
  /// the first upcoming queue position whose song ranks after it.
  List<QueueInsertRun> _rankedRuns({
    required List<SongsTableData> songs,
    required List<String> queueIds,
    required int firstUpcoming,
    required Map<String, int> ranks,
  }) {
    final runs = <QueueInsertRun>[];
    var runIndex = -1;
    var runSongs = <SongsTableData>[];
    // Songs arrive in album order and the upcoming queue keeps that order, so
    // each target is at or after the previous one: one pass over the queue.
    var scan = min(firstUpcoming, queueIds.length);
    for (final song in songs) {
      final rank = ranks[song.id] ?? -1;
      while (scan < queueIds.length && (ranks[queueIds[scan]] ?? -1) <= rank) {
        scan++;
      }
      final target = scan;
      if (target != runIndex && runSongs.isNotEmpty) {
        runs.add(QueueInsertRun(runIndex, runSongs));
        runSongs = <SongsTableData>[];
      }
      runIndex = target;
      runSongs.add(song);
    }
    if (runSongs.isNotEmpty) runs.add(QueueInsertRun(runIndex, runSongs));
    return runs;
  }

  ArtistPlaybackSelection _withSongs(
    ArtistPlaybackSelection selection,
    List<SongsTableData> songs,
  ) => ArtistPlaybackSelection(
    songs: songs,
    albumCount: selection.albumCount,
    completedAlbumCount: selection.completedAlbumCount,
    unresolvedAlbumIds: selection.unresolvedAlbumIds,
    metadataComplete: selection.metadataComplete,
    unavailableSongIds: selection.unavailableSongIds,
    offline: selection.offline,
  );

  ArtistPlaybackSelection _withUnavailableSongs(
    ArtistPlaybackSelection selection,
    List<SongsTableData> skipped,
  ) => ArtistPlaybackSelection(
    songs: selection.songs,
    albumCount: selection.albumCount,
    completedAlbumCount: selection.completedAlbumCount,
    unresolvedAlbumIds: selection.unresolvedAlbumIds,
    metadataComplete: selection.metadataComplete,
    offline: selection.offline,
    unavailableSongIds: Set.unmodifiable({
      ...selection.unavailableSongIds,
      ...skipped.map((song) => song.id),
    }),
  );

  List<SongsTableData> _unqueuedSongs(
    ArtistPlaybackSelection selection,
    List<String> priorQueue,
  ) {
    final counts = <String, int>{};
    for (final id in ref.read(queueProvider)) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    for (final id in priorQueue) {
      counts[id] = (counts[id] ?? 0) - 1;
    }
    return selection.songs.where((song) {
      final count = counts[song.id] ?? 0;
      if (selection.unavailableSongIds.contains(song.id) || count <= 0) {
        return true;
      }
      counts[song.id] = count - 1;
      return false;
    }).toList();
  }

  /// Shows songs of this controller's queue that the player dropped later
  /// as unavailable. Fed by [artistQueueDropRetentionProvider].
  void retainDroppedSongs(QueueSongsDropped event) {
    final selection = _queueSelection;
    if (!ref.mounted ||
        selection == null ||
        !ref.read(queueProvider.notifier).ownsSelection(selection)) {
      return;
    }
    // Another occurrence of a song may still be queued; one missing
    // occurrence is still worth showing.
    final songs = <SongsTableData>[
      for (final id in event.songIds)
        if (_queuedSongs[id] case final song? when _retainedDrops.add(id)) song,
    ];
    if (songs.isEmpty) return;
    AppLogger.info(
      'Artist queue retained ${songs.length} songs dropped by the player '
      '(${event.reason.name}).',
    );
    ref.read(retainedArtistQueueProvider.notifier).retain(songs, append: true);
  }

  void cancel() {
    if (!ref.mounted ||
        (state.stage != ArtistPlaybackStage.loading &&
            state.stage != ArtistPlaybackStage.committing)) {
      return;
    }
    ++_generation;
    state = ArtistPlaybackState(
      artistId: state.artistId,
      stage: ArtistPlaybackStage.cancelled,
      action: state.action,
      elapsedMilliseconds: _timer?.elapsedMilliseconds ?? 0,
    );
    _recordOutcome();
  }

  void _recordOutcome() {
    AppLogger.info(
      'Artist queue preparation ${jsonEncode(state.diagnostics())}',
    );
  }
}
