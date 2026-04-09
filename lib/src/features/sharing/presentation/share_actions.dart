import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/sharing/domain/share_content.dart';
import 'package:navis/src/features/sharing/presentation/share_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shares a song via the system share sheet.
Future<void> shareSong(
  BuildContext context,
  WidgetRef ref,
  SongsTableData song, {
  bool copyOnly = false,
}) async {
  final content = ShareContent.song(
    title: song.title,
    artist: song.artistName ?? 'Unknown Artist',
    album: song.albumName,
    coverArtId: song.coverArt,
  );
  await _executeShare(
    context,
    ref,
    content,
    entityId: song.id,
    copyOnly: copyOnly,
  );
}

/// Shares an album. Fetches album data from the provider first.
Future<void> shareAlbum(
  BuildContext context,
  WidgetRef ref,
  String albumId, {
  bool copyOnly = false,
}) async {
  final album = await ref.read(albumProvider(albumId).future);
  if (album == null) return;
  final content = ShareContent.album(
    name: album.album.name,
    artist: album.album.artistName ?? 'Unknown Artist',
    coverArtId: album.album.coverArt,
  );
  await _executeShare(
    context,
    ref,
    content,
    entityId: albumId,
    copyOnly: copyOnly,
  );
}

/// Shares an artist. Fetches artist data from the API first.
Future<void> shareArtist(
  BuildContext context,
  WidgetRef ref,
  String artistId, {
  bool copyOnly = false,
}) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) return;
  final artist = await api.getArtist(artistId);
  final content = ShareContent.artist(
    name: artist.name,
    coverArtId: artist.coverArt,
  );
  await _executeShare(
    context,
    ref,
    content,
    entityId: artistId,
    copyOnly: copyOnly,
  );
}

/// Shares a playlist. Fetches playlist data from the API first.
Future<void> sharePlaylist(
  BuildContext context,
  WidgetRef ref,
  String playlistId, {
  bool copyOnly = false,
}) async {
  final api = ref.read(subsonicApiProvider);
  if (api == null) return;
  final playlist = await api.getPlaylist(playlistId);
  final content = ShareContent.playlist(
    name: playlist.name,
    owner: playlist.owner,
    coverArtId: playlist.coverArt,
  );
  await _executeShare(
    context,
    ref,
    content,
    entityId: playlistId,
    copyOnly: copyOnly,
  );
}

Future<void> _executeShare(
  BuildContext context,
  WidgetRef ref,
  ShareContent content, {
  String? entityId,
  required bool copyOnly,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // Capture before any async gap — the triggering widget (e.g. context menu)
  // may be unmounted by the time the await returns.
  final noticeController = AppNoticeScope.maybeOf(context);

  try {
    final service = ref.read(shareServiceProvider);
    if (copyOnly) {
      await service.copyLink(content, entityId: entityId);
      noticeController?.show(message: l10n.linkCopied);
    } else {
      await service.share(content, entityId: entityId, context: context);
    }
  } catch (e) {
    noticeController?.show(message: l10n.shareError);
  }
}
