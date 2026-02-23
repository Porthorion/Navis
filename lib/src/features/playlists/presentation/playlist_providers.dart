import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Watches the local playlist list (synced from server).
final playlistListProvider =
    StreamProvider.autoDispose<List<PlaylistsTableData>>((ref) {
  final db = ref.watch(navisDatabaseProvider);
  return db.playlistDao.watchPlaylists();
});

/// Fetches playlist data from the server and stores it locally.
/// Returns the list of playlists after sync.
final playlistSyncProvider = FutureProvider.autoDispose<void>((ref) async {
  final api = ref.read(subsonicApiProvider);
  final db = ref.read(navisDatabaseProvider);
  if (api == null) return;

  final playlists = await api.getPlaylists();
  final companions = playlists
      .map(
        (p) => PlaylistsTableCompanion.insert(
          id: p.id,
          name: p.name,
          songCount: Value(p.songCount),
          duration: Value(p.duration),
          owner: Value(p.owner),
          isPublic: Value(p.isPublic),
          coverArt: Value(p.coverArt),
          comment: Value(p.comment),
        ),
      )
      .toList(growable: false);
  await db.playlistDao.upsertPlaylists(companions);
});

/// Family provider: fetches a single playlist's songs from the server
/// and stores them locally. Returns the playlist metadata + song list.
final playlistDetailSyncProvider =
    FutureProvider.autoDispose.family<void, String>((ref, playlistId) async {
  final api = ref.read(subsonicApiProvider);
  final db = ref.read(navisDatabaseProvider);
  if (api == null) return;

  final playlist = await api.getPlaylist(playlistId);

  // Upsert the playlist metadata
  await db.playlistDao.upsertPlaylists([
    PlaylistsTableCompanion.insert(
      id: playlist.id,
      name: playlist.name,
      songCount: Value(playlist.songCount),
      duration: Value(playlist.duration),
      owner: Value(playlist.owner),
      isPublic: Value(playlist.isPublic),
      coverArt: Value(playlist.coverArt),
      comment: Value(playlist.comment),
    ),
  ]);

  // Upsert song rows from entries
  if (playlist.entries.isNotEmpty) {
    final songCompanions = playlist.entries
        .map(
          (song) => SongsTableCompanion.insert(
            id: song.id,
            title: song.title,
            albumId: Value(song.albumId),
            artistId: Value(song.artistId),
            artistName: Value(song.artist),
            albumName: Value(song.album),
            track: Value(song.track),
            discNumber: Value(song.discNumber),
            duration: Value(song.duration),
            bitRate: Value(song.bitRate),
            contentType: Value(song.contentType),
            suffix: Value(song.suffix),
            size: Value(song.size),
            coverArt: Value(song.coverArt),
            starred: Value(song.starred),
            playCount: Value(song.playCount),
            createdAt: Value(song.created),
          ),
        )
        .toList(growable: false);
    await db.libraryDao.upsertSongs(songCompanions);
  }

  // Replace the playlist_songs join table
  final songJoins = <PlaylistSongsTableCompanion>[];
  for (var i = 0; i < playlist.entries.length; i++) {
    songJoins.add(
      PlaylistSongsTableCompanion.insert(
        playlistId: playlistId,
        songId: playlist.entries[i].id,
        sortOrder: i,
      ),
    );
  }
  await db.playlistDao.replacePlaylistSongs(playlistId, songJoins);
});

/// Watches songs for a given playlist from the local DB.
final playlistSongsProvider =
    StreamProvider.autoDispose.family<List<SongsTableData>, String>((
  ref,
  playlistId,
) {
  final db = ref.watch(navisDatabaseProvider);
  return db.playlistDao.watchPlaylistSongs(playlistId);
});

/// Watches a single playlist's metadata.
final playlistByIdProvider =
    StreamProvider.autoDispose.family<PlaylistsTableData?, String>((
  ref,
  playlistId,
) {
  final db = ref.watch(navisDatabaseProvider);
  final query = db.select(db.playlistsTable)
    ..where((t) => t.id.equals(playlistId));
  return query.watchSingleOrNull();
});
