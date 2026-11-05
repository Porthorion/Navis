import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/artist_playback_action.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/presentation/search_song_menu.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/format_utils.dart';

/// The best matches across artists, albums and songs under one header: the
/// first is a hero card with Play, a second action and More, the others are
/// tiles. On desktop all of them share one row (2 : 1 : 1), on mobile the
/// tiles sit side by side under the hero.
class SearchTopResultsSection extends StatelessWidget {
  const new({required this.topResults, super.key, this.desktopMode = false});

  final List<SearchTopResult> topResults;
  final bool desktopMode;

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hero = KeyedSubtree(
      key: const ValueKey<String>('search-top-result-0'),
      child: _TopHero(result: topResults.first),
    );
    // Missing tiles leave empty space, so the hero keeps its width.
    final tiles = <Widget>[
      for (var i = 1; i <= 2; i++)
        if (i < topResults.length)
          KeyedSubtree(
            key: ValueKey<String>('search-top-result-$i'),
            child: _TopTile(result: topResults[i]),
          )
        else
          const SizedBox.shrink(),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        NavisSectionHeader(
          title: l10n.searchTopResultsSection,
          compact: true,
          padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 4),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: desktopMode
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(flex: 2, child: hero),
                      for (final tile in tiles) ...<Widget>[
                        const SizedBox(width: _gap),
                        Expanded(child: tile),
                      ],
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    hero,
                    if (topResults.length > 1) ...<Widget>[
                      const SizedBox(height: _gap),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(child: tiles[0]),
                            const SizedBox(width: _gap),
                            Expanded(child: tiles[1]),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// What a Top Result shows and does; the same handlers the result rows use.
class _TopView {
  const new({
    required this.title,
    required this.subtitle,
    required this.coverArtId,
    required this.isRemote,
    required this.cover,
    required this.open,
    required this.menu,
  });

  final String title;
  final String subtitle;
  final String? coverArtId;
  final bool isRemote;
  final Widget Function(double extent) cover;
  final VoidCallback open;
  final void Function(Offset? anchor) menu;
}

_TopView _viewOf(BuildContext context, WidgetRef ref, SearchTopResult result) {
  final l10n = AppLocalizations.of(context)!;
  switch (result) {
    case TopArtistResult(:final artist):
      final isRemote = isExternalCatalogSource(
        id: artist.id,
        apiIsExternal: artist.isExternal,
      );
      final count = artist.albumCount ?? 0;
      return _TopView(
        title: artist.name,
        subtitle: count > 0
            ? l10n.searchTopArtistAlbums(count)
            : l10n.searchTopArtist,
        coverArtId: artist.coverArt,
        isRemote: isRemote,
        cover: (extent) => CoverArtImage(
          coverArtId: artist.coverArt,
          size: (extent * 2).round(),
          width: extent,
          height: extent,
          shape: ArtworkShapeRole.artist,
          placeholderIcon: Icons.person_outline,
          isExternalSource: isRemote,
          remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
        ),
        open: () => NavService.openArtistDetail(
          context,
          ref,
          artist.id,
          name: artist.name,
        ),
        menu: (anchor) => unawaited(
          showArtistContextMenu(context, ref, artist.id, anchor: anchor),
        ),
      );
    case TopAlbumResult(:final album):
      final isRemote = isExternalCatalogSource(
        id: album.id,
        apiIsExternal: album.isExternal,
      );
      final heroTag = buildCoverArtHeroTag(
        coverArtId: album.coverArt,
        context: 'search_top_album',
        entityId: album.id,
      );
      final year = album.year;
      return _TopView(
        title: album.name,
        subtitle: year != null && year > 0
            ? l10n.searchTopAlbumYear('$year')
            : l10n.searchTopAlbum,
        coverArtId: album.coverArt,
        isRemote: isRemote,
        cover: (extent) => HeroCoverArt(
          coverArtId: album.coverArt,
          heroTag: heroTag,
          size: (extent * 2).round(),
          width: extent,
          height: extent,
          borderRadius: artworkBorderRadius(
            ref.watch(coverArtShapeProvider),
            extent: extent,
          ),
          isExternalSource: isRemote,
          remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
        ),
        open: () => NavService.openAlbumDetail(
          context,
          ref,
          album.id,
          heroTag: heroTag,
          name: album.name,
          artistName: album.artist,
        ),
        menu: (anchor) => unawaited(
          showAlbumContextMenu(context, ref, album.id, anchor: anchor),
        ),
      );
    case TopSongResult(:final song):
      final isRemote = isExternalCatalogSource(
        id: song.id,
        apiIsExternal: song.isExternal,
      );
      final album = song.album?.trim() ?? '';
      final seconds = song.duration ?? 0;
      final duration = formatSeconds(seconds);
      return _TopView(
        title: song.title,
        subtitle: switch ((album.isNotEmpty, seconds > 0)) {
          (true, true) => l10n.searchTopSongAlbumDuration(album, duration),
          (true, false) => l10n.searchTopSongAlbum(album),
          (false, true) => l10n.searchTopSongDuration(duration),
          (false, false) => l10n.searchTopSong,
        },
        coverArtId: song.coverArt,
        isRemote: isRemote,
        cover: (extent) => CoverArtImage(
          coverArtId: song.coverArt,
          size: (extent * 2).round(),
          width: extent,
          height: extent,
          shape: ArtworkShapeRole.cover,
          isExternalSource: isRemote,
          remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
        ),
        open: () => unawaited(
          ref.read(queueProvider.notifier).replaceWithSongs(<Song>[song]),
        ),
        menu: (anchor) =>
            showSearchSongMenu(context, ref, song, anchor: anchor),
      );
  }
}

Offset? _centerOf(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox
      ? box.localToGlobal(box.size.center(Offset.zero))
      : null;
}

class _TopSubtitle extends StatelessWidget {
  const new({required this.view});

  final _TopView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RemoteSourceMetadataLine(
      metadata: Text(
        view.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isRemote: view.isRemote,
      spacing: 8,
    );
  }
}

class _TopHero extends ConsumerWidget {
  const new({required this.result});

  final SearchTopResult result;

  static const double _artwork = 104;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final view = _viewOf(context, ref, result);
    final base = theme.colorScheme.surfaceContainerHigh;
    // Flat tint of the cover's colour; the plain surface until it resolves,
    // for a cover without one, and for a remote cover. Keyed by cover, so a
    // new query never shows the previous hero's colour.
    final coverId = view.coverArtId?.trim() ?? '';
    final seed = coverId.isEmpty || view.isRemote
        ? null
        : ref.watch(artworkSeedColorProvider(coverId)).value ??
              ref.watch(dynamicAccentColorCacheProvider).peek('id:$coverId');
    final color = seed == null
        ? base
        : Color.alphaBlend(Color(seed).withValues(alpha: 0.28), base);
    final radius = NavisShapeData.of(context).lgAll;
    final secondary = switch (result) {
      TopSongResult(:final song) =>
        view.isRemote ? const SizedBox.shrink() : _LikeButton(songId: song.id),
      TopArtistResult(:final artist) => IconButton.outlined(
        tooltip: l10n.albumDetailShuffleAction,
        icon: const Icon(Icons.shuffle_rounded),
        onPressed: () => unawaited(
          startArtistPlayback(
            ProviderScope.containerOf(context, listen: false),
            artist.id,
            ArtistPlaybackAction.shuffle,
          ),
        ),
      ),
      TopAlbumResult(:final album) => IconButton.outlined(
        tooltip: l10n.albumDetailShuffleAction,
        icon: const Icon(Icons.shuffle_rounded),
        onPressed: () => _playAlbum(context, ref, album, view, shuffle: true),
      ),
    };

    return AnimatedContainer(
      duration: MotionPolicy.of(context).tint,
      decoration: BoxDecoration(color: color, borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                button: true,
                container: true,
                excludeSemantics: true,
                label: '${view.title}, ${view.subtitle}',
                onTap: view.open,
                onLongPress: () => view.menu(null),
                child: InkWell(
                  borderRadius: NavisShapeData.of(context).mdAll,
                  onTap: view.open,
                  onLongPress: () => view.menu(null),
                  onSecondaryTapDown: (details) =>
                      view.menu(details.globalPosition),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      view.cover(_artwork),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              view.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            _TopSubtitle(view: view),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(l10n.albumDetailPlayAction),
                    onPressed: () => _play(context, ref, view),
                  ),
                  secondary,
                  Builder(
                    builder: (buttonContext) => IconButton(
                      key: result is TopSongResult
                          ? ValueKey<String>(
                              'search-top-song-menu-'
                              '${(result as TopSongResult).song.id}',
                            )
                          : const ValueKey<String>('search-top-menu'),
                      tooltip: l10n.actionMore,
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () => view.menu(_centerOf(buttonContext)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(BuildContext context, WidgetRef ref, _TopView view) {
    switch (result) {
      case TopArtistResult(:final artist):
        unawaited(
          startArtistPlayback(
            ProviderScope.containerOf(context, listen: false),
            artist.id,
            ArtistPlaybackAction.play,
          ),
        );
      case TopAlbumResult(:final album):
        _playAlbum(context, ref, album, view, shuffle: false);
      case TopSongResult():
        view.open();
    }
  }

  /// A remote album has no tracks in the library yet: its page fetches them.
  void _playAlbum(
    BuildContext context,
    WidgetRef ref,
    Album album,
    _TopView view, {
    required bool shuffle,
  }) {
    if (view.isRemote) {
      view.open();
    } else {
      unawaited(playAlbumById(ref, album.id, shuffle: shuffle));
    }
  }
}

class _LikeButton extends ConsumerWidget {
  const new({required this.songId});

  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final liked = ref.watch(songStarredProvider(songId)).asData?.value ?? false;
    return IconButton.outlined(
      key: ValueKey<String>('search-top-song-heart-$songId'),
      tooltip: liked ? l10n.actionLiked : l10n.actionLike,
      isSelected: liked,
      icon: const Icon(Icons.favorite_border),
      selectedIcon: const Icon(Icons.favorite),
      onPressed: () => unawaited(
        toggleSongStar(songId, ref).catchError((_) {
          if (context.mounted) {
            showAppNotice(
              context,
              message: l10n.albumDetailStarFailure,
              level: AppNoticeLevel.error,
            );
          }
        }),
      ),
    );
  }
}

class _TopTile extends ConsumerWidget {
  const new({required this.result});

  final SearchTopResult result;

  static const double _artwork = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = _viewOf(context, ref, result);
    final shape = NavisShapeData.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      shape: shape.lgShape,
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        container: true,
        excludeSemantics: true,
        label: '${view.title}, ${view.subtitle}',
        onTap: view.open,
        onLongPress: () => view.menu(null),
        child: InkWell(
          onTap: view.open,
          onLongPress: () => view.menu(null),
          onSecondaryTapDown: (details) => view.menu(details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                view.cover(_artwork),
                const SizedBox(height: 8),
                Text(
                  view.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                _TopSubtitle(view: view),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
