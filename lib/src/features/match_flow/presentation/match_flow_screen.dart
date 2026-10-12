import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_error_message.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';

final matchFlowsProvider = StreamProvider<List<MatchFlowWithSongs>>((ref) {
  return ref.watch(matchFlowDaoProvider).watchFlowsWithSongs();
});

class MatchFlowScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final flowsAsync = ref.watch(matchFlowsProvider);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.matchFlowTitle),
        actions: <Widget>[
          if (desktopMode)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: () => _createFlow(context, ref),
                icon: const Icon(Icons.add),
                label: Text(l10n.matchFlowCreateAction),
              ),
            ),
        ],
      ),
      floatingActionButton: desktopMode
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _createFlow(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.matchFlowCreateAction),
            ),
      body: AsyncBody(
        value: flowsAsync,
        data: (flows) {
          if (flows.isEmpty) {
            return _EmptyMatchFlowState(
              onCreate: () => _createFlow(context, ref),
            );
          }
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              desktopMode ? 24 : 16,
              desktopMode ? 24 : 16,
              desktopMode ? 24 : 16,
              desktopMode ? 24 : 96,
            ),
            itemCount: flows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _MatchFlowCard(flow: flows[index]),
          );
        },
        errorTitle: l10n.matchFlowLoadError,
        onRetry: () => ref.invalidate(matchFlowsProvider),
      ),
    );
  }

  Future<void> _createFlow(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(matchFlowDaoProvider).createFlow();
    } on Object {
      if (!context.mounted) return;
      showAppNotice(
        context,
        message: l10n.matchFlowSaveError,
        level: AppNoticeLevel.error,
      );
    }
  }
}

class _EmptyMatchFlowState extends StatelessWidget {
  const new({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.account_tree_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.matchFlowEmptyTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.matchFlowEmptySubtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: Text(l10n.matchFlowCreateAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _MatchFlowCard extends ConsumerStatefulWidget {
  const new({required this.flow});

  final MatchFlowWithSongs flow;

  @override
  ConsumerState<_MatchFlowCard> createState() => _MatchFlowCardState();
}

class _MatchFlowCardState extends ConsumerState<_MatchFlowCard> {
  bool _contentsExpanded = false;
  List<MatchFlowSongEntry>? _optimisticSongs;
  List<String>? _pendingSongOrder;

  @override
  void didUpdateWidget(covariant _MatchFlowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow.flow.id != widget.flow.flow.id) {
      _optimisticSongs = null;
      _pendingSongOrder = null;
      return;
    }

    final incomingOrder = _songOrder(widget.flow.songs);
    final pendingOrder = _pendingSongOrder;
    if (pendingOrder == null) {
      _optimisticSongs = null;
      return;
    }
    if (_sameOrder(incomingOrder, pendingOrder)) {
      _optimisticSongs = null;
      _pendingSongOrder = null;
      return;
    }
    final optimistic = _optimisticSongs;
    if (optimistic != null && !_sameSongMembers(incomingOrder, optimistic)) {
      _optimisticSongs = null;
      _pendingSongOrder = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final flow = widget.flow;
    final visibleSongs = _optimisticSongs ?? flow.songs;
    final visibleFlow = MatchFlowWithSongs(
      flow: flow.flow,
      songs: visibleSongs,
    );
    final contentsVisible = _contentsExpanded;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      flow.flow.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      l10n.matchFlowSongCount(visibleSongs.length),
                    ),
                  ),
                ),
                Switch(
                  value: flow.flow.enabled,
                  onChanged: (value) => _run(context, ref, () async {
                    if (!value && mounted) {
                      setState(() {
                        _contentsExpanded = false;
                      });
                    }
                    await ref
                        .read(matchFlowDaoProvider)
                        .setFlowEnabled(flow.flow.id, enabled: value);
                  }),
                ),
                PopupMenuButton<_FlowAction>(
                  onSelected: (action) => switch (action) {
                    _FlowAction.rename => _rename(context),
                    _FlowAction.delete => _delete(context),
                  },
                  itemBuilder: (context) => <PopupMenuEntry<_FlowAction>>[
                    PopupMenuItem(
                      value: _FlowAction.rename,
                      child: Text(l10n.commonRename),
                    ),
                    PopupMenuItem(
                      value: _FlowAction.delete,
                      child: Text(l10n.commonDelete),
                    ),
                  ],
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music),
              title: Text(l10n.matchFlowContentsTitle),
              trailing: IconButton(
                tooltip: contentsVisible
                    ? l10n.matchFlowCollapseContents
                    : l10n.matchFlowExpandContents,
                onPressed: _toggleContents,
                icon: Icon(
                  contentsVisible
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                ),
              ),
              onTap: _toggleContents,
            ),
            if (contentsVisible)
              _MatchFlowContents(
                flow: visibleFlow,
                enabled: flow.flow.enabled,
                onReorder: _reorderSong,
                onRemove: (songId) => _run(
                  context,
                  ref,
                  () => ref
                      .read(matchFlowDaoProvider)
                      .removeSong(flow.flow.id, songId),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleContents() {
    setState(() {
      _contentsExpanded = !_contentsExpanded;
    });
  }

  void _reorderSong(int oldIndex, int newIndex) {
    final flow = widget.flow;
    final adjusted = newIndex;
    final currentSongs = List<MatchFlowSongEntry>.of(
      _optimisticSongs ?? flow.songs,
    );
    if (oldIndex < 0 ||
        oldIndex >= currentSongs.length ||
        adjusted < 0 ||
        adjusted >= currentSongs.length) {
      return;
    }
    final previousSongs = List<MatchFlowSongEntry>.of(currentSongs);
    final moved = currentSongs.removeAt(oldIndex);
    currentSongs.insert(adjusted, moved);
    final pendingOrder = _songOrder(currentSongs);
    setState(() {
      _optimisticSongs = List<MatchFlowSongEntry>.unmodifiable(currentSongs);
      _pendingSongOrder = pendingOrder;
    });

    final songId = moved.link.songId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _run(
          context,
          ref,
          () => ref
              .read(matchFlowDaoProvider)
              .reorderSong(flow.flow.id, songId, newIndex: adjusted),
        ).then((success) {
          if (success || !mounted) return;
          final activePendingOrder = _pendingSongOrder;
          if (activePendingOrder == null ||
              !_sameOrder(activePendingOrder, pendingOrder)) {
            return;
          }
          setState(() {
            _optimisticSongs = List<MatchFlowSongEntry>.unmodifiable(
              previousSongs,
            );
            _pendingSongOrder = null;
          });
        }),
      );
    });
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _RenameMatchFlowDialog(initialName: widget.flow.flow.name),
    );
    if (name == null) return;
    if (!context.mounted) return;
    await _run(
      context,
      ref,
      () =>
          ref.read(matchFlowDaoProvider).renameFlow(widget.flow.flow.id, name),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.matchFlowDeleteTitle,
      message: l10n.matchFlowDeleteMessage(widget.flow.flow.name),
      confirmLabel: l10n.commonDelete,
      cancelLabel: l10n.commonCancel,
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(matchFlowDaoProvider).deleteFlow(widget.flow.flow.id),
    );
  }

  Future<bool> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
      return true;
    } on MatchFlowException catch (error) {
      if (!context.mounted) return false;
      showAppNotice(
        context,
        message: matchFlowErrorMessage(l10n, error),
        level: AppNoticeLevel.info,
      );
      return false;
    } on Object {
      if (!context.mounted) return false;
      showAppNotice(
        context,
        message: l10n.matchFlowSaveError,
        level: AppNoticeLevel.error,
      );
      return false;
    }
  }

  List<String> _songOrder(List<MatchFlowSongEntry> songs) {
    return songs.map((entry) => entry.link.songId).toList(growable: false);
  }

  bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _sameSongMembers(List<String> incoming, List<MatchFlowSongEntry> songs) {
    final optimistic = _songOrder(songs);
    if (incoming.length != optimistic.length) return false;
    final incomingIds = incoming.toSet();
    final optimisticIds = optimistic.toSet();
    return incomingIds.containsAll(optimisticIds) &&
        optimisticIds.containsAll(incomingIds);
  }
}

class _RenameMatchFlowDialog extends StatefulWidget {
  const new({required this.initialName});

  final String initialName;

  @override
  State<_RenameMatchFlowDialog> createState() => _RenameMatchFlowDialogState();
}

class _RenameMatchFlowDialogState extends State<_RenameMatchFlowDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.matchFlowRenameTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: l10n.matchFlowNameLabel),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _MatchFlowContents extends ConsumerWidget {
  const new({
    required this.flow,
    required this.enabled,
    required this.onReorder,
    required this.onRemove,
  });

  final MatchFlowWithSongs flow;
  final bool enabled;
  final ReorderCallback onReorder;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          children: <Widget>[
            if (flow.songs.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.matchFlowNoSongs,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  return ReorderableListView.builder(
                    shrinkWrap: true,
                    primary: false,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: flow.songs.length,
                    onReorderItem: onReorder,
                    proxyDecorator: (child, index, animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) {
                          final elevation = animation.value * 6;
                          return SizedBox(
                            width: constraints.maxWidth,
                            child: Material(
                              elevation: elevation,
                              color: Theme.of(context).colorScheme.surface,
                              child: child,
                            ),
                          );
                        },
                        child: child,
                      );
                    },
                    itemBuilder: (context, index) {
                      final entry = flow.songs[index];
                      return _MatchFlowSongTile(
                        key: ValueKey('${flow.flow.id}-${entry.link.songId}'),
                        entry: entry,
                        index: index,
                        onRemove: () => onRemove(entry.link.songId),
                      );
                    },
                  );
                },
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    NavService.openMatchFlowSearch(context, ref, flow.flow.id),
                icon: const Icon(Icons.add),
                label: Text(l10n.matchFlowAddSongAction),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MatchFlowSongTile extends ConsumerWidget {
  const new({
    required super.key,
    required this.entry,
    required this.index,
    required this.onRemove,
  });

  final MatchFlowSongEntry entry;
  final int index;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final song = entry.song;
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(entry.link.songId),
    );
    final isSelected = playbackState.isSelected;
    final title =
        song?.title ?? l10n.matchFlowUnresolvedSong(entry.link.songId);
    final subtitle = song == null
        ? entry.link.songId
        : [
            song.artistName,
            song.albumName,
          ].where((value) => value != null && value.isNotEmpty).join(' · ');
    final row = Material(
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: <Widget>[
            if (song == null)
              SizedBox(
                width: 44,
                height: 44,
                child: isSelected
                    ? Center(child: SongPlaybackMarker(state: playbackState))
                    : const Icon(Icons.music_note_outlined),
              )
            else
              ArtworkPlaybackMarker(
                state: playbackState,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: CoverArtImage(
                    coverArtId: song.coverArt,
                    size: 80,
                    width: 44,
                    height: 44,
                    shape: ArtworkShapeRole.cover,
                    isExternalSource: song.isExternal,
                    remoteSourceIndicatorPolicy:
                        RemoteSourceIndicatorPolicy.hidden,
                  ),
                ),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                        ),
                      ),
                      if (index == 0) ...<Widget>[
                        const SizedBox(width: 8),
                        Chip(
                          label: Text(l10n.matchFlowMasterLabel),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  if (subtitle.isNotEmpty || (song?.isExternal ?? false))
                    RemoteSourceMetadataLine(
                      metadata: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      isRemote: song?.isExternal ?? false,
                      spacing: subtitle.isEmpty ? 0 : 6,
                    ),
                ],
              ),
            ),
            Semantics(
              button: true,
              label: l10n.commonRemove,
              child: IconButton(
                tooltip: l10n.commonRemove,
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: Semantics(
                button: true,
                label: l10n.commonReorder,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: row);
  }
}

enum _FlowAction { rename, delete }
