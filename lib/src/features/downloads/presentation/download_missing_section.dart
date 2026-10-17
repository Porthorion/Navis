import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/downloads/domain/backfill_progress.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Downloads settings section listing downloaded songs and albums that still
/// lack lyrics or artwork, with a manual Backfill now action.
class DownloadMissingSection extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final gapsState = ref.watch(downloadMetadataGapsProvider);
    final gaps = gapsState.value;
    final hasApiClient = ref.watch(subsonicApiProvider) != null;
    final progress =
        ref.watch(downloadBackfillProgressProvider).value ??
        const BackfillProgress();
    // The counts come from disk, so refresh them whenever a pass ends.
    ref.listen(downloadBackfillProgressProvider, (previous, next) {
      final before = previous?.value?.phase;
      if (before != null &&
          before != BackfillPhase.idle &&
          next.value?.phase == BackfillPhase.idle) {
        ref.invalidate(downloadMetadataGapsProvider);
      }
    });
    final running = progress.phase != BackfillPhase.idle;
    final blocked = switch (progress.blockedReason) {
      BackfillBlockedReason.none => null,
      BackfillBlockedReason.offline => l10n.downloadsBackfillOffline,
      BackfillBlockedReason.wifiOnly => l10n.downloadsBackfillWifiOnly,
      BackfillBlockedReason.rateLimited => l10n.downloadsBackfillRateLimited,
    };
    final result = progress.lastResult;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.downloadsMissingTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (gapsState.isLoading)
          ListTile(title: Text(l10n.commonLoading))
        else if (gapsState.hasError)
          ListTile(title: Text(l10n.downloadsMissingCheckError)),
        if (gaps != null &&
            gaps.songsMissingLyrics.isEmpty &&
            gaps.albumsMissingArtwork.isEmpty)
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: Text(l10n.downloadsMissingNone),
          ),
        if (gaps != null && gaps.songsMissingLyrics.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.lyrics_outlined),
            title: Text(
              l10n.downloadsMissingLyricsCount(gaps.songsMissingLyrics.length),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openList(context, l10n.downloadsMissingSongsTitle, [
              for (final song in gaps.songsMissingLyrics)
                (title: song.title, artist: song.artist),
            ]),
          ),
        if (gaps != null && gaps.albumsMissingArtwork.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.image_not_supported_outlined),
            title: Text(
              l10n.downloadsMissingArtworkCount(
                gaps.albumsMissingArtwork.length,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openList(context, l10n.downloadsMissingAlbumsTitle, [
              for (final album in gaps.albumsMissingArtwork)
                (title: album.name, artist: album.artist),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                  onPressed: running || !hasApiClient
                      ? null
                      : () =>
                            ref.read(downloadServiceProvider).runBackfillNow(),
                  child: Text(l10n.downloadsBackfillNow),
                ),
              ),
              if (running) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  progress.phase == BackfillPhase.lyrics
                      ? l10n.downloadsBackfillLyrics
                      : l10n.downloadsBackfillArtwork,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  l10n.downloadsBackfillProgress(progress.done, progress.total),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: progress.total > 0
                      ? progress.done / progress.total
                      : null,
                ),
              ],
              if (blocked != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(blocked, style: theme.textTheme.bodySmall),
              ],
              if (!running &&
                  (result.lyricsResolved > 0 ||
                      result.artworkStored > 0)) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  l10n.downloadsBackfillResult(
                    result.lyricsResolved,
                    result.artworkStored,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _openList(
    BuildContext context,
    String title,
    List<({String title, String? artist})> rows,
  ) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(
            children: <Widget>[
              for (final row in rows)
                ListTile(
                  title: Text(row.title),
                  subtitle: row.artist == null || row.artist!.isEmpty
                      ? null
                      : Text(row.artist!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
