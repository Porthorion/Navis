import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/providers/app_providers.dart';

class NowPlayingLyricsScreen extends ConsumerWidget {
  const NowPlayingLyricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playback = ref.watch(playerStateProvider);
    final songId = playback.currentSongId;
    final position =
        ref.watch(playbackPositionProvider).asData?.value ?? playback.position;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.lyricsTitle),
      ),
      body: songId == null
          ? Center(
              child: Text(
                l10n.lyricsNoneAvailable,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            )
          : _LyricsContent(
              songId: songId,
              position: position,
            ),
    );
  }
}

class _LyricsContent extends ConsumerWidget {
  const _LyricsContent({
    required this.songId,
    required this.position,
  });

  final String songId;
  final Duration position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lyricsAsync = ref.watch(lyricsProvider(songId));

    return lyricsAsync.when(
      data: (lyrics) => LyricsDisplayWidget(
        lyrics: lyrics,
        currentPosition: position,
        onSeek: (seekPosition) {
          final handler = ref.read(audioHandlerProvider);
          handler?.seek(seekPosition);
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) {
        final String message;
        final VoidCallback? onRetry;

        if (error is LyricsUnsupportedException) {
          message = l10n.lyricsUnsupported;
          onRetry = null;
        } else if (error is LyricsNetworkException) {
          message = l10n.lyricsError;
          onRetry = () => ref.invalidate(lyricsProvider(songId));
        } else {
          message = l10n.lyricsNoneAvailable;
          onRetry = null;
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
