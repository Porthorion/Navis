import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/domain/playlist_ownership.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

const String listenBrainzWeeklyExplorationVirtualPlaylistId =
    'virtual:listenbrainz:weekly-exploration';
const String listenBrainzWeeklyJamsVirtualPlaylistId =
    'virtual:listenbrainz:weekly-jams';

/// Home's Trending Now as a Library playlist; opens the Trending page.
const String trendingVirtualPlaylistId = NavService.trendingPlaylistId;

enum PlaylistLibrarySection { yours, madeForYou, other }

/// A row of Library › Playlists, grouped by ownership or virtual source.
class PlaylistLibraryItem {
  const new _({
    required this.section,
    this.playlist,
    this.virtualPlaylist,
    this.isTrending = false,
    this.trendingTracks,
  });

  const new normal(
    PlaylistsTableData playlist, {
    PlaylistLibrarySection section = PlaylistLibrarySection.yours,
  }) : this._(playlist: playlist, section: section);

  const new virtual(ListenBrainzDiscoverPlaylist virtualPlaylist)
    : this._(
        virtualPlaylist: virtualPlaylist,
        section: PlaylistLibrarySection.madeForYou,
      );

  /// Trending Now with its chart rows, or null while they load.
  const new trending(List<ResolvedArtistTopTrack>? tracks)
    : this._(
        isTrending: true,
        trendingTracks: tracks,
        section: PlaylistLibrarySection.madeForYou,
      );

  final PlaylistLibrarySection section;
  final PlaylistsTableData? playlist;
  final ListenBrainzDiscoverPlaylist? virtualPlaylist;
  final bool isTrending;
  final List<ResolvedArtistTopTrack>? trendingTracks;

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

/// Watches device playlists and cached server playlists.
/// Non-autoDispose so the stream stays alive across tab switches, preventing
/// the playlist tab from resetting back to a loading/empty state on revisit.
final playlistListProvider = StreamProvider<List<PlaylistsTableData>>((ref) {
  final db = ref.watch(navisDatabaseProvider);
  return db.playlistDao.watchPlaylists();
});

/// The signed-in username that [canEditPlaylist] and [isOwnPlaylist] compare
/// owners with. The server config survives offline; the API client may not.
final playlistViewerProvider = Provider<String?>(
  (ref) => ref.watch(
    serverConfigStateProvider.select((config) => config.value?.username),
  ),
);

/// Library › Playlists: yours by name, weekly and Trending mixes, then others.
/// Trending keeps its existing integration and account gates.
///
/// While the server playlists load, or if reading them fails, the virtual
/// playlists (weekly or Trending) are still listed on their own; the loading
/// or error state shows only when there are none.
final playlistLibraryItemsProvider =
    Provider<AsyncValue<List<PlaylistLibraryItem>>>((ref) {
      final playlistsAsync = ref.watch(playlistListProvider);
      final me = ref.watch(playlistViewerProvider);
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
        data: (playlists) {
          final yours = <PlaylistsTableData>[];
          final other = <PlaylistsTableData>[];
          for (final playlist in playlists) {
            (isOwnPlaylist(playlist, me) ? yours : other).add(playlist);
          }
          int byName(PlaylistsTableData a, PlaylistsTableData b) =>
              a.name.toLowerCase().compareTo(b.name.toLowerCase());
          yours.sort(byName);
          other.sort(byName);
          return AsyncData(<PlaylistLibraryItem>[
            for (final playlist in yours) PlaylistLibraryItem.normal(playlist),
            ...virtualItems,
            for (final playlist in other)
              PlaylistLibraryItem.normal(
                playlist,
                section: PlaylistLibrarySection.other,
              ),
          ]);
        },
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

/// Whether the create dialog can offer server storage.
final playlistServerCreationAvailableProvider = Provider<bool>((ref) {
  return ref.watch(networkTypeProvider) != NetworkType.offline &&
      ref.watch(subsonicApiProvider) != null &&
      ref.watch(
            serverReachabilityControllerProvider.select(
              (state) => state.status,
            ),
          ) !=
          ServerReachabilityStatus.offline;
});

/// Device playlist ids that were uploaded, mapped to their server ids, so an
/// open detail screen can follow its playlist to the server copy.
final playlistMovedToServerProvider =
    NotifierProvider<PlaylistMovedToServerController, Map<String, String>>(
      PlaylistMovedToServerController.new,
    );

class PlaylistMovedToServerController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const <String, String>{};

  void moved(String localId, String serverId) =>
      state = {...state, localId: serverId};
}

final playlistCreateOnServerProvider =
    NotifierProvider<PlaylistCreateOnServerController, bool>(
      PlaylistCreateOnServerController.new,
    );

/// The sticky destination choice, forced off without saving while offline.
class PlaylistCreateOnServerController extends Notifier<bool> {
  @override
  bool build() {
    final saved = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.asData?.value.playlistCreateOnServer ?? true,
      ),
    );
    return ref.watch(playlistServerCreationAvailableProvider) && saved;
  }

  Future<void> setOnServer({required bool enabled}) async {
    if (!ref.read(playlistServerCreationAvailableProvider)) return;
    await ref
        .read(settingsRepositoryProvider)
        .setPlaylistCreateOnServer(enabled: enabled);
  }
}

/// Reconciles the authoritative server playlist list through the durable sync
/// coordinator. Changed playlist contents are queued for targeted hydration.
final playlistSyncProvider = FutureProvider.autoDispose<void>((ref) async {
  final result = await ref
      .read(librarySyncControllerProvider.notifier)
      .requestTarget(
        const LibrarySyncTarget.playlistHeaders(),
        requireFresh: true,
      );
  if (result.status == LibrarySyncStatus.failed) {
    throw StateError(result.errorMessage ?? 'Playlist refresh failed.');
  }
});

/// Hydrates server playlist songs; device playlists use only stored rows.
final playlistDetailSyncProvider = FutureProvider.autoDispose
    .family<void, String>((ref, playlistId) async {
      final db = ref.read(navisDatabaseProvider);
      final playlist = await db.playlistDao.watchPlaylistById(playlistId).first;
      // Deleted device rows still have a local namespace, never a server ID.
      if (!ref.mounted ||
          playlist?.isLocal == true ||
          playlistId.startsWith('local:')) {
        return;
      }
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
