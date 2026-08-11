part of 'library_screen.dart';

class _TypeFilterBadge extends StatelessWidget {
  const _TypeFilterBadge({
    required this.query,
    required this.onClear,
  });

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.filter_list_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Filtering: "$query"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: onClear,
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatusBanner extends StatelessWidget {
  const _SyncStatusBanner({
    required this.syncState,
    required this.onRetry,
    this.onCancel,
  });

  final LibrarySyncState syncState;
  final Future<void> Function() onRetry;
  final VoidCallback? onCancel;

  static const Key bannerKey = ValueKey<String>('library-sync-status-banner');
  static const Key progressKey = ValueKey<String>(
    'library-sync-status-progress',
  );
  static const Key cancelKey = ValueKey<String>('library-sync-status-cancel');
  static const Key retryKey = ValueKey<String>('library-sync-status-retry');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (syncState.status == LibrarySyncStatus.failed) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final message = syncState.errorMessage ?? l10n.librarySyncFailureFallback;
      return Semantics(
        container: true,
        liveRegion: true,
        label: l10n.syncSettingsStatusFailed,
        child: Material(
          key: bannerKey,
          color: colors.errorContainer,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 12, 10),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  color: colors.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: retryKey,
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!syncState.isRunning && syncState.lastSyncedAt == null) {
      return const SizedBox.shrink();
    }

    if (syncState.isRunning) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final total = syncState.total;
      final processed = syncState.processed ?? 0;
      // Metadata stages use different units (artists, catalog pages, and
      // candidate validation), so their percentages cannot form one stable
      // overall value. Reserve the determinate bar for durable song hydration.
      final durableHydration =
          syncState.metadataReady &&
          syncState.stage == LibrarySyncStage.fetchingSongs;
      final progress = !durableHydration || total == null || total == 0
          ? null
          : (processed / total).clamp(0.0, 1.0);
      final label = _runningLabel(l10n, total, processed);
      return Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: Material(
          key: bannerKey,
          color: colors.surfaceContainerHigh,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 10),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2,
                          color: colors.primary,
                          backgroundColor: colors.primary.withValues(
                            alpha: 0.16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodySmall),
                    ),
                    if (onCancel != null)
                      TextButton.icon(
                        key: cancelKey,
                        onPressed: onCancel,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(l10n.commonCancel),
                      ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                key: progressKey,
                value: progress,
                minHeight: 3,
                color: colors.primary,
                backgroundColor: colors.primary.withValues(alpha: 0.12),
              ),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  String _runningLabel(
    AppLocalizations l10n,
    int? total,
    int processed,
  ) {
    final pending = syncState.pendingHydrationCount ?? 0;
    if (syncState.metadataReady &&
        syncState.stage == LibrarySyncStage.fetchingSongs) {
      if (total == null || total == 0) {
        return l10n.librarySyncHydratingUnknown;
      }
      final throughput = syncState.hydrationThroughputAlbumsPerSecond;
      if (throughput != null && throughput > 0) {
        return l10n.librarySyncHydratingProgressWithRate(
          processed,
          total,
          pending,
          throughput.toStringAsFixed(1),
        );
      }
      return l10n.librarySyncHydratingProgress(processed, total, pending);
    }

    if (total == null) {
      return l10n.librarySyncRunningStage(_stageLabel(syncState.stage, l10n));
    }
    return l10n.librarySyncRunningWithProgress(processed, total);
  }

  String _stageLabel(LibrarySyncStage stage, AppLocalizations l10n) {
    return switch (stage) {
      LibrarySyncStage.preparing => l10n.librarySyncStagePreparing,
      LibrarySyncStage.fetchingArtists => l10n.librarySyncStageArtists,
      LibrarySyncStage.fetchingAlbums => l10n.librarySyncStageAlbums,
      LibrarySyncStage.persistingMetadata => l10n.librarySyncStagePersisting,
      LibrarySyncStage.fetchingSongs => l10n.librarySyncStageSongs,
      LibrarySyncStage.fetchingGenres => l10n.librarySyncStageGenres,
      LibrarySyncStage.fetchingPlaylists => l10n.librarySyncStagePlaylists,
      LibrarySyncStage.finalizing => l10n.librarySyncStageFinalizing,
      _ => l10n.librarySyncRunning,
    };
  }
}

class _SectionRail extends StatelessWidget {
  const _SectionRail({
    required this.labels,
    required this.activeLabel,
    required this.onLabelSelected,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    this.railKey,
    this.activeLabelKey,
    this.width = 36,
  });

  final Key? railKey;
  final Key? activeLabelKey;
  final double width;
  final List<String> labels;
  final String? activeLabel;
  final void Function(String label, {required bool animate}) onLabelSelected;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      key: railKey,
      width: width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void selectAtDy(double dy) {
            if (constraints.maxHeight <= 0) {
              return;
            }
            final normalized = ((dy / constraints.maxHeight) * labels.length)
                .clamp(0, labels.length - 0.0001);
            final index = normalized.floor().clamp(
              0,
              labels.length - 1,
            );
            onLabelSelected(
              labels[index],
              animate: false,
            );
          }

          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (details) {
              onInteractionStart();
              selectAtDy(details.localPosition.dy);
            },
            onPointerMove: (details) => selectAtDy(details.localPosition.dy),
            onPointerUp: (details) {
              selectAtDy(details.localPosition.dy);
              onInteractionEnd();
            },
            onPointerCancel: (_) => onInteractionEnd(),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: labels
                    .map(
                      (label) => Expanded(
                        child: Center(
                          child: Text(
                            label,
                            key: label == activeLabel ? activeLabelKey : null,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(
                                  color: label == activeLabel
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                  fontWeight: label == activeLabel
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RailOverlay extends StatelessWidget {
  const _RailOverlay({
    required this.overlayKey,
    required this.label,
  });

  final Key overlayKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            key: overlayKey,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Text(
                label,
                style:
                    Theme.of(
                      context,
                    ).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class _ArtistListItem {
  const _ArtistListItem._({required this.letter, this.artist});

  const _ArtistListItem.header(String letter) : this._(letter: letter);

  const _ArtistListItem.artist(String letter, ArtistsTableData artist)
    : this._(letter: letter, artist: artist);

  final String letter;
  final ArtistsTableData? artist;
}

class _YearListItem {
  _YearListItem.header({
    required this.label,
    required this.isUnknownYear,
    this.decadeStart,
  }) : albums = const [];

  _YearListItem.albumRow(AlbumsTableData left, [AlbumsTableData? right])
    : label = '',
      isUnknownYear = false,
      decadeStart = null,
      albums = right != null ? [left, right] : [left];

  final String label;
  final bool isUnknownYear;
  final int? decadeStart;
  final List<AlbumsTableData> albums;

  bool get isHeader => albums.isEmpty;
}

class _SortFilterRow<T> extends StatelessWidget {
  const _SortFilterRow({
    required this.sortLabel,
    required this.sortValue,
    required this.sortItems,
    required this.onSortChanged,
    required this.downloadedOnly,
    required this.onDownloadedOnlyChanged,
    this.likedOnly = false,
    this.onLikedOnlyChanged,
  });

  final String sortLabel;
  final T sortValue;
  final List<DropdownMenuItem<T>> sortItems;
  final ValueChanged<T?> onSortChanged;
  final bool downloadedOnly;
  final ValueChanged<bool> onDownloadedOnlyChanged;
  final bool likedOnly;
  final ValueChanged<bool>? onLikedOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget buildSortDropdown() {
      return DropdownButton<T>(
        value: sortValue,
        isExpanded: true,
        isDense: true,
        items: sortItems,
        onChanged: onSortChanged,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useStackedLayout = constraints.maxWidth < 320;

          final filters = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilterChip(
                label: Text(l10n.libraryDownloadedOnlyFilter),
                selected: downloadedOnly,
                onSelected: onDownloadedOnlyChanged,
                avatar: Icon(
                  downloadedOnly
                      ? Icons.download_done
                      : Icons.download_outlined,
                  size: 18,
                ),
              ),
              if (onLikedOnlyChanged != null)
                FilterChip(
                  label: Text(l10n.libraryLikedOnlyFilter),
                  selected: likedOnly,
                  onSelected: onLikedOnlyChanged,
                  avatar: Icon(
                    likedOnly ? Icons.favorite : Icons.favorite_border_outlined,
                    size: 18,
                  ),
                ),
            ],
          );

          if (useStackedLayout) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                filters,
                const SizedBox(height: 8),
                buildSortDropdown(),
              ],
            );
          }

          return Row(
            children: <Widget>[
              Expanded(child: filters),
              const SizedBox(width: 12),
              Flexible(
                fit: FlexFit.loose,
                child: buildSortDropdown(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoadingListPlaceholder extends StatelessWidget {
  const _LoadingListPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ShimmerPlaceholder(height: 18, width: 180),
          SizedBox(height: 8),
          ShimmerPlaceholder(height: 14, width: 120),
        ],
      ),
    );
  }
}
