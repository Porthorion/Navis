part of 'now_playing_screen.dart';

class _InlineLyrics extends ConsumerWidget {
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

/// The pinned fullscreen lyrics page. [songId] and [title] are the song it was
/// opened on; the page then follows the playing song like the standalone
/// lyrics route, so tap-to-seek always targets the lyrics on screen.
class _FullscreenLyricsPage extends ConsumerWidget {
  const new({required this.songId, required this.title});

  final String songId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playback = ref.watch(playerStateProvider);
    final playingSongId = playback.currentSongId?.trim();
    final shownSongId = playingSongId == null || playingSongId.isEmpty
        ? songId
        : playingSongId;
    final song = ref.watch(songByIdProvider(shownSongId)).asData?.value;
    final shownTitle = shownSongId == songId
        ? title
        : (song?.title ??
              ref.watch(currentMediaItemProvider).asData?.value?.title ??
              l10n.nowPlayingUnknownTrack);
    final backLabel = MaterialLocalizations.of(context).backButtonTooltip;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 108,
        leading: TextButton.icon(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
          label: Text(backLabel),
        ),
        title: Text(
          l10n.nowPlayingLyrics,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              shownTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: <Widget>[
              Expanded(child: _InlineLyrics(songId: shownSongId)),
              const SizedBox(height: 8),
              _TransportControls(
                playback: playback,
                isExternalSource: song?.isExternal ?? false,
                isRadio: playback.isRadioMode,
                compact: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmbeddedFullscreenLyricsPanel extends ConsumerWidget {
  const new({required this.songId, required this.playback});

  final String songId;
  final PlaybackSnapshot playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(songByIdProvider(songId)).asData?.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(
        children: <Widget>[
          Expanded(child: _InlineLyrics(songId: songId)),
          if (!playback.isRadioMode) ...<Widget>[
            const SizedBox(height: 8),
            _SeekBar(playback: playback),
          ],
          const SizedBox(height: 8),
          _TransportControls(
            playback: playback,
            isExternalSource: song?.isExternal ?? false,
            isRadio: playback.isRadioMode,
            compact: true,
          ),
        ],
      ),
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

String _formatPreferenceSummary(AppLocalizations l10n, SongsTableData? song) {
  if (song == null) return '-';
  final likedText = song.starred == null
      ? l10n.ratingNotLiked
      : l10n.actionLiked;
  final rating = song.userRating;
  if (rating == null || rating <= 0) {
    return '$likedText • ${l10n.ratingNoValue}';
  }
  return '$likedText • ${l10n.ratingValueShort(rating)}';
}
