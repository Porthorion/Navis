part of 'home_screen.dart';

/// Why an item appears in You Might Like.
String _showcaseReasonLabel(
  AppLocalizations l10n,
  HomeRandomShowcaseItem item,
) {
  if (item is HomeRandomShowcaseListenBrainz) {
    return l10n.homeShowcaseReasonListenBrainz;
  }
  return switch ((item as HomeRandomShowcaseAlbum).source) {
    HomeRandomShowcaseSource.likedDiscovery =>
      l10n.homeShowcaseReasonLikedDiscovery,
    HomeRandomShowcaseSource.serverRandom => l10n.homeShowcaseReasonServer,
    HomeRandomShowcaseSource.localFallback => l10n.homeShowcaseReasonLibrary,
  };
}

/// Cover whose colours tint the section: an album's own cover, or the first
/// cover in a weekly playlist's mosaic.
String? _showcaseWashCoverId(HomeRandomShowcaseItem item) {
  if (item is HomeRandomShowcaseAlbum) return item.coverArtId;
  final playlist = (item as HomeRandomShowcaseListenBrainz).playlist;
  if (playlist == null) return null;
  for (final recommendation in playlist.recommendations) {
    final coverArt =
        recommendation.song?.coverArt ?? recommendation.tableSong?.coverArt;
    if (coverArt != null && coverArt.trim().isNotEmpty) return coverArt;
  }
  return null;
}

/// "2023 • 12 songs · Similar to your likes": unknown parts are left out.
String _showcaseMetaLine(AppLocalizations l10n, HomeRandomShowcaseItem item) {
  final reason = _showcaseReasonLabel(l10n, item);
  if (item is! HomeRandomShowcaseAlbum) return reason;
  final year = item.year;
  final songCount = item.songCount;
  final summary = <String>[
    if (year != null && year > 0) '$year',
    if (songCount != null && songCount > 0) l10n.playlistsSongCount(songCount),
  ].join(' • ');
  return summary.isEmpty ? reason : '$summary · $reason';
}

/// A square, uncropped cover for the phone carousel.
///
/// Titles live in [_ShowcaseInfoPanel] below the carousel so the artwork is
/// never darkened or covered; only the focused cover shows a Play button.
class _ShowcaseCoverCard extends ConsumerWidget {
  const _ShowcaseCoverCard({
    required this.item,
    required this.heroContext,
    required this.focused,
  });

  static const Key playKey = ValueKey<String>('home-showcase-play');

  final HomeRandomShowcaseItem item;
  final String heroContext;
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final radius = coverArtShapeToRadius(ref.watch(coverArtShapeProvider));
    final motion = MotionPolicy.of(context);
    final item = this.item;

    final Widget artwork;
    final VoidCallback? onTap;
    VoidCallback? onLongPress;
    GestureTapDownCallback? onSecondaryTapDown;
    VoidCallback? onPlay;
    String semanticLabel;
    if (item is HomeRandomShowcaseAlbum) {
      final heroTag = buildCoverArtHeroTag(
        coverArtId: item.coverArtId,
        context: '${heroContext}_hero',
        entityId: item.id,
      );
      artwork = HeroCoverArt(
        coverArtId: item.coverArtId,
        heroTag: heroTag,
        size: kCoverArtStandardSize,
        fit: BoxFit.cover,
        placeholderIcon: Icons.album_outlined,
        borderRadius: radius,
        isExternalSource: item.isExternal,
      );
      onTap = () =>
          NavService.openAlbumDetail(context, ref, item.id, heroTag: heroTag);
      onLongPress = () => showAlbumContextMenu(context, ref, item.id);
      onSecondaryTapDown = (details) => showAlbumContextMenu(
        context,
        ref,
        item.id,
        anchor: details.globalPosition,
      );
      onPlay = () => unawaited(playAlbumById(ref, item.id));
      final artist = item.artist?.trim() ?? '';
      semanticLabel = artist.isEmpty
          ? item.name
          : l10n.homeShowcaseAlbumSemantics(item.name, artist);
    } else {
      final listenBrainz = item as HomeRandomShowcaseListenBrainz;
      final playlist = listenBrainz.playlist;
      artwork = listenBrainz.isLoading || playlist == null
          ? const _ListenBrainzLoadingArtwork()
          : _ListenBrainzArtwork(playlist: playlist, size: 420);
      onTap = listenBrainz.isLoading || playlist == null
          ? null
          : () => _showListenBrainzDiscoverDetail(context, ref, playlist);
      semanticLabel = listenBrainz.displayTitle;
    }

    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTapDown: onSecondaryTapDown,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ExcludeSemantics(child: artwork),
                if (onPlay != null)
                  PositionedDirectional(
                    end: NavisSpace.sm,
                    bottom: NavisSpace.sm,
                    child: IgnorePointer(
                      ignoring: !focused,
                      child: ExcludeFocus(
                        excluding: !focused,
                        child: AnimatedOpacity(
                          opacity: focused ? 1 : 0,
                          duration: motion.reduceMotion
                              ? Duration.zero
                              : motion.surface,
                          child: IconButton.filled(
                            key: focused ? playKey : null,
                            tooltip: l10n.homeShowcasePlayTooltip(
                              (item as HomeRandomShowcaseAlbum).name,
                            ),
                            iconSize: 26,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: onPlay,
                            icon: const Icon(Icons.play_arrow_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Title, artist and "year • songs · reason" for the focused carousel item.
class _ShowcaseInfoPanel extends ConsumerWidget {
  const _ShowcaseInfoPanel({required this.item, required this.heroContext});

  static const Key panelKey = ValueKey<String>('home-showcase-info');

  final HomeRandomShowcaseItem item;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final motion = MotionPolicy.of(context);
    final item = this.item;
    final title = item is HomeRandomShowcaseAlbum
        ? item.name
        : (item as HomeRandomShowcaseListenBrainz).displayTitle;
    final subtitle = item is HomeRandomShowcaseAlbum
        ? (item.artist?.trim() ?? '')
        : _listenBrainzSubtitle(l10n, item as HomeRandomShowcaseListenBrainz);

    VoidCallback? openItem;
    if (item is HomeRandomShowcaseAlbum) {
      openItem = () => NavService.openAlbumDetail(context, ref, item.id);
    } else {
      final playlist = (item as HomeRandomShowcaseListenBrainz).playlist;
      if (!item.isLoading && playlist != null) {
        openItem = () =>
            _showListenBrainzDiscoverDetail(context, ref, playlist);
      }
    }

    final content = Column(
      key: ValueKey<String>('home-showcase-info-${item.stableId}'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: openItem,
          borderRadius: NavisRadius.smAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NavisSpace.xxs),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: NavisSpace.xxs),
        Text(
          _showcaseMetaLine(l10n, item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );

    return Padding(
      key: panelKey,
      padding: const EdgeInsets.symmetric(horizontal: NavisSpace.xl),
      child: AnimatedSwitcher(
        duration: motion.reduceMotion ? Duration.zero : motion.surface,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[...previous, ?current],
        ),
        child: content,
      ),
    );
  }

  static String _listenBrainzSubtitle(
    AppLocalizations l10n,
    HomeRandomShowcaseListenBrainz item,
  ) {
    final playlist = item.playlist;
    if (item.isLoading || playlist == null) return l10n.weeklyPlaylistFetching;
    return _listenBrainzAvailabilityText(playlist, l10n);
  }
}

/// A soft wash of the focused cover's colours behind the section.
///
/// The cover is sampled into a small colour grid (see
/// [coverColourFieldProvider]) and painted as a smoothly shaded mesh, which
/// stays smooth at any width, unlike a stretched thumbnail. Switching covers
/// glides the colours instead of crossfading images, and a page-coloured
/// veil keeps contrast.
class _ShowcaseColourWash extends ConsumerWidget {
  const _ShowcaseColourWash({required this.coverArtId, this.subtle = false});

  static const Key washKey = ValueKey<String>('home-showcase-wash');

  final String? coverArtId;

  /// Large desktop surfaces use a lighter tint.
  final bool subtle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;
    final motion = MotionPolicy.of(context);
    final coverId = coverArtId?.trim();
    // Light surfaces need a gentler tint to keep text contrast.
    final light = theme.brightness == Brightness.light;
    final veil = subtle ? (light ? 0.9 : 0.78) : (light ? 0.84 : 0.66);
    final field = coverId == null || coverId.isEmpty
        ? null
        : ref.watch(coverColourFieldProvider(coverId)).asData?.value;
    final target = field ?? CoverColourField.uniform(background);
    return IgnorePointer(
      key: washKey,
      child: ExcludeSemantics(
        // The mesh overscans its box so no edge shows; clip it to the box so
        // the unveiled overscan never spills onto neighbouring content.
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              TweenAnimationBuilder<CoverColourField>(
                tween: _CoverColourFieldTween(end: target),
                duration: motion.reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 400),
                curve: Curves.easeOut,
                builder: (context, value, _) => CustomPaint(
                  painter: CoverColourFieldPainter(value),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      background,
                      background.withValues(alpha: veil),
                      background.withValues(alpha: veil),
                      background,
                    ],
                    stops: const <double>[0, 0.18, 0.7, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverColourFieldTween extends Tween<CoverColourField> {
  _CoverColourFieldTween({super.end});

  @override
  CoverColourField lerp(double t) {
    final from = begin ?? end!;
    return CoverColourField.lerp(from, end!, t);
  }
}
