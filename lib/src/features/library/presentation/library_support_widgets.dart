part of 'library_screen.dart';

class _TypeFilterBadge extends StatelessWidget {
  const new({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
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
              l10n.libraryFilteringLabel(query),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: l10n.libraryClearFiltersAction,
            child: GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatusBanner extends StatefulWidget {
  const new({required this.syncState, required this.onRetry, this.onCancel});

  final LibrarySyncState syncState;
  final Future<void> Function() onRetry;
  final VoidCallback? onCancel;

  static const Key bannerKey = ValueKey<String>('library-sync-status-banner');
  static const Key progressKey = ValueKey<String>(
    'library-sync-status-progress',
  );
  static const Key cancelKey = ValueKey<String>('library-sync-status-cancel');
  static const Key retryKey = ValueKey<String>('library-sync-status-retry');
  static const Key dismissKey = ValueKey<String>('library-sync-status-dismiss');

  @override
  State<_SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<_SyncStatusBanner> {
  bool _failureDismissed = false;

  @override
  void didUpdateWidget(covariant _SyncStatusBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A dismissed failure stays hidden only until the sync state moves on,
    // so a later failure is always shown.
    if (oldWidget.syncState.status != widget.syncState.status ||
        oldWidget.syncState.errorMessage != widget.syncState.errorMessage) {
      _failureDismissed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = widget.syncState;
    final l10n = AppLocalizations.of(context)!;
    if (syncState.status == LibrarySyncStatus.failed) {
      if (_failureDismissed) {
        return const SizedBox.shrink();
      }
      final theme = Theme.of(context);
      final tokens = NavisTokens.of(context);
      final detail = syncState.errorMessage ?? l10n.librarySyncFailureFallback;
      // A failed background sync leaves the library usable, so it is shown
      // as a quiet, dismissible warning rather than a blocking error.
      return Semantics(
        container: true,
        liveRegion: true,
        label: l10n.syncSettingsStatusFailed,
        child: Material(
          key: _SyncStatusBanner.bannerKey,
          color: tokens.quietWarningContainer,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 20,
                  color: tokens.quietWarningAccent,
                ),
                const SizedBox(width: NavisSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        l10n.syncSettingsStatusFailed,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: tokens.onQuietWarningContainer,
                        ),
                      ),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: NavisSpace.xs),
                TextButton.icon(
                  key: _SyncStatusBanner.retryKey,
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.commonRetry),
                ),
                IconButton(
                  key: _SyncStatusBanner.dismissKey,
                  tooltip: l10n.updateDismiss,
                  onPressed: () => setState(() => _failureDismissed = true),
                  icon: const Icon(Icons.close_rounded, size: 20),
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
          syncState.stage == LibrarySyncStage.fetchingSongs &&
          !syncState.fastPathActive;
      final scanningSongIndex =
          syncState.metadataReady &&
          syncState.stage == LibrarySyncStage.fetchingSongs &&
          syncState.fastPathActive;
      final progress = !durableHydration || total == null || total == 0
          ? null
          : (processed / total).clamp(0.0, 1.0);
      final label = _runningLabel(l10n, total, processed);
      return Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: Material(
          key: _SyncStatusBanner.bannerKey,
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
                    if (widget.onCancel != null)
                      TextButton.icon(
                        key: _SyncStatusBanner.cancelKey,
                        onPressed: widget.onCancel,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(l10n.commonCancel),
                      ),
                  ],
                ),
              ),
              if (!scanningSongIndex)
                LinearProgressIndicator(
                  key: _SyncStatusBanner.progressKey,
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

    // Between runs the hydration backlog is reported in Sync settings, not
    // here: it drains slowly and can include albums the server cannot serve,
    // so a Library notice would never go away.
    return const SizedBox.shrink();
  }

  String _runningLabel(AppLocalizations l10n, int? total, int processed) {
    final syncState = widget.syncState;
    final pending = syncState.pendingHydrationCount ?? 0;
    if (syncState.metadataReady &&
        syncState.stage == LibrarySyncStage.fetchingSongs) {
      if (syncState.fastPathActive) {
        return l10n.librarySyncScanningSongIndex(
          syncState.songIndexEntriesScanned,
        );
      }
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
      LibrarySyncStage.fetchingStarred => l10n.librarySyncStageStarred,
      LibrarySyncStage.fetchingPlaylists => l10n.librarySyncStagePlaylists,
      LibrarySyncStage.finalizing => l10n.librarySyncStageFinalizing,
      _ => l10n.librarySyncRunning,
    };
  }
}

class _SectionRail extends StatelessWidget {
  const new({
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
            final index = normalized.floor().clamp(0, labels.length - 1);
            onLabelSelected(labels[index], animate: false);
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
                borderRadius: NavisRadius.mdAll,
              ),
              child: Column(
                children: labels
                    .map(
                      (label) => Expanded(
                        child: Center(
                          child: Text(
                            label,
                            key: label == activeLabel ? activeLabelKey : null,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
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
  const new({required this.overlayKey, required this.label});

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
              color: Theme.of(context).colorScheme.surfaceContainerHigh
                  .withValues(alpha: 0.92),
              borderRadius: NavisRadius.mdAll,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Text(
                label,
                style: Theme.of(context).textTheme.headlineMedium,
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
  const new _({required this.letter, this.artist});

  const new header(String letter) : this._(letter: letter);

  const new artist(String letter, ArtistsTableData artist)
    : this._(letter: letter, artist: artist);

  final String letter;
  final ArtistsTableData? artist;
}

class _YearListItem {
  new header({
    required this.label,
    required this.isUnknownYear,
    this.decadeStart,
  }) : albums = const [];

  new albumRow(AlbumsTableData left, [AlbumsTableData? right])
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
  const new({
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
        key: const ValueKey<String>('libraryAlbumSortControl'),
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
          // At large system text the two controls still fit geometrically,
          // but each loses enough width to truncate its state label. Stack
          // them before that happens so both the active filter and sort stay
          // legible and directly actionable.
          final useStackedLayout =
              constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;

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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: buildSortDropdown(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoadingListPlaceholder extends StatelessWidget {
  const new();

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
