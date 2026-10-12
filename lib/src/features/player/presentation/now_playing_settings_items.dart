part of 'now_playing_screen.dart';

/// The Now Playing settings rows shared by the phone modal sheet and the wide
/// panel: Sound (speed/pitch, equalizer), then rating, lyrics, navigation,
/// playlist and download rows.
///
/// The two hosts differ only in how their actions are reached, so each passes
/// explicit callbacks:
/// * [onOpenSpeedPitch] opens the Speed & Pitch panel from the tapped tile.
/// * [onOpenEqualizerFullPage] is the equalizer card's full-page action.
/// * [onOpenFullscreenLyrics] is null when the lyrics row is not offered.
/// * [beforeNavigate] runs before Go to album/artist (phone: dismiss the
///   sheet; wide: collapse the panel).
/// * [beforeAction] runs before the playlist, delete and download actions
///   (phone: dismiss the sheet; wide: nothing).
///
/// [ref] feeds the watched state; [actionRef] performs actions that outlive
/// the host (the phone sheet is gone by then, so it passes the caller's ref).
List<Widget> _nowPlayingSettingsItems(
  BuildContext context,
  WidgetRef ref, {
  required WidgetRef actionRef,
  required SongsTableData? song,
  required void Function(BuildContext tileContext) onOpenSpeedPitch,
  required VoidCallback? onOpenEqualizerFullPage,
  required EdgeInsets equalizerCardPadding,
  required bool dimRemoteRatingTile,
  required VoidCallback? onOpenFullscreenLyrics,
  required VoidCallback beforeNavigate,
  required VoidCallback beforeAction,
}) {
  final l10n = AppLocalizations.of(context)!;
  final currentSongRating = song == null
      ? null
      : ref.watch(songRatingProvider(song.id)).asData?.value;
  final isRemote = song != null && !isServerAddressableSongId(song.id);
  final songDownloadState = song == null
      ? SongDownloadState.none
      : ref.watch(songDownloadStateProvider(song.id));
  final disabledColor = Theme.of(context).colorScheme.onSurface
      .withValues(alpha: 0.38);
  final eqSupported = ref.watch(eqCapabilitiesProvider).supported;

  return <Widget>[
    _NowPlayingSoundSectionLabel(label: l10n.nowPlayingSoundSection),
    Builder(
      builder: (tileContext) => ListTile(
        key: const ValueKey('playbackAdjustmentEntryPoint'),
        leading: const Icon(Icons.speed),
        title: Text(l10n.playbackSpeedPitchTitle),
        subtitle: const PlaybackAdjustmentSummary(),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onOpenSpeedPitch(tileContext),
      ),
    ),
    if (eqSupported)
      Padding(
        padding: equalizerCardPadding,
        child: EqQuickCard(onOpenFullPage: onOpenEqualizerFullPage),
      )
    else
      const EqualizerEntry(),
    const Divider(height: 1),
    if (song != null)
      ListTile(
        iconColor: dimRemoteRatingTile && isRemote ? disabledColor : null,
        textColor: dimRemoteRatingTile && isRemote ? disabledColor : null,
        leading: const Icon(Icons.star_outline),
        title: Text(l10n.ratingTitle),
        subtitle: Text(l10n.ratingHint),
        trailing: isRemote
            ? IgnorePointer(
                child: Opacity(
                  opacity: 0.38,
                  child: RatingWidget(
                    rating: currentSongRating,
                    compact: true,
                    onChanged: (_) {},
                  ),
                ),
              )
            : RatingWidget(
                rating: currentSongRating,
                compact: true,
                onChanged: (next) {
                  unawaited(
                    setSongRating(song.id, next, ref).catchError((_) {
                      if (context.mounted) {
                        showAppNotice(
                          context,
                          message: l10n.ratingUpdateFailed,
                          level: AppNoticeLevel.error,
                        );
                      }
                    }),
                  );
                },
              ),
        onTap: isRemote
            ? () => showAppNotice(
                context,
                message: l10n.remoteSourceActionUnavailable,
                level: AppNoticeLevel.error,
              )
            : null,
      ),
    if (onOpenFullscreenLyrics != null)
      ListTile(
        leading: const Icon(Icons.fullscreen),
        title: Text(l10n.nowPlayingLyrics),
        onTap: onOpenFullscreenLyrics,
      ),
    if (song != null &&
        ((song.albumId ?? '').trim().isNotEmpty ||
            (song.albumName ?? '').trim().isNotEmpty))
      ListTile(
        leading: const Icon(Icons.album_outlined),
        title: Text(l10n.nowPlayingGoToAlbum),
        onTap: () {
          beforeNavigate();
          unawaited(
            NormalPlaybackMetadataNavigator.goToAlbum(
              context,
              actionRef,
              song: song,
            ),
          );
        },
      ),
    if (song != null &&
        ((song.artistId ?? '').trim().isNotEmpty ||
            (song.artistName ?? '').trim().isNotEmpty))
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: Text(l10n.nowPlayingGoToArtist),
        onTap: () {
          beforeNavigate();
          unawaited(
            NormalPlaybackMetadataNavigator.goToArtist(
              context,
              actionRef,
              song: song,
            ),
          );
        },
      ),
    if (song != null)
      ListTile(
        leading: const Icon(Icons.playlist_add),
        title: Text(l10n.librarySongMenuAddToPlaylist),
        onTap: () {
          beforeAction();
          unawaited(showAddToPlaylistSheet(context, actionRef, [song.id]));
        },
      ),
    if (song != null &&
        songDownloadState.status == SongDownloadStatus.downloaded)
      ListTile(
        leading: Icon(
          Icons.delete_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(
          l10n.deleteDownloadAction,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        onTap: () {
          beforeAction();
          unawaited(confirmAndDeleteDownload(context, ref, song.id));
        },
      )
    else if (song != null &&
        songDownloadState.status != SongDownloadStatus.queued &&
        songDownloadState.status != SongDownloadStatus.downloading)
      ListTile(
        iconColor: isRemote ? disabledColor : null,
        textColor: isRemote ? disabledColor : null,
        leading: const Icon(Icons.download_outlined),
        title: Text(l10n.downloadAction),
        onTap: () async {
          if (isRemote) {
            showAppNotice(
              context,
              message: l10n.remoteSourceActionUnavailable,
              level: AppNoticeLevel.error,
            );
            return;
          }
          beforeAction();
          await downloadSongWithQualityPrompt(context, actionRef, song.id);
        },
      ),
  ];
}
