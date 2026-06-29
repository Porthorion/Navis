import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Top Tracks section for the artist detail page, powered by Last.fm.
///
/// Shows 5 tracks by default with a "Show more" button that expands the list
/// to 10.  Only rendered when a Last.fm API key is configured at build time.
class ArtistTopTracksSection extends ConsumerStatefulWidget {
  const ArtistTopTracksSection({required this.artistName, super.key});

  final String artistName;

  @override
  ConsumerState<ArtistTopTracksSection> createState() =>
      _ArtistTopTracksSectionState();
}

class _ArtistTopTracksSectionState extends ConsumerState<ArtistTopTracksSection>
    with AutomaticKeepAliveClientMixin {
  bool _expanded = false;
  bool _playing = false;

  @override
  bool get wantKeepAlive => true;

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  Future<void> _onTrackTap(
    BuildContext context,
    ResolvedArtistTopTrack track,
    List<ResolvedArtistTopTrack> availableTracks,
  ) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      // Fast path: pre-resolved local song.
      if (track.resolvedSong != null) {
        _playResolvedTrack(track, availableTracks);
        return;
      }

      // Slow path: live search3 on tap.
      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        _showNotAvailable(context);
        return;
      }

      final query = '${track.title} ${track.artist}'.trim();
      final result = await api.search3(
        query: query,
        artistCount: 0,
        albumCount: 0,
        songCount: 5,
      );

      // Reuse the same matching logic as the provider.
      final rawTrack = LastFmArtistTopTrack(
        rank: track.rank,
        title: track.title,
        artist: track.artist,
        listeners: track.listeners,
      );
      final playable = pickBestArtistTopTrackMatch(
        track: rawTrack,
        candidates: result.songs,
      );

      if (playable == null) {
        AppLogger.debug(
          'ArtistTopTracksSection: no playable match for '
          '"${track.title}" by "${track.artist}"',
        );
        if (context.mounted) _showNotAvailable(context);
        return;
      }

      await ref.read(queueProvider.notifier).replaceWithSongs([playable]);
    } on SubsonicConnectionException {
      if (context.mounted) _showNotAvailable(context);
    } on Object catch (e) {
      AppLogger.debug('ArtistTopTracksSection: play error: $e');
      if (context.mounted) _showPlayError(context);
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  void _playResolvedTrack(
    ResolvedArtistTopTrack track,
    List<ResolvedArtistTopTrack> availableTracks,
  ) {
    final tappedSong = track.resolvedSong;
    if (tappedSong == null) return;

    final queueTopTracks = ref.read(albumQueueEnabledProvider);
    final queueController = ref.read(queueProvider.notifier);
    final queueSongs = availableTracks
        .map((candidate) => candidate.resolvedSong)
        .nonNulls
        .toList(growable: false);

    if (queueTopTracks && queueSongs.length > 1) {
      final startIndex = queueSongs.indexWhere(
        (song) => song.id == tappedSong.id,
      );
      queueController.fireAndForget(
        () => queueController.replaceWithSongs(
          queueSongs,
          startIndex: startIndex < 0 ? 0 : startIndex,
          autoPlay: true,
        ),
        label: 'playNow',
      );
      return;
    }

    queueController.fireAndForget(
      () => queueController.replaceWithSongs([tappedSong]),
      label: 'playNow',
    );
  }

  void _showNotAvailable(BuildContext context) {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.artistTopTracksNotAvailable,
      level: AppNoticeLevel.info,
    );
  }

  void _showPlayError(BuildContext context) {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.artistTopTracksPlayError,
      level: AppNoticeLevel.error,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final asyncTracks = ref.watch(
      artistTopTracksProvider(widget.artistName),
    );

    return asyncTracks.when(
      skipLoadingOnReload: true,
      data: (tracks) {
        final resolved = tracks
            .where((t) => t.isLocallyResolved)
            .toList(growable: false);
        if (resolved.isEmpty) return const SizedBox.shrink();
        return _TrackList(
          tracks: resolved,
          expanded: _expanded,
          playing: _playing,
          l10n: l10n,
          onToggleExpanded: () => setState(() => _expanded = !_expanded),
          onTrackTap: (track) => _onTrackTap(context, track, resolved),
        );
      },
      loading: () => const _TopTracksShimmer(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

// ---------------------------------------------------------------------------
// Private: track list panel
// ---------------------------------------------------------------------------

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.tracks,
    required this.expanded,
    required this.playing,
    required this.l10n,
    required this.onToggleExpanded,
    required this.onTrackTap,
  });

  final List<ResolvedArtistTopTrack> tracks;
  final bool expanded;
  final bool playing;
  final AppLocalizations l10n;
  final VoidCallback onToggleExpanded;
  final void Function(ResolvedArtistTopTrack) onTrackTap;

  @override
  Widget build(BuildContext context) {
    final visibleCount =
        (expanded ? kArtistTopTracksMax : kArtistTopTracksCollapsed).clamp(
          0,
          tracks.length,
        );
    final visible = tracks.take(visibleCount).toList(growable: false);
    final canExpand = tracks.length > kArtistTopTracksCollapsed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.artistTopTracksSection,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: visible
                  .map(
                    (track) => _TopTrackTile(
                      track: track,
                      enabled: !playing,
                      onTap: () => onTrackTap(track),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          if (canExpand)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onToggleExpanded,
                icon: Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                ),
                label: Text(
                  expanded
                      ? l10n.artistTopTracksShowLess
                      : l10n.artistTopTracksShowMore,
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private: individual track tile
// ---------------------------------------------------------------------------

class _TopTrackTile extends ConsumerWidget {
  const _TopTrackTile({
    required this.track,
    required this.enabled,
    required this.onTap,
  });

  final ResolvedArtistTopTrack track;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final rankText = '${track.rank}';
    final subtitle = track.listeners != null
        ? _formatListeners(track.listeners!, context)
        : null;

    // Watch DB row for the resolved song (needed for context menu).
    final resolvedId = track.resolvedSong?.id;
    final dbSong = resolvedId != null
        ? ref.watch(songByIdProvider(resolvedId)).asData?.value
        : null;

    // ── Leading: rank number + album art thumbnail ──────────────────────
    final leading = SizedBox(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 28,
            child: Center(
              child: Text(
                rankText,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            height: 40,
            child: CoverArtImage(
              coverArtId: track.resolvedSong?.coverArt,
              size: 80,
              borderRadius: BorderRadius.circular(4),
              placeholderIcon: Icons.music_note_outlined,
              showLoadingPlaceholder: false,
            ),
          ),
        ],
      ),
    );

    // ── Trailing: download status + 3-dot menu (resolved tracks only) ───
    Widget? trailing;
    if (resolvedId != null) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SongDownloadStatusIcon(
            songId: resolvedId,
            onDownload: () => _downloadSong(context, ref, resolvedId),
            size: 20,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
            onPressed: dbSong != null
                ? () => unawaited(
                    showSongContextMenu(context, ref, dbSong),
                  )
                : null,
          ),
        ],
      );
    }

    // ── Tile ────────────────────────────────────────────────────────────
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      enabled: enabled,
      onTap: onTap,
      onLongPress: dbSong != null
          ? () {
              HapticFeedback.mediumImpact();
              unawaited(showSongContextMenu(context, ref, dbSong));
            }
          : null,
      minLeadingWidth: 76,
      leading: leading,
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
              ),
            )
          : null,
      trailing: trailing,
    );

    // Wrap with GestureDetector to support desktop right-click context menu.
    if (dbSong == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) => unawaited(
        showSongContextMenu(
          context,
          ref,
          dbSong,
          anchor: details.globalPosition,
        ),
      ),
      child: tile,
    );
  }

  void _downloadSong(BuildContext context, WidgetRef ref, String songId) {
    unawaited(
      () async {
        final choice = await showDownloadQualitySheet(context);
        if (choice == null || !context.mounted) return;
        unawaited(
          ref
              .read(downloadServiceProvider)
              .enqueueSong(
                songId,
                quality: choice.quality,
                format: choice.format,
              ),
        );
        if (!context.mounted) return;
        showAppNotice(
          context,
          message: AppLocalizations.of(context)!.downloadSongQueued,
          level: AppNoticeLevel.success,
        );
      }(),
    );
  }

  String _formatListeners(int count, BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final formatted = switch (count) {
      >= 1000000 => '${(count / 1000000).toStringAsFixed(1)}M',
      >= 1000 => '${(count / 1000).toStringAsFixed(0)}K',
      _ => '$count',
    };
    return l10n.artistTopTracksListeners(formatted);
  }
}

// ---------------------------------------------------------------------------
// Private: shimmer loading skeleton
// ---------------------------------------------------------------------------

class _TopTracksShimmer extends StatelessWidget {
  const _TopTracksShimmer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ShimmerPlaceholder(height: 22, width: 120),
          const SizedBox(height: 12),
          for (var i = 0; i < kArtistTopTracksCollapsed; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: <Widget>[
                  const ShimmerPlaceholder(height: 16, width: 24),
                  const SizedBox(width: 8),
                  const ShimmerPlaceholder(height: 40, width: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ShimmerPlaceholder(
                          height: 14,
                          width: double.infinity,
                        ),
                        const SizedBox(height: 6),
                        const ShimmerPlaceholder(height: 11, width: 80),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
