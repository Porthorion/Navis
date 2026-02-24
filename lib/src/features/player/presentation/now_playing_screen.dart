import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({
    super.key,
    this.onCollapse,
  });

  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playerStateProvider);
    final currentSongId = playback.currentSongId;
    final songAsync = currentSongId == null
        ? const AsyncValue<SongsTableData?>.data(null)
        : ref.watch(songByIdProvider(currentSongId));
    final song = songAsync.asData?.value;

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            _NowPlayingAppBar(song: song, onCollapse: onCollapse),
            Expanded(
              child: _NowPlayingBody(
                playback: playback,
                song: song,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingAppBar extends ConsumerWidget {
  const _NowPlayingAppBar({this.song, this.onCollapse});

  final SongsTableData? song;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: onCollapse ?? () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              l10n.nowPlayingTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.nowPlayingMore,
            onPressed: () => _showOverflowMenu(context, ref, song),
          ),
        ],
      ),
    );
  }

  void _showOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    SongsTableData? song,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (song?.albumId != null && song!.albumId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: Text(l10n.nowPlayingGoToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.goToAlbum(context, ref, song.albumId!);
                },
              ),
            if (song?.artistId != null && song!.artistId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(l10n.nowPlayingGoToArtist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.goToArtist(context, ref, song.artistId!);
                },
              ),
            if (song != null)
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(l10n.librarySongMenuAddToPlaylist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showAddToPlaylistSheet(context, ref, [song.id]);
                },
              ),
            if (song != null)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(l10n.downloadAction),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final choice =
                      await showDownloadQualitySheet(context);
                  if (choice == null || !context.mounted) return;
                  final service = ref.read(downloadServiceProvider);
                  await service.enqueueSong(
                    song.id,
                    quality: choice.quality,
                    format: choice.format,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.downloadSongQueued)),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody({
    required this.playback,
    this.song,
  });

  final PlaybackSnapshot playback;
  final SongsTableData? song;

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody> {
  bool _showLyrics = false;

  void _togglePlayPause() {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    if (widget.playback.playing) {
      unawaited(handler.pause());
    } else {
      unawaited(handler.play());
    }
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 300) return;
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;
    if (velocity < 0) {
      // Swipe left → next track
      unawaited(handler.skipToNext());
    } else {
      // Swipe right → previous track
      unawaited(handler.skipToPrevious());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final playback = widget.playback;
    final title = song?.title ?? l10n.nowPlayingUnknownTrack;
    final artist = song?.artistName ?? l10n.nowPlayingUnknownArtist;
    final album = song?.albumName ?? l10n.nowPlayingUnknownAlbum;

    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // During the expand/collapse animation the available height can be
          // very small (even <2 px). Rendering the full Column at that size
          // causes a RenderFlex overflow. Skip the layout entirely when there
          // isn't enough room — the content is invisible at that point anyway.
          if (constraints.maxHeight < 200) {
            return const SizedBox.shrink();
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: <Widget>[
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: _showLyrics && playback.currentSongId != null
                        ? _InlineLyrics(
                            songId: playback.currentSongId!,
                          )
                        : GestureDetector(
                            onTap: _togglePlayPause,
                            onHorizontalDragEnd: _handleHorizontalSwipe,
                            child: _CoverArt(coverArtId: song?.coverArt),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                _TrackInfo(title: title, artist: artist, album: album),
                const SizedBox(height: 16),
                _SeekBar(playback: playback),
                const SizedBox(height: 8),
                _TransportControls(playback: playback),
                const SizedBox(height: 8),
                _ActionRow(
                  songId: playback.currentSongId,
                  showLyrics: _showLyrics,
                  onLyricsToggle: () =>
                      setState(() => _showLyrics = !_showLyrics),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CoverArt extends StatelessWidget {
  const _CoverArt({this.coverArtId});

  final String? coverArtId;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final artSize = screenWidth - 48;
    final clampedSize = artSize.clamp(200.0, 400.0);

    return CoverArtImage(
      coverArtId: coverArtId,
      size: 640,
      width: clampedSize,
      height: clampedSize,
      borderRadius: BorderRadius.circular(12),
      placeholderIcon: Icons.music_note_outlined,
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.title,
    required this.artist,
    required this.album,
  });

  final String title;
  final String artist;
  final String album;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          artist,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          album,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar({required this.playback});

  final PlaybackSnapshot playback;

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _draggingValue;

  @override
  Widget build(BuildContext context) {
    final position =
        ref.watch(playbackPositionProvider).asData?.value ??
        widget.playback.position;
    final duration = widget.playback.duration;
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;

    final sliderValue =
        _draggingValue ??
        (durationMs > 0
            ? positionMs.toDouble().clamp(0, durationMs.toDouble())
            : 0.0);
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;

    return Column(
      children: <Widget>[
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: sliderValue.clamp(0, sliderMax),
            max: sliderMax,
            onChanged: (value) {
              setState(() => _draggingValue = value);
            },
            onChangeEnd: (value) {
              setState(() => _draggingValue = null);
              final handler = ref.read(audioHandlerProvider);
              unawaited(
                handler?.seek(Duration(milliseconds: value.round())),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                _formatDuration(
                  _draggingValue != null
                      ? Duration(milliseconds: _draggingValue!.round())
                      : position,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                _formatDuration(duration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TransportControls extends ConsumerWidget {
  const _TransportControls({required this.playback});

  final PlaybackSnapshot playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;
    final shuffleOn = playback.shuffleMode == AudioServiceShuffleMode.all;
    final repeatMode = playback.repeatMode;

    String repeatTooltip;
    IconData repeatIcon;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        repeatTooltip = l10n.nowPlayingRepeatOne;
        repeatIcon = Icons.repeat_one;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        repeatTooltip = l10n.nowPlayingRepeatAll;
        repeatIcon = Icons.repeat;
      case AudioServiceRepeatMode.none:
        repeatTooltip = l10n.nowPlayingRepeatOff;
        repeatIcon = Icons.repeat;
    }

    final isRepeatActive = repeatMode != AudioServiceRepeatMode.none;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          icon: Icon(
            Icons.shuffle,
            color: shuffleOn ? Theme.of(context).colorScheme.primary : null,
          ),
          tooltip: shuffleOn
              ? l10n.nowPlayingShuffle
              : l10n.nowPlayingShuffleOff,
          onPressed: () {
            final handler = ref.read(audioHandlerProvider);
            final next = shuffleOn
                ? AudioServiceShuffleMode.none
                : AudioServiceShuffleMode.all;
            unawaited(handler?.setShuffleMode(next));
          },
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.skip_previous, size: 32),
          tooltip: l10n.nowPlayingPrevious,
          onPressed: () {
            final handler = ref.read(audioHandlerProvider);
            unawaited(handler?.skipToPrevious());
          },
        ),
        const SizedBox(width: 8),
        FilledButton(
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(16),
          ),
          onPressed: () {
            final handler = ref.read(audioHandlerProvider);
            if (isPlaying) {
              unawaited(handler?.pause());
            } else {
              unawaited(handler?.play());
            }
          },
          child: Icon(
            isPlaying ? Icons.pause : Icons.play_arrow,
            size: 36,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.skip_next, size: 32),
          tooltip: l10n.nowPlayingNext,
          onPressed: () {
            final handler = ref.read(audioHandlerProvider);
            unawaited(handler?.skipToNext());
          },
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(
            repeatIcon,
            color: isRepeatActive
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: repeatTooltip,
          onPressed: () {
            final handler = ref.read(audioHandlerProvider);
            final next = switch (repeatMode) {
              AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
              AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
              AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
              AudioServiceRepeatMode.group => AudioServiceRepeatMode.none,
            };
            unawaited(handler?.setRepeatMode(next));
          },
        ),
      ],
    );
  }
}

class _InlineLyrics extends ConsumerWidget {
  const _InlineLyrics({
    required this.songId,
  });

  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lyricsAsync = ref.watch(lyricsProvider(songId));
    final position =
        ref.watch(playbackPositionProvider).asData?.value ??
        ref.watch(playerStateProvider).position;

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
      error: (_, _) => Center(
        child: Text(
          l10n.lyricsNoneAvailable,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends ConsumerWidget {
  const _ActionRow({
    this.songId,
    this.showLyrics = false,
    this.onLyricsToggle,
  });

  final String? songId;
  final bool showLyrics;
  final VoidCallback? onLyricsToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.favorite_border),
          tooltip: l10n.nowPlayingStar,
          onPressed: songId == null
              ? null
              : () {
                  // Star/unstar will be wired in a later increment
                },
        ),
        IconButton(
          icon: Icon(
            showLyrics ? Icons.lyrics : Icons.lyrics_outlined,
            color: showLyrics ? Theme.of(context).colorScheme.primary : null,
          ),
          tooltip: l10n.nowPlayingLyrics,
          onPressed: songId == null ? null : onLyricsToggle,
        ),
        IconButton(
          icon: const Icon(Icons.queue_music),
          tooltip: l10n.nowPlayingQueue,
          onPressed: () => NavService.showQueue(context),
        ),
      ],
    );
  }
}
