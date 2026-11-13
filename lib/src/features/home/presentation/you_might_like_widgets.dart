part of 'home_screen.dart';

/// Why an item appears in You Might Like.
String _showcaseReasonLabel(
  AppLocalizations l10n,
  HomeRandomShowcaseItem item,
) {
  return switch (item) {
    HomeRandomShowcaseAlbum(:final source) => switch (source) {
      HomeRandomShowcaseSource.likedDiscovery =>
        l10n.homeShowcaseReasonLikedDiscovery,
      HomeRandomShowcaseSource.serverRandom => l10n.homeShowcaseReasonServer,
      HomeRandomShowcaseSource.localFallback => l10n.homeShowcaseReasonLibrary,
    },
    HomeRandomShowcaseListenBrainz() => l10n.homeShowcaseReasonListenBrainz,
    HomeRandomShowcaseTrending() => l10n.homeShowcaseReasonTrending,
  };
}

/// Cover whose colours tint the section: an album's own cover, or the first
/// cover in a playlist's mosaic.
String? _showcaseWashCoverId(HomeRandomShowcaseItem item) {
  return switch (item) {
    HomeRandomShowcaseAlbum(:final coverArtId) => coverArtId,
    HomeRandomShowcasePlaylist() => item.coverArtIds.firstOrNull,
  };
}

/// Revision of the album cover when local library metadata is available.
int _showcaseWashCoverRevision(HomeRandomShowcaseItem item) => switch (item) {
  HomeRandomShowcaseAlbum(:final coverArtRevision) => coverArtRevision,
  HomeRandomShowcasePlaylist() => 0,
};

/// "2023 • 12 songs · Similar to your likes": unknown parts are left out.
String _showcaseMetaLine(AppLocalizations l10n, HomeRandomShowcaseItem item) {
  final reason = _showcaseReasonLabel(l10n, item);
  switch (item) {
    case HomeRandomShowcasePlaylist():
      return reason;
    case HomeRandomShowcaseAlbum(:final year, :final songCount):
      final summary = <String>[
        if (year != null && year > 0) '$year',
        if (songCount != null && songCount > 0)
          l10n.playlistsSongCount(songCount),
      ].join(' • ');
      return summary.isEmpty ? reason : '$summary · $reason';
  }
}

/// Opens a hero playlist's page; null while a weekly playlist is fetched.
VoidCallback? _showcasePlaylistOpener(
  BuildContext context,
  WidgetRef ref,
  HomeRandomShowcasePlaylist item,
) {
  return switch (item) {
    HomeRandomShowcaseListenBrainz(:final playlist?, isLoading: false) =>
      () => _showListenBrainzDiscoverDetail(context, ref, playlist),
    HomeRandomShowcaseListenBrainz() => null,
    HomeRandomShowcaseTrending() => () => NavService.openTrending(context, ref),
  };
}

/// "12 of 50 available" for a weekly playlist, "24 songs you can play" for
/// Trending.
String _showcasePlaylistAvailability(
  AppLocalizations l10n,
  HomeRandomShowcasePlaylist item,
) {
  return switch (item) {
    HomeRandomShowcaseListenBrainz(:final playlist?, isLoading: false) =>
      _listenBrainzAvailabilityText(playlist, l10n),
    HomeRandomShowcaseListenBrainz() => l10n.weeklyPlaylistFetching,
    HomeRandomShowcaseTrending(:final tracks) => trendingAvailability(
      l10n,
      tracks,
    ),
  };
}

/// A hero playlist's cover at [size]: the weekly playlist's artwork (a
/// placeholder while it is fetched) or Trending's mosaic.
class _ShowcasePlaylistArtwork extends StatelessWidget {
  const new({required this.item, required this.size});

  final HomeRandomShowcasePlaylist item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return switch (item) {
      HomeRandomShowcaseListenBrainz(:final playlist?, isLoading: false) =>
        _ListenBrainzArtwork(playlist: playlist, size: size),
      HomeRandomShowcaseListenBrainz() => const _ListenBrainzLoadingArtwork(),
      HomeRandomShowcaseTrending() => PlaylistCoverMosaic(
        coverArtIds: item.coverArtIds,
        size: size,
        fallbackIcon: Icons.trending_up_rounded,
      ),
    };
  }
}

/// A square, uncropped cover for the phone carousel.
///
/// Titles live in [_ShowcaseInfoPanel] below the carousel so the artwork is
/// never darkened or covered; only the focused cover shows a Play button.
class _ShowcaseCoverCard extends ConsumerWidget {
  const new({
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
    final radius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: double.infinity,
    );
    final motion = MotionPolicy.of(context);
    final item = this.item;

    final Widget artwork;
    final VoidCallback? onTap;
    VoidCallback? onLongPress;
    GestureTapDownCallback? onSecondaryTapDown;
    VoidCallback? onPlay;
    String? playName;
    String semanticLabel;
    switch (item) {
      case HomeRandomShowcaseAlbum():
        final heroTag = buildCoverArtHeroTag(
          coverArtId: item.coverArtId,
          context: '${heroContext}_hero',
          entityId: item.id,
        );
        artwork = HeroCoverArt(
          coverArtId: item.coverArtId,
          revision: item.coverArtRevision,
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
        playName = item.name;
        final artist = item.artist?.trim() ?? '';
        semanticLabel = artist.isEmpty
            ? item.name
            : l10n.homeShowcaseAlbumSemantics(item.name, artist);
      case HomeRandomShowcasePlaylist():
        // Playlists open their page; their songs play from there.
        artwork = _ShowcasePlaylistArtwork(item: item, size: 420);
        onTap = _showcasePlaylistOpener(context, ref, item);
        semanticLabel = item.localizedTitle(l10n);
    }

    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          // Flat: no drop shadow under the showcase artwork.
          boxShadow: NavisColorStyleData.of(context).flatSurfaces
              ? null
              : <BoxShadow>[
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
            enableFeedback: false,
            onLongPress: withLongPressHaptic(onLongPress),
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
                            style: NavisColorStyleData.playStyleOf(
                              context,
                              circular: true,
                            ),
                            tooltip: l10n.homeShowcasePlayTooltip(
                              playName ?? '',
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

/// One ellipsized line at exactly its style's line height (a forced strut), so
/// a script whose fallback font has taller metrics (Arabic, Japanese) cannot
/// make the section taller than Latin text does.
class _ShowcaseLine extends StatelessWidget {
  const new(this.text, {required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = this.style ?? DefaultTextStyle.of(context).style;
    final line =
        MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14) *
        (style.height ?? 1.2);
    return SizedBox(
      height: line.ceilToDouble(),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style,
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
      ),
    );
  }
}

/// Title, artist and "year • songs · reason" for the focused carousel item.
///
/// Always three fixed-height lines (the artist line stays reserved when it is
/// empty), so the panel is the same height for every item and script.
class _ShowcaseInfoPanel extends ConsumerWidget {
  const new({required this.item, required this.heroContext});

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
    final String title;
    final String subtitle;
    final VoidCallback? openItem;
    switch (item) {
      case HomeRandomShowcaseAlbum():
        title = item.name;
        subtitle = item.artist?.trim() ?? '';
        openItem = () => NavService.openAlbumDetail(context, ref, item.id);
      case HomeRandomShowcasePlaylist():
        title = item.localizedTitle(l10n);
        subtitle = _showcasePlaylistAvailability(l10n, item);
        openItem = _showcasePlaylistOpener(context, ref, item);
    }

    final content = Column(
      key: ValueKey<String>('home-showcase-info-${item.stableId}'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: openItem,
          borderRadius: NavisShapeData.of(context).smAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NavisSpace.xxs),
            child: _ShowcaseLine(title, style: textTheme.titleMedium),
          ),
        ),
        _ShowcaseLine(
          subtitle,
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: NavisSpace.xxs),
        _ShowcaseLine(
          _showcaseMetaLine(l10n, item),
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
}

/// The cover the section backdrop paints.
typedef _ShowcaseWashSource = ({String? coverArtId, int revision});

/// Test seam for the private [_ShowcaseBackdrop].
@visibleForTesting
typedef ShowcaseBackdrop = _ShowcaseBackdrop;

/// The ambient backdrop of the whole You Might Like section.
///
/// It sits behind the title and the body, bleeds [bleed] past each side so it
/// runs to the page edge instead of stopping at the list's inner padding, and
/// fades into [surface] at the top and bottom. The showcase carousel or pager
/// below reports its focused cover through [report].
class _ShowcaseBackdrop extends StatefulWidget {
  const new({
    required this.child,
    required this.washVisible,
    this.bleed = 0,
    this.surface,
    this.subtle = false,
    this.fadeLeft = false,
    this.fadeRight = false,
  });

  static const Key childKey = ValueKey<String>('home-showcase-backdrop-child');

  final Widget child;

  /// False under Flat Surfaces or without showcase data: no wash is built,
  /// and [child] keeps its place in the tree either way.
  final bool washVisible;

  /// How far the wash extends past the left and right of [child].
  final double bleed;
  final Color? surface;
  final bool subtle;

  /// Fade the wash into the page background towards that page edge, which
  /// borders a bare system inset instead of a different surface.
  final bool fadeLeft;
  final bool fadeRight;

  /// Publishes the focused cover to the nearest backdrop above [context].
  static void report(
    BuildContext context, {
    required String? coverArtId,
    required int coverArtRevision,
  }) {
    final notifier = context
        .getInheritedWidgetOfExactType<_ShowcaseBackdropScope>()
        ?.source;
    final source = (coverArtId: coverArtId, revision: coverArtRevision);
    if (notifier == null || notifier.value == source) {
      return;
    }
    // Never notify while building: the wash rebuilds on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (notifier.value != source && context.mounted) {
        notifier.value = source;
      }
    });
  }

  @override
  State<_ShowcaseBackdrop> createState() => _ShowcaseBackdropState();
}

class _ShowcaseBackdropState extends State<_ShowcaseBackdrop> {
  final ValueNotifier<_ShowcaseWashSource?> _source =
      ValueNotifier<_ShowcaseWashSource?>(null);

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShowcaseBackdropScope(
      source: _source,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          if (widget.washVisible)
            Positioned(
              // One extra pixel at each side: at a fractional page edge the
              // viewport clip then cuts mesh and veil alike.
              left: -widget.bleed - 1,
              right: -widget.bleed - 1,
              top: 0,
              bottom: 0,
              child: ValueListenableBuilder<_ShowcaseWashSource?>(
                valueListenable: _source,
                builder: (context, source, _) => _ShowcaseColourWash(
                  coverArtId: source?.coverArtId,
                  coverArtRevision: source?.revision ?? 0,
                  subtle: widget.subtle,
                  surface: widget.surface,
                  fadeLeft: widget.fadeLeft,
                  fadeRight: widget.fadeRight,
                ),
              ),
            ),
          KeyedSubtree(key: _ShowcaseBackdrop.childKey, child: widget.child),
        ],
      ),
    );
  }
}

class _ShowcaseBackdropScope extends InheritedWidget {
  const new({required this.source, required super.child});

  final ValueNotifier<_ShowcaseWashSource?> source;

  @override
  bool updateShouldNotify(_ShowcaseBackdropScope oldWidget) =>
      source != oldWidget.source;
}

/// Test seam for the private [_ShowcaseColourWash].
@visibleForTesting
typedef ShowcaseColourWash = _ShowcaseColourWash;

/// A soft wash of the focused cover's colours behind the section.
///
/// The cover is sampled into a small colour grid (see
/// [backgroundCoverColourFieldProvider]) and painted as a smoothly shaded mesh, which
/// stays smooth at any width, unlike a stretched thumbnail. Switching covers
/// glides the colours instead of crossfading images, and a page-coloured
/// veil keeps contrast.
class _ShowcaseColourWash extends ConsumerWidget {
  const new({
    required this.coverArtId,
    this.coverArtRevision = 0,
    this.subtle = false,
    this.surface,
    this.fadeLeft = false,
    this.fadeRight = false,
  });

  static const Key washKey = ValueKey<String>('home-showcase-wash');

  final String? coverArtId;
  final int coverArtRevision;

  /// Large desktop surfaces use a lighter tint.
  final bool subtle;

  /// The colour under the wash that the veil fades into at the top and the
  /// bottom: the card colour inside a card, else the page background.
  final Color? surface;

  /// Soften a hard side edge into the [surface] over [sideFadeWidth].
  final bool fadeLeft;
  final bool fadeRight;

  /// Width of the horizontal fade at a side that borders a bare inset.
  static const double sideFadeWidth = 40;
  static const Key fadeLeftKey = ValueKey<String>('home-showcase-fade-left');
  static const Key fadeRightKey = ValueKey<String>('home-showcase-fade-right');

  Widget _sideFade(Color color, {required bool left}) => Positioned(
    key: left ? fadeLeftKey : fadeRightKey,
    left: left ? 0 : null,
    right: left ? null : 0,
    top: 0,
    bottom: 0,
    width: sideFadeWidth,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: easedFadeGradient(
          color: color,
          points: <(double, double)>[(0, left ? 1 : 0), (1, left ? 0 : 1)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final background = surface ?? theme.scaffoldBackgroundColor;
    final motion = MotionPolicy.of(context);
    final coverId = coverArtId?.trim();
    // The colour style sets the veil (light surfaces need a gentler tint to
    // keep text contrast) and reshapes the sampled cover colours.
    final style = NavisColorStyleData.of(context);
    final veil = style.artWashVeil(subtle: subtle);
    final field = coverId == null || coverId.isEmpty
        ? null
        : ref
                  .watch(
                    backgroundCoverColourFieldProvider((
                      coverId,
                      coverArtRevision,
                    )),
                  )
                  .value ??
              peekCoverColourField(coverId);
    final target = field == null
        ? CoverColourField.uniform(background)
        : CoverColourField(
            field.colors.map(style.adaptArtColor).toList(growable: false),
          );
    return IgnorePointer(
      key: washKey,
      child: ExcludeSemantics(
        // The mesh overscans its box so no edge shows; clip it to the box so
        // the unveiled overscan never spills onto neighbouring content.
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // The mesh stops one pixel short of the veil's faded top and
              // bottom: at a fractional edge its hard clip would otherwise
              // leave a thin unveiled line there.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: ClipRect(
                  child: TweenAnimationBuilder<CoverColourField>(
                    tween: _CoverColourFieldTween(end: target),
                    duration: motion.reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    builder: (context, value, _) => CustomPaint(
                      size: Size.infinite,
                      painter: CoverColourFieldPainter(value),
                    ),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  // Eased, not piecewise linear: the kinks of a linear veil
                  // show as lines on high-contrast covers.
                  gradient: easedFadeGradient(
                    color: background,
                    points: <(double, double)>[
                      (0, 1),
                      (0.18, veil),
                      (0.7, veil),
                      (1, 1),
                    ],
                  ),
                ),
              ),
              if (fadeLeft) _sideFade(background, left: true),
              if (fadeRight) _sideFade(background, left: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverColourFieldTween extends Tween<CoverColourField> {
  new({super.end});

  @override
  CoverColourField lerp(double t) {
    final from = begin ?? end!;
    return CoverColourField.lerp(from, end!, t);
  }
}
