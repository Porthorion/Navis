import 'dart:async';
import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/downloads/presentation/custom_download_folder_controller.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/list_filter_field.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/player/presentation/play_song_in_collection.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/downloads/domain/download_failure_message.dart';
import 'package:navis/src/features/downloads/presentation/download_missing_section.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/presentation/download_reconciliation_screen.dart';
import 'package:navis/src/features/downloads/presentation/manual_download_matching_provider.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final showSearch = _tabController.index != 2;
    return Scaffold(
      appBar: desktopMode
          ? null
          : AppBar(
              title: Text(l10n.downloadsTitle),
              bottom: TabBar(
                controller: _tabController,
                tabs: <Widget>[
                  Tab(text: l10n.downloadsTabQueue),
                  Tab(text: l10n.downloadsTabDownloaded),
                  Tab(text: l10n.downloadsTabSettings),
                ],
              ),
            ),
      body: Column(
        children: <Widget>[
          if (desktopMode)
            _DownloadsDesktopCommandStrip(
              controller: _tabController,
              searchController: _searchController,
              showSearch: showSearch,
              searchHint: _tabController.index == 0
                  ? l10n.downloadsQueueSearchHint
                  : l10n.downloadsSearchHint,
              onSearchChanged: (value) => setState(() => _query = value),
              onClearSearch: _clearSearch,
            )
          else if (showSearch)
            ListFilterField(
              controller: _searchController,
              hint: _tabController.index == 0
                  ? l10n.downloadsQueueSearchHint
                  : l10n.downloadsSearchHint,
              onChanged: (value) => setState(() => _query = value),
              onClear: _clearSearch,
            ),
          ref
              .watch(downloadFolderProblemProvider)
              .when(
                data: (problem) => problem == null
                    ? const SizedBox.shrink()
                    : _DownloadFolderHoldBanner(problem: problem),
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
              ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: <Widget>[
                _QueueTab(query: _query, onClearQuery: _clearSearch),
                _DownloadedTab(query: _query, onClearQuery: _clearSearch),
                const _DownloadSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadsDesktopCommandStrip extends StatelessWidget {
  const new({
    required this.controller,
    required this.searchController,
    required this.showSearch,
    required this.searchHint,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final TabController controller;
  final TextEditingController searchController;
  final bool showSearch;
  final String searchHint;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey<String>('downloadsDesktopCommandStrip'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
        child: Row(
          children: <Widget>[
            IconButton(
              key: const ValueKey<String>('desktopDownloadsBackButton'),
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () =>
                  NavService.back(context, fallback: AppRoutes.settings),
            ),
            const SizedBox(width: 4),
            Text(
              l10n.downloadsTitle,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: controller,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: <Widget>[
                    Tab(text: l10n.downloadsTabQueue),
                    Tab(text: l10n.downloadsTabDownloaded),
                    Tab(text: l10n.downloadsTabSettings),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerRight,
              child: showSearch
                  ? SizedBox(
                      width: 304,
                      child: ListFilterField(
                        controller: searchController,
                        hint: searchHint,
                        onChanged: onSearchChanged,
                        onClear: onClearSearch,
                        dense: true,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _toggleCustomDownloadFolder(
  BuildContext context,
  WidgetRef ref,
  bool enabled,
) async {
  if (enabled) {
    await _pickCustomDownloadFolder(context, ref);
    return;
  }
  final path = ref.read(customDownloadFolderPathProvider);
  if (path == null || path.trim().isEmpty) {
    await _applyCustomDownloadFolder(context, ref, enabled: false);
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  final confirm = await showConfirmDialog(
    context,
    title: l10n.downloadsCustomFolderDisableTitle,
    message: l10n.downloadsCustomFolderDisableConfirm,
    confirmLabel: l10n.downloadsCustomFolderDisableAction,
    confirmKey: const ValueKey<String>('downloadsCustomFolderDisableConfirm'),
  );
  if (!confirm || !context.mounted) return;
  await _applyCustomDownloadFolder(context, ref, enabled: false);
}

Future<void> _pickCustomDownloadFolder(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context)!;
  final selectedPath = await FilePicker.getDirectoryPath(
    dialogTitle: l10n.downloadsCustomFolderChooseAction,
    androidOptions: Platform.isAndroid
        ? FilePickerAndroidOptions(
            safOptions: AndroidSAFOptions(
              grant: AndroidSAFGrant.lifetime,
              accessMode: AndroidSAFAccessMode.readWrite,
              persistGrant: true,
            ),
          )
        : const AndroidOptions(),
  );
  if (!context.mounted || selectedPath == null) {
    return;
  }
  await _applyCustomDownloadFolder(
    context,
    ref,
    enabled: true,
    path: selectedPath,
  );
}

/// Folder changes run in [customDownloadFolderControllerProvider], so they
/// finish (and fill Manual Matching) even if this tab is left mid-scan;
/// only the notice needs the tab to still be shown.
Future<void> _applyCustomDownloadFolder(
  BuildContext context,
  WidgetRef ref, {
  required bool enabled,
  String? path,
}) async {
  final controller = ref.read(customDownloadFolderControllerProvider.notifier);
  try {
    if (enabled && path != null) {
      await controller.choose(path);
    } else {
      await controller.disable();
    }
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    AppNoticeMessenger.of(context).clearSnackBars();
    showAppNotice(
      context,
      message: enabled
          ? l10n.downloadsCustomFolderSaved
          : l10n.downloadsCustomFolderDisabled,
      level: AppNoticeLevel.success,
    );
  } on Object catch (error) {
    AppLogger.warning('Download folder update failed: ${error.runtimeType}');
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    AppNoticeMessenger.of(context).clearSnackBars();
    showAppNotice(
      context,
      message: error is FileSystemException
          ? l10n.downloadsCustomFolderError(error.message)
          : l10n.downloadsScanError,
      level: AppNoticeLevel.error,
    );
  }
}

String downloadFolderProblemMessage(
  AppLocalizations l10n,
  DownloadFolderProblem problem,
) => switch (problem) {
  DownloadFolderProblem.unset => l10n.downloadsFolderHoldUnset,
  DownloadFolderProblem.missing => l10n.downloadsFolderHoldMissing,
  DownloadFolderProblem.inaccessible => l10n.downloadsFolderHoldInaccessible,
  DownloadFolderProblem.noSpace => l10n.downloadsFolderHoldNoSpace,
};

class _DownloadFolderHoldBanner extends ConsumerWidget {
  const new({required this.problem});
  final DownloadFolderProblem problem;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final busy = ref.watch(customDownloadFolderControllerProvider).busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card.filled(
        key: const ValueKey<String>('downloadsFolderHoldBanner'),
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: Text(downloadFolderProblemMessage(l10n, problem)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _pickCustomDownloadFolder(context, ref),
                    child: Text(l10n.downloadsFolderHoldChoose),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () =>
                              _toggleCustomDownloadFolder(context, ref, false),
                    child: Text(l10n.downloadsFolderHoldUseAppStorage),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Queue tab — shows pending / active / failed downloads
// ---------------------------------------------------------------------------

class _QueueTab extends ConsumerWidget {
  const new({required this.query, required this.onClearQuery});

  final String query;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueAsync = ref.watch(downloadQueueProvider);

    return AsyncBody(
      value: queueAsync,
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            title: l10n.downloadsQueueEmpty,
            subtitle: l10n.downloadsQueueEmptySubtitle,
            icon: Icons.download_outlined,
          );
        }

        // Resolve song data for all items so we can filter by title/artist.
        final songsById =
            ref.watch(downloadRelatedSongsProvider).asData?.value ??
            const <String, SongsTableData>{};
        final resolvedSongs = <int, SongsTableData?>{
          for (final item in items)
            if (item.songId != null) item.id: songsById[item.songId],
        };

        final filtered = query.isEmpty
            ? items
            : items
                  .where((item) {
                    final song = resolvedSongs[item.id];
                    final title = (song?.title ?? item.songId ?? '')
                        .toLowerCase();
                    final artist = (song?.artistName ?? '').toLowerCase();
                    final q = query.toLowerCase();
                    return title.contains(q) || artist.contains(q);
                  })
                  .toList(growable: false);

        final hasFailed = filtered.any(
          (i) => i.status == DownloadStatus.failed,
        );

        Future<void> clearQueue() async {
          final confirmed = await showConfirmDialog(
            context,
            title: l10n.downloadsClearQueue,
            message: l10n.downloadsClearQueueConfirm,
            confirmLabel: l10n.downloadsClearQueue,
          );
          if (!confirmed) return;
          await ref.read(downloadServiceProvider).clearQueue();
        }

        final paused =
            ref.watch(downloadsPausedProvider).asData?.value ?? false;

        return Column(
          children: <Widget>[
            if (paused)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Card.filled(
                  key: const ValueKey<String>('downloadsPausedBanner'),
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.pause_circle_outline),
                    title: Text(l10n.downloadsPausedBanner),
                  ),
                ),
              ),
            if (hasFailed || filtered.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: NavisColorStyleData.tonalStyleOf(context),
                        key: const ValueKey<String>('downloadsPauseToggle'),
                        onPressed: () => unawaited(
                          ref
                              .read(downloadServiceProvider)
                              .setPaused(paused: !paused),
                        ),
                        icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                        label: Text(
                          paused
                              ? l10n.downloadsResumeAll
                              : l10n.downloadsPauseAll,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (hasFailed)
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: NavisColorStyleData.tonalStyleOf(context),
                          onPressed: () {
                            final dao = ref
                                .read(navisDatabaseProvider)
                                .downloadQueueDao;
                            unawaited(dao.retryAllFailed());
                          },
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.downloadsRetryAllFailed),
                        ),
                      ),
                    if (hasFailed) const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: clearQueue,
                        icon: const Icon(Icons.clear_all),
                        label: Text(l10n.downloadsClearQueue),
                      ),
                    ),
                  ],
                ),
              ),
            if (filtered.isEmpty && query.isNotEmpty)
              Expanded(
                child: EmptyState(
                  title: l10n.downloadsSearchNoResults(query),
                  icon: Icons.search_off,
                  action: FilledButton.tonalIcon(
                    style: NavisColorStyleData.tonalStyleOf(context),
                    onPressed: onClearQuery,
                    icon: const Icon(Icons.clear_all_outlined),
                    label: Text(l10n.searchShowAll),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    return _QueueItemTile(item: item);
                  },
                ),
              ),
          ],
        );
      },
      loading: const ShimmerListPage(count: 8),
      errorTitle: l10n.downloadsErrorLoadingQueue,
      onRetry: () => ref.invalidate(downloadQueueProvider),
    );
  }
}

class _QueueItemTile extends ConsumerWidget {
  const new({required this.item});

  final DownloadQueueTableData item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songId = item.songId;
    final songAsync = songId != null
        ? ref.watch(songByIdProvider(songId))
        : null;
    final song = songAsync?.asData?.value;

    final title = song?.title ?? songId ?? '—';
    final artist = song?.artistName ?? '';
    final isActive = item.status == DownloadStatus.downloading;
    final isFailed = item.status == DownloadStatus.failed;
    final playbackState = songId == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(songId));
    final isSelected = playbackState.isSelected;

    final tile = ListTile(
      selected: isSelected,
      selectedColor: Theme.of(context).colorScheme.primary,
      selectedTileColor: Theme.of(context).colorScheme.primary
          .withValues(alpha: 0.08),
      leading: ArtworkPlaybackMarker(
        state: playbackState,
        child: SizedBox(
          width: 48,
          height: 48,
          child: song?.coverArt != null
              ? CoverArtImage(
                  coverArtId: song!.coverArt,
                  size: 48,
                  width: 48,
                  height: 48,
                  shape: ArtworkShapeRole.cover,
                  isExternalSource: song.isExternal,
                  remoteSourceIndicatorPolicy:
                      RemoteSourceIndicatorPolicy.hidden,
                )
              : Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: artworkBorderRadius(
                      ref.watch(coverArtShapeProvider),
                      extent: 48,
                    ),
                  ),
                  child: const Icon(Icons.music_note),
                ),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isSelected
            ? TextStyle(color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (artist.isNotEmpty || (song?.isExternal ?? false))
            RemoteSourceMetadataLine(
              metadata: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              isRemote: song?.isExternal ?? false,
              spacing: artist.isEmpty ? 0 : 6,
            ),
          if (isActive)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // A transfer without a known length has no progress to show.
              child: LinearProgressIndicator(
                value: item.progress > 0 ? item.progress : null,
              ),
            ),
          if (isFailed)
            Text(
              downloadFailureMessage(l10n, item.failureReason),
              semanticsLabel:
                  '${l10n.downloadsStatusFailed}: ${downloadFailureMessage(l10n, item.failureReason)}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      trailing: IconButton(
        icon: Icon(isFailed ? Icons.refresh : Icons.close),
        tooltip: isFailed
            ? l10n.downloadsRetryFailed
            : l10n.downloadsCancelAction,
        onPressed: () {
          if (isFailed) {
            final dao = ref.read(navisDatabaseProvider).downloadQueueDao;
            unawaited(dao.retry(item.id));
          } else {
            // Stops the transfer too when this item is downloading.
            unawaited(
              ref.read(downloadServiceProvider).cancelQueueItem(item.id),
            );
          }
        },
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: tile);
  }
}

// ---------------------------------------------------------------------------
// Downloaded tab — shows permanently cached tracks (uses Riverpod)
// ---------------------------------------------------------------------------

class _DownloadedTab extends ConsumerWidget {
  const new({required this.query, required this.onClearQuery});

  final String query;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tracksAsync = ref.watch(permanentCachedTracksProvider);

    return AsyncBody(
      value: tracksAsync,
      data: (tracks) {
        if (tracks.isEmpty) {
          return EmptyState(
            title: l10n.downloadsDownloadedEmpty,
            subtitle: l10n.downloadsDownloadedEmptySubtitle,
            icon: Icons.download_done_outlined,
          );
        }

        // Resolve song data so we can filter by title/artist.
        final resolvedSongs =
            ref.watch(downloadRelatedSongsProvider).asData?.value ??
            const <String, SongsTableData>{};

        final filtered = query.isEmpty
            ? tracks
            : tracks
                  .where((track) {
                    final song = resolvedSongs[track.songId];
                    final title = (song?.title ?? track.songId).toLowerCase();
                    final artist = (song?.artistName ?? '').toLowerCase();
                    final q = query.toLowerCase();
                    return title.contains(q) || artist.contains(q);
                  })
                  .toList(growable: false);

        return Column(
          children: <Widget>[
            if (filtered.isEmpty && query.isNotEmpty)
              Expanded(
                child: EmptyState(
                  title: l10n.downloadsSearchNoResults(query),
                  icon: Icons.search_off,
                  action: FilledButton.tonalIcon(
                    style: NavisColorStyleData.tonalStyleOf(context),
                    onPressed: onClearQuery,
                    icon: const Icon(Icons.clear_all_outlined),
                    label: Text(l10n.searchShowAll),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: filtered.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return const AdaptiveTrackHeader(actionExtent: 48);
                    }
                    final track = filtered[index - 1];
                    return _DownloadedTrackTile(
                      track: track,
                      allTracks: filtered,
                      trackIndex: index - 1,
                    );
                  },
                ),
              ),
          ],
        );
      },
      loading: const ShimmerListPage(count: 8),
      errorTitle: l10n.downloadsErrorLoadingQueue,
      onRetry: () => ref.invalidate(permanentCachedTracksProvider),
    );
  }
}

class _DownloadedTrackTile extends ConsumerWidget {
  const new({
    required this.track,
    required this.allTracks,
    required this.trackIndex,
  });

  final CachedTracksTableData track;
  final List<CachedTracksTableData> allTracks;
  final int trackIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(track.songId));
    final song = songAsync.asData?.value;

    final title = song?.title ?? track.songId;
    final artist = song?.artistName ?? '';
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(track.songId),
    );
    final isSelected = playbackState.isSelected;

    final tile = AdaptiveTrackRow(
      title: title,
      artist: artist,
      album: song?.albumName,
      duration: song?.duration,
      selected: isSelected,
      isRemote: song?.isExternal ?? false,
      actionExtent: 48,
      leading: ArtworkPlaybackMarker(
        state: playbackState,
        child: SizedBox(
          width: 48,
          height: 48,
          child: song?.coverArt != null
              ? CoverArtImage(
                  coverArtId: song!.coverArt,
                  size: 48,
                  width: 48,
                  height: 48,
                  shape: ArtworkShapeRole.cover,
                  isExternalSource: song.isExternal,
                  remoteSourceIndicatorPolicy:
                      RemoteSourceIndicatorPolicy.hidden,
                )
              : Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: artworkBorderRadius(
                      ref.watch(coverArtShapeProvider),
                      extent: 48,
                    ),
                  ),
                  child: const Icon(Icons.music_note),
                ),
        ),
      ),
      badge: Text(
        '${track.format.toUpperCase()} · ${formatBytes(track.fileSize)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      actions: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: l10n.downloadsRemoveAction,
        onPressed: () => _confirmAndDelete(context, ref, track, l10n),
      ),
      onTap: () => _playTrack(ref),
      onLongPress: () => _showTrackMenu(context, ref, track, l10n),
    );
    final interactiveTile = !isDesktopRuntime
        ? tile
        : GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (details) => unawaited(
              _showTrackMenu(
                context,
                ref,
                track,
                l10n,
                anchor: details.globalPosition,
              ),
            ),
            child: tile,
          );
    return SongPlaybackSemantics(state: playbackState, child: interactiveTile);
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n,
  ) async {
    final confirmed = await confirmRemoveDownload(context);
    if (!confirmed) return;
    await ref.read(downloadServiceProvider).removeDownloadedTrack(track.songId);
  }

  Future<void> _showTrackMenu(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n, {
    Offset? anchor,
  }) async {
    if (anchor != null && isDesktopRuntime) {
      final action = await showDesktopContextMenu<_DownloadedTrackAction>(
        context: context,
        anchor: anchor,
        items: <PopupMenuEntry<_DownloadedTrackAction>>[
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.playNow,
            child: Text(l10n.librarySongMenuPlayNow),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.changeQuality,
            child: Text(l10n.downloadsChangeQuality),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.addQueue,
            child: Text(l10n.librarySongMenuAddToQueue),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.openFolder,
            child: Text(l10n.downloadsOpenFolderAction),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.removeDownload,
            textStyle: TextStyle(color: Theme.of(context).colorScheme.error),
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      );
      if (!context.mounted || action == null) {
        return;
      }
      await _handleTrackMenuAction(context, ref, track, l10n, action);
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(l10n.librarySongMenuPlayNow),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.playNow,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_vert),
                title: Text(l10n.downloadsChangeQuality),
                subtitle: Text(
                  l10n.downloadsChangeQualityCurrent(
                    downloadQualityLabel(
                      l10n,
                      downloadedQualityChoice(
                        track,
                        ref.read(songByIdProvider(track.songId)).asData?.value,
                      ),
                    ),
                  ),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.changeQuality,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(l10n.librarySongMenuAddToQueue),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.addQueue,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(l10n.downloadsOpenFolderAction),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.openFolder,
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  l10n.downloadsRemoveAction,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.removeDownload,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Plays this download, with the whole downloads list when Album Queue is on.
  void _playTrack(WidgetRef ref) => playSongIdInCollection(
    ref,
    allTracks.map((t) => t.songId).toList(growable: false),
    trackIndex,
    expandMatchFlows: true,
  );

  Future<void> _handleTrackMenuAction(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n,
    _DownloadedTrackAction action,
  ) async {
    switch (action) {
      case _DownloadedTrackAction.playNow:
        _playTrack(ref);
        return;
      case _DownloadedTrackAction.changeQuality:
        final currentChoice = downloadedQualityChoice(
          track,
          ref.read(songByIdProvider(track.songId)).asData?.value,
        );
        final preference = await ref
            .read(navisDatabaseProvider)
            .appSettingsDao
            .getDownloadQualityPreference();
        if (!context.mounted) return;
        // An explicit change always asks, whatever the saved preference.
        final choice = await showDownloadQualitySheet(
          context,
          initialChoice: currentChoice,
          format: currentChoice.format ?? preference.format,
        );
        if (choice == null) return;
        final service = ref.read(downloadServiceProvider);
        await service.removeDownloadedTrack(track.songId);
        await service.enqueueSong(
          track.songId,
          forceRedownload: true,
          quality: choice.quality,
          format: choice.format,
        );
        if (context.mounted) {
          showAppNotice(
            context,
            message: l10n.downloadsRedownloadQueued,
            level: AppNoticeLevel.success,
          );
        }
        return;
      case _DownloadedTrackAction.addQueue:
        final song = ref.read(songByIdProvider(track.songId)).asData?.value;
        await ref.read(queueProvider.notifier).add(track.songId);
        if (context.mounted) {
          showAppNotice(
            context,
            message: l10n.librarySongAddedToQueue(song?.title ?? track.songId),
            level: AppNoticeLevel.success,
          );
        }
        return;
      case _DownloadedTrackAction.openFolder:
        final opened = await openDirectoryInFileManager(
          File(track.filePath).parent.path,
        );
        if (!opened && context.mounted) {
          showAppNotice(
            context,
            message: l10n.downloadsOpenFolderError,
            level: AppNoticeLevel.error,
          );
        }
        return;
      case _DownloadedTrackAction.removeDownload:
        await _confirmAndDelete(context, ref, track, l10n);
        return;
    }
  }
}

enum _DownloadedTrackAction {
  playNow,
  changeQuality,
  addQueue,
  openFolder,
  removeDownload,
}

// ---------------------------------------------------------------------------
// Download Settings tab
// ---------------------------------------------------------------------------

class _DownloadSettingsTab extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_DownloadSettingsTab> createState() =>
      _DownloadSettingsTabState();
}

class _DownloadSettingsTabState extends ConsumerState<_DownloadSettingsTab> {
  bool _clearing = false;

  bool get _supportsCustomDownloadFolderSelection =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows;

  Future<bool> _confirmCellularAutoDownload() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsAutoDownloadCellularWarningTitle,
      message: l10n.cacheSettingsAutoDownloadCellularWarning,
      confirmLabel: l10n.cacheSettingsAutoDownloadCellularWarningContinue,
    );
    return confirm;
  }

  Future<void> _updateWifiOnlyDownloads(bool enabled) async {
    if (!enabled && ref.read(autoDownloadStarredOnWifiProvider)) {
      final confirmed = await _confirmCellularAutoDownload();
      if (!confirmed || !mounted) {
        return;
      }
    }
    await ref
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateWifiOnlyDownloads(enabled: enabled);
  }

  Future<void> _updateAutoDownloadLiked(bool enabled) async {
    if (enabled && !ref.read(wifiOnlyDownloadsProvider)) {
      final confirmed = await _confirmCellularAutoDownload();
      if (!confirmed || !mounted) {
        return;
      }
    }
    await ref
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateAutoDownloadStarredOnWifi(enabled: enabled);
  }

  Future<void> _clearDownloads() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsClearPermanent,
      message: l10n.cacheSettingsClearPermanentConfirm,
      confirmLabel: l10n.cacheSettingsClearPermanent,
      destructive: true,
    );
    if (!confirm || !mounted) return;

    setState(() => _clearing = true);
    try {
      final tracks = await ref
          .read(navisDatabaseProvider)
          .cacheDao
          .watchCachedTracksByType(CacheType.permanent)
          .first;
      await ref
          .read(downloadServiceProvider)
          .removeDownloadedTracks(tracks.map((t) => t.songId));
      if (mounted) {
        AppNoticeMessenger.of(context).clearSnackBars();
        showAppNotice(
          context,
          message: l10n.cacheSettingsClearSuccess,
          level: AppNoticeLevel.success,
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _rescanCustomDownloadFolder() async {
    try {
      final result = await ref
          .read(customDownloadFolderControllerProvider.notifier)
          .rescan();
      if (result == null || !mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!
            .downloadsRescanImported(result.importedCount),
        level: AppNoticeLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Download folder rescan failed. $error\n$stackTrace');
      if (mounted) {
        showAppNotice(
          context,
          message: AppLocalizations.of(context)!.downloadsScanError,
          level: AppNoticeLevel.error,
        );
      }
    }
  }

  Future<void> _openManualMatching() async {
    final matching = ref.read(manualDownloadMatchingProvider);
    final preview = matching.preview;
    if (preview == null || !matching.needsManualMatching) return;
    final manualSongIds = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute<Map<String, String>>(
        builder: (_) => DownloadReconciliationScreen(
          preview: preview,
          automaticallyImported: matching.automaticallyImported,
          pendingPaths: matching.pendingPaths,
        ),
      ),
    );
    if (manualSongIds == null || manualSongIds.isEmpty || !mounted) return;
    try {
      final result = await ref
          .read(customDownloadFolderControllerProvider.notifier)
          .importManual(preview, manualSongIds);
      ref
          .read(manualDownloadMatchingProvider.notifier)
          .markImported(manualSongIds.keys);
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!
            .downloadsManualImported(result.importedCount),
        level: AppNoticeLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Manual download import failed. $error\n$stackTrace');
      if (mounted) {
        showAppNotice(
          context,
          message: AppLocalizations.of(context)!.downloadsScanError,
          level: AppNoticeLevel.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final permanentStats = ref.watch(permanentCacheStatsProvider);
    final customFolderEnabled = ref.watch(customDownloadFolderEnabledProvider);
    final customFolderPath = ref.watch(customDownloadFolderPathProvider);
    final manualMatching = ref.watch(manualDownloadMatchingProvider);
    final updatingFolder = ref
        .watch(customDownloadFolderControllerProvider)
        .busy;

    if (_clearing || updatingFolder) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              updatingFolder
                  ? l10n.downloadsCustomFolderUpdating
                  : l10n.downloadsRemoving,
            ),
          ],
        ),
      );
    }

    return ListView(
      children: <Widget>[
        const _DownloadQualitySettings(),
        const _ConcurrentDownloadsTile(),
        const Divider(),
        if (!isDesktopRuntime)
          SwitchListTile(
            title: Text(l10n.cacheSettingsWifiOnlyDownloads),
            subtitle: Text(l10n.cacheSettingsWifiOnlyDownloadsSub),
            value: ref.watch(wifiOnlyDownloadsProvider),
            onChanged: _updateWifiOnlyDownloads,
          ),
        SwitchListTile(
          title: Text(l10n.cacheSettingsAutoDownloadStarred),
          subtitle: Text(l10n.cacheSettingsAutoDownloadStarredSub),
          value: ref.watch(autoDownloadStarredOnWifiProvider),
          onChanged: _updateAutoDownloadLiked,
        ),
        SwitchListTile(
          key: const ValueKey<String>('downloadsCustomFolderSwitch'),
          title: Text(l10n.downloadsCustomFolderTitle),
          subtitle:
              _supportsCustomDownloadFolderSelection &&
                  customFolderEnabled &&
                  customFolderPath != null
              ? _CustomFolderLabel(path: customFolderPath)
              : Text(
                  _supportsCustomDownloadFolderSelection
                      ? l10n.downloadsCustomFolderSubtitle
                      : l10n.downloadsCustomFolderUnsupported,
                ),
          value: customFolderEnabled,
          onChanged: _supportsCustomDownloadFolderSelection
              ? (enabled) => _toggleCustomDownloadFolder(context, ref, enabled)
              : null,
        ),
        if (_supportsCustomDownloadFolderSelection && customFolderEnabled)
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(l10n.downloadsCustomFolderChooseAction),
            subtitle: _CustomFolderLabel(path: customFolderPath),
            onTap: () => _pickCustomDownloadFolder(context, ref),
          ),
        if (_supportsCustomDownloadFolderSelection && customFolderEnabled)
          ListTile(
            leading: const Icon(Icons.manage_search_outlined),
            title: Text(l10n.downloadsRescanTitle),
            subtitle: Text(l10n.downloadsRescanSubtitle),
            onTap: _rescanCustomDownloadFolder,
          ),
        if (_supportsCustomDownloadFolderSelection && customFolderEnabled)
          ListTile(
            enabled: manualMatching.needsManualMatching,
            leading: const Icon(Icons.rule_folder_outlined),
            title: Text(l10n.downloadsManualMatchingTitle),
            subtitle: Text(
              manualMatching.needsManualMatching
                  ? l10n.downloadsManualMatchingPending(
                      manualMatching.pendingCount,
                    )
                  : l10n.downloadsManualMatchingNone,
            ),
            trailing: _ManualMatchingCount(
              count: manualMatching.pendingCount,
              enabled: manualMatching.needsManualMatching,
            ),
            onTap: manualMatching.needsManualMatching
                ? _openManualMatching
                : null,
          ),
        const Divider(),
        permanentStats.when(
          data: (stats) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  formatBytes(stats.totalBytes),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.cacheSettingsPermanentTrackCount(stats.trackCount),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const SizedBox.shrink(),
        ),
        const Divider(),
        const DownloadMissingSection(),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(l10n.cacheSettingsClearPermanent),
          onTap: _clearDownloads,
        ),
      ],
    );
  }
}

/// The saved download quality and the transcode format.
class _DownloadQualitySettings extends ConsumerWidget {
  const new();

  static const String _ask = 'ask';
  static const String _original = 'original';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final preference =
        ref.watch(downloadQualityPreferenceProvider).asData?.value ??
        const DownloadQualityPreference();
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    final selected = switch (preference.mode) {
      DownloadQualityMode.ask => _ask,
      DownloadQualityMode.original => _original,
      DownloadQualityMode.transcode => '${preference.bitRate}',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.downloadsSettingsQualitySection,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('downloadQualityMode:$selected'),
            initialValue: selected,
            decoration: InputDecoration(
              labelText: l10n.downloadsSettingsQualityLabel,
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: _ask,
                child: Text(l10n.downloadsSettingsQualityAsk),
              ),
              DropdownMenuItem<String>(
                value: _original,
                child: Text(l10n.downloadQualityOriginal),
              ),
              for (final kbps in kDownloadBitRateOptions)
                DropdownMenuItem<String>(
                  value: '$kbps',
                  child: Text(
                    downloadQualityLabel(
                      l10n,
                      DownloadQualityChoice(
                        quality: '$kbps',
                        format: preference.format,
                      ),
                    ),
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null || value == selected) return;
              unawaited(switch (value) {
                _ask => dao.updateDownloadQuality(
                  mode: DownloadQualityMode.ask,
                ),
                _original => dao.updateDownloadQuality(
                  mode: DownloadQualityMode.original,
                ),
                _ => dao.updateDownloadQuality(
                  mode: DownloadQualityMode.transcode,
                  bitRate: int.parse(value),
                ),
              });
              // Choosing here answers the one-time question too.
              unawaited(dao.updateDownloadQualityPrompted(prompted: true));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('downloadFormat:${preference.format}'),
            initialValue: preference.format,
            decoration: InputDecoration(
              labelText: l10n.downloadsSettingsFormatLabel,
              helperText: l10n.downloadsSettingsFormatHelper,
            ),
            items: <DropdownMenuItem<String>>[
              for (final format in kDownloadFormatOptions)
                DropdownMenuItem<String>(
                  value: format,
                  child: Text(downloadFormatLabel(format)),
                ),
            ],
            onChanged: preference.mode == DownloadQualityMode.original
                ? null
                : (value) {
                    if (value == null || value == preference.format) return;
                    unawaited(dao.updateDownloadFormat(value));
                  },
          ),
        ],
      ),
    );
  }
}

/// How many downloads transfer at once.
class _ConcurrentDownloadsTile extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_ConcurrentDownloadsTile> createState() =>
      _ConcurrentDownloadsTileState();
}

class _ConcurrentDownloadsTileState
    extends ConsumerState<_ConcurrentDownloadsTile> {
  /// The value while the slider is dragged; null shows the saved value.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final saved =
        ref.watch(maxConcurrentDownloadsProvider).asData?.value ??
        kDefaultConcurrentDownloads;
    final value = _dragValue ?? saved.toDouble();
    final count = value.round();
    final description = l10n.downloadsSettingsConcurrentValue(count);
    return ListTile(
      key: const ValueKey<String>('downloadsConcurrentTile'),
      title: Text(l10n.downloadsSettingsConcurrentTitle),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            isDesktopRuntime
                ? description
                : l10n.downloadsSettingsConcurrentCellular(description),
          ),
          Slider(
            key: const ValueKey<String>('downloadsConcurrentSlider'),
            min: 1,
            max: kMaxConcurrentDownloads.toDouble(),
            divisions: kMaxConcurrentDownloads - 1,
            value: value,
            label: '$count',
            onChanged: (next) => setState(() => _dragValue = next),
            onChangeEnd: (next) {
              setState(() => _dragValue = null);
              unawaited(
                ref
                    .read(downloadServiceProvider)
                    .setMaxConcurrentDownloads(next.round()),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A tree URI is intentionally opaque. Android users see the provider's
/// folder name, while desktop platforms retain the useful filesystem path.
/// Names of SAF folders already looked up, so rebuilding the Downloads
/// settings does not query the folder's provider again.
final Map<String, Future<AndroidSafTree>> _safFolderDetails =
    <String, Future<AndroidSafTree>>{};

class _CustomFolderLabel extends StatelessWidget {
  const new({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final value = path;
    if (!Platform.isAndroid ||
        value == null ||
        !value.startsWith('content://')) {
      return Text(value ?? '');
    }
    return FutureBuilder<AndroidSafTree>(
      future: _safFolderDetails[value] ??= const AndroidSafStorage()
          .inspectTree(value)
          .catchError((Object error) {
            // Look the folder up again next time instead of caching a failure.
            unawaited(_safFolderDetails.remove(value));
            Error.throwWithStackTrace(error, StackTrace.current);
          }),
      builder: (context, snapshot) => Text(
        snapshot.data?.displayName ??
            AppLocalizations.of(context)!.downloadsCustomFolderSelected,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ManualMatchingCount extends StatelessWidget {
  const new({required this.count, required this.enabled});

  final int count;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final colorStyle = NavisColorStyleData.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: enabled
            ? colorStyle.tonalControlFill(colors)
            : colors.surfaceContainerHighest,
        borderRadius: NavisShapeData.of(context).controlAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          '$count',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: enabled
                ? colorStyle.onTonalControlFill(colors)
                : colors.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
