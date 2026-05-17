import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/providers/app_providers.dart';

final matchFlowsProvider = StreamProvider<List<MatchFlowWithSongs>>((ref) {
  return ref.watch(matchFlowDaoProvider).watchFlowsWithSongs();
});

class MatchFlowScreen extends ConsumerWidget {
  const MatchFlowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final flowsAsync = ref.watch(matchFlowsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.matchFlowTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createFlow(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.matchFlowCreateAction),
      ),
      body: flowsAsync.when(
        data: (flows) {
          if (flows.isEmpty) {
            return _EmptyMatchFlowState(
              onCreate: () => _createFlow(context, ref),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: flows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _MatchFlowCard(flow: flows[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.matchFlowLoadError(error.toString()),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createFlow(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(matchFlowDaoProvider).createFlow();
    } on Object catch (error) {
      if (!context.mounted) return;
      showAppNotice(
        context,
        message: l10n.matchFlowSaveError(error.toString()),
        level: AppNoticeLevel.error,
      );
    }
  }
}

class _EmptyMatchFlowState extends StatelessWidget {
  const _EmptyMatchFlowState({required this.onCreate});

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
  const _MatchFlowCard({required this.flow});

  final MatchFlowWithSongs flow;

  @override
  ConsumerState<_MatchFlowCard> createState() => _MatchFlowCardState();
}

class _MatchFlowCardState extends ConsumerState<_MatchFlowCard> {
  bool _contentsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final flow = widget.flow;
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
                      l10n.matchFlowSongCount(flow.songs.length),
                    ),
                  ),
                ),
                Switch(
                  value: flow.flow.enabled,
                  onChanged: (value) => _run(
                    context,
                    ref,
                    () async {
                      if (!value && mounted) {
                        setState(() {
                          _contentsExpanded = false;
                        });
                      }
                      await ref
                          .read(matchFlowDaoProvider)
                          .setFlowEnabled(flow.flow.id, enabled: value);
                    },
                  ),
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
                flow: flow,
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
    final adjusted = oldIndex < newIndex ? newIndex - 1 : newIndex;
    final songId = flow.songs[oldIndex].link.songId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _run(
          context,
          ref,
          () => ref
              .read(matchFlowDaoProvider)
              .reorderSong(flow.flow.id, songId, newIndex: adjusted),
        ),
      );
    });
  }

  Future<void> _rename(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: widget.flow.flow.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.matchFlowRenameTitle),
        content: TextField(
          controller: controller,
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
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.matchFlowDeleteTitle),
        content: Text(l10n.matchFlowDeleteMessage(widget.flow.flow.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(matchFlowDaoProvider).deleteFlow(widget.flow.flow.id),
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
    } on MatchFlowException catch (error) {
      if (!context.mounted) return;
      showAppNotice(
        context,
        message: error.message,
        level: AppNoticeLevel.info,
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showAppNotice(
        context,
        message: l10n.matchFlowSaveError(error.toString()),
        level: AppNoticeLevel.error,
      );
    }
  }
}

class _MatchFlowContents extends StatelessWidget {
  const _MatchFlowContents({
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
  Widget build(BuildContext context) {
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
              ReorderableListView.builder(
                shrinkWrap: true,
                primary: false,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: flow.songs.length,
                onReorder: onReorder,
                itemBuilder: (context, index) {
                  final entry = flow.songs[index];
                  return _MatchFlowSongTile(
                    key: ValueKey('${flow.flow.id}-${entry.link.songId}'),
                    entry: entry,
                    index: index,
                    onRemove: () => onRemove(entry.link.songId),
                  );
                },
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.push(
                  '/settings/playback/match-flow/${flow.flow.id}/search',
                ),
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

class _MatchFlowSongTile extends StatelessWidget {
  const _MatchFlowSongTile({
    required super.key,
    required this.entry,
    required this.index,
    required this.onRemove,
  });

  final MatchFlowSongEntry entry;
  final int index;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = entry.song;
    final title =
        song?.title ?? l10n.matchFlowUnresolvedSong(entry.link.songId);
    final subtitle = song == null
        ? entry.link.songId
        : [
            song.artistName,
            song.albumName,
          ].where((value) => value != null && value.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          if (song == null)
            const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.music_note_outlined),
            )
          else
            SizedBox(
              width: 44,
              height: 44,
              child: CoverArtImage(
                coverArtId: song.coverArt,
                size: 80,
                borderRadius: BorderRadius.circular(6),
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
                        style: Theme.of(context).textTheme.bodyLarge,
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
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.commonRemove,
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: l10n.commonReorder,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FlowAction { rename, delete }
