import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

/// Server playlist mutations. Failures propagate for callers to show a notice.
class PlaylistActions {
  new(this._ref);

  final Ref _ref;

  SubsonicApiClient _serverApi(PlaylistsTableData playlist) {
    if (playlist.isLocal) {
      throw UnsupportedError(
        'Device playlist actions are not implemented yet.',
      );
    }
    final api = _ref.read(subsonicApiProvider);
    if (api == null) throw StateError('The server is unavailable.');
    return api;
  }

  Future<void> rename(PlaylistsTableData playlist, String name) async {
    await _serverApi(playlist).updatePlaylist(id: playlist.id, name: name);
    if (_ref.mounted) _ref.invalidate(playlistSyncProvider);
  }

  Future<void> delete(PlaylistsTableData playlist) async {
    await _serverApi(playlist).deletePlaylist(playlist.id);
    if (_ref.mounted) _ref.invalidate(playlistSyncProvider);
  }

  /// Returns the number of skipped songs (zero for server playlists).
  Future<int> addSongs(
    PlaylistsTableData playlist,
    List<String> songIds,
  ) async {
    await _serverApi(playlist)
        .updatePlaylist(id: playlist.id, songIdsToAdd: songIds);
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
    await _serverApi(playlist)
        .updatePlaylist(id: playlist.id, songIndexesToRemove: [index]);
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
    final api = _serverApi(playlist);
    final reordered = currentIds.toList();
    final songId = reordered.removeAt(from);
    reordered.insert(to, songId);
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
