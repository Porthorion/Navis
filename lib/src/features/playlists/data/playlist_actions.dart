import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

/// Device and server playlist mutations; failures propagate to the caller.
class PlaylistActions {
  new(this._ref);

  final Ref _ref;

  final _uploads = <String, Future<String?>>{};

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

  /// Moves device playlist [localId] to the server and returns the new server
  /// id (null when the server did not report one). The device playlist is
  /// deleted only after the server create succeeded; a failure leaves it as
  /// it was. Concurrent calls for one playlist share a single create.
  Future<String?> uploadToServer(String localId) => _uploads.putIfAbsent(
    localId,
    () => _upload(localId).whenComplete(() {
      // A block body: returning the removed future would make it await itself.
      _uploads.remove(localId);
    }),
  );

  Future<String?> _upload(String localId) async {
    final api = _serverApi();
    final dao = _ref.read(navisDatabaseProvider).playlistDao;
    final local = await dao.watchPlaylistById(localId).first;
    if (local == null || !local.isLocal) {
      throw StateError('Only device playlists can be saved on the server.');
    }
    final songIds = [
      for (final song in await dao.watchPlaylistSongs(localId).first) song.id,
    ];
    final created = await api.createPlaylist(local.name, songIds: songIds);
    // The client's fallback id when the server returned no playlist body.
    final reported = created.id != 'created';
    if (reported) {
      await dao.replaceLocalWithServer(
        localId,
        PlaylistsTableCompanion.insert(
          id: created.id,
          name: created.name,
          songCount: Value(created.songCount ?? local.songCount),
          duration: Value(created.duration ?? local.duration),
          owner: Value(created.owner),
          isPublic: Value(created.isPublic),
          readOnly: Value(created.readOnly),
          coverArt: Value(created.coverArt ?? local.coverArt),
          comment: Value(created.comment),
        ),
      );
    } else {
      await dao.deletePlaylist(localId);
    }
    if (!_ref.mounted) return reported ? created.id : null;
    if (reported) {
      _ref
          .read(playlistMovedToServerProvider.notifier)
          .moved(localId, created.id);
    }
    _ref.invalidate(playlistSyncProvider);
    return reported ? created.id : null;
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
