import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cache_badge.dart';
import 'package:navis/src/providers/app_providers.dart';

class AlbumDownloadBadge extends ConsumerWidget {
  const AlbumDownloadBadge({required this.albumId, super.key});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(albumTileDownloadStateProvider(albumId));
    if (state.fullyDownloaded) {
      return const CacheBadge();
    }
    if (!state.queued) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final label = state.progress <= 0
        ? AppLocalizations.of(context)!.commonQueued
        : '${(state.progress * 100).round()}%';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.download_outlined,
              size: 12,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
