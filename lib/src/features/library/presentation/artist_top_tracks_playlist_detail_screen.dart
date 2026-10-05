import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_virtual_playlist_artwork.dart';
import 'package:navis/src/features/library/presentation/ranked_virtual_playlist_content.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class ArtistTopTracksPlaylistDetailScreen extends ConsumerWidget {
  const new({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final artistAsync = ref.watch(artistByIdProvider(artistId));
    final artistInfoAsync = ref.watch(artistInfoProvider(artistId));
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final artist = artistAsync.asData?.value;
    final appBarTitle = artist == null
        ? l10n.playlistDetailTitle
        : l10n.artistTopTracksPlaylistTitle(artist.name);

    final body = artistAsync.when(
      data: (artist) {
        if (artist == null) {
          return EmptyState(
            title: l10n.artistDetailNotFoundTitle,
            subtitle: l10n.artistDetailNotFoundSubtitle,
            icon: Icons.person_off_outlined,
          );
        }
        final key = (artistId: artist.id, name: artist.name);
        final tracksAsync = ref.watch(artistTopTracksPlaylistProvider(key));
        return tracksAsync.when(
          skipLoadingOnReload: true,
          data: (tracks) {
            // No source allowed, or none had songs.
            if (tracks.isEmpty) {
              return EmptyState(
                title: l10n.artistTopTracksPlaylistEmptyTitle,
                subtitle: l10n.artistTopTracksPlaylistEmptySubtitle,
                icon: Icons.queue_music_outlined,
              );
            }
            final imageUrl =
                artistInfoAsync.asData?.value?.largeImageUrl ??
                artistInfoAsync.asData?.value?.mediumImageUrl;
            return RankedVirtualPlaylistContent(
              keyPrefix: 'artist-top-tracks',
              title: l10n.artistTopTracksPlaylistTitle(artist.name),
              meta: l10n.playlistDetailMeta(artist.name, tracks.length),
              artworkBuilder: (coverArtIds, size) =>
                  ArtistVirtualPlaylistArtwork(
                    coverArtIds: coverArtIds,
                    imageUrl: imageUrl,
                    size: size,
                  ),
              tracks: tracks,
            );
          },
          loading: () => const ShimmerListPage(count: 8),
          error: (error, _) => ErrorState(
            title: l10n.artistTopTracksPlaylistErrorTitle,
            onRetry: () => ref.invalidate(
              artistTopTracksPlaylistProvider((
                artistId: artist.id,
                name: artist.name,
              )),
            ),
          ),
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.artistDetailLoadErrorTitle,
        onRetry: () => ref.invalidate(artistByIdProvider(artistId)),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle)),
      body: desktopMode
          ? DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              padding: EdgeInsets.zero,
              child: body,
            )
          : body,
    );
  }
}
