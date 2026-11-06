import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/presentation/audio_quality_format.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Raised while the details wait for the network; the state stays an error so
/// opening the dialog asks again, and nothing is shown or logged.
class _MediaInfoDeferred implements Exception {
  const new();
}

/// The getSong fields the library DB does not keep (path, bit depth,
/// channels, BPM, comment). [mediaInfoPrefetchProvider] loads them when a
/// song starts and keeps them for the dialog. Null when the song is not on
/// the server or nobody is signed in.
///
/// Rebuilds only when the account changes (not on every Wi-Fi/cellular
/// flip), cancels its request when the song changes, and never retries by
/// itself: a failure is asked again once per dialog open.
final songServerDetailsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, songId) async {
      final account = ref.watch(
        serverConfigStateProvider.select((state) {
          final config = state.asData?.value;
          return config == null
              ? null
              : (url: config.url, username: config.username);
        }),
      );
      if (account == null) return null;
      if (!networkSettled(ref)) {
        kickAfterReconciliation(ref, ref.invalidateSelf);
        ref.listen(networkTypeProvider, (previous, next) {
          if (previous == NetworkType.offline && next != NetworkType.offline) {
            ref.invalidateSelf();
          }
        });
        throw const _MediaInfoDeferred();
      }
      final token = CancelToken();
      ref.onDispose(token.cancel);
      try {
        return await ref
            .read(subsonicApiProvider)
            ?.getSongPayload(songId, cancelToken: token);
      } on SubsonicNotFoundException {
        return null;
      } on Object catch (error) {
        if (ref.mounted && !token.isCancelled) {
          AppLogger.debug('Media info unavailable for $songId: $error');
        }
        rethrow;
      }
    }, retry: (_, _) => null);

/// Keeps the current song's media info ready: its row, server details and
/// album, so the dialog opens nearly complete (the admin-only rows follow
/// when the dialog asks for the admin flag). One request per song; the
/// previous song's request is cancelled when the next one starts.
final mediaInfoPrefetchProvider = Provider<void>((ref) {
  final (:isRadio, :songId) = ref.watch(
    playerStateProvider.select(
      (s) => (isRadio: s.isRadioMode, songId: s.currentSongId),
    ),
  );
  if (isRadio || songId == null || songId.isEmpty) return;
  final albumId = ref.watch(songByIdProvider(songId)).asData?.value?.albumId;
  if (albumId != null) ref.watch(albumProvider(albumId));
  ref.watch(songServerDetailsProvider(songId));
});

/// Opens the media info for the playing song: a dialog on desktop, a bottom
/// sheet elsewhere (the mobile branch of `showQuickPanel`). Every entry point
/// calls this: it asks again for details that failed or were deferred.
Future<void> showMediaInfo(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final songId = container.read(playerStateProvider).currentSongId;
  if (songId != null) {
    final details = songServerDetailsProvider(songId);
    if (container.exists(details) &&
        container.read(details).hasError &&
        !container.read(details).isLoading) {
      container.invalidate(details);
    }
  }
  if (resolveAdaptiveContextFor(context).desktopRuntime) {
    return showDialog<void>(
      context: context,
      builder: (_) => const MediaInfoView(sheet: false),
    );
  }
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: screenHeight * 0.88),
    builder: (_) => const MediaInfoView(sheet: true),
  );
}

/// Media information for the playing song, shared by the desktop dialog and
/// the phone sheet. Empty fields and groups are hidden.
class MediaInfoView extends ConsumerWidget {
  const new({required this.sheet, super.key});

  final bool sheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songId = ref.watch(playerStateProvider).currentSongId;
    final songAsync = songId == null
        ? null
        : ref.watch(songByIdProvider(songId));
    final song = songAsync?.asData?.value;
    final songMissing = song == null && !(songAsync?.isLoading ?? false);
    final albumId = song?.albumId;
    final album = albumId == null
        ? null
        : ref.watch(albumProvider(albumId)).asData?.value?.album;
    final detailsAsync = songId == null
        ? null
        : ref.watch(songServerDetailsProvider(songId));
    final details = detailsAsync?.asData?.value;
    // Remote tracks never use the server's answer, so they never wait for it.
    final remote =
        song != null &&
        (song.isExternal || !isServerAddressableSongId(song.id));
    final detailsNote = remote || detailsAsync == null
        ? null
        : detailsAsync.isLoading
        ? l10n.mediaInfoDetailsLoading
        : detailsAsync.hasError
        ? l10n.mediaInfoDetailsUnavailable
        : null;
    final isAdmin = ref.watch(serverUserIsAdminProvider).asData?.value ?? false;
    final downloaded =
        songId != null &&
        ref.watch(songDownloadStateProvider(songId)).status ==
            SongDownloadStatus.downloaded;
    final info = song == null
        ? null
        : buildMediaInfo(
            l10n: l10n,
            song: song,
            albumYear: album?.year,
            mediaItem: ref.watch(currentMediaItemProvider).asData?.value,
            details: details,
            isAdmin: isAdmin,
            downloaded: downloaded,
          );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MediaInfoHeader(song: song, info: info),
        if (info != null)
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _MediaInfoGroups(info: info, sheet: sheet),
                  if (detailsNote != null)
                    Text(
                      detailsNote,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          )
        else if (songMissing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(l10n.mediaInfoNoTrack),
          ),
      ],
    );
    final scoped = Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l10n.mediaInfoTrackInfoRow,
      child: body,
    );
    if (sheet) {
      return KeyedSubtree(
        key: const ValueKey<String>('mediaInfoSheet'),
        child: SafeArea(top: false, child: scoped),
      );
    }
    return Dialog(
      key: const ValueKey<String>('desktopMediaInfoDialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: scoped,
      ),
    );
  }
}

class _MediaInfoHeader extends StatelessWidget {
  const new({required this.song, required this.info});

  final SongsTableData? song;
  final MediaInfo? info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          if (song != null) ...<Widget>[
            CoverArtImage(
              coverArtId: song!.coverArt,
              size: 56,
              borderRadius: NavisRadius.mdAll,
              isExternalSource: info?.origin == MediaInfoOrigin.remote,
              remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    song?.title ?? l10n.mediaInfoTrackInfoRow,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (info != null && info!.subtitle.isNotEmpty)
                  Text(
                    info!.subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('mediaInfoClose'),
            tooltip: l10n.mediaInfoClose,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _MediaInfoGroups extends StatelessWidget {
  const new({required this.info, required this.sheet});

  final MediaInfo info;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final library = info.library.isEmpty
        ? null
        : _MediaInfoGroup(
            title: l10n.mediaInfoSectionLibrary,
            collapsible: sheet,
            child: _MediaInfoRows(rows: info.library),
          );
    final track = info.track.isEmpty
        ? null
        : _MediaInfoGroup(
            title: l10n.mediaInfoSectionTrack,
            child: _MediaInfoRows(rows: info.track),
          );
    final now = _MediaInfoGroup(
      title: l10n.mediaInfoNowPlaying,
      child: _NowPlayingBody(info: info),
    );
    final file = _MediaInfoGroup(
      title: info.fileTitle,
      note: info.fileNote,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (info.tiles.isNotEmpty) _MediaInfoTiles(tiles: info.tiles),
          if (info.admin.isNotEmpty) ...<Widget>[
            if (info.tiles.isNotEmpty) const SizedBox(height: 6),
            _MediaInfoRows(rows: info.admin),
          ],
        ],
      ),
    );
    if (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[now, file, ?track, ?library],
      );
    }
    // Desktop: what plays and the file on the left, the rest on the right,
    // so nothing scrolls at 800x600.
    final right = <Widget>[?track, ?library];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[now, file],
          ),
        ),
        if (right.isNotEmpty) ...<Widget>[
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: right,
            ),
          ),
        ],
      ],
    );
  }
}

class _MediaInfoGroup extends StatelessWidget {
  const new({
    required this.title,
    required this.child,
    this.note,
    this.collapsible = false,
  });

  final String title;
  final String? note;
  final Widget child;
  final bool collapsible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final titleText = Semantics(
      header: true,
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(color: colors.primary),
      ),
    );
    final noteText = note == null
        ? null
        : Text(
            note!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: NavisRadius.lgAll,
        ),
        child: collapsible
            ? Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: ValueKey<String>('mediaInfoGroup:$title'),
                  title: titleText,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  shape: const RoundedRectangleBorder(
                    borderRadius: NavisRadius.lgAll,
                  ),
                  collapsedShape: const RoundedRectangleBorder(
                    borderRadius: NavisRadius.lgAll,
                  ),
                  children: <Widget>[child],
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[titleText, ?noteText],
                    ),
                    const SizedBox(height: 6),
                    child,
                  ],
                ),
              ),
      ),
    );
  }
}

class _NowPlayingBody extends StatelessWidget {
  const new({required this.info});

  final MediaInfo info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(info.sourceLabel, style: theme.textTheme.titleSmall),
            Text(info.sourceNote, style: muted),
          ],
        ),
        if (info.chips.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (var i = 0; i < info.chips.length; i++)
                _Pill(label: info.chips[i], primary: i == 0),
            ],
          ),
        ],
        if (info.original != null) ...<Widget>[
          const SizedBox(height: 6),
          Semantics(
            container: true,
            label: '${l10n.mediaInfoOriginal}: ${info.original}',
            excludeSemantics: true,
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                Text(l10n.mediaInfoOriginal, style: muted),
                Text(info.original!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const new({required this.label, required this.primary});

  final String label;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: primary
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: NavisRadius.pillAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: primary ? colors.onPrimaryContainer : colors.onSurface,
          ),
        ),
      ),
    );
  }
}

class _MediaInfoTiles extends StatelessWidget {
  const new({required this.tiles});

  final List<MediaInfoRow> tiles;

  static const _columns = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        final width = (constraints.maxWidth - gap * (_columns - 1)) / _columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final tile in tiles)
              SizedBox(
                width: width,
                child: Semantics(
                  container: true,
                  label: '${tile.label}: ${tile.value}',
                  excludeSemantics: true,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: NavisRadius.smAll,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            tile.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(tile.value, style: theme.textTheme.titleSmall),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MediaInfoRows extends StatelessWidget {
  const new({required this.rows});

  final List<MediaInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Room for the label and its admin tag.
    final labelWidth = rows.any((row) => row.admin) ? 172.0 : 100.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Semantics(
              container: true,
              label:
                  '${row.label}${row.admin ? ' (${l10n.mediaInfoAdminTag})' : ''}'
                  ': ${row.value}',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: labelWidth,
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            row.label,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (row.admin) ...<Widget>[
                          const SizedBox(width: 6),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: colors.tertiary),
                              borderRadius: NavisRadius.xsAll,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Text(
                                l10n.mediaInfoAdminTag,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.tertiary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      row.value,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class MediaInfoRow {
  const new(this.label, this.value, {this.admin = false});
  final String label;
  final String value;

  /// Shown only to server admins; the row carries an "admin" tag.
  final bool admin;
}

enum MediaInfoOrigin { downloaded, server, remote }

/// What the media info shows, resolved from the library row, the player's
/// stream and the server answer. Each file fact comes from one source: the
/// library row, plus the server's getSong details when the file is the
/// library's own (never for remote tracks, whose ids the server does not
/// know).
class MediaInfo {
  const new({
    required this.origin,
    required this.subtitle,
    required this.sourceLabel,
    required this.sourceNote,
    required this.chips,
    required this.original,
    required this.fileTitle,
    required this.fileNote,
    required this.tiles,
    required this.admin,
    required this.library,
    required this.track,
  });

  final MediaInfoOrigin origin;

  /// Artist, album and year.
  final String subtitle;
  final String sourceLabel;
  final String sourceNote;

  /// The effective stream quality, format first.
  final List<String> chips;

  /// The original's quality when the stream is transcoded.
  final String? original;
  final String fileTitle;
  final String fileNote;
  final List<MediaInfoRow> tiles;
  final List<MediaInfoRow> admin;
  final List<MediaInfoRow> library;
  final List<MediaInfoRow> track;
}

/// Builds the media info with every empty field dropped. [details] is the raw
/// getSong payload; [mediaItem] carries the stream the player resolved for
/// the song; [downloaded] is whether a permanent download exists.
MediaInfo buildMediaInfo({
  required AppLocalizations l10n,
  required SongsTableData song,
  required int? albumYear,
  required MediaItem? mediaItem,
  required Map<String, dynamic>? details,
  required bool isAdmin,
  required bool downloaded,
}) {
  String? text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  int? positive(Object? raw) {
    final value = raw is num ? raw.round() : int.tryParse('$raw');
    return value != null && value > 0 ? value : null;
  }

  String? gain(double? db) =>
      db == null ? null : '${db > 0 ? '+' : ''}${db.toStringAsFixed(2)} dB';
  final trackGain = gain(song.replayGainTrackGain);
  final albumGain = gain(song.replayGainAlbumGain);

  final remote = song.isExternal || !isServerAddressableSongId(song.id);
  final origin = remote
      ? MediaInfoOrigin.remote
      : downloaded
      ? MediaInfoOrigin.downloaded
      : MediaInfoOrigin.server;
  // One source per group: the server's answer describes the library file, so
  // it never mixes into a remote track.
  final server = remote ? null : details;

  // A skip can leave the previous song's item for a moment.
  final extras = mediaItem?.id == song.id ? mediaItem?.extras : null;
  final transcoded =
      extras?['bridgeFormat'] != null || extras?['transcodingApplied'] == true;
  final sourceFormat =
      text(song.suffix)?.toUpperCase() ?? inferAudioFormat(song.contentType);
  final sourceBitRate = positive(song.bitRate);
  final storedFormat = audioFormatLabel(extras?['resolvedFormat'] as String?);
  final storedBitRate = positive(extras?['resolvedBitRate']);
  // A permanent download can be stored at another format or bitrate than the
  // library row: then the row and the server answer describe the original,
  // not the copy.
  final copyDiffers =
      origin == MediaInfoOrigin.downloaded &&
      ((storedFormat != null &&
              sourceFormat != null &&
              storedFormat.toLowerCase() != sourceFormat.toLowerCase()) ||
          (storedBitRate != null &&
              sourceBitRate != null &&
              storedBitRate < sourceBitRate));
  final replaced = transcoded || copyDiffers;
  final sampleRate = positive(song.sampleRate);
  // Bit depth is a lossless-file fact; lossy formats never show one.
  final bitDepth = isLosslessPlaybackFormat(sourceFormat)
      ? positive(server?['bitDepth'])
      : null;
  final channels = positive(server?['channelCount']);
  final size = positive(song.size);
  final duration = positive(song.duration);

  String? bits(int? depth) =>
      depth == null ? null : l10n.mediaInfoBitDepthValue(depth);
  List<String> quality({
    String? format,
    String? depth,
    int? rate,
    int? bitRate,
  }) => <String>[
    ?format,
    ?depth,
    if (rate != null) formatSampleRate(rate),
    if (bitRate != null && bitRate > 0) formatBitRate(bitRate),
  ];

  final streamedFormat =
      audioFormatLabel(
        (extras?['bridgeFormat'] ?? extras?['resolvedFormat']) as String?,
      ) ??
      sourceFormat;
  final streamedBitRate =
      (extras?['bridgeBitRate'] as int?) ??
      (extras?['resolvedBitRate'] as int?) ??
      sourceBitRate;
  final chips = quality(
    format: streamedFormat,
    // A transcode's sample rate and depth are unknown.
    depth: replaced ? null : bits(bitDepth),
    rate: replaced ? null : readSampleRateFromExtras(extras) ?? sampleRate,
    bitRate: streamedBitRate,
  );
  final original = replaced
      ? quality(
          format: sourceFormat,
          depth: bits(bitDepth),
          rate: sampleRate,
          bitRate: sourceBitRate,
        ).join(' • ')
      : null;

  final (sourceLabel, sourceNote) = switch (origin) {
    MediaInfoOrigin.remote => (
      l10n.mediaInfoSourceRemote,
      l10n.mediaInfoSourceRemoteNote,
    ),
    MediaInfoOrigin.downloaded => (
      l10n.mediaInfoSourceDownloaded,
      l10n.mediaInfoSourceDownloadedNote,
    ),
    MediaInfoOrigin.server when transcoded => (
      l10n.mediaInfoSourceTranscoded,
      l10n.mediaInfoSourceTranscodedNote,
    ),
    MediaInfoOrigin.server => (
      l10n.mediaInfoSourceServer,
      l10n.mediaInfoSourceServerNote,
    ),
  };
  final (fileTitle, fileNote) = switch (origin) {
    MediaInfoOrigin.remote => (
      l10n.mediaInfoFileRemote,
      l10n.mediaInfoFileRemoteNote,
    ),
    // A transcoded copy is not the file the facts describe.
    MediaInfoOrigin.downloaded when !replaced => (
      l10n.mediaInfoFileDownloaded,
      l10n.mediaInfoFileDownloadedNote,
    ),
    _ => (
      l10n.mediaInfoFileServer,
      replaced
          ? l10n.mediaInfoFileServerOriginalNote
          : l10n.mediaInfoFileServerNote,
    ),
  };

  return MediaInfo(
    origin: origin,
    subtitle: <String>[
      ?text(song.artistName),
      ?text(song.albumName),
      if (albumYear != null && albumYear > 0) '$albumYear',
    ].join(' · '),
    sourceLabel: sourceLabel,
    sourceNote: sourceNote,
    chips: chips,
    original: original == null || original.isEmpty ? null : original,
    fileTitle: fileTitle,
    fileNote: fileNote,
    tiles: <MediaInfoRow>[
      if (sourceFormat != null)
        MediaInfoRow(l10n.mediaInfoFormat, sourceFormat),
      if (sourceBitRate != null)
        MediaInfoRow(l10n.mediaInfoBitrate, formatBitRate(sourceBitRate)),
      if (sampleRate != null)
        MediaInfoRow(l10n.mediaInfoSampleRate, formatSampleRate(sampleRate)),
      if (bitDepth != null)
        MediaInfoRow(
          l10n.mediaInfoBitDepth,
          l10n.mediaInfoBitDepthValue(bitDepth),
        ),
      if (channels != null) MediaInfoRow(l10n.mediaInfoChannels, '$channels'),
      if (size != null) MediaInfoRow(l10n.mediaInfoSize, formatBytes(size)),
      if (duration != null)
        MediaInfoRow(l10n.mediaInfoDuration, formatSeconds(duration)),
    ],
    admin: <MediaInfoRow>[
      if (isAdmin)
        if (text(server?['path']) case final path?)
          MediaInfoRow(l10n.mediaInfoServerPath, path, admin: true),
    ],
    library: <MediaInfoRow>[
      if (song.playCount case final plays? when plays > 0)
        MediaInfoRow(l10n.mediaInfoPlayCount, '$plays'),
      if (song.userRating case final rating? when rating > 0)
        MediaInfoRow(l10n.ratingTitle, l10n.ratingValueShort(rating)),
      if (trackGain != null || albumGain != null)
        MediaInfoRow(
          l10n.mediaInfoReplayGain,
          <String>[
            if (trackGain != null) l10n.mediaInfoReplayGainTrack(trackGain),
            if (albumGain != null) l10n.mediaInfoReplayGainAlbum(albumGain),
          ].join(' • '),
        ),
      if (text(song.recordingMbid) case final id?)
        MediaInfoRow(l10n.mediaInfoRecordingId, id),
      if (text(song.albumMbid) case final id?)
        MediaInfoRow(l10n.mediaInfoAlbumId, id),
      if (text(song.artistMbid) case final id?)
        MediaInfoRow(l10n.mediaInfoArtistId, id),
      if (positive(server?['bpm']) case final bpm?)
        MediaInfoRow(l10n.mediaInfoBpm, '$bpm'),
      if (text(server?['comment']) case final comment?)
        MediaInfoRow(l10n.mediaInfoComment, comment),
    ],
    track: <MediaInfoRow>[
      if (song.genres case final genres? when genres.isNotEmpty)
        MediaInfoRow(l10n.libraryTabGenres, genres.join(', ')),
      if (positive(song.track) case final number?)
        MediaInfoRow(l10n.mediaInfoTrackNumber, '$number'),
      if (positive(song.discNumber) case final disc?)
        MediaInfoRow(l10n.mediaInfoDiscNumber, '$disc'),
    ],
  );
}
