import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';

/// Keeps identified tracks visible when source preparation cannot queue them.
class QueueUnavailableTracks extends ConsumerWidget {
  const QueueUnavailableTracks({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(retainedArtistQueueProvider);
    final l10n = AppLocalizations.of(context)!;
    final color = Theme.of(context).disabledColor;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < songs.length; index++)
          ListTile(
            key: ValueKey('unavailable-$index-${songs[index].id}'),
            leading: Icon(Icons.music_off_outlined, color: color),
            title: Text(songs[index].title, style: TextStyle(color: color)),
            subtitle: Text(
              l10n.queueTrackUnavailable,
              style: TextStyle(color: color),
            ),
            trailing: IconButton(
              tooltip: l10n.commonRemove,
              icon: const Icon(Icons.close),
              onPressed: () => ref
                  .read(retainedArtistQueueProvider.notifier)
                  .removeAt(index),
            ),
          ),
      ],
    );
  }
}
