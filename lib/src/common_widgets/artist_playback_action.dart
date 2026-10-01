import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';

/// Starts an artist action beyond the lifetime of its menu or screen.
Future<void> startArtistPlayback(
  ProviderContainer container,
  String artistId,
  ArtistPlaybackAction action,
) => container
    .read(artistPlaybackControllerProvider.notifier)
    .prepare(artistId, action);

/// Shows compact, optional progress while the artist queue grows.
class ArtistPlaybackProgressIndicator extends ConsumerWidget {
  const new({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(artistPlaybackControllerProvider);
    if (!state.busy || state.artistId != artistId) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.progress.total == 0
                  ? l10n.artistPlaybackPreparing
                  : l10n.artistPlaybackProgress(
                      state.progress.completed,
                      state.progress.total,
                    ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            key: const ValueKey('artist-playback-cancel'),
            tooltip: l10n.commonCancel,
            onPressed: ref
                .read(artistPlaybackControllerProvider.notifier)
                .cancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}
