part of 'home_screen.dart';

class _RandomHeroShimmer extends StatelessWidget {
  const _RandomHeroShimmer({
    required this.desktopMode,
    required this.adaptiveLayoutClass,
    this.density = _HomeSectionDensity.comfortable,
  });

  final bool desktopMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final _HomeSectionDensity density;

  double _heroHeightFor(double availableWidth) {
    final compact = density == _HomeSectionDensity.compact;
    if (desktopMode) {
      return (availableWidth * (compact ? 0.28 : 0.32)).clamp(
        compact ? 260.0 : 300.0,
        compact ? 420.0 : 500.0,
      );
    }
    return switch (adaptiveLayoutClass) {
      AdaptiveLayoutClass.phoneCompact => compact ? 208 : 228,
      AdaptiveLayoutClass.tabletMedium => compact ? 224 : 244,
      AdaptiveLayoutClass.tabletExpanded => compact ? 236 : 258,
    };
  }

  @override
  Widget build(BuildContext context) {
    final availableWidth = MediaQuery.sizeOf(context).width;
    final heroHeight = _heroHeightFor(availableWidth);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: ShimmerPlaceholder(
              height: heroHeight,
              width: double.infinity,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List<Widget>.generate(
              3,
              (index) => Padding(
                padding: EdgeInsets.only(right: index == 2 ? 0 : 6),
                child: ShimmerPlaceholder(
                  height: 6,
                  width: index == 1 ? 16 : 6,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselShimmer extends StatelessWidget {
  const _CarouselShimmer({
    required this.compactWideLandscapeMode,
    this.density = _HomeSectionDensity.comfortable,
  });

  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context) {
    final compactDensity = density == _HomeSectionDensity.compact;
    final cardSize = compactDensity ? 138.0 : 150.0;
    return SizedBox(
      height: cardSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: compactWideLandscapeMode ? 0 : 16,
        ),
        itemCount: 4,
        separatorBuilder: (_, _) => SizedBox(width: compactDensity ? 10 : 12),
        itemBuilder: (context, _) {
          return SizedBox(
            width: cardSize,
            child: Card(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ShimmerPlaceholder(
                height: cardSize,
                width: cardSize,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ListShimmer extends StatelessWidget {
  const _ListShimmer({
    this.density = _HomeSectionDensity.comfortable,
  });

  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context) {
    final compactDensity = density == _HomeSectionDensity.compact;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: List<Widget>.generate(
          4,
          (index) => Padding(
            padding: EdgeInsets.only(bottom: index == 3 ? 0 : 8),
            child: ShimmerPlaceholder(
              height: compactDensity ? 52 : 60,
              width: double.infinity,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  Future<void> _handleUpdateAction(
    BuildContext context,
    WidgetRef ref,
    UpdateInfo info,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final updateService = ref.read(updateServiceProvider);
    if (info.delivery == UpdateDelivery.storeRedirect) {
      final launched = await updateService.openPlayStoreListing(
        fallbackUrl: info.htmlUrl,
      );
      if (!context.mounted) {
        return;
      }
      if (!launched) {
        showAppNotice(
          context,
          message: l10n.updatePlayStoreFallbackNotice,
          level: AppNoticeLevel.info,
        );
      }
      return;
    }

    if (info.downloadUrl != null) {
      await showUpdateDialog(
        context,
        info,
        updateService: updateService,
      );
      return;
    }

    await launchUrl(
      Uri.parse(info.htmlUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updateAsync = ref.watch(updateProvider);
    final settings = ref.watch(appSettingsProvider).asData?.value;

    if (settings != null && !settings.updateCheckEnabled) {
      return const SizedBox.shrink();
    }

    return updateAsync.when(
      data: (info) {
        if (info == null) return const SizedBox.shrink();
        final actionLabel = switch (info.delivery) {
          UpdateDelivery.storeRedirect => l10n.updateOpenPlayStore,
          UpdateDelivery.forgejoSelfUpdate => l10n.updateInstall,
          UpdateDelivery.desktopSelfUpdate =>
            info.downloadUrl != null ? l10n.updateInstall : l10n.updateDownload,
        };
        return MaterialBanner(
          content: Text(l10n.updateAvailableBody(info.tagName)),
          leading: const Icon(Icons.system_update_outlined),
          actions: [
            TextButton(
              onPressed: () => ref.invalidate(updateProvider),
              child: Text(l10n.updateDismiss),
            ),
            TextButton(
              onPressed: () =>
                  unawaited(_handleUpdateAction(context, ref, info)),
              child: Text(actionLabel),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ListenBrainzArtwork extends StatelessWidget {
  const _ListenBrainzArtwork({
    required this.playlist,
    required this.size,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenBrainzPlaylistArtwork(
      playlist: playlist,
      size: size,
    );
  }
}

Future<void> _showListenBrainzDiscoverDetail(
  BuildContext context,
  WidgetRef ref,
  ListenBrainzDiscoverPlaylist playlist,
) {
  if (GoRouter.maybeOf(context) == null) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ListenBrainzDiscoverDetailSheet(
        playlist: playlist,
        ref: ref,
      ),
    );
  }
  NavService.openListenBrainzWeeklyDetail(
    context,
    ref,
    playlist.playlist.sourcePatch ?? '',
  );
  return Future<void>.value();
}

class _ListenBrainzDiscoverDetailSheet extends StatelessWidget {
  const _ListenBrainzDiscoverDetailSheet({
    required this.playlist,
    required this.ref,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final playableSongs = playlist.playableSongs;
    final serverSongs = playlist.recommendations
        .where((recommendation) => recommendation.hasServerSong)
        .map((recommendation) => recommendation.tableSong!)
        .toList(growable: false);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _ListenBrainzArtwork(playlist: playlist, size: 112),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        playlist.displayTitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (playlist.playlist.description != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          playlist.playlist.description!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '${playlist.matchedCount} of ${playlist.totalCount} available',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.68),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: playableSongs.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          if (serverSongs.length == playableSongs.length) {
                            ref
                                .read(queueProvider.notifier)
                                .replaceWithTableData(
                                  serverSongs,
                                  expandMatchFlows: false,
                                )
                                .ignore();
                          } else {
                            ref
                                .read(queueProvider.notifier)
                                .replaceWithSongs(
                                  playableSongs,
                                  expandMatchFlows: false,
                                )
                                .ignore();
                          }
                        },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: playableSongs.isEmpty
                      ? null
                      : () {
                          final shuffled = List<Song>.from(playableSongs)
                            ..shuffle(math.Random());
                          Navigator.of(context).pop();
                          if (serverSongs.length == playableSongs.length) {
                            final shuffledRows = List<SongsTableData>.from(
                              serverSongs,
                            )..shuffle(math.Random());
                            ref
                                .read(queueProvider.notifier)
                                .replaceWithTableData(
                                  shuffledRows,
                                  expandMatchFlows: false,
                                )
                                .ignore();
                          } else {
                            ref
                                .read(queueProvider.notifier)
                                .replaceWithSongs(
                                  shuffled,
                                  expandMatchFlows: false,
                                )
                                .ignore();
                          }
                        },
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Shuffle'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < playlist.recommendations.length; i++)
              _ListenBrainzRecommendationTile(
                recommendation: playlist.recommendations[i],
                index: i + 1,
                onPlay: (song) {
                  Navigator.of(context).pop();
                  final recommendation = playlist.recommendations[i];
                  final tableSong = recommendation.hasServerSong
                      ? recommendation.tableSong
                      : null;
                  if (tableSong != null) {
                    ref.read(queueProvider.notifier).replaceWithTableData(
                      <SongsTableData>[tableSong],
                      expandMatchFlows: false,
                    ).ignore();
                  } else {
                    ref.read(queueProvider.notifier).replaceWithSongs(
                      <Song>[song],
                      expandMatchFlows: false,
                    ).ignore();
                  }
                },
                onSearch: (track) {
                  Navigator.of(context).pop();
                  NavService.openSearch(
                    context,
                    ref,
                    '${track.title} ${track.creator ?? ''}'.trim(),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

class _ListenBrainzRecommendationTile extends ConsumerWidget {
  const _ListenBrainzRecommendationTile({
    required this.recommendation,
    required this.index,
    required this.onPlay,
    required this.onSearch,
    this.contentPadding,
    this.horizontalTitleGap = 6,
  });

  final ListenBrainzResolvedRecommendation recommendation;
  final int index;
  final ValueChanged<Song> onPlay;
  final ValueChanged<ListenBrainzPlaylistTrack> onSearch;
  final EdgeInsetsGeometry? contentPadding;
  final double horizontalTitleGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final song = recommendation.song;
    final track = recommendation.track;
    final pending =
        recommendation.status == ListenBrainzRecommendationMatchStatus.pending;
    final unavailable = !pending && !recommendation.isPlayable;
    final playableSong = unavailable ? null : song;
    final isRemote =
        playableSong != null &&
        isExternalCatalogSource(
          id: playableSong.id,
          apiIsExternal: playableSong.isExternal,
        );
    final playbackState = playableSong == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(playableSong.id));
    final isSelected = playbackState.isSelected;
    final subtitle = pending
        ? <String>[
            if (track.creator != null) track.creator!,
            if (track.album != null) track.album!,
            'Matching',
          ].join(' · ')
        : song == null
        ? <String>[
            if (track.creator != null) track.creator!,
            if (track.album != null) track.album!,
            recommendation.status ==
                    ListenBrainzRecommendationMatchStatus.ambiguous
                ? 'Ambiguous match'
                : 'Not available on your server',
          ].join(' · ')
        : <String>[
            if (song.artist != null) song.artist!,
            if (song.album != null) song.album!,
          ].join(' · ');

    final tile = Opacity(
      opacity: unavailable ? 0.58 : 1,
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          selected: isSelected,
          selectedColor: cs.primary,
          selectedTileColor: cs.primary.withValues(alpha: 0.08),
          dense: true,
          minTileHeight: 64,
          contentPadding: contentPadding,
          minLeadingWidth: 32,
          horizontalTitleGap: horizontalTitleGap,
          leading: SizedBox(
            width: 32,
            child: Center(
              child: isSelected
                  ? SongPlaybackMarker(state: playbackState)
                  : pending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      '$index',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          title: Text(
            playableSong?.title ?? track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: isSelected ? cs.primary : null,
            ),
          ),
          subtitle: RemoteSourceMetadataLine(
            metadata: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: unavailable
                    ? cs.onSurface.withValues(alpha: 0.55)
                    : cs.onSurfaceVariant,
              ),
            ),
            isRemote: isRemote,
          ),
          trailing: SizedBox(
            width: 76,
            child: Align(
              alignment: Alignment.centerRight,
              child: playableSong == null
                  ? IconButton(
                      tooltip: pending ? 'Matching' : 'Search',
                      icon: Icon(
                        pending
                            ? Icons.hourglass_empty_rounded
                            : Icons.search_rounded,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: pending ? null : () => onSearch(track),
                    )
                  : Text(
                      formatSeconds(playableSong.duration),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
            ),
          ),
          onTap: playableSong == null ? null : () => onPlay(playableSong),
        ),
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: tile);
  }
}
