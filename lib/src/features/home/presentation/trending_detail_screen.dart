import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/library/presentation/ranked_virtual_playlist_content.dart';
import 'package:navis/src/routing/desktop_layout.dart';

/// Trending Now, opened from the You Might Like hero: the Deezer chart songs
/// the user can play, numbered by chart position, in the "This Is" layout.
class TrendingDetailScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final body = ref
        .watch(homeTrendingProvider)
        .when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          data: (tracks) => tracks.isEmpty
              ? EmptyState(
                  title: l10n.trendingEmptyTitle,
                  subtitle: l10n.trendingEmptySubtitle,
                  icon: Icons.trending_up_rounded,
                )
              : RankedVirtualPlaylistContent(
                  keyPrefix: 'trending',
                  title: l10n.homeTrendingTitle,
                  meta: l10n.trendingPlaylistMeta(tracks.length),
                  artworkBuilder: (coverArtIds, size) => PlaylistCoverMosaic(
                    coverArtIds: coverArtIds,
                    size: size,
                    fallbackIcon: Icons.trending_up_rounded,
                  ),
                  tracks: tracks,
                ),
          loading: () => const ShimmerListPage(count: 8),
          error: (error, _) => ErrorState(
            title: l10n.trendingErrorTitle,
            onRetry: () => ref.invalidate(homeTrendingProvider),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeTrendingTitle)),
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
