import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Lyrics for [songId]: synced or plain lines with tap-to-seek, source and
/// attribution labels, and loading/error states. Shared by the inline, pinned
/// fullscreen, embedded and standalone lyrics surfaces. [maxSize] frames it as
/// a clamped square; leave it null for unframed content.
class PlaybackLyricsContent extends ConsumerWidget {
  const new({super.key, required this.songId, this.maxSize});

  final String songId;
  final double? maxSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lyricsAsync = ref.watch(lyricsProvider(songId));
    final lyrics = lyricsAsync.asData?.value.lyrics;
    // Rebuild on active-line changes only, not on every position tick.
    final position = ref.watch(
      playbackPositionProvider.select(
        (value) => lyricsActiveLinePosition(
          lyrics,
          value.asData?.value ?? ref.read(playerStateProvider).position,
        ),
      ),
    );

    Widget buildContent(LyricsResolution resolution) {
      return LyricsDisplayWidget(
        lyrics: resolution.lyrics,
        instrumental: resolution.instrumental,
        currentPosition: position,
        sourceLabel: _showExternalLyricsMeta(resolution)
            ? _lyricsSourceLabel(context, resolution.source)
            : null,
        attribution: _showExternalLyricsMeta(resolution)
            ? l10n.lyricsAttributionLrclib
            : null,
        onSeek: (seekPosition) {
          final handler = ref.read(audioHandlerProvider);
          unawaited(handler?.seek(seekPosition));
        },
      );
    }

    Widget withOptionalSquareFrame(Widget child) {
      final size = maxSize;
      if (size == null) {
        return child;
      }
      final framedSize = size.clamp(180.0, 680.0);
      return SizedBox(width: framedSize, height: framedSize, child: child);
    }

    return lyricsAsync.when(
      data: (resolution) => withOptionalSquareFrame(buildContent(resolution)),
      loading: () => withOptionalSquareFrame(
        const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) {
        final l10n = AppLocalizations.of(context)!;
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

        final errorView = Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.6),
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
        return withOptionalSquareFrame(errorView);
      },
    );
  }
}

String _lyricsSourceLabel(BuildContext context, LyricsSource source) {
  final l10n = AppLocalizations.of(context)!;
  return switch (source) {
    LyricsSource.serverSynced => l10n.lyricsSourceServerSynced,
    LyricsSource.serverPlain => l10n.lyricsSourceServerPlain,
    LyricsSource.lrclibSynced => l10n.lyricsSourceLrclibSynced,
    LyricsSource.lrclibPlain => l10n.lyricsSourceLrclibPlain,
  };
}

bool _showExternalLyricsMeta(LyricsResolution resolution) {
  if (!resolution.isExternal) {
    return false;
  }
  if (resolution.lyrics.structuredLyrics.isNotEmpty) {
    final lines = resolution.lyrics.structuredLyrics.first.line;
    return lines.any((line) => (line.value ?? '').trim().isNotEmpty);
  }
  return (resolution.lyrics.value ?? '').trim().isNotEmpty;
}
