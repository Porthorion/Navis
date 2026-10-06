import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/app_logger.dart';

const String listenBrainzWeeklyExplorationVirtualPlaylistId =
    'virtual:listenbrainz:weekly-exploration';
const String listenBrainzWeeklyJamsVirtualPlaylistId =
    'virtual:listenbrainz:weekly-jams';

/// Home's Trending Now as a Library playlist; opens the Trending page.
const String trendingVirtualPlaylistId = NavService.trendingPlaylistId;

/// A row of Library › Playlists: a ListenBrainz weekly playlist, Trending
/// Now, or a server playlist.
class PlaylistLibraryItem {
  const new _({
    this.playlist,
    this.virtualPlaylist,
    this.isTrending = false,
    this.trendingTracks,
  });

  const new normal(PlaylistsTableData playlist) : this._(playlist: playlist);

  const new virtual(ListenBrainzDiscoverPlaylist virtualPlaylist)
    : this._(virtualPlaylist: virtualPlaylist);

  /// Trending Now with its chart rows, or null while they load.
  const new trending(List<ResolvedArtistTopTrack>? tracks)
    : this._(isTrending: true, trendingTracks: tracks);

  final PlaylistsTableData? playlist;
  final ListenBrainzDiscoverPlaylist? virtualPlaylist;
  final bool isTrending;
  final List<ResolvedArtistTopTrack>? trendingTracks;

  bool get isVirtual => virtualPlaylist != null || isTrending;

  String get id {
    if (isTrending) return trendingVirtualPlaylistId;
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

  /// The title; Trending Now's is localized where it is shown.
  String get name =>
      virtualPlaylist?.displayTitle ?? playlist?.name ?? 'Trending Now';

  int get songCount =>
      virtualPlaylist?.totalCount ??
      trendingTracks?.length ??
      playlist?.songCount ??
      0;
}

/// Watches the local playlist list (synced from server).
/// Non-autoDispose so the stream stays alive across tab switches, preventing
/// the playlist tab from resetting back to a loading/empty state on revisit.
final playlistListProvider = StreamProvider<List<PlaylistsTableData>>((ref) {
  final db = ref.watch(navisDatabaseProvider);
  return db.playlistDao.watchPlaylists();
});

/// Library › Playlists: the ListenBrainz weekly playlists, then Trending
/// Now while `deezer.trending` is allowed (so it can always be found, even
/// when the You Might Like hero leaves it out), then the server playlists.
///
/// While the server playlists load, or if reading them fails, the virtual
/// playlists (weekly or Trending) are still listed on their own; the loading
/// or error state shows only when there are none.
final playlistLibraryItemsProvider =
    Provider<AsyncValue<List<PlaylistLibraryItem>>>((ref) {
      final playlistsAsync = ref.watch(playlistListProvider);
      final virtualAsync = ref.watch(listenBrainzDiscoverStreamProvider);
      final trendingAllowed =
          ref.watch(
            integrationPolicyProvider.select(
              (policy) => policy.allows(IntegrationFeature.deezerTrending),
            ),
          ) &&
          ref.watch(integrationAccountScopeProvider) != null;
      final trending = trendingAllowed
          ? PlaylistLibraryItem.trending(ref.watch(homeTrendingProvider).value)
          : null;
      final virtualItems = <PlaylistLibraryItem>[
        for (final playlist
            in virtualAsync.asData?.value ??
                const <ListenBrainzDiscoverPlaylist>[])
          PlaylistLibraryItem.virtual(playlist),
        ?trending,
      ];

      return playlistsAsync.when(
        data: (playlists) => AsyncData(<PlaylistLibraryItem>[
          ...virtualItems,
          for (final playlist in playlists)
            PlaylistLibraryItem.normal(playlist),
        ]),
        loading: () => virtualItems.isEmpty
            ? const AsyncLoading()
            : AsyncData(virtualItems),
        error: (error, stackTrace) {
          if (virtualItems.isEmpty) return AsyncError(error, stackTrace);
          AppLogger.warning(
            'Playlists unreadable; showing virtual ones: $error',
          );
          return AsyncData(virtualItems);
        },
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
