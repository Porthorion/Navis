import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

class AlbumDownloadBadge extends ConsumerWidget {
  const new({required this.albumId, super.key});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(albumTileDownloadStateProvider(albumId));
    if (state.fullyDownloaded) {
      return const _CompletedAlbumBadge();
    }
    if (state.downloadedTrackCount > 0 && state.totalTrackCount > 0) {
      return _PartialAlbumBadge(
        downloadedTrackCount: state.downloadedTrackCount,
        totalTrackCount: state.totalTrackCount,
      );
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
        borderRadius: NavisShapeData.of(context).controlAll,
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

class _CompletedAlbumBadge extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(Icons.check, size: 16, color: theme.colorScheme.secondary),
      ),
    );
  }
}

class _PartialAlbumBadge extends StatelessWidget {
  const new({
    required this.downloadedTrackCount,
    required this.totalTrackCount,
  });

  final int downloadedTrackCount;
  final int totalTrackCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digitCount = totalTrackCount < 100
        ? 2
        : totalTrackCount.toString().length;
    final label =
        '${downloadedTrackCount.toString().padLeft(digitCount, '0')}/'
        '${totalTrackCount.toString().padLeft(digitCount, '0')}';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: NavisShapeData.of(context).controlAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: const Color(0xFFFFB84D),
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
