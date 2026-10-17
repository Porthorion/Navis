import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/server_create_recovery.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/library_sync_response_validation.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

typedef PlaylistUploadResult = ({
  String serverId,
  bool deviceCopyKept,
  int kept,
  int total,
});
typedef _UploadSnapshot = ({String name, List<String> songIds});

final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

/// Device and server playlist mutations; failures propagate to the caller.
class PlaylistActions {
  new(this._ref);

  final Ref _ref;

  final _uploads = <String, Future<PlaylistUploadResult>>{};
  final _createRecovery = ServerCreateRecovery<_UploadSnapshot>();

  SubsonicApiClient _serverApi() {
    final api = _ref.read(subsonicApiProvider);
    if (api == null) throw StateError('The server is unavailable.');
    return api;
  }

  String _validatedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty');
    }
    return trimmed;
  }

  Future<String> create(
    String name,
    List<String> songIds, {
    required bool onServer,
  }) async {
    final trimmed = _validatedName(name);
    if (!onServer) {
      return await _ref
          .read(navisDatabaseProvider)
          .playlistDao
          .createLocalPlaylist(trimmed, songIds);
    }
    final playlist = await _serverApi().createPlaylist(
      trimmed,
      songIds: songIds,
    );
    if (_ref.mounted) _ref.invalidate(playlistSyncProvider);
    return playlist.id;
  }

  /// Uploads a device snapshot, preserving concurrent edits and reporting the
  /// server's accepted song count. Concurrent calls share the entire move.
  Future<PlaylistUploadResult> uploadToServer(String localId) =>
      _uploads.putIfAbsent(
        localId,
        () => _upload(localId).whenComplete(() {
          unawaited(_uploads.remove(localId));
        }),
      );

  Future<PlaylistUploadResult> _upload(String localId) async {
    final api = _serverApi();
    final db = _ref.read(navisDatabaseProvider);
    final dao = db.playlistDao;
    final snapshot = await db.transaction(() async {
      final local = await dao.watchPlaylistById(localId).first;
      if (local == null || !local.isLocal) {
        throw StateError('Only device playlists can be saved on the server.');
      }
      return (
        name: local.name,
        songIds: [
          for (final song in await dao.watchPlaylistSongs(localId).first)
            song.id,
        ],
      );
    });
    final resolved = await _createRecovery.run(
      localId,
      snapshot: snapshot,
      name: snapshot.name,
      list: () async => [
        for (final row in await api.getPlaylists())
          (id: row.id, name: row.name),
      ],
      create: () async {
        final created = await api.createPlaylist(
          snapshot.name,
          songIds: snapshot.songIds,
        );
        return created.id == 'created' || created.id.isEmpty
            ? null
            : created.id;
      },
    );
    final actual = await api.getPlaylist(resolved.id);
    validatePlaylistSnapshot(actual, requestedId: resolved.id);
    final keptDevice = await dao.replaceLocalWithServer(
      localId,
      PlaylistsTableCompanion.insert(
        id: actual.id,
        name: actual.name,
        songCount: Value(actual.entries.length),
        duration: Value(actual.duration),
        owner: Value(actual.owner),
        isPublic: Value(actual.isPublic),
        readOnly: Value(actual.readOnly),
        coverArt: Value(actual.coverArt),
        comment: Value(actual.comment),
      ),
      uploadedName: resolved.snapshot.name,
      uploadedSongIds: resolved.snapshot.songIds,
      songs: [
        for (final song in actual.entries)
          SongsTableCompanion.insert(
            id: song.id,
            title: song.title,
            duration: Value.absentIfNull(song.duration),
            coverArt: Value.absentIfNull(song.coverArt),
          ),
      ],
      serverSongIds: actual.entries.map((song) => song.id).toList(),
    );
    _createRecovery.complete(localId);
    if (_ref.mounted) {
      if (!keptDevice) {
        _ref
            .read(playlistMovedToServerProvider.notifier)
            .moved(localId, actual.id);
      }
      _ref.invalidate(playlistSyncProvider);
    }
    return (
      serverId: actual.id,
      deviceCopyKept: keptDevice,
      kept: actual.entries.length,
      total: resolved.snapshot.songIds.length,
    );
  }

  Future<void> rename(PlaylistsTableData playlist, String name) async {
    final trimmed = _validatedName(name);
    if (playlist.isLocal) {
      await _ref
          .read(navisDatabaseProvider)
          .playlistDao
          .renamePlaylist(playlist.id, trimmed);
      return;
    }
    await _serverApi().updatePlaylist(id: playlist.id, name: trimmed);
    if (_ref.mounted) _ref.invalidate(playlistSyncProvider);
  }

  Future<void> delete(PlaylistsTableData playlist) async {
    if (playlist.isLocal) {
      await _ref
          .read(navisDatabaseProvider)
          .playlistDao
          .deletePlaylist(playlist.id);
      return;
    }
    await _serverApi().deletePlaylist(playlist.id);
    if (_ref.mounted) _ref.invalidate(playlistSyncProvider);
  }

  /// Returns the number of skipped songs (zero for server playlists).
  Future<int> addSongs(
    PlaylistsTableData playlist,
    List<String> songIds,
  ) async {
    if (playlist.isLocal) {
      final db = _ref.read(navisDatabaseProvider);
      return await db.transaction(() async {
        final current = await db.playlistDao
            .watchPlaylistSongs(playlist.id)
            .first;
        return await db.playlistDao.setLocalPlaylistSongs(playlist.id, [
          ...current.map((song) => song.id),
          ...songIds,
        ]);
      });
    }
    await _serverApi().updatePlaylist(id: playlist.id, songIdsToAdd: songIds);
    if (_ref.mounted) {
      _ref.invalidate(playlistDetailSyncProvider(playlist.id));
      _ref.invalidate(playlistSyncProvider);
    }
    return 0;
  }

  Future<void> removeAt(
    PlaylistsTableData playlist,
    List<String> currentIds,
    int index,
  ) async {
    if (playlist.isLocal) {
      final ids = currentIds.toList()..removeAt(index);
      await _ref
          .read(navisDatabaseProvider)
          .playlistDao
          .setLocalPlaylistSongs(playlist.id, ids);
      return;
    }
    await _serverApi().updatePlaylist(
      id: playlist.id,
      songIndexesToRemove: [index],
    );
    if (_ref.mounted) {
      _ref.invalidate(playlistDetailSyncProvider(playlist.id));
    }
  }

  Future<void> reorder(
    PlaylistsTableData playlist,
    List<String> currentIds,
    int from,
    int to,
  ) async {
    if (from == to) return;
    final reordered = currentIds.toList();
    final songId = reordered.removeAt(from);
    reordered.insert(to, songId);
    if (playlist.isLocal) {
      await _ref
          .read(navisDatabaseProvider)
          .playlistDao
          .setLocalPlaylistSongs(playlist.id, reordered);
      return;
    }
    final api = _serverApi();
    try {
      await api.replacePlaylistSongs(
        playlistId: playlist.id,
        songIds: reordered,
      );
    } finally {
      // Refresh on failure too, reverting the detail screen's optimistic order.
      if (_ref.mounted) {
        _ref.invalidate(playlistDetailSyncProvider(playlist.id));
      }
    }
  }
}
