part of 'home_screen.dart';

class _RandomHeroShimmer extends StatelessWidget {
  const new({
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
                borderRadius: NavisShapeData.of(context).xlAll,
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
  const new({
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
              shape: NavisShapeData.of(context).mdShape,
              child: ShimmerPlaceholder(height: cardSize, width: cardSize),
            ),
          );
        },
      ),
    );
  }
}

class _ListShimmer extends StatelessWidget {
  const new({this.density = _HomeSectionDensity.comfortable});

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
              borderRadius: NavisShapeData.of(context).mdAll,
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateTile extends ConsumerWidget {
  const new();

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
      await showUpdateDialog(context, info, updateService: updateService);
      return;
    }

    await launchExternalHttpUrl(info.htmlUrl);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updateAsync = ref.watch(updateProvider);
    final dismissedUpdate = ref.watch(dismissedUpdateProvider);
    final automaticChecksAllowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => policy.isEnabled(IntegrationFeature.updatesAutomatic),
      ),
    );

    // Off, or settings still loading: no banner and no check.
    if (!automaticChecksAllowed) {
      return const SizedBox.shrink();
    }

    return updateAsync.when(
      data: (info) {
        if (info == null ||
            dismissedUpdate.isLoading ||
            dismissedUpdate.asData?.value ==
                '${info.tagName}+${info.buildNumber ?? 0}') {
          return const SizedBox.shrink();
        }
        final actionLabel = switch (info.delivery) {
          UpdateDelivery.storeRedirect => l10n.updateOpenPlayStore,
          UpdateDelivery.selfUpdate => l10n.updateInstall,
          UpdateDelivery.desktopSelfUpdate =>
            info.downloadUrl != null ? l10n.updateInstall : l10n.updateDownload,
        };
        final body = switch (info.delivery) {
          UpdateDelivery.storeRedirect => l10n.updatePlayStoreTitle,
          UpdateDelivery.selfUpdate => l10n.updateReadyBodyInstall,
          UpdateDelivery.desktopSelfUpdate =>
            info.downloadUrl != null
                ? l10n.updateReadyBodyInstall
                : l10n.updateReadyBodyDownload,
        };
        return HomeNoticeCard(
          openKey: const ValueKey<String>('updateTileOpen'),
          dismissKey: const ValueKey<String>('updateTileDismiss'),
          icon: Icons.system_update_outlined,
          title: l10n.updateReadyTitle(info.tagName),
          subtitle: body,
          dismissTooltip: l10n.updateDismiss,
          onDismiss: () async {
            await ref
                .read(updateCheckStoreProvider)
                .recordDismissedUpdate(
                  '${info.tagName}+${info.buildNumber ?? 0}',
                );
            if (context.mounted) ref.invalidate(dismissedUpdateProvider);
          },
          secondaryAction: info.htmlUrl.isEmpty
              ? null
              : NoticeAction(
                  key: const ValueKey<String>('updateTileReleaseNotes'),
                  label: l10n.updateReleaseNotes,
                  onPressed: () =>
                      unawaited(launchExternalHttpUrl(info.htmlUrl)),
                ),
          primaryAction: NoticeAction(
            key: const ValueKey<String>('updateTileAction'),
            label: actionLabel,
            onPressed: () => unawaited(_handleUpdateAction(context, ref, info)),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ListenBrainzArtwork extends StatelessWidget {
  const new({required this.playlist, required this.size});

  final ListenBrainzDiscoverPlaylist playlist;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenBrainzPlaylistArtwork(playlist: playlist, size: size);
  }
}

Future<void> _showListenBrainzDiscoverDetail(
  BuildContext context,
  WidgetRef ref,
  ListenBrainzDiscoverPlaylist playlist,
) {
  NavService.openListenBrainzWeeklyDetail(
    context,
    ref,
    playlist.playlist.sourcePatch ?? '',
  );
  return Future<void>.value();
}

class _ListenBrainzRecommendationTile extends ConsumerWidget {
  const new({
    required this.recommendation,
    required this.index,
    required this.onPlay,
    required this.onSearch,
    this.contentPadding,
    this.horizontalTitleGap = 6,
    this.minHeight = 64,
    this.leadingExtent,
    super.key,
  });

  final ListenBrainzResolvedRecommendation recommendation;
  final int index;
  final ValueChanged<Song> onPlay;
  final ValueChanged<ListenBrainzPlaylistTrack> onSearch;
  final EdgeInsetsGeometry? contentPadding;
  final double horizontalTitleGap;
  final double minHeight;

  /// Width of the number slot; null follows the Density cover size so titles
  /// line up with the matched rows' artwork.
  final double? leadingExtent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final statusKind = pending
        ? TrackMatchLabelKind.matching
        : unavailable
        ? ambiguous
              ? TrackMatchLabelKind.ambiguous
              : TrackMatchLabelKind.unavailable
        : null;

    final tile = Opacity(
      opacity: unavailable ? TrackMatchStatusLabel.unavailableOpacity : 1,
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
          leadingExtent: leadingExtent,
          leadingGap: horizontalTitleGap,
          actionExtent: 96,
          minHeight: minHeight,
          titleBadge: statusKind == null
              ? null
              : TrackMatchStatusLabel(kind: statusKind),
          leading: Center(
            child: isSelected
                ? SongPlaybackMarker(state: playbackState)
                : pending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('$index', maxLines: 1, overflow: TextOverflow.ellipsis),
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
