part of 'now_playing_screen.dart';

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
        centerTitle: true,
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
              textAlign: TextAlign.center,
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
              Expanded(child: PlaybackLyricsContent(songId: shownSongId)),
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
          Expanded(child: PlaybackLyricsContent(songId: songId)),
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
