import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart'
    show ValueKey, immutable, listEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/provisional_search_songs.dart';
import 'package:navis/src/features/library/data/song_identity_cache_epoch.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart'
    show PlaybackSourceUnavailableException;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Global broadcast stream for playback action errors.
///
/// UI screens fire queue actions with `.ignore()` (fire-and-forget) and errors
/// are routed here instead of being awaited per-screen.  The app shell
/// subscribes to display snackbars.
final playbackActionErrorProvider = StreamProvider<PlaybackActionError>((ref) {
  return ref.watch(_playbackActionErrorControllerProvider).stream;
});

final _playbackActionErrorControllerProvider =
    Provider<StreamController<PlaybackActionError>>((ref) {
      final controller = StreamController<PlaybackActionError>.broadcast();
      ref.onDispose(controller.close);
      return controller;
    });

void resetPlaybackActionErrors(Ref ref) {
  ref.invalidate(_playbackActionErrorControllerProvider);
  ref.invalidate(playbackActionErrorProvider);
}

class PlaybackActionError {
  const new({required this.error, this.action});
  final Object error;
  final String? action;
}

/// The queue entries that were observed after a recommendation commit.
class RecommendationQueueResult {
  const new(this.insertedIds);

  final List<String> insertedIds;

  int get count => insertedIds.length;
}

final lyricsPrewarmProvider = Provider<Future<void> Function(String)>((ref) {
  return (songId) => ref.read(lyricsProvider(songId).future).then<void>((_) {});
});

final regularQueueReplacementEpochProvider =
    NotifierProvider<RegularQueueReplacementEpoch, int>(
      RegularQueueReplacementEpoch.new,
    );

class RegularQueueReplacementEpoch extends Notifier<int> {
  @override
  int build() => 0;

  void bump() {
    state += 1;
  }
}

/// Known artist tracks omitted by source preparation remain visible in the queue.
/// Native indexes and repeated playable occurrences remain owned by the handler.
final retainedArtistQueueProvider =
    NotifierProvider<RetainedArtistQueue, List<SongsTableData>>(
      RetainedArtistQueue.new,
    );

class RetainedArtistQueue extends Notifier<List<SongsTableData>> {
  @override
  List<SongsTableData> build() {
    ref.listen<int>(regularQueueReplacementEpochProvider, (_, next) => clear());
    ref.listen<bool>(playerStateProvider.select((value) => value.isRadioMode), (
      _,
      next,
    ) {
      if (next) clear();
    });
    return const [];
  }

  void retain(List<SongsTableData> songs, {required bool append}) {
    state = List.unmodifiable([if (append) ...state, ...songs]);
  }

  void removeAt(int index) {
    state = List.unmodifiable([...state]..removeAt(index));
  }

  void clear() => state = const [];
}

/// What [QueueController.removeForUndo] removed, enough to put it back with
/// [QueueController.undoRemoval] even if the queue changed in between.
@immutable
class QueueRemoval {
  const new({
    required this.index,
    required this.songId,
    required this.successorId,
    required this.epoch,
    required this.idsAfter,
    required this.wasOnly,
  });

  final int index;
  final String songId;

  /// The song that followed the removed row, or null when it was last.
  final String? successorId;

  /// [QueueController.selectionGeneration] at removal.
  final int epoch;

  /// The queue as it read once the removal showed.
  final List<String> idsAfter;

  /// The removed row was the only one: nothing is left to anchor an Undo.
  final bool wasOnly;
}

class QueueController extends Notifier<List<String>> {
  Future<void> _recommendationCommitTail = Future<void>.value();
  Future<void> _removalTail = Future<void>.value();

  /// Set while a removal waits for the queue to show it. `ref.listen` made
  /// in a method would be closed by the rebuild that delivers the change.
  void Function(List<String> queue)? _onQueueState;
  int _regularSelectionEpoch = 0;

  /// Reserves a selection before its metadata is ready to replace the queue.
  int reserveSelection() => ++_regularSelectionEpoch;

  int get selectionGeneration => _regularSelectionEpoch;

  bool ownsSelection(int epoch) => epoch == _regularSelectionEpoch;

  @override
  List<String> build() {
    listenSelf((_, next) => _onQueueState?.call(next));
    // Only the queue ids: play/pause and loading changes must not rebuild
    // every queue listener. The handler publishes an unmodifiable list and
    // reuses it until the queue changes, so this neither copies nor rebuilds
    // for unchanged queues.
    final published =
        ref.watch(
          playbackSnapshotProvider.select(
            (snapshot) => snapshot.asData?.value.queueSongIds,
          ),
        ) ??
        const <String>[];
    final pending = _pendingOrder;
    if (pending == null) return published;
    // A queue that gained, lost or swapped songs was replaced under the move.
    if (_sameSongs(pending, published)) return pending;
    _pendingOrder = null;
    return published;
  }

  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    final selectionEpoch = ++_regularSelectionEpoch;
    final handler = _requireHandler();
    _markRegularQueueReplacement(notify: notifyMixSessionReset);
    final normalized = _normalizeSongIds(ids);
    if (normalized.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, normalized.length - 1);
    await handler.replaceQueue(
      normalized,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
      originalOrder: originalOrder,
    );
    _relinkLater(normalized.where(_isRemoteId));
    if (selectionEpoch != _regularSelectionEpoch) return;
    _prewarmLyricsForIds(
      normalized,
      priorityId: normalized[normalizedStartIndex],
    );
  }

  /// Like [replace] but accepts pre-fetched [SongsTableData] rows so the
  /// audio handler can skip the library DAO read.  Use this from screens that
  /// already have the song data in memory to avoid a DB read during sync.
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    final selectionEpoch = ++_regularSelectionEpoch;
    final handler = _requireHandler();
    _markRegularQueueReplacement(notify: notifyMixSessionReset);
    if (songs.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, songs.length - 1);
    await handler.replaceQueueWithData(
      songs,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
      originalOrder: originalOrder,
    );
    _relinkLater(_remoteRowIds(songs));
    if (selectionEpoch != _regularSelectionEpoch) return;
    _prewarmLyricsForIds(
      songs.map((song) => song.id),
      priorityId: songs[normalizedStartIndex].id,
    );
  }

  Future<void> add(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(<String>[normalizedId]);
    _relinkLater(<String>[normalizedId].where(_isRemoteId));
    _prewarmLyricsForIds(<String>[normalizedId]);
  }

  Future<void> addTableData(List<SongsTableData> songs) async {
    if (songs.isEmpty) return;
    await _requireHandler().addToQueue(
      songs.map((song) => song.id).toList(growable: false),
      expandMatchFlows: false,
    );
    _relinkLater(_remoteRowIds(songs));
    _prewarmLyricsForIds(songs.map((song) => song.id));
  }

  /// Merges [songs] at random upcoming positions at or after [notBefore]
  /// without touching songs already handed to the player. Returns the ids
  /// that could not be queued. Handlers without batched edits append instead.
  Future<List<String>> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    Random? random,
  }) async {
    if (songs.isEmpty) return const <String>[];
    final handler = _requireHandler();
    if (handler is QueueBatchEditor) {
      final result = await (handler as QueueBatchEditor).mergeIntoUpcoming(
        songs,
        notBefore: notBefore,
        random: random,
      );
      _relinkLater(_remoteRowIds(songs));
      return result.skippedSongIds;
    }
    await addTableData(songs);
    return const <String>[];
  }

  /// Inserts each run's songs contiguously at its queue index, in one batched
  /// edit. Returns the ids that could not be queued. Handlers without batched
  /// edits append instead.
  Future<List<String>> insertRuns(List<QueueInsertRun> runs) async {
    final songs = <SongsTableData>[for (final run in runs) ...run.songs];
    if (songs.isEmpty) return const <String>[];
    final handler = _requireHandler();
    if (handler is QueueBatchEditor) {
      final result = await (handler as QueueBatchEditor).insertQueueRuns(runs);
      _relinkLater(_remoteRowIds(songs));
      return result.skippedSongIds;
    }
    await addTableData(songs);
    return const <String>[];
  }

  Future<void> playNext(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.playNext(<String>[normalizedId]);
    _relinkLater(<String>[normalizedId].where(_isRemoteId));
    _prewarmLyricsForIds(<String>[normalizedId]);
  }

  /// Like [replace], but accepts [Song] API model objects and ensures they
  /// are persisted in the local database before queueing.  This is required
  /// for songs that originate from search results (e.g. remote sources
  /// injected by Octo-Fiesta / similar plugins) which may not have been
  /// synced to the local library yet.
  Future<void> replaceWithSongs(
    List<Song> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    final selectionEpoch = ++_regularSelectionEpoch;
    final handler = _requireHandler();
    _markRegularQueueReplacement(notify: notifyMixSessionReset);
    if (songs.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final selectedSong = songs[startIndex.clamp(0, songs.length - 1)];
    final startupObserver = handler is PlaybackStartupObserver
        ? handler as PlaybackStartupObserver
        : null;
    final startupAttempt = startupObserver?.beginPlaybackSelection(
      selectedSong.id,
      song: provisionalSongTableData(selectedSong),
      isExternal: isExternalCatalogSource(
        id: selectedSong.id,
        apiIsExternal: selectedSong.isExternal,
      ),
    );
    try {
      await _ensureSongsInDatabase(songs);
    } on Object {
      if (startupAttempt != null) {
        startupObserver?.notePlaybackSelectionStage(
          startupAttempt,
          'provisionalPersistenceFailed',
        );
      }
      rethrow;
    }
    if (selectionEpoch != _regularSelectionEpoch) return;
    if (startupAttempt != null &&
        startupObserver?.isPlaybackSelectionCurrent(startupAttempt) == false) {
      return;
    }
    if (startupAttempt != null) {
      startupObserver?.notePlaybackSelectionStage(
        startupAttempt,
        'provisionalPersistenceComplete',
      );
    }
    final ids = songs.map((s) => s.id).toList(growable: false);
    final db = ref.read(navisDatabaseProvider);
    final persistedSongs = await db.libraryDao.getSongsByIds(ids);
    if (selectionEpoch != _regularSelectionEpoch) return;
    if (startupAttempt != null &&
        startupObserver?.isPlaybackSelectionCurrent(startupAttempt) == false) {
      return;
    }
    if (startupAttempt != null) {
      startupObserver?.notePlaybackSelectionStage(
        startupAttempt,
        'songReadbackComplete',
      );
    }
    if (persistedSongs.length == ids.length) {
      await replaceWithTableData(
        persistedSongs,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: expandMatchFlows,
        originalOrder: originalOrder,
        notifyMixSessionReset: false,
      );
      return;
    }
    await replace(
      ids,
      startIndex: startIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
      originalOrder: originalOrder,
      notifyMixSessionReset: false,
    );
  }

  /// Like [add], but accepts a [Song] API model object.
  Future<void> addWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return await add(song.id);
  }

  /// Like [playNext], but accepts a [Song] API model object.
  Future<void> playNextWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return await playNext(song.id);
  }

  Future<void> retainCurrentAsQueue(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.retainCurrentSongAsQueue(normalizedId);
    _prewarmLyricsForIds(<String>[normalizedId], priorityId: normalizedId);
  }

  /// Serializes recommendation appends and checks session ownership again
  /// immediately before the handler's queue operation.
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) async {
    final normalizedSongs = songs
        .map((song) {
          final id = song.id.trim();
          return id.isEmpty ? null : song.copyWith(id: id);
        })
        .nonNulls
        .toList(growable: false);
    if (normalizedSongs.isEmpty) {
      return const RecommendationQueueResult(<String>[]);
    }
    await _ensureSongsInDatabase(normalizedSongs);
    final ids = normalizedSongs.map((song) => song.id).toList(growable: false);
    final previous = _recommendationCommitTail;
    final complete = Completer<void>();
    _recommendationCommitTail = complete.future;
    await previous;
    try {
      if (isCurrent != null && !isCurrent()) {
        return const RecommendationQueueResult(<String>[]);
      }
      final handler = _requireHandler();
      final before = handler.snapshot.queueSongIds;
      try {
        await handler.addToQueue(ids, expandMatchFlows: expandMatchFlows);
      } on OperationCancelledException {
        // A queue replacement discarded the append: nothing was inserted.
        return const RecommendationQueueResult(<String>[]);
      }
      final after = handler.snapshot.queueSongIds;
      final insertedIds = _insertedSongIds(before: before, after: after);
      _relinkLater(ids.where(_isRemoteId));
      _prewarmLyricsForIds(insertedIds);
      return RecommendationQueueResult(insertedIds);
    } finally {
      complete.complete();
    }
  }

  void _markRegularQueueReplacement({required bool notify}) {
    if (!notify) {
      return;
    }
    ref.read(regularQueueReplacementEpochProvider.notifier).bump();
  }

  List<String> _insertedSongIds({
    required List<String> before,
    required List<String> after,
  }) {
    final beforeCounts = <String, int>{};
    for (final id in before) {
      beforeCounts[id] = (beforeCounts[id] ?? 0) + 1;
    }
    final inserted = <String>[];
    for (final id in after) {
      final remaining = beforeCounts[id] ?? 0;
      if (remaining > 0) {
        beforeCounts[id] = remaining - 1;
      } else {
        inserted.add(id);
      }
    }
    return inserted;
  }

  /// Upsert [Song] API model objects into the local database so that the
  /// ID-based playback pipeline can resolve them.
  ///
  /// Remote songs (e.g. from Octo-Fiesta) reference artist/album IDs that may
  /// not exist in the local library.  The songs table has FOREIGN KEY
  /// constraints on `artist_id → artists.id` and `album_id → albums.id`, so
  /// we must upsert stub artist and album rows first to satisfy them.
  ///
  /// If the full upsert (with FK parents) still fails for any reason, we
  /// retry with foreign-key columns set to NULL so playback is never blocked.
  /// Stores [songs] the library lacks as provisional rows, as playing a
  /// search result does, without touching the queue. Rows the server
  /// catalogue already owns are left as they are.
  Future<void> storeProvisionalSongs(List<Song> songs) async {
    await _ensureSongsInDatabase(songs);
    // Nothing is handed to the player here, so there is no order to keep.
    await ref.read(relinkExternalCopiesProvider)([
      for (final song in songs)
        if (isExternalCatalogSource(
          id: song.id,
          apiIsExternal: song.isExternal,
        ))
          song.id,
    ]);
  }

  Future<void> _ensureSongsInDatabase(List<Song> songs) async {
    if (songs.isEmpty) return;
    final db = ref.read(navisDatabaseProvider);

    try {
      // 1. Upsert referenced artists (deduplicated).
      final artistEntries = <String, ({String? name, bool isExternal})>{};
      for (final song in songs) {
        final id = song.artistId?.trim();
        if (id != null && id.isNotEmpty && !artistEntries.containsKey(id)) {
          artistEntries[id] = (
            name: song.artist,
            isExternal: isExternalCatalogSource(
              id: song.id,
              apiIsExternal: song.isExternal,
            ),
          );
        }
      }
      if (artistEntries.isNotEmpty) {
        final artistCompanions = artistEntries.entries
            .map(
              (e) => ArtistsTableCompanion.insert(
                id: e.key,
                name: e.value.name ?? e.key,
                isExternal: Value(e.value.isExternal),
              ),
            )
            .toList(growable: false);
        await db.libraryDao.upsertProvisionalArtists(artistCompanions);
      }

      // 2. Upsert referenced albums (deduplicated).
      final albumEntries = <String, Song>{};
      for (final song in songs) {
        final id = song.albumId?.trim();
        if (id != null && id.isNotEmpty && !albumEntries.containsKey(id)) {
          albumEntries[id] = song;
        }
      }
      if (albumEntries.isNotEmpty) {
        final albumCompanions = albumEntries.entries
            .map(
              (e) => AlbumsTableCompanion.insert(
                id: e.key,
                name: e.value.album ?? e.key,
                artistId: Value(e.value.artistId),
                artistName: Value(e.value.artist),
                coverArt: Value(e.value.coverArt),
                year: Value(e.value.year),
                isExternal: Value(
                  isExternalCatalogSource(
                    id: e.value.id,
                    apiIsExternal: e.value.isExternal,
                  ),
                ),
              ),
            )
            .toList(growable: false);
        await db.libraryDao.upsertProvisionalAlbums(albumCompanions);
      }

      // 3. Upsert the song rows themselves.
      await _upsertSongRows(db, songs);
    } on Object {
      // FK upsert failed (unexpected schema issue, etc.).  Retry with
      // foreign-key columns nulled out so playback still works.
      await _upsertSongRows(db, songs, nullForeignKeys: true);
    }
  }

  /// Relinks remote copies among [ids] to their library songs once the
  /// queue has been handed to the player, never before: the handler maps
  /// aliases on every lookup and learns each one before its remap commits
  /// (the sequence catalog sync uses while songs are queued), so this adds no
  /// await and no swapped ids to the tap path. One batch per call; failures
  /// are logged by the provider and never block playback.
  void _relinkLater(Iterable<String> ids) {
    final remote = ids.toList(growable: false);
    if (remote.isEmpty) return;
    unawaited(ref.read(relinkExternalCopiesProvider)(remote));
  }

  static bool _isRemoteId(String id) => isExternalCatalogSource(id: id);

  static List<String> _remoteRowIds(List<SongsTableData> songs) => [
    for (final song in songs)
      if (song.isExternal) song.id,
  ];

  Future<void> _upsertSongRows(
    NavisDatabase db,
    List<Song> songs, {
    bool nullForeignKeys = false,
  }) async {
    final companions = songs
        .map(
          (song) => SongsTableCompanion.insert(
            id: song.id,
            title: song.title,
            albumId: Value(nullForeignKeys ? null : song.albumId),
            artistId: Value(nullForeignKeys ? null : song.artistId),
            artistName: Value(song.artist),
            albumName: Value(song.album),
            track: Value(song.track),
            discNumber: Value(song.discNumber),
            duration: Value(song.duration),
            bitRate: Value(song.bitRate),
            sampleRate: Value(song.sampleRate),
            contentType: Value(song.contentType),
            suffix: Value(song.suffix),
            size: Value(song.size),
            coverArt: Value(song.coverArt),
            starred: Value(song.starred),
            recordingMbid: Value(song.musicBrainzId),
            playCount: Value(song.playCount),
            createdAt: Value(song.created),
            isExternal: Value(
              isExternalCatalogSource(
                id: song.id,
                apiIsExternal: song.isExternal,
              ),
            ),
            replayGainTrackGain: Value(song.replayGain?.trackGain),
            replayGainAlbumGain: Value(song.replayGain?.albumGain),
            replayGainTrackPeak: Value(song.replayGain?.trackPeak),
            replayGainAlbumPeak: Value(song.replayGain?.albumPeak),
          ),
        )
        .toList(growable: false);
    await db.libraryDao.upsertProvisionalSongs(companions);
  }

  /// The queue as the user dropped it while the handler's moves are in
  /// flight. The handler publishes only after its native move returns, so
  /// without this the list would draw the old order, snap back, then jump.
  List<String>? _pendingOrder;
  int _reordersInFlight = 0;

  /// Completes when [_reordersInFlight] drops to zero; taps wait on it.
  Completer<void>? _reordersIdle;

  /// Moves the row at [oldIndex] to the insertion index [newIndex] (counted
  /// before the row is removed, as the handler counts it). The list shows the
  /// move at once and returns to the handler's order once every move is done.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final handler = _requireHandler();
    final current = state;
    if (oldIndex >= 0 &&
        oldIndex < current.length &&
        newIndex >= 0 &&
        newIndex <= current.length) {
      final moved = [...current];
      final target = oldIndex < newIndex ? newIndex - 1 : newIndex;
      moved.insert(target, moved.removeAt(oldIndex));
      _pendingOrder = List.unmodifiable(moved);
      state = _pendingOrder!;
    }
    if (_reordersInFlight++ == 0) _reordersIdle = Completer<void>();
    try {
      await handler.reorderQueue(oldIndex, newIndex);
    } finally {
      if (--_reordersInFlight == 0) {
        _reordersIdle!.complete();
        if (_pendingOrder != null) {
          _pendingOrder = null;
          if (ref.mounted) ref.invalidateSelf();
        }
      }
    }
  }

  static bool _sameSongs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final counts = <String, int>{};
    for (final id in a) {
      counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final id in b) {
      if (counts.update(id, (n) => n - 1, ifAbsent: () => -1) < 0) {
        return false;
      }
    }
    return true;
  }

  Future<T> _inRemovalOrder<T>(Future<T> Function() task) {
    final previous = _removalTail;
    final complete = Completer<void>();
    _removalTail = complete.future;
    return previous.then((_) => task()).whenComplete(complete.complete);
  }

  /// Removes the row at [requestedIndex] if it still holds [songId], one
  /// removal at a time, and returns what [undoRemoval] needs once the queue
  /// shows the change. At its turn, a row that moved (an earlier removal
  /// shifted it) is found again by [songId] when that song occurs exactly
  /// once, unless the queue was replaced since the swipe; with no copy
  /// or several copies nothing is removed, because the swiped row cannot be
  /// told apart. Null means nothing was removed: a stale row or a failed
  /// removal (reported). If the handler removed the row but the queue did not
  /// show it within 2 s, the removal is returned anyway with the queue as it
  /// reads now; the content guard of [undoRemoval] covers the lag.
  ///
  /// ponytail: both guards read the published queue, not the handler's. An
  /// edit already in the handler's `_enqueueQueueEdit` lane but not yet
  /// published can shift indices, so `removeAt(index)` may hit another song
  /// (pre-existing). Upgrade path: handler-side `removeAt(index, expectedId)`
  /// with the successor anchor resolved inside the lane. The removal lane has
  /// no bound on a hung handler call (a hung handler blocks playback edits
  /// anyway).
  Future<QueueRemoval?> removeForUndo(int requestedIndex, String songId) {
    final swipeEpoch = _regularSelectionEpoch;
    return _inRemovalOrder(() async {
      final before = state;
      var index = requestedIndex;
      if (index < 0 || index >= before.length || before[index] != songId) {
        // A replaced queue is not the one the user swiped in.
        if (!ownsSelection(swipeEpoch)) return null;
        index = before.indexOf(songId);
        if (index < 0 || index != before.lastIndexOf(songId)) return null;
      }
      final epoch = _regularSelectionEpoch;
      final successorId = index + 1 < before.length ? before[index + 1] : null;
      final ok = await runReportingErrors(
        () => _requireHandler().removeAt(index),
        label: 'remove from queue',
      );
      if (!ok) return null;
      final after = await _queueChangedFrom(before) ?? state;
      return QueueRemoval(
        index: index,
        songId: songId,
        successorId: successorId,
        epoch: epoch,
        idsAfter: after,
        wasOnly: before.length == 1,
      );
    });
  }

  /// The queue once it differs from [before], or null after a short wait.
  Future<List<String>?> _queueChangedFrom(List<String> before) async {
    if (!listEquals(state, before)) return state;
    final changed = Completer<List<String>?>();
    _onQueueState = (next) {
      if (!changed.isCompleted && !listEquals(next, before)) {
        changed.complete(next);
      }
    };
    try {
      return await changed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    } finally {
      _onQueueState = null;
    }
  }

  /// Puts a removed song back where it was, judged by the queue's content now.
  ///
  /// ponytail: an Android Auto or media-session queue replacement does not
  /// bump the selection epoch; the content guard limits the damage. Upgrade
  /// path: compare the handler's queue identity. The insert index is judged
  /// on the published queue too (see [removeForUndo]).
  Future<void> undoRemoval(QueueRemoval r) {
    return _inRemovalOrder(
      () => runReportingErrors(() async {
        if (r.wasOnly || !ownsSelection(r.epoch) || state.isEmpty) return;
        // Never the append fallback of insertRuns: that is a wrong-index undo.
        final handler = _requireHandler();
        if (handler is! QueueBatchEditor) return;
        final songs = await ref
            .read(navisDatabaseProvider)
            .libraryDao
            .getSongsByIds(<String>[r.songId]);
        if (songs.isEmpty || !ownsSelection(r.epoch)) return;
        final ids = state;
        final target = listEquals(ids, r.idsAfter)
            ? r.index
            : _indexBefore(ids, r.successorId, r.index);
        final result = await (handler as QueueBatchEditor).insertQueueRuns([
          QueueInsertRun(target, songs),
        ]);
        _relinkLater(_remoteRowIds(songs));
        if (result.skippedSongIds.isNotEmpty) {
          throw const PlaybackSourceUnavailableException(
            'The removed song has no playable source to restore.',
          );
        }
      }, label: 'undo queue removal'),
    );
  }

  /// Before the song that followed the removed row: its copy at or after
  /// [index] first, then any copy, else [index] clamped.
  static int _indexBefore(List<String> ids, String? successorId, int index) {
    final fallback = index.clamp(0, ids.length);
    if (successorId == null) return fallback;
    final near = ids.indexOf(successorId, fallback);
    if (near >= 0) return near;
    final any = ids.indexOf(successorId);
    return any >= 0 ? any : fallback;
  }

  /// Plays the row at [index] of the shown order. While moves are in flight
  /// the handler still indexes the old order, so the tap waits for them and
  /// then plays the same row (by [queueRowKey]) in the handler's order; if
  /// the queue was replaced meanwhile it plays nothing.
  Future<void> playFromIndex(int index) async {
    final handler = _requireHandler();
    if (_reordersInFlight > 0 && index >= 0 && index < state.length) {
      final shown = state;
      final row = queueRowKey(shown, index);
      while (_reordersInFlight > 0) {
        await _reordersIdle!.future;
      }
      final order = handler.snapshot.queueSongIds;
      if (!_sameSongs(shown, order)) return;
      index = List.generate(
        order.length,
        (i) => i,
      ).indexWhere((i) => queueRowKey(order, i) == row);
      if (index < 0) return;
    }
    await handler.playFromIndex(index);
  }

  Future<void> clear() async {
    ++_regularSelectionEpoch;
    final handler = _requireHandler();
    _markRegularQueueReplacement(notify: true);
    await handler.clearQueue();
  }

  List<String> _normalizeSongIds(Iterable<String> ids) {
    return ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  NavisPlaybackHandler _requireHandler() {
    final handler = ref.read(audioHandlerProvider);
    if (handler != null) {
      return handler;
    }
    final bootstrap = ref.read(audioBootstrapControllerProvider);
    final reason = switch (bootstrap.status) {
      AudioBootstrapStatus.initializing =>
        PlaybackUnavailableReason.initializing,
      AudioBootstrapStatus.failed => PlaybackUnavailableReason.startupFailed,
      AudioBootstrapStatus.ready => PlaybackUnavailableReason.unavailable,
    };
    throw PlaybackUnavailableException(
      reason: reason,
      message: bootstrap.errorMessage,
    );
  }

  static const int _lyricsPrewarmWindow = 3;

  void _prewarmLyricsForIds(Iterable<String> ids, {String? priorityId}) {
    final normalized = _normalizeSongIds(ids);
    if (normalized.isEmpty) {
      return;
    }
    // Prefetch only a small window: the selected song and the next few.
    // Prefetching a whole artist or library queue would start one lyrics
    // lookup (database, server and optionally LRCLIB) per song at once.
    final priority = priorityId?.trim();
    final priorityIndex = priority == null || priority.isEmpty
        ? -1
        : normalized.indexOf(priority);
    final windowStart = priorityIndex < 0 ? 0 : priorityIndex;
    final ordered = normalized
        .skip(windowStart)
        .take(_lyricsPrewarmWindow)
        .toList(growable: false);
    final tasks = <({String id, Future<void> future})>[];
    final prewarmLyrics = ref.read(lyricsPrewarmProvider);
    for (final id in ordered) {
      try {
        tasks.add((id: id, future: prewarmLyrics(id)));
      } on Object catch (error) {
        AppLogger.debug('Lyrics prewarm skipped for $id: $error');
      }
    }
    if (tasks.isEmpty) {
      return;
    }
    unawaited(
      Future<void>(() async {
        for (final task in tasks) {
          try {
            await task.future;
          } on Object catch (error) {
            AppLogger.debug('Lyrics prewarm skipped for ${task.id}: $error');
          }
        }
      }),
    );
  }

  void _emitError(Object error, {String? action}) {
    if (error is OperationCancelledException) return;
    AppLogger.warning('Playback action error (action=$action): $error');
    ref
        .read(_playbackActionErrorControllerProvider)
        .add(PlaybackActionError(error: error, action: action));
  }

  /// Runs [action] and routes errors to [playbackActionErrorProvider]
  /// instead of throwing. Returns whether it completed; a superseded action
  /// returns false without an error.
  Future<bool> runReportingErrors(
    Future<void> Function() action, {
    String? label,
  }) async {
    try {
      await action();
      return true;
    } on OperationCancelledException {
      // Superseded — not an error.
    } on Object catch (error) {
      _emitError(error, action: label);
    }
    return false;
  }

  /// Fire-and-forget wrapper around [runReportingErrors].
  void fireAndForget(Future<void> Function() action, {String? label}) {
    unawaited(runReportingErrors(action, label: label));
  }
}

final Expando<List<int>> _queueRowOccurrences = Expando<List<int>>(
  'queue row occurrences',
);

/// A stable key for the queue row at [index]: its song id and which
/// occurrence of that song it is. Unlike an index-based key, songs inserted
/// or released elsewhere do not remount (and re-query) every following row.
ValueKey<(String, int)> queueRowKey(List<String> queueIds, int index) {
  final occurrences = _queueRowOccurrences[queueIds] ??= () {
    final seen = <String, int>{};
    return List<int>.unmodifiable(<int>[
      for (final id in queueIds)
        seen.update(id, (count) => count + 1, ifAbsent: () => 0),
    ]);
  }();
  return ValueKey<(String, int)>((queueIds[index], occurrences[index]));
}

/// Relinks remote catalog copies (Deezer) among the given song ids to the
/// library song they duplicate and returns the old-to-library id map.
///
/// The one entry for every writer or reader of such rows (queue entry points,
/// song menus). It lives here, not in the DAO, because a remap must tell the
/// audio handler first, the same hand-off catalog sync uses. A failure is
/// logged and ignored: it never blocks playback, and the next full promotion
/// relinks the copy.
final relinkExternalCopiesProvider =
    Provider<Future<Map<String, String>> Function(Iterable<String>)>((ref) {
      return serializeRelinks((ids) async {
        final remote = ids.toSet();
        if (remote.isEmpty) return const <String, String>{};
        try {
          return await SongIdentityReconciler(
            ref.read(navisDatabaseProvider).songIdentityDao,
            onBeforeRemap: (aliases) async {
              SongIdentityCacheEpoch.invalidate();
              await ref
                  .read(audioHandlerProvider)
                  ?.applySongIdentityAliases(aliases);
            },
            readActiveSongId: () =>
                ref.read(audioHandlerProvider)?.snapshot.currentSongId,
          ).relinkExternalCopies(remote);
        } on Object catch (error) {
          AppLogger.debug('Remote copy relink skipped: $error');
          return const <String, String>{};
        }
      });
    });

/// Runs [relink] calls one at a time: a later call starts after the earlier
/// one finishes, so two relinks of one id never overlap (the second would see
/// the first's alias already moved the playing song and could delete the
/// cache file the first kept).
@visibleForTesting
Future<Map<String, String>> Function(Iterable<String>) serializeRelinks(
  Future<Map<String, String>> Function(Iterable<String>) relink,
) {
  var tail = Future<void>.value();
  return (ids) {
    final run = tail.then((_) => relink(ids));
    tail = run.then((_) {}, onError: (Object _) {});
    return run;
  };
}

final queueProvider = NotifierProvider<QueueController, List<String>>(
  QueueController.new,
);

final reorderQueueProvider = Provider<Future<void> Function(int, int)>((ref) {
  return (oldIndex, newIndex) =>
      ref.read(queueProvider.notifier).reorder(oldIndex, newIndex);
});
