import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/server_create_recovery.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/library_sync_response_validation.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

typedef PlaylistUploadResult = ({
  String serverId,
  bool deviceCopyKept,
  int kept,
  int total,
});

/// Songs [PlaylistActions.addSongs] added, skipped because the playlist already
/// had them (or the picked list repeated them) and could not add.
typedef PlaylistAddResult = ({int added, int alreadyThere, int failed});
typedef _UploadSnapshot = ({String name, List<String> songIds});

final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

/// Device and server playlist mutations; failures propagate to the caller.
class PlaylistActions {
  new(this._ref);

  final Ref _ref;

  final _uploads = <String, Future<PlaylistUploadResult>>{};
  final _edits = <String, Future<Object?>>{};
  final _createRecovery = ServerCreateRecovery<_UploadSnapshot>();
  final _keptUploads = <String>{};

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
    var uploadedSnapshot = resolved.snapshot;
    if (_keptUploads.contains(localId)) {
      final current = await api.getPlaylist(resolved.id);
      validatePlaylistSnapshot(current, requestedId: resolved.id);
      await api.updatePlaylist(
        id: resolved.id,
        name: snapshot.name,
        songIndexesToRemove: List.generate(current.entries.length, (i) => i),
        songIdsToAdd: snapshot.songIds,
      );
      uploadedSnapshot = snapshot;
    }
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
      uploadedName: uploadedSnapshot.name,
      uploadedSongIds: uploadedSnapshot.songIds,
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
    if (keptDevice) {
      _keptUploads.add(localId);
    } else {
      _keptUploads.remove(localId);
      _createRecovery.complete(localId);
    }
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
      total: uploadedSnapshot.songIds.length,
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

  /// Adds the songs the playlist does not hold yet, in the picked order; a
  /// repeated or present id counts as `alreadyThere`. `failed` counts songs
  /// that did not land (local: unknown ids; server: still missing after a
  /// read-back).
  Future<PlaylistAddResult> addSongs(
    PlaylistsTableData playlist,
    List<String> songIds,
  ) async {
    if (playlist.isLocal) {
      final db = _ref.read(navisDatabaseProvider);
      return await db.transaction(() async {
        final current = [
          for (final song
              in await db.playlistDao.watchPlaylistSongs(playlist.id).first)
            song.id,
        ];
        final fresh = _newIds(songIds, current);
        final failed = await db.playlistDao.setLocalPlaylistSongs(playlist.id, [
          ...current,
          ...fresh,
        ]);
        return (
          added: fresh.length - failed,
          alreadyThere: songIds.length - fresh.length,
          failed: failed,
        );
      });
    }
    final api = _serverApi();
    try {
      return await _edit(
        playlist.id,
        () => _addToServer(api, playlist.id, songIds),
      );
    } finally {
      if (_ref.mounted) {
        _ref.invalidate(playlistDetailSyncProvider(playlist.id));
        _ref.invalidate(playlistSyncProvider);
      }
    }
  }

  /// Runs one server edit of a playlist at a time (add, remove, reorder): a
  /// second waits for the first, whether or not it failed.
  Future<T> _edit<T>(String id, Future<T> Function() run) {
    final previous = _edits[id];
    final task =
        (previous?.then<void>((_) {}, onError: (_) {}) ?? Future<void>.value())
            .then((_) => run());
    _edits[id] = task;
    return task.whenComplete(() {
      if (identical(_edits[id], task)) unawaited(_edits.remove(id));
    });
  }

  /// [picked] without repeats and without anything in [present], in order.
  List<String> _newIds(List<String> picked, List<String> present) {
    final seen = present.toSet();
    return [
      for (final id in picked)
        if (seen.add(id)) id,
    ];
  }

  Future<PlaylistAddResult> _addToServer(
    SubsonicApiClient api,
    String id,
    List<String> picked,
  ) async {
    final before = await _entryIds(api, id);
    final songIds = _newIds(picked, before);
    final alreadyThere = picked.length - songIds.length;
    if (songIds.isEmpty) {
      return (added: 0, alreadyThere: alreadyThere, failed: 0);
    }
    // Navidrome 0.64 answers ok to a multi-id add but adds nothing, so the
    // result is verified and what is missing is re-added one id per request.
    // A failed request leaves its ids missing; the read-backs decide.
    try {
      await api.updatePlaylist(id: id, songIdsToAdd: songIds);
    } on Object {
      // Counted as missing below.
    }
    var missing = _missing(songIds, before, await _entryIds(api, id));
    if (missing.isEmpty) {
      return (added: songIds.length, alreadyThere: alreadyThere, failed: 0);
    }
    for (final song in missing) {
      try {
        await api.updatePlaylist(id: id, songIdsToAdd: [song]);
      } on Object {
        // Counted as missing below.
      }
    }
    missing = _missing(songIds, before, await _entryIds(api, id));
    return (
      added: songIds.length - missing.length,
      alreadyThere: alreadyThere,
      failed: missing.length,
    );
  }

  /// The playlist's song ids on the server; throws when the read is
  /// inconclusive (the entry list does not match the reported song count).
  Future<List<String>> _entryIds(SubsonicApiClient api, String id) async {
    final playlist = await api.getPlaylist(id);
    final count = playlist.songCount;
    if (count != null && count != playlist.entries.length) {
      throw StateError('Playlist read-back is incomplete');
    }
    return [for (final song in playlist.entries) song.id];
  }

  /// [wanted] minus the ids that [after] gained over [before], as a multiset.
  List<String> _missing(
    List<String> wanted,
    List<String> before,
    List<String> after,
  ) {
    final gained = <String, int>{};
    for (final id in after) {
      gained[id] = (gained[id] ?? 0) + 1;
    }
    for (final id in before) {
      gained[id] = (gained[id] ?? 0) - 1;
    }
    final missing = <String>[];
    for (final id in wanted) {
      final left = gained[id] ?? 0;
      if (left > 0) {
        gained[id] = left - 1;
      } else {
        missing.add(id);
      }
    }
    return missing;
  }

  /// Removes one occurrence of [songId]: the [occurrence]-th (0-based) entry
  /// with that id in the list the caller saw, or the last one if the playlist
  /// now has fewer. Never removes by position, so a list that moved under the
  /// caller cannot take another song; a song already gone removes nothing.
  Future<void> removeAt(
    PlaylistsTableData playlist, {
    required String songId,
    required int occurrence,
  }) async {
    if (playlist.isLocal) {
      final db = _ref.read(navisDatabaseProvider);
      await db.transaction(() async {
        final ids = [
          for (final song
              in await db.playlistDao.watchPlaylistSongs(playlist.id).first)
            song.id,
        ];
        final at = _occurrenceIndex(ids, songId, occurrence);
        if (at < 0) return;
        await db.playlistDao.setLocalPlaylistSongs(
          playlist.id,
          ids..removeAt(at),
        );
      });
      return;
    }
    final api = _serverApi();
    await _edit(playlist.id, () async {
      final ids = await _entryIds(api, playlist.id);
      final at = _occurrenceIndex(ids, songId, occurrence);
      if (at < 0) return;
      // One index per call: Navidrome 0.64 ignores several.
      await api.updatePlaylist(id: playlist.id, songIndexesToRemove: [at]);
      try {
        await _storeEntries(playlist.id, ids..removeAt(at));
      } on Object {
        // The server edit succeeded; the hydration below repairs the list.
      }
    });
    if (!_ref.mounted) return;
    _ref.invalidate(playlistSyncProvider);
    // The stored list is already right; this settles counts and covers. It
    // must not join a hydration that started before the edit.
    unawaited(
      _ref
          .read(librarySyncControllerProvider.notifier)
          .requestTarget(
            LibrarySyncTarget.playlist(playlist.id),
            requireFresh: true,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// Index of the [occurrence]-th [songId] in [ids], else the last one, else -1.
  int _occurrenceIndex(List<String> ids, String songId, int occurrence) {
    var seen = 0;
    var last = -1;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != songId) continue;
      if (seen++ == occurrence) return i;
      last = i;
    }
    return last;
  }

  /// Stores a server playlist's entries right after an edit. Ids the library
  /// does not hold yet are left for the hydration the caller starts next.
  Future<void> _storeEntries(String id, List<String> ids) async {
    final db = _ref.read(navisDatabaseProvider);
    final known = {
      for (final song in await db.libraryDao.getSongsByIds(ids)) song.id,
    };
    await db.playlistDao.replacePlaylistSongs(id, [
      for (final songId in ids.where(known.contains).indexed)
        PlaylistSongsTableCompanion.insert(
          playlistId: id,
          songId: songId.$2,
          sortOrder: songId.$1,
        ),
    ]);
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
      await _edit(
        playlist.id,
        () => api.replacePlaylistSongs(
          playlistId: playlist.id,
          songIds: reordered,
        ),
      );
    } finally {
      // Refresh on failure too, reverting the detail screen's optimistic order.
      if (_ref.mounted) {
        _ref.invalidate(playlistDetailSyncProvider(playlist.id));
      }
    }
  }
}
