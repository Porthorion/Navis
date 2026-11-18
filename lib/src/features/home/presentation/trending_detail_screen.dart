import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/presentation/ranked_virtual_playlist_content.dart';
import 'package:navis/src/routing/desktop_layout.dart';

/// Trending Now, opened from the You Might Like hero or Library › Playlists:
/// every Deezer chart song, numbered by chart position, in the "This Is"
/// layout. Songs found on neither the library nor the server stay as faded
/// "Not on server" rows with a Search action, like the weekly playlists'.
class TrendingDetailScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<TrendingDetailScreen> createState() =>
      _TrendingDetailScreenState();
}

class _TrendingDetailScreenState extends ConsumerState<TrendingDetailScreen> {
  late final _open = ref.read(trendingScreenOpenProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Tells Trending a user is waiting, so it skips Home's startup gate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open.value = true;
    });
  }

  @override
  void dispose() {
    // After the tree is unlocked; a disposed container just ignores it.
    scheduleMicrotask(() {
      try {
        _open.value = false;
      } on Object {
        // Container already gone.
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  meta: trendingAvailabilityMeta(l10n, tracks),
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
            onRetry: () => ref
                .read(homeTrendingRefreshProvider.notifier)
                .refresh(manual: true),
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

/// "Deezer chart • 100 songs • 40 of 100 available", or "… 40 tracks
/// available, matching" while the server is still searched.
String trendingAvailabilityMeta(
  AppLocalizations l10n,
  List<ResolvedArtistTopTrack> tracks,
) => <String>[
  l10n.trendingPlaylistMeta(tracks.length),
  trendingAvailability(l10n, tracks),
].join(' • ');

/// "40 of 100 available", or "40 tracks available, matching", like the
/// weekly playlists.
String trendingAvailability(
  AppLocalizations l10n,
  List<ResolvedArtistTopTrack> tracks,
) {
  final playable = tracks.where((track) => track.resolvedSong != null).length;
  return tracks.any((track) => track.isMatching)
      ? l10n.weeklyPlaylistAvailableMatching(playable)
      : l10n.weeklyPlaylistAvailableCount(playable, tracks.length);
}
