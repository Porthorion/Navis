import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

const String listenBrainzWeeklyExplorationVirtualPlaylistId =
    'virtual:listenbrainz:weekly-exploration';
const String listenBrainzWeeklyJamsVirtualPlaylistId =
    'virtual:listenbrainz:weekly-jams';

class PlaylistLibraryItem {
  const new _({this.playlist, this.virtualPlaylist});

  const new normal(PlaylistsTableData playlist) : this._(playlist: playlist);

  const new virtual(ListenBrainzDiscoverPlaylist virtualPlaylist)
    : this._(virtualPlaylist: virtualPlaylist);

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

/// Reconciles the authoritative server playlist list through the durable sync
/// coordinator. Changed playlist contents are queued for targeted hydration.
final playlistSyncProvider = FutureProvider.autoDispose<void>((ref) async {
  final result = await ref
      .read(librarySyncControllerProvider.notifier)
      .requestTarget(const LibrarySyncTarget.playlistHeaders());
  if (result.status == LibrarySyncStatus.failed) {
    throw StateError(result.errorMessage ?? 'Playlist refresh failed.');
  }
});

/// Family provider: fetches a single playlist's songs from the server
/// and stores them locally. Returns the playlist metadata + song list.
final playlistDetailSyncProvider = FutureProvider.autoDispose
    .family<void, String>((ref, playlistId) async {
      final result = await ref
          .read(librarySyncControllerProvider.notifier)
          .requestTarget(LibrarySyncTarget.playlist(playlistId));
      if (result.status == LibrarySyncStatus.failed) {
        throw StateError(result.errorMessage ?? 'Playlist refresh failed.');
      }
    });

/// Watches songs for a given playlist from the local DB.
final playlistSongsProvider = StreamProvider.autoDispose
    .family<List<SongsTableData>, String>((ref, playlistId) {
      final db = ref.watch(navisDatabaseProvider);
      return db.playlistDao.watchPlaylistSongs(playlistId);
    });

/// Watches a single playlist's metadata.
final playlistByIdProvider = StreamProvider.autoDispose
    .family<PlaylistsTableData?, String>((ref, playlistId) {
      final db = ref.watch(navisDatabaseProvider);
      final query = db.select(db.playlistsTable)
        ..where((t) => t.id.equals(playlistId));
      return query.watchSingleOrNull();
    });
