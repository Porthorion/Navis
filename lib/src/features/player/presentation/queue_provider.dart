import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:uuid/uuid.dart';

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

class PlaybackActionError {
  const PlaybackActionError({required this.error, this.action});
  final Object error;
  final String? action;
}

final currentQueueSongIdProvider = Provider<String?>((ref) {
  return ref.watch(currentSongProvider);
});

class QueueController extends Notifier<List<String>> {
  static const Uuid _uuid = Uuid();

  @override
  List<String> build() {
    final snapshot = ref.watch(playbackSnapshotProvider).asData?.value;
    final ids = snapshot?.queueSongIds ?? const <String>[];
    return List<String>.unmodifiable(ids);
  }

  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
    bool syncGroupListening = true,
  }) async {
    final handler = _requireHandler();
    final normalized = _normalizeSongIds(ids);
    if (syncGroupListening &&
        await _sendGroupListeningQueueReplace(
          normalized,
          startIndex: startIndex,
          autoPlay: autoPlay,
        )) {
      return;
    }
    if (normalized.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, normalized.length - 1);
    await handler.replaceQueue(
      normalized,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
    );
  }

  /// Like [replace] but accepts pre-fetched [SongsTableData] rows so the
  /// audio handler can skip the library DAO read.  Use this from screens that
  /// already have the song data in memory to avoid a DB read during sync.
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool syncGroupListening = true,
  }) async {
    final handler = _requireHandler();
    if (syncGroupListening &&
        await _sendGroupListeningQueueReplace(
          songs.map((song) => song.id),
          startIndex: startIndex,
          autoPlay: autoPlay,
        )) {
      return;
    }
    if (songs.isEmpty) {
      await handler.clearQueue();
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, songs.length - 1);
    await handler.replaceQueueWithData(
      songs,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
    );
  }

  Future<void> add(String id, {bool syncGroupListening = true}) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    if (syncGroupListening && await _sendGroupListeningQueueAdd(normalizedId)) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(<String>[normalizedId]);
  }

  Future<void> playNext(String id, {bool syncGroupListening = true}) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    if (syncGroupListening &&
        await _sendGroupListeningQueueAdd(
          normalizedId,
          insertIndex: _nextGroupListeningInsertIndex(),
        )) {
      return;
    }
    final handler = _requireHandler();
    await handler.playNext(<String>[normalizedId]);
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
    bool syncGroupListening = true,
  }) async {
    if (songs.isEmpty) {
      final handler = _requireHandler();
      if (syncGroupListening &&
          await _sendGroupListeningQueueReplace(
            const <String>[],
            startIndex: startIndex,
            autoPlay: autoPlay,
          )) {
        return;
      }
      await handler.clearQueue();
      return;
    }
    await _ensureSongsInDatabase(songs);
    final ids = songs.map((s) => s.id).toList(growable: false);
    if (syncGroupListening &&
        await _sendGroupListeningQueueReplace(
          ids,
          startIndex: startIndex,
          autoPlay: autoPlay,
          songs: songs,
        )) {
      return;
    }
    await replace(
      ids,
      startIndex: startIndex,
      autoPlay: autoPlay,
      syncGroupListening: false,
    );
    // Belt-and-suspenders: if autoPlay was requested, explicitly ensure the
    // handler is playing.  Remote sources (Octo-Fiesta) can trigger preload
    // timing quirks that leave the player paused despite autoPlay being set.
    if (autoPlay) {
      final handler = ref.read(audioHandlerProvider);
      await handler?.play();
    }
  }

  /// Like [add], but accepts a [Song] API model object.
  Future<void> addWithSong(
    Song song, {
    bool syncGroupListening = true,
  }) async {
    await _ensureSongsInDatabase(<Song>[song]);
    if (syncGroupListening &&
        await _sendGroupListeningQueueAdd(song.id, song: song)) {
      return;
    }
    return add(song.id, syncGroupListening: syncGroupListening);
  }

  /// Like [add], but accepts multiple [Song] API model objects and queues
  /// them in one call after persisting all rows locally.
  Future<void> addWithSongs(
    List<Song> songs, {
    bool expandMatchFlows = true,
    bool syncGroupListening = true,
  }) async {
    if (songs.isEmpty) {
      return;
    }
    await _ensureSongsInDatabase(songs);
    final ids = songs
        .map((song) => song.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    if (syncGroupListening &&
        await _sendGroupListeningQueueReplace(
          <String>[...state, ...ids],
          startIndex: _currentGroupListeningIndex() ?? 0,
          autoPlay: ref.read(audioHandlerProvider)?.snapshot.playing ?? false,
          songs: songs,
        )) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(ids, expandMatchFlows: expandMatchFlows);
  }

  /// Like [playNext], but accepts multiple [Song] API model objects and
  /// inserts them after the current item in one call after persisting all rows
  /// locally.
  Future<void> playNextWithSongs(
    List<Song> songs, {
    bool expandMatchFlows = true,
    bool syncGroupListening = true,
  }) async {
    final normalizedSongs = songs
        .map((song) {
          final id = song.id.trim();
          return id.isEmpty ? null : song.copyWith(id: id);
        })
        .nonNulls
        .toList(growable: false);
    if (normalizedSongs.isEmpty) {
      return;
    }
    await _ensureSongsInDatabase(normalizedSongs);
    final ids = normalizedSongs.map((song) => song.id).toList(growable: false);
    if (syncGroupListening) {
      final insertIndex = _nextGroupListeningInsertIndex();
      final existing = state;
      final nextQueue = <String>[
        ...existing.take(insertIndex),
        ...ids,
        ...existing.skip(insertIndex),
      ];
      if (await _sendGroupListeningQueueReplace(
        nextQueue,
        startIndex: _currentGroupListeningIndex() ?? 0,
        autoPlay: ref.read(audioHandlerProvider)?.snapshot.playing ?? false,
        songs: normalizedSongs,
      )) {
        return;
      }
    }
    final handler = _requireHandler();
    await handler.playNext(ids, expandMatchFlows: expandMatchFlows);
  }

  /// Like [playNext], but accepts a [Song] API model object.
  Future<void> playNextWithSong(
    Song song, {
    bool syncGroupListening = true,
  }) async {
    await _ensureSongsInDatabase(<Song>[song]);
    if (syncGroupListening &&
        await _sendGroupListeningQueueAdd(
          song.id,
          song: song,
          insertIndex: _nextGroupListeningInsertIndex(),
        )) {
      return;
    }
    return playNext(song.id, syncGroupListening: syncGroupListening);
  }

  Future<void> cacheGroupListeningQueueMetadata(
    List<GroupListeningQueueEntry> entries,
  ) async {
    final songs = entries
        .where((entry) => entry.hasMetadata)
        .map(_songFromGroupListeningQueueEntry)
        .toList(growable: false);
    if (songs.isEmpty) {
      return;
    }
    await _ensureSongsInDatabase(songs);
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
  Future<void> _ensureSongsInDatabase(List<Song> songs) async {
    if (songs.isEmpty) return;
    final db = ref.read(navisDatabaseProvider);

    try {
      // 1. Upsert referenced artists (deduplicated).
      final artistEntries = <String, String?>{};
      for (final song in songs) {
        final id = song.artistId?.trim();
        if (id != null && id.isNotEmpty && !artistEntries.containsKey(id)) {
          artistEntries[id] = song.artist;
        }
      }
      if (artistEntries.isNotEmpty) {
        final artistCompanions = artistEntries.entries
            .map(
              (e) => ArtistsTableCompanion.insert(
                id: e.key,
                name: e.value ?? e.key,
              ),
            )
            .toList(growable: false);
        await db.libraryDao.upsertArtists(artistCompanions);
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
              ),
            )
            .toList(growable: false);
        await db.libraryDao.upsertAlbums(albumCompanions);
      }

      // 3. Upsert the song rows themselves.
      await _upsertSongRows(db, songs);
    } on Object {
      // FK upsert failed (unexpected schema issue, etc.).  Retry with
      // foreign-key columns nulled out so playback still works.
      await _upsertSongRows(db, songs, nullForeignKeys: true);
    }
  }

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
            playCount: Value(song.playCount),
            createdAt: Value(song.created),
            replayGainTrackGain: Value(song.replayGain?.trackGain),
            replayGainAlbumGain: Value(song.replayGain?.albumGain),
            replayGainTrackPeak: Value(song.replayGain?.trackPeak),
            replayGainAlbumPeak: Value(song.replayGain?.albumPeak),
          ),
        )
        .toList(growable: false);
    await db.libraryDao.upsertSongs(companions);
  }

  Song _songFromGroupListeningQueueEntry(GroupListeningQueueEntry entry) {
    final replayGain =
        entry.replayGainTrackGain != null ||
            entry.replayGainAlbumGain != null ||
            entry.replayGainTrackPeak != null ||
            entry.replayGainAlbumPeak != null
        ? ReplayGain(
            trackGain: entry.replayGainTrackGain,
            albumGain: entry.replayGainAlbumGain,
            trackPeak: entry.replayGainTrackPeak,
            albumPeak: entry.replayGainAlbumPeak,
          )
        : null;
    return Song(
      id: entry.songId,
      title: entry.title ?? entry.songId,
      album: entry.album,
      albumId: entry.albumId,
      artist: entry.artist,
      artistId: entry.artistId,
      track: entry.track,
      discNumber: entry.discNumber,
      year: entry.year,
      duration: entry.durationSeconds,
      bitRate: entry.bitRate,
      sampleRate: entry.sampleRate,
      contentType: entry.contentType,
      suffix: entry.suffix,
      size: entry.size,
      coverArt: entry.coverArt,
      replayGain: replayGain,
    );
  }

  Future<void> reorder(
    int oldIndex,
    int newIndex, {
    bool syncGroupListening = true,
  }) async {
    if (syncGroupListening) {
      final nextQueue = List<String>.of(state);
      if (oldIndex >= 0 &&
          oldIndex < nextQueue.length &&
          newIndex >= 0 &&
          newIndex <= nextQueue.length) {
        final songId = nextQueue.removeAt(oldIndex);
        final adjustedIndex = (newIndex > oldIndex ? newIndex - 1 : newIndex)
            .clamp(0, nextQueue.length);
        nextQueue.insert(adjustedIndex, songId);
        if (await _sendGroupListeningQueueReplace(
          nextQueue,
          startIndex: _currentGroupListeningIndex() ?? 0,
          autoPlay: ref.read(audioHandlerProvider)?.snapshot.playing ?? false,
        )) {
          return;
        }
      }
    }
    final handler = _requireHandler();
    await handler.reorderQueue(oldIndex, newIndex);
  }

  Future<void> removeAt(int index, {bool syncGroupListening = true}) async {
    if (syncGroupListening && await _sendGroupListeningQueueRemoveAt(index)) {
      return;
    }
    final handler = _requireHandler();
    await handler.removeAt(index);
  }

  Future<void> playFromIndex(int index) async {
    final handler = _requireHandler();
    await handler.playFromIndex(index);
  }

  Future<void> clear({bool syncGroupListening = true}) async {
    final handler = _requireHandler();
    if (syncGroupListening &&
        await _sendGroupListeningQueueReplace(
          const <String>[],
          startIndex: 0,
          autoPlay: false,
        )) {
      return;
    }
    await handler.clearQueue();
    final settings =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    if (settings.playbackSpeed == 1) {
      return;
    }
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(playbackSpeed: 1),
        );
    await handler.applyRuntimeSettings();
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

  bool _canSyncGroupListeningQueue(GroupListeningSessionState session) {
    final room = session.room;
    final configuration = session.configuration;
    return room != null &&
        configuration != null &&
        session.availability == GroupListeningAvailability.ready &&
        session.connection.isConnected &&
        !session.snapshotRequired &&
        room.roomStatus == GroupListeningRoomStatus.active &&
        room.self.canControl &&
        room.sourceServerFingerprint == configuration.sourceServerFingerprint;
  }

  int? _currentGroupListeningIndex() {
    final session = ref.read(groupListeningSessionControllerProvider);
    return session.room?.queue.currentIndex;
  }

  int _nextGroupListeningInsertIndex() {
    final session = ref.read(groupListeningSessionControllerProvider);
    final room = session.room;
    if (room == null) {
      return state.length;
    }
    final currentIndex = room.queue.currentIndex;
    if (currentIndex == null || currentIndex < 0) {
      return room.queue.entries.length;
    }
    return (currentIndex + 1).clamp(0, room.queue.entries.length);
  }

  Future<bool> _sendGroupListeningQueueAdd(
    String songId, {
    Song? song,
    int? insertIndex,
  }) async {
    final session = ref.read(groupListeningSessionControllerProvider);
    if (!_canSyncGroupListeningQueue(session)) {
      return false;
    }
    final room = session.room!;
    final entry = _queueEntryForSong(
      songId: songId,
      room: room,
      song: song,
    );
    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .sendMutation(
          type: GroupListeningMutationType.queueAdd,
          queue: GroupListeningQueueState(
            queueVersion: room.queue.queueVersion,
            currentIndex: room.queue.currentIndex,
            entries: <GroupListeningQueueEntry>[entry],
          ),
          targetQueueEntryId: entry.queueEntryId,
          insertIndex: insertIndex,
        );
    return mutationId != null && mutationId.isNotEmpty;
  }

  GroupListeningQueueEntry _queueEntryForSong({
    required String songId,
    required GroupListeningRoomState room,
    Song? song,
  }) {
    return GroupListeningQueueEntry(
      queueEntryId: _uuid.v4(),
      songId: songId,
      addedByMemberId: room.self.memberId,
      addedAt: DateTime.now(),
      title: song?.title,
      artist: song?.artist,
      artistId: song?.artistId,
      album: song?.album,
      albumId: song?.albumId,
      durationSeconds: song?.duration,
      track: song?.track,
      discNumber: song?.discNumber,
      year: song?.year,
      coverArt: song?.coverArt,
      contentType: song?.contentType,
      suffix: song?.suffix,
      bitRate: song?.bitRate,
      sampleRate: song?.sampleRate,
      size: song?.size,
      replayGainTrackGain: song?.replayGain?.trackGain,
      replayGainAlbumGain: song?.replayGain?.albumGain,
      replayGainTrackPeak: song?.replayGain?.trackPeak,
      replayGainAlbumPeak: song?.replayGain?.albumPeak,
    );
  }

  Future<bool> _sendGroupListeningQueueRemoveAt(int index) async {
    final session = ref.read(groupListeningSessionControllerProvider);
    if (!_canSyncGroupListeningQueue(session)) {
      return false;
    }
    final entries = session.room!.queue.entries;
    if (index < 0 || index >= entries.length) {
      return false;
    }
    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .sendMutation(
          type: GroupListeningMutationType.queueRemove,
          targetQueueEntryId: entries[index].queueEntryId,
        );
    return mutationId != null && mutationId.isNotEmpty;
  }

  Future<bool> _sendGroupListeningQueueReplace(
    Iterable<String> ids, {
    required int startIndex,
    required bool autoPlay,
    List<Song> songs = const <Song>[],
  }) async {
    final session = ref.read(groupListeningSessionControllerProvider);
    if (!_canSyncGroupListeningQueue(session)) {
      return false;
    }

    final normalized = _normalizeSongIds(ids);
    final room = session.room!;
    final currentIndex = normalized.isEmpty
        ? null
        : startIndex.clamp(0, normalized.length - 1);
    final queue = GroupListeningQueueState(
      queueVersion: room.queue.queueVersion,
      currentIndex: currentIndex,
      entries: _queueEntriesForIds(room, normalized, songs),
    );
    final anchor = _playbackAnchorForQueueReplace(
      session: session,
      queue: queue,
      autoPlay: autoPlay,
    );
    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .sendMutation(
          type: GroupListeningMutationType.queueReplace,
          queue: queue,
          playbackAnchor: anchor,
        );
    return mutationId != null && mutationId.isNotEmpty;
  }

  List<GroupListeningQueueEntry> _queueEntriesForIds(
    GroupListeningRoomState room,
    List<String> ids,
    List<Song> songs,
  ) {
    final existingEntriesBySongId =
        <String, ListQueue<GroupListeningQueueEntry>>{};
    for (final entry in room.queue.entries) {
      existingEntriesBySongId
          .putIfAbsent(entry.songId, ListQueue<GroupListeningQueueEntry>.new)
          .add(entry);
    }
    final songsById = <String, ListQueue<Song>>{};
    for (final song in songs) {
      songsById.putIfAbsent(song.id, ListQueue<Song>.new).add(song);
    }

    final now = DateTime.now();
    return ids
        .map((songId) {
          final existingEntries = existingEntriesBySongId[songId];
          if (existingEntries != null && existingEntries.isNotEmpty) {
            return existingEntries.removeFirst();
          }
          final songQueue = songsById[songId];
          final song = songQueue != null && songQueue.isNotEmpty
              ? songQueue.removeFirst()
              : null;
          return GroupListeningQueueEntry(
            queueEntryId: _uuid.v4(),
            songId: songId,
            addedByMemberId: room.self.memberId,
            addedAt: now,
            title: song?.title,
            artist: song?.artist,
            artistId: song?.artistId,
            album: song?.album,
            albumId: song?.albumId,
            durationSeconds: song?.duration,
            track: song?.track,
            discNumber: song?.discNumber,
            year: song?.year,
            coverArt: song?.coverArt,
            contentType: song?.contentType,
            suffix: song?.suffix,
            bitRate: song?.bitRate,
            sampleRate: song?.sampleRate,
            size: song?.size,
            replayGainTrackGain: song?.replayGain?.trackGain,
            replayGainAlbumGain: song?.replayGain?.albumGain,
            replayGainTrackPeak: song?.replayGain?.trackPeak,
            replayGainAlbumPeak: song?.replayGain?.albumPeak,
          );
        })
        .toList(growable: false);
  }

  GroupListeningPlaybackAnchor? _playbackAnchorForQueueReplace({
    required GroupListeningSessionState session,
    required GroupListeningQueueState queue,
    required bool autoPlay,
  }) {
    if (queue.entries.isEmpty) {
      return null;
    }
    final handler = ref.read(audioHandlerProvider);
    final snapshot = handler?.snapshot;
    final settings =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final currentEntry = queue.currentEntry;
    final position = currentEntry?.songId == snapshot?.currentSongId
        ? snapshot?.position ?? Duration.zero
        : Duration.zero;
    return GroupListeningPlaybackAnchor(
      roomVersion: session.lastAppliedRoomVersion,
      queueVersion: queue.queueVersion,
      currentIndex: queue.currentIndex,
      currentQueueEntryId: currentEntry?.queueEntryId,
      currentSongId: currentEntry?.songId,
      playbackState: autoPlay || (snapshot?.playing ?? false)
          ? GroupListeningPlaybackStatus.playing
          : GroupListeningPlaybackStatus.paused,
      position: position,
      capturedAt: DateTime.now(),
      playbackRate: settings.playbackSpeed,
      reason: GroupListeningPlaybackAnchorReason.trackChange,
      issuedByMemberId: session.room?.self.memberId,
      issuedByConnectionId: session.connection.clientConnectionId,
    );
  }

  void _emitError(Object error, {String? action}) {
    if (error is OperationCancelledException) return;
    AppLogger.warning('Playback action error (action=$action): $error');
    ref
        .read(_playbackActionErrorControllerProvider)
        .add(PlaybackActionError(error: error, action: action));
  }

  /// Fire-and-forget wrapper: runs [action] and routes errors to
  /// [playbackActionErrorProvider] instead of throwing.
  void fireAndForget(
    Future<void> Function() action, {
    String? label,
  }) {
    unawaited(
      Future<void>(() async {
        try {
          await action();
        } on OperationCancelledException {
          // Superseded — not an error.
        } on Object catch (error) {
          _emitError(error, action: label);
        }
      }),
    );
  }
}

final queueProvider = NotifierProvider<QueueController, List<String>>(
  QueueController.new,
);

final playNextProvider = Provider<Future<void> Function(String)>((ref) {
  return (songId) => ref.read(queueProvider.notifier).playNext(songId);
});

final reorderQueueProvider = Provider<Future<void> Function(int, int)>((ref) {
  return (oldIndex, newIndex) =>
      ref.read(queueProvider.notifier).reorder(oldIndex, newIndex);
});
