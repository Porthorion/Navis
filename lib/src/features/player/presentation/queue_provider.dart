import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

final currentQueueSongIdProvider = Provider<String?>((ref) {
  return ref.watch(currentSongProvider);
});

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
  }) async {
    final handler = _requireHandler();
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
    );
  }

  Future<void> add(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final handler = _requireHandler();
    await handler.addToQueue(<String>[normalizedId]);
  }

  Future<void> playNext(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
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
  }) async {
    if (songs.isEmpty) {
      final handler = _requireHandler();
      await handler.clearQueue();
      return;
    }
    await _ensureSongsInDatabase(songs);
    await replace(
      songs.map((s) => s.id).toList(),
      startIndex: startIndex,
      autoPlay: autoPlay,
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
  Future<void> addWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return add(song.id);
  }

  /// Like [add], but accepts multiple [Song] API model objects and queues
  /// them in one call after persisting all rows locally.
  Future<void> addWithSongs(List<Song> songs) async {
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
    await handler.addToQueue(ids);
  }

  /// Like [playNext], but accepts a [Song] API model object.
  Future<void> playNextWithSong(Song song) async {
    await _ensureSongsInDatabase(<Song>[song]);
    return playNext(song.id);
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
