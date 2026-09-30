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
      if (availableWidth < 640) return compact ? 240 : 260;
      return (availableWidth * (compact ? 0.28 : 0.32)).clamp(
        compact ? 260.0 : 300.0,
        compact ? 330.0 : 360.0,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final heroHeight = _heroHeightFor(constraints.maxWidth);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            children: <Widget>[
              ClipRRect(
                borderRadius: NavisRadius.xlAll,
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
                      borderRadius: NavisRadius.pillAll,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
                borderRadius: NavisRadius.mdAll,
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
              borderRadius: NavisRadius.mdAll,
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

/// A quiet, in-context entry point for ordinary release notes.
///
/// Unlike the historical dialog, this keeps Home available on first launch
/// after an update. Opening or dismissing the card records the version as
/// seen, matching the old acknowledgement behavior.
class _ChangelogDiscoveryCard extends ConsumerStatefulWidget {
  const _ChangelogDiscoveryCard();

  @override
  ConsumerState<_ChangelogDiscoveryCard> createState() =>
      _ChangelogDiscoveryCardState();
}

class _ChangelogDiscoveryCardState
    extends ConsumerState<_ChangelogDiscoveryCard> {
  var _dismissed = false;

  void _markSeen(String version) {
    if (_dismissed) {
      return;
    }
    setState(() {
      _dismissed = true;
    });
    unawaited(markChangelogSeen(version));
  }

  void _openChangelog(BuildContext context, String version) {
    _markSeen(version);
    NavService.openAboutChangelog(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const SizedBox.shrink();
    }

    final version = ref.watch(changelogToShowProvider).asData?.value;
    if (version == null) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final highlight = version.entries
        .where((entry) => entry.type != ChangelogEntryType.fix)
        .map((entry) => entry.text)
        .firstOrNull;
    final summary = highlight ?? l10n.changelogDiscoveryFixesSummary;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        desktopMode ? 16 : 12,
        4,
        desktopMode ? 16 : 12,
        12,
      ),
      child: Semantics(
        container: true,
        label: l10n.changelogDiscoverySemanticLabel(version.version),
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: NavisRadius.lgAll,
            side: BorderSide(
              color: colorScheme.primary.withValues(alpha: 0.24),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.auto_awesome_outlined,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l10n.changelogDiscoveryTitle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.changelogDiscoveryVersion(version.version),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        key: const ValueKey<String>('changelogDiscoveryOpen'),
                        onPressed: () =>
                            _openChangelog(context, version.version),
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: Text(l10n.changelogDiscoveryAction),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('changelogDiscoveryDismiss'),
                  tooltip: l10n.changelogDiscoveryDismiss,
                  onPressed: () => _markSeen(version.version),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
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
    final l10n = AppLocalizations.of(context)!;
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
                        l10n.weeklyPlaylistAvailableCount(
                          playlist.matchedCount,
                          playlist.totalCount,
                        ),
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
                  label: Text(l10n.albumDetailPlayAction),
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
                  label: Text(l10n.albumDetailShuffleAction),
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
    this.minHeight = 64,
  });

  final ListenBrainzResolvedRecommendation recommendation;
  final int index;
  final ValueChanged<Song> onPlay;
  final ValueChanged<ListenBrainzPlaylistTrack> onSearch;
  final EdgeInsetsGeometry? contentPadding;
  final double horizontalTitleGap;
  final double minHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
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
    final ambiguous =
        recommendation.status ==
        ListenBrainzRecommendationMatchStatus.ambiguous;
    final statusLabel = pending
        ? l10n.weeklyPlaylistMatching
        : unavailable
        ? ambiguous
              ? l10n.weeklyPlaylistAmbiguousMatch
              : l10n.weeklyPlaylistTrackUnavailable
        : null;
    // The status rides on the title line as a short label; the full
    // sentence stays available as its tooltip and accessible label.
    final shortStatus = pending
        ? l10n.weeklyPlaylistMatching
        : unavailable
        ? ambiguous
              ? l10n.weeklyPlaylistAmbiguousMatchShort
              : l10n.weeklyPlaylistTrackUnavailableShort
        : null;

    final tile = Opacity(
      opacity: unavailable ? 0.58 : 1,
      child: Material(
        type: MaterialType.transparency,
        child: AdaptiveTrackRow(
          title: playableSong?.title ?? track.title,
          artist: playableSong?.artist ?? track.creator,
          album: playableSong?.album ?? track.album,
          duration: playableSong?.duration,
          selected: isSelected,
          isRemote: isRemote,
          padding:
              contentPadding ??
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          leadingExtent: 32,
          leadingGap: horizontalTitleGap,
          actionExtent: 96,
          minHeight: minHeight,
          titleBadge: shortStatus == null
              ? null
              : Tooltip(
                  // "Matching" is already short and matches the hourglass
                  // button's tooltip, so it needs no second tooltip.
                  message: shortStatus == statusLabel ? '' : statusLabel,
                  excludeFromSemantics: true,
                  child: Semantics(
                    label: statusLabel,
                    excludeSemantics: true,
                    child: Row(
                      key: const ValueKey<String>('weekly-track-status'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!pending) ...[
                          Icon(
                            ambiguous
                                ? Icons.help_outline_rounded
                                : Icons.cloud_off_rounded,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Flexible(
                          child: Text(
                            shortStatus,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
          actions: playableSong == null
              ? IconButton(
                  tooltip: pending
                      ? l10n.weeklyPlaylistMatching
                      : l10n.weeklyPlaylistSearchAction,
                  icon: Icon(
                    pending
                        ? Icons.hourglass_empty_rounded
                        : Icons.search_rounded,
                  ),
                  onPressed: pending ? null : () => onSearch(track),
                )
              : null,
          onTap: playableSong == null ? null : () => onPlay(playableSong),
        ),
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: tile);
  }
}
