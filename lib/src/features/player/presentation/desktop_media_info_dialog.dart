import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/audio_quality_format.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';

/// The getSong fields the library DB does not keep (path, bit depth,
/// channels, BPM, comment), read once when the dialog opens. Null when the
/// server is unreachable or the song is not on it.
final songServerDetailsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, songId) async {
      final api = ref.watch(subsonicApiProvider);
      if (api == null) return null;
      try {
        return await api.getSongPayload(songId);
      } on Object {
        return null;
      }
    });

Future<void> showDesktopMediaInfoDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const DesktopMediaInfoDialog(),
  );
}

/// Media information for the playing song. Empty fields are hidden; the
/// Server section is for admins only.
class DesktopMediaInfoDialog extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songId = ref.watch(playerStateProvider).currentSongId;
    final song = songId == null
        ? null
        : ref.watch(songByIdProvider(songId)).asData?.value;
    final albumId = song?.albumId;
    final album = albumId == null
        ? null
        : ref.watch(albumProvider(albumId)).asData?.value?.album;
    final details = songId == null
        ? null
        : ref.watch(songServerDetailsProvider(songId)).asData?.value;
    final isAdmin = ref.watch(serverUserIsAdminProvider).asData?.value ?? false;
    final sections = song == null
        ? const <MediaInfoSection>[]
        : buildMediaInfoSections(
            l10n: l10n,
            song: song,
            albumYear: album?.year,
            mediaItem: ref.watch(currentMediaItemProvider).asData?.value,
            details: details,
            isAdmin: isAdmin,
          );
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey<String>('desktopMediaInfoDialog'),
      title: Text(l10n.mediaInfoTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final section in sections) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Semantics(
                    header: true,
                    child: Text(
                      section.title,
                      style: textTheme.titleSmall?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
                for (final row in section.rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Semantics(
                      container: true,
                      label: '${row.label}: ${row.value}',
                      excludeSemantics: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            width: 150,
                            child: Text(
                              row.label,
                              style: textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              row.value,
                              style: textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.mediaInfoClose),
        ),
      ],
    );
  }
}

class MediaInfoRow {
  const new(this.label, this.value);
  final String label;
  final String value;
}

class MediaInfoSection {
  const new(this.title, this.rows);
  final String title;
  final List<MediaInfoRow> rows;
}

/// The dialog's sections with every empty field and empty section dropped.
/// [details] is the raw getSong payload; [mediaItem] carries the stream the
/// player resolved for the song.
List<MediaInfoSection> buildMediaInfoSections({
  required AppLocalizations l10n,
  required SongsTableData song,
  required int? albumYear,
  required MediaItem? mediaItem,
  required Map<String, dynamic>? details,
  required bool isAdmin,
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

  final extras = mediaItem?.extras;
  final streamedFormat = audioFormatLabel(
    (extras?['bridgeFormat'] ?? extras?['resolvedFormat']) as String?,
  );
  final streamedBitRate =
      (extras?['bridgeBitRate'] as int?) ??
      (extras?['resolvedBitRate'] as int?);
  final transcoding =
      extras?['bridgeFormat'] != null || extras?['transcodingApplied'] == true;
  final sourceFormat =
      text(song.suffix)?.toUpperCase() ?? inferAudioFormat(song.contentType);
  final sourceBitRate = positive(song.bitRate);
  final sampleRate = positive(song.sampleRate);
  final bitDepth = positive(details?['bitDepth']);
  final channels = positive(details?['channelCount']);
  final size = positive(song.size);
  final duration = positive(song.duration);

  final sections = <MediaInfoSection>[
    MediaInfoSection(l10n.mediaInfoSectionTrack, <MediaInfoRow>[
      MediaInfoRow(l10n.trackColumnTitle, song.title),
      if (text(song.artistName) case final artist?)
        MediaInfoRow(l10n.libraryTabArtists, artist),
      if (text(song.albumName) case final album?)
        MediaInfoRow(l10n.trackColumnAlbum, album),
      if (albumYear != null && albumYear > 0)
        MediaInfoRow(l10n.mediaInfoYear, '$albumYear'),
      if (song.genres case final genres? when genres.isNotEmpty)
        MediaInfoRow(l10n.libraryTabGenres, genres.join(', ')),
    ]),
    MediaInfoSection(l10n.mediaInfoSectionFile, <MediaInfoRow>[
      if (sourceFormat != null)
        MediaInfoRow(l10n.mediaInfoFormat, sourceFormat),
      if (sourceBitRate != null)
        MediaInfoRow(l10n.mediaInfoBitrate, formatBitRate(sourceBitRate)),
      if (sampleRate != null)
        MediaInfoRow(l10n.mediaInfoSampleRate, formatSampleRate(sampleRate)),
      if (bitDepth != null) MediaInfoRow(l10n.mediaInfoBitDepth, '$bitDepth'),
      if (channels != null) MediaInfoRow(l10n.mediaInfoChannels, '$channels'),
      if (size != null) MediaInfoRow(l10n.mediaInfoSize, formatBytes(size)),
      if (duration != null)
        MediaInfoRow(l10n.mediaInfoDuration, formatSeconds(duration)),
    ]),
    if (transcoding)
      MediaInfoSection(l10n.mediaInfoSectionTranscode, <MediaInfoRow>[
        if (sourceFormat != null || sourceBitRate != null)
          MediaInfoRow(
            l10n.mediaInfoTranscodeSource,
            <String>[
              ?sourceFormat,
              if (sourceBitRate != null) formatBitRate(sourceBitRate),
            ].join(' • '),
          ),
        if (streamedFormat != null || streamedBitRate != null)
          MediaInfoRow(
            l10n.mediaInfoTranscodeStreamed,
            <String>[
              ?streamedFormat,
              if (streamedBitRate != null && streamedBitRate > 0)
                formatBitRate(streamedBitRate),
            ].join(' • '),
          ),
      ]),
    MediaInfoSection(l10n.mediaInfoSectionLibrary, <MediaInfoRow>[
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
      if (positive(details?['bpm']) case final bpm?)
        MediaInfoRow(l10n.mediaInfoBpm, '$bpm'),
      if (text(details?['comment']) case final comment?)
        MediaInfoRow(l10n.mediaInfoComment, comment),
    ]),
    if (isAdmin)
      MediaInfoSection(l10n.configurationServerSection, <MediaInfoRow>[
        if (text(details?['path']) case final path?)
          MediaInfoRow(l10n.mediaInfoServerPath, path),
      ]),
  ];
  return sections.where((s) => s.rows.isNotEmpty).toList(growable: false);
}
