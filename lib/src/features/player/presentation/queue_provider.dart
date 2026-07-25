import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

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

class QueueController extends Notifier<List<String>> {
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
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    final handler = _requireHandler();
    final normalized = _normalizeSongIds(ids);
    if (normalized.isEmpty) {
      await handler.clearQueue();
      _markRegularQueueReplacement(notify: notifyMixSessionReset);
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, normalized.length - 1);
    await handler.replaceQueue(
      normalized,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
    );
    await _ensurePlayingAfterAutoPlay(
      autoPlay: autoPlay,
      songId: normalized[normalizedStartIndex],
    );
    _prewarmLyricsForIds(
      normalized,
      priorityId: normalized[normalizedStartIndex],
    );
    _markRegularQueueReplacement(notify: notifyMixSessionReset);
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
  }) async {
    final handler = _requireHandler();
    if (songs.isEmpty) {
      await handler.clearQueue();
      _markRegularQueueReplacement(notify: notifyMixSessionReset);
      return;
    }
    final normalizedStartIndex = startIndex.clamp(0, songs.length - 1);
    await handler.replaceQueueWithData(
      songs,
      startIndex: normalizedStartIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
    );
    await _ensurePlayingAfterAutoPlay(
      autoPlay: autoPlay,
      songId: songs[normalizedStartIndex].id,
    );
    _prewarmLyricsForIds(
      songs.map((song) => song.id),
      priorityId: songs[normalizedStartIndex].id,
    );
    _markRegularQueueReplacement(notify: notifyMixSessionReset);
  }

  Future<void> add(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(<String>[normalizedId]);
    _prewarmLyricsForIds(<String>[normalizedId]);
  }

  Future<void> playNext(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.playNext(<String>[normalizedId]);
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
  }) async {
    if (songs.isEmpty) {
      final handler = _requireHandler();
      await handler.clearQueue();
      _markRegularQueueReplacement(notify: notifyMixSessionReset);
      return;
    }
    await _ensureSongsInDatabase(songs);
    final ids = songs.map((s) => s.id).toList(growable: false);
    final db = ref.read(navisDatabaseProvider);
    final persistedSongs = await db.libraryDao.getSongsByIds(ids);
    if (persistedSongs.length == ids.length) {
      await replaceWithTableData(
        persistedSongs,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: expandMatchFlows,
        notifyMixSessionReset: notifyMixSessionReset,
      );
      return;
    }
    await replace(
      ids,
      startIndex: startIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
      notifyMixSessionReset: notifyMixSessionReset,
    );
  }

  /// Like [add], but accepts a [Song] API model object.
  Future<void> addWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return add(song.id);
  }

  /// Like [add], but accepts multiple [Song] API model objects and queues
  /// them in one call after persisting all rows locally.
  Future<void> addWithSongs(
    List<Song> songs, {
    bool expandMatchFlows = true,
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
    final handler = _requireHandler();
    await handler.addToQueue(ids, expandMatchFlows: expandMatchFlows);
    _prewarmLyricsForIds(ids);
  }

  /// Like [playNext], but accepts multiple [Song] API model objects and
  /// inserts them after the current item in one call after persisting all rows
  /// locally.
  Future<void> playNextWithSongs(
    List<Song> songs, {
    bool expandMatchFlows = true,
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
    final handler = _requireHandler();
    await handler.playNext(ids, expandMatchFlows: expandMatchFlows);
    _prewarmLyricsForIds(ids);
  }

  /// Like [playNext], but accepts a [Song] API model object.
  Future<void> playNextWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return playNext(song.id);
  }

  /// Persists [Song] rows locally so [NavisAudioHandler] can resolve them.
  Future<void> persistSongsForPlayback(List<Song> songs) async {
    await _ensureSongsInDatabase(songs);
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

  /// Appends mix/refill tracks to the bottom of the queue. Persists metadata
  /// first, then delegates to the audio handler.
  Future<int> appendMixTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
  }) async {
    final normalizedSongs = songs
        .map((song) {
          final id = song.id.trim();
          return id.isEmpty ? null : song.copyWith(id: id);
        })
        .nonNulls
        .toList(growable: false);
    if (normalizedSongs.isEmpty) {
      return 0;
    }
    await _ensureSongsInDatabase(normalizedSongs);
    final ids = normalizedSongs.map((song) => song.id).toList(growable: false);
    final handler = _requireHandler();
    final before = handler.snapshot.queueSongIds;
    await handler.addToQueue(ids, expandMatchFlows: expandMatchFlows);
    _prewarmLyricsForIds(ids);
    final after = handler.snapshot.queueSongIds;
    final inserted = _countInsertedSongIds(before: before, after: after);
    return inserted > 0 ? inserted : normalizedSongs.length;
  }

  void _markRegularQueueReplacement({required bool notify}) {
    if (!notify) {
      return;
    }
    ref.read(regularQueueReplacementEpochProvider.notifier).bump();
  }

  int _countInsertedSongIds({
    required List<String> before,
    required List<String> after,
  }) {
    final beforeCounts = <String, int>{};
    for (final id in before) {
      beforeCounts[id] = (beforeCounts[id] ?? 0) + 1;
    }
    var inserted = 0;
    for (final id in after) {
      final remaining = beforeCounts[id] ?? 0;
      if (remaining > 0) {
        beforeCounts[id] = remaining - 1;
      } else {
        inserted++;
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
            replayGainTrackGain: Value(song.replayGain?.trackGain),
            replayGainAlbumGain: Value(song.replayGain?.albumGain),
            replayGainTrackPeak: Value(song.replayGain?.trackPeak),
            replayGainAlbumPeak: Value(song.replayGain?.albumPeak),
          ),
        )
        .toList(growable: false);
    await db.libraryDao.upsertProvisionalSongs(companions);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final handler = _requireHandler();
    await handler.reorderQueue(oldIndex, newIndex);
  }

  Future<void> removeAt(int index) async {
    final handler = _requireHandler();
    await handler.removeAt(index);
  }

  Future<void> playFromIndex(int index) async {
    final handler = _requireHandler();
    await handler.playFromIndex(index);
  }

  Future<void> clear() async {
    final handler = _requireHandler();
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

  Future<void> _ensurePlayingAfterAutoPlay({
    required bool autoPlay,
    String? songId,
  }) async {
    if (!autoPlay) {
      return;
    }
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) {
      return;
    }
    final normalized = songId?.trim() ?? '';
    if (normalized.isNotEmpty && !isServerAddressableSongId(normalized)) {
      await handler.play();
      return;
    }
    if (!handler.snapshot.playing) {
      await handler.play();
    }
  }

  void _prewarmLyricsForIds(
    Iterable<String> ids, {
    String? priorityId,
  }) {
    final normalized = _normalizeSongIds(ids);
    if (normalized.isEmpty) {
      return;
    }
    final priority = priorityId?.trim();
    final ordered = <String>[
      if (priority != null && priority.isNotEmpty) priority,
      ...normalized.where((id) => id != priority),
    ];
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
