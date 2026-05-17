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

class _MatchFlowCard extends ConsumerWidget {
  const _MatchFlowCard({required this.flow});

  final MatchFlowWithSongs flow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
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
                    () => ref
                        .read(matchFlowDaoProvider)
                        .setFlowEnabled(flow.flow.id, enabled: value),
                  ),
                ),
                PopupMenuButton<_FlowAction>(
                  onSelected: (action) => switch (action) {
                    _FlowAction.rename => _rename(context, ref),
                    _FlowAction.delete => _delete(context, ref),
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
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: flow.songs.length,
                onReorder: (oldIndex, newIndex) {
                  final adjusted = oldIndex < newIndex
                      ? newIndex - 1
                      : newIndex;
                  final songId = flow.songs[oldIndex].link.songId;
                  unawaited(
                    _run(
                      context,
                      ref,
                      () => ref
                          .read(matchFlowDaoProvider)
                          .reorderSong(
                            flow.flow.id,
                            songId,
                            newIndex: adjusted,
                          ),
                    ),
                  );
                },
                itemBuilder: (context, index) {
                  return _MatchFlowSongTile(
                    key: ValueKey(
                      '${flow.flow.id}-${flow.songs[index].link.songId}',
                    ),
                    entry: flow.songs[index],
                    index: index,
                    onRemove: () => _run(
                      context,
                      ref,
                      () => ref
                          .read(matchFlowDaoProvider)
                          .removeSong(
                            flow.flow.id,
                            flow.songs[index].link.songId,
                          ),
                    ),
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

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: flow.flow.name);
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
      () => ref.read(matchFlowDaoProvider).renameFlow(flow.flow.id, name),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.matchFlowDeleteTitle),
        content: Text(l10n.matchFlowDeleteMessage(flow.flow.name)),
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
      () => ref.read(matchFlowDaoProvider).deleteFlow(flow.flow.id),
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
    return ListTile(
      leading: song == null
          ? const Icon(Icons.music_note_outlined)
          : SizedBox(
              width: 44,
              height: 44,
              child: CoverArtImage(
                coverArtId: song.coverArt,
                size: 80,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: l10n.commonRemove,
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
          ReorderableDragStartListener(
            index: index,
            child: IconButton(
              tooltip: l10n.commonReorder,
              onPressed: () {},
              icon: const Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FlowAction { rename, delete }
