import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

const String listenBrainzWeeklyExplorationVirtualPlaylistId =
    'virtual:listenbrainz:weekly-exploration';
const String listenBrainzWeeklyJamsVirtualPlaylistId =
    'virtual:listenbrainz:weekly-jams';

class PlaylistLibraryItem {
  const PlaylistLibraryItem._({
    this.playlist,
    this.virtualPlaylist,
  });

  const PlaylistLibraryItem.normal(PlaylistsTableData playlist)
    : this._(playlist: playlist);

  const PlaylistLibraryItem.virtual(
    ListenBrainzDiscoverPlaylist virtualPlaylist,
  ) : this._(virtualPlaylist: virtualPlaylist);

  final PlaylistsTableData? playlist;
  final ListenBrainzDiscoverPlaylist? virtualPlaylist;

  bool get isVirtual => virtualPlaylist != null;

  String get id {
    final virtual = virtualPlaylist;
    if (virtual != null) {
      return switch (virtual.playlist.sourcePatch) {
        'weekly-exploration' => listenBrainzWeeklyExplorationVirtualPlaylistId,
        'weekly-jams' => listenBrainzWeeklyJamsVirtualPlaylistId,
        final sourcePatch? => 'virtual:listenbrainz:$sourcePatch',
        _ => 'virtual:listenbrainz:${virtual.playlist.identifier}',
      };
    }
    return playlist!.id;
  }

  String get name => virtualPlaylist?.displayTitle ?? playlist!.name;

  int get songCount => virtualPlaylist?.totalCount ?? playlist!.songCount ?? 0;
}

String listenBrainzPlaylistAvailabilityLabel(
  ListenBrainzDiscoverPlaylist playlist,
) {
  if (!playlist.matchingComplete) {
    return '${playlist.matchedCount} available · matching';
  }
  return '${playlist.matchedCount} of ${playlist.totalCount} available';
}

/// Watches the local playlist list (synced from server).
/// Non-autoDispose so the stream stays alive across tab switches, preventing
/// the playlist tab from resetting back to a loading/empty state on revisit.
final playlistListProvider = StreamProvider<List<PlaylistsTableData>>((ref) {
  final db = ref.watch(navisDatabaseProvider);
  return db.playlistDao.watchPlaylists();
});

final playlistLibraryItemsProvider =
    Provider<AsyncValue<List<PlaylistLibraryItem>>>((ref) {
      final playlistsAsync = ref.watch(playlistListProvider);
      final virtualAsync = ref.watch(listenBrainzDiscoverStreamProvider);

      return playlistsAsync.when(
        data: (playlists) {
          final items = <PlaylistLibraryItem>[
            for (final playlist
                in virtualAsync.asData?.value ??
                    const <ListenBrainzDiscoverPlaylist>[])
              PlaylistLibraryItem.virtual(playlist),
            for (final playlist in playlists)
              PlaylistLibraryItem.normal(playlist),
          ];
          return AsyncData(items);
        },
        loading: () {
          final virtual = virtualAsync.asData?.value;
          if (virtual != null) {
            return AsyncData(<PlaylistLibraryItem>[
              for (final playlist in virtual)
                PlaylistLibraryItem.virtual(playlist),
            ]);
          }
          return const AsyncLoading();
        },
        error: AsyncError.new,
      );
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

  // Prune locally-cached playlists that no longer exist on the server.
  final serverIds = playlists.map((p) => p.id).toList(growable: false);
  await db.playlistDao.deletePlaylistsNotIn(serverIds);
});

/// Family provider: fetches a single playlist's songs from the server
/// and stores them locally. Returns the playlist metadata + song list.
final playlistDetailSyncProvider = FutureProvider.autoDispose
    .family<void, String>((ref, playlistId) async {
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
final playlistSongsProvider = StreamProvider.autoDispose
    .family<List<SongsTableData>, String>((
      ref,
      playlistId,
    ) {
      final db = ref.watch(navisDatabaseProvider);
      return db.playlistDao.watchPlaylistSongs(playlistId);
    });

/// Watches a single playlist's metadata.
final playlistByIdProvider = StreamProvider.autoDispose
    .family<PlaylistsTableData?, String>((
      ref,
      playlistId,
    ) {
      final db = ref.watch(navisDatabaseProvider);
      final query = db.select(db.playlistsTable)
        ..where((t) => t.id.equals(playlistId));
      return query.watchSingleOrNull();
    });
